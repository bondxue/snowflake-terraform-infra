# Requirements Document

## Introduction

This feature introduces "warehouse roles" (resource roles) to the Snowflake Terraform infrastructure project. Following Snowflake's RBAC best practice of separating resource roles from functional roles, a dedicated warehouse role is automatically created for each warehouse defined in `config/warehouses.yml`. Warehouse privileges are granted to the warehouse role (not directly to functional roles), the warehouse role is then granted to the relevant functional role(s), and also granted to the SYSADMIN account role. The implementation remains config-driven via YAML with minimal changes to the existing config structure.

## Glossary

- **Warehouse_Role**: A Snowflake account role that acts as a resource role scoped to a single warehouse (e.g. `DEV_INGESTION_WH`). Also called a "resource role".
- **Functional_Role**: A Snowflake account role that represents a job function and receives access by being granted resource roles (e.g. `DEV_INGESTION`).
- **Account_Role**: A top-level Snowflake role not prefixed by the environment/project (e.g. `SYSADMIN`).
- **Object_Prefix**: The environment/project prefix prepended to all prefixed role and warehouse names (e.g. `DEV` or `DEV_MYPROJECT`).
- **Warehouse_Privilege**: A Snowflake privilege applicable to a warehouse resource (e.g. `USAGE`, `OPERATE`, `MONITOR`, `MODIFY`).
- **Terraform_Config**: The set of YAML files under `config/` that drive resource creation.
- **Warehouse_Role_Suffix**: The suffix appended to a warehouse name to form the warehouse role name. Defaults to `WH`.
- **SYSADMIN**: The built-in Snowflake account role that must receive every warehouse role grant.

## Requirements

### Requirement 1: Warehouse Role Creation

**User Story:** As a Snowflake infrastructure engineer, I want a dedicated warehouse role created automatically for each warehouse, so that warehouse privileges are encapsulated in a resource role following Snowflake RBAC best practices.

#### Acceptance Criteria

1. THE Terraform_Config SHALL define warehouse roles implicitly through the existing `warehouses.yml` warehouse definitions, requiring no new top-level config section for the basic case.
2. WHEN a warehouse entry exists in `config/warehouses.yml`, THE Warehouse_Role SHALL be created as a Snowflake account role named `<OBJECT_PREFIX>_<WAREHOUSE_NAME>_<WAREHOUSE_ROLE_SUFFIX>` (e.g. `DEV_INGESTION_WAREHOUSE`).
3. THE Warehouse_Role SHALL be created using the `snowflake.securityadmin` provider alias, consistent with all other role resources.
4. IF a warehouse is removed from `config/warehouses.yml`, THEN THE Terraform_Config SHALL destroy the corresponding Warehouse_Role on the next apply.
5. THE Warehouse_Role name SHALL be fully uppercased.

### Requirement 2: Warehouse Privilege Grants to Warehouse Role

**User Story:** As a Snowflake infrastructure engineer, I want warehouse privileges granted to the warehouse role instead of directly to functional roles, so that privilege management is centralised at the resource role layer.

#### Acceptance Criteria

1. WHEN privileges are listed under a warehouse's `roles` map in `config/warehouses.yml`, THE Terraform_Config SHALL grant those privileges to the Warehouse_Role rather than directly to the named functional role.
2. THE Terraform_Config SHALL support all non-ownership warehouse privileges (`USAGE`, `OPERATE`, `MONITOR`, `MODIFY`) as valid values in the `roles` privilege list.
3. WHEN `ownership` is listed as a privilege for a warehouse role entry, THE Terraform_Config SHALL handle it via a separate ownership grant resource, consistent with the existing ownership grant pattern.
4. IF no non-ownership privileges are specified for a warehouse entry, THEN THE Terraform_Config SHALL create no privilege grant resources for that warehouse role.
5. THE privilege grant resources SHALL depend on the Warehouse_Role resource being created before the grant is applied.

### Requirement 3: Warehouse Role Granted to Functional Roles

**User Story:** As a Snowflake infrastructure engineer, I want the warehouse role automatically granted to the functional roles listed under that warehouse in the config, so that functional roles inherit warehouse access through the resource role layer.

#### Acceptance Criteria

1. WHEN a functional role name appears as a key under a warehouse's `roles` map in `config/warehouses.yml`, THE Terraform_Config SHALL grant the Warehouse_Role to that Functional_Role.
2. THE grant of Warehouse_Role to Functional_Role SHALL use the `snowflake_grant_account_role` resource with the `snowflake.securityadmin` provider alias.
3. THE grant resource SHALL depend on both the Warehouse_Role and the target Functional_Role existing before the grant is applied.
4. WHEN a functional role is removed from a warehouse's `roles` map, THE Terraform_Config SHALL revoke the corresponding Warehouse_Role grant on the next apply.
5. THE Terraform_Config SHALL support multiple functional roles listed under a single warehouse, granting the Warehouse_Role to each.

### Requirement 4: Warehouse Role Granted to SYSADMIN

**User Story:** As a Snowflake infrastructure engineer, I want every warehouse role automatically granted to the SYSADMIN account role, so that SYSADMIN retains full operational access to all warehouses without manual configuration.

#### Acceptance Criteria

1. THE Terraform_Config SHALL grant every Warehouse_Role to the `SYSADMIN` account role automatically, without requiring any entry in `config/roles.yml`.
2. THE SYSADMIN grant SHALL use the `snowflake_grant_account_role` resource with the `snowflake.securityadmin` provider alias.
3. THE SYSADMIN grant resource SHALL depend on the Warehouse_Role existing before the grant is applied.
4. WHEN a warehouse is removed from `config/warehouses.yml`, THE Terraform_Config SHALL destroy the corresponding SYSADMIN grant on the next apply.

### Requirement 5: Config Backward Compatibility

**User Story:** As a Snowflake infrastructure engineer, I want the existing `config/warehouses.yml` structure to remain valid with minimal changes, so that the migration to warehouse roles does not require a full config rewrite.

#### Acceptance Criteria

1. THE Terraform_Config SHALL continue to read warehouse definitions from the existing `warehouses` key in `config/warehouses.yml` without requiring a new top-level key.
2. THE existing `roles` map under each warehouse entry SHALL continue to define which functional roles are associated with the warehouse and which privileges apply, reusing the current structure.
3. WHEN the `roles` map under a warehouse entry is absent or empty, THE Terraform_Config SHALL create the Warehouse_Role with no privilege grants and no functional role grants.
4. THE Terraform_Config SHALL remain compatible with the commented-out warehouse examples already present in `config/warehouses.yml` (developer, transform, reporting) without modification to those entries.

### Requirement 6: Naming Consistency

**User Story:** As a Snowflake infrastructure engineer, I want warehouse role names to follow a predictable, consistent convention, so that roles are easily identifiable and auditable.

#### Acceptance Criteria

1. THE Warehouse_Role name SHALL follow the pattern `<OBJECT_PREFIX>_<WAREHOUSE_NAME>_WH` using the same `object_prefix` local value used for all other prefixed resources.
2. THE Warehouse_Role name SHALL be fully uppercased, consistent with all other role and warehouse names in the project.
3. THE Terraform_Config SHALL derive the Warehouse_Role name deterministically from the warehouse key in `config/warehouses.yml`, requiring no explicit name field in the config.
