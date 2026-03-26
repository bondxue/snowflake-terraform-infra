# Requirements Document

## Introduction

This feature introduces config-driven management of Snowflake service users via Terraform. Service users are non-human accounts used by tools such as dbt, Fivetran, and Airflow to connect to Snowflake. Each service user is defined in a new `config/users.yml` file and follows the naming convention `SVC_<NAME>_<ENV>` (e.g. `SVC_DBT_DEV`). Authentication is via RSA key-pair (SNOWFLAKE_JWT), consistent with the existing provider configuration. The feature integrates with the existing YAML-driven, provider-alias pattern used throughout the project.

The implementation targets the following provider versions as defined in `providers.tf`:
- `snowflakedb/snowflake ~> 2.1.0`
- `hashicorp/aws ~> 5.100`

## Glossary

- **Service_User**: A non-human Snowflake user account used by an automated tool or service (e.g. dbt, Fivetran, Airflow).
- **User_Config**: The YAML definition of a service user in `config/users.yml`.
- **RSA_Public_Key**: The PEM-encoded RSA public key assigned to a Service_User for key-pair authentication.
- **Object_Prefix**: The environment/project prefix derived from `var.environment` and `var.project` (e.g. `DEV` or `DEV_MYPROJECT`).
- **Service_User_Name**: The fully-formed Snowflake username following the pattern `SVC_<NAME>_<ENV>` (e.g. `SVC_DBT_DEV`).
- **Default_Role**: The Snowflake role assigned as the default role for a Service_User.
- **Default_Warehouse**: The Snowflake warehouse assigned as the default warehouse for a Service_User.
- **Terraform_Config**: The set of YAML files under `config/` that drive resource creation.
- **SECURITYADMIN**: The built-in Snowflake account role used to manage users and roles.
- **Snowflake_Provider**: The `snowflakedb/snowflake` Terraform provider at version `~> 2.1.0` used throughout this project.

## Requirements

### Requirement 1: Service User Definition in Config

**User Story:** As a Snowflake infrastructure engineer, I want to define service users in a YAML config file, so that all service user definitions are version-controlled and consistent with the existing config-driven pattern.

#### Acceptance Criteria

1. THE Terraform_Config SHALL read service user definitions from a `config/users.yml` file decoded in `locals.tf`, consistent with how `roles.yml`, `warehouses.yml`, and `databases.yml` are loaded.
2. THE `config/users.yml` file SHALL support a top-level `service_users` key containing a map of user entries keyed by a short logical name (e.g. `dbt`, `fivetran`).
3. WHEN a service user entry is present in `config/users.yml`, THE Terraform_Config SHALL expose it as a local value available to `users.tf`.
4. THE User_Config SHALL support the following optional fields per entry: `rsa_public_key`, `default_role`, `default_warehouse`, `comment`.
5. IF a field is absent from a User_Config entry, THEN THE Terraform_Config SHALL apply a safe default (omit the attribute or use the provider default) without error.

### Requirement 2: Service User Naming Convention

**User Story:** As a Snowflake infrastructure engineer, I want service users named `SVC_<NAME>_<ENV>` automatically, so that service accounts are immediately distinguishable from human users and follow a predictable convention.

#### Acceptance Criteria

1. THE Service_User_Name SHALL follow the pattern `SVC_<NAME>_<ENV>` where `<NAME>` is the uppercased logical key from `config/users.yml` and `<ENV>` is the uppercased value of `var.environment`.
2. THE Service_User_Name SHALL be fully uppercased (e.g. `SVC_DBT_DEV`, `SVC_FIVETRAN_PROD`).
3. THE Terraform_Config SHALL derive the Service_User_Name deterministically from the user key and `var.environment`, requiring no explicit `name` field in the User_Config.
4. THE Service_User_Name SHALL NOT use the `object_prefix` local (which may include a project component), ensuring the naming pattern is always `SVC_<NAME>_<ENV>` regardless of whether `var.project` is set.

### Requirement 3: Service User Resource Creation

**User Story:** As a Snowflake infrastructure engineer, I want a `snowflake_user` resource created for each service user entry, so that service accounts exist in Snowflake and can authenticate via RSA key-pair.

#### Acceptance Criteria

1. WHEN a service user entry exists in `config/users.yml`, THE Terraform_Config SHALL create a `snowflake_user` resource with the derived Service_User_Name as the `name` attribute.
2. THE `snowflake_user` resource SHALL set `login_name` equal to the Service_User_Name.
3. WHEN `rsa_public_key` is provided in the User_Config, THE `snowflake_user` resource SHALL set the `rsa_public_key` attribute to that value.
4. WHEN `default_role` is provided in the User_Config, THE `snowflake_user` resource SHALL set the `default_role` attribute to the uppercased fully-qualified role name.
5. WHEN `default_warehouse` is provided in the User_Config, THE `snowflake_user` resource SHALL set the `default_warehouse` attribute to the uppercased fully-qualified warehouse name.
6. THE `snowflake_user` resource SHALL set the `comment` attribute to `var.comment` when no per-user comment is specified, or to the per-user comment when one is provided in the User_Config.
7. IF a service user entry is removed from `config/users.yml`, THEN THE Terraform_Config SHALL destroy the corresponding `snowflake_user` resource on the next apply.

### Requirement 4: RSA Key-Pair Authentication

**User Story:** As a Snowflake infrastructure engineer, I want service users configured for RSA key-pair authentication, so that they can connect using SNOWFLAKE_JWT consistent with the existing provider authentication method.

#### Acceptance Criteria

1. THE `snowflake_user` resource SHALL support setting `rsa_public_key` from the User_Config to enable key-pair authentication.
2. THE Terraform_Config SHALL treat the `rsa_public_key` value as a sensitive input, ensuring it is not logged in plain text in Terraform output.
3. WHEN `rsa_public_key` is absent from a User_Config entry, THE Terraform_Config SHALL create the user without an RSA key, allowing the key to be set out-of-band.
4. THE Terraform_Config SHALL NOT store private key material; only the public key SHALL be referenced in config or state.

### Requirement 5: Provider and Permission Consistency

**User Story:** As a Snowflake infrastructure engineer, I want service user resources to use the correct provider alias, so that user management follows the same security boundary pattern as role and grant resources.

#### Acceptance Criteria

1. THE `snowflake_user` resource SHALL use the `snowflake.securityadmin` provider alias, consistent with role and grant resources that require elevated privileges.
2. THE Terraform_Config SHALL manage all service user resources in a dedicated `users.tf` file, keeping user management separate from role and warehouse management.

### Requirement 7: Provider Version Compatibility

**User Story:** As a Snowflake infrastructure engineer, I want the service user implementation to be compatible with the pinned provider versions, so that no provider upgrades are required to use this feature.

#### Acceptance Criteria

1. THE `snowflake_user` resource implementation SHALL be compatible with `snowflakedb/snowflake ~> 2.1.0` and use only attributes supported by that version.
2. THE Terraform_Config SHALL NOT introduce any new provider dependencies beyond those already declared in `providers.tf`.
3. THE implementation SHALL use the `snowflake_user` resource schema as defined in Snowflake provider v2.1.x, including correct attribute names for `name`, `login_name`, `rsa_public_key`, `default_role`, `default_warehouse`, and `comment`.

### Requirement 8: Config/YAML Structure

**User Story:** As a Snowflake infrastructure engineer, I want the `config/users.yml` structure to follow the same conventions as existing config files, so that the project remains consistent and easy to extend.

#### Acceptance Criteria

1. THE `config/users.yml` file SHALL use a `service_users` top-level key containing a map, consistent with the `functional_roles`, `warehouses`, and `databases` top-level keys in other config files.
2. THE Terraform_Config SHALL decode `config/users.yml` in `locals.tf` using `yamldecode(file(...))`, consistent with all other config file loading.
3. WHEN `config/users.yml` is absent or the `service_users` key is empty, THE Terraform_Config SHALL create no user resources without error, using `try(..., {})` or equivalent.
4. THE `config/users.yml` file SHALL include commented-out examples for common service users (e.g. dbt, fivetran, airflow) to guide future additions.
