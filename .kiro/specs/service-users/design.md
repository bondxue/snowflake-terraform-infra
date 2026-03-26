# Design Document: Service Users

## Overview

This feature introduces config-driven management of Snowflake service users via Terraform. Service users are non-human accounts used by automated tools (dbt, Fivetran, Airflow, etc.) to connect to Snowflake via RSA key-pair authentication (SNOWFLAKE_JWT).

Each service user is defined in a new `config/users.yml` file and follows the naming convention `SVC_<NAME>_<ENV>` (e.g. `SVC_DBT_DEV`). The implementation follows the same YAML-driven, provider-alias pattern used throughout the project.

The privilege hierarchy is unchanged — service users are assigned a `default_role` and `default_warehouse` directly in their config; no new role-grant resources are introduced by this feature.

```
config/users.yml
      │
      ▼
locals.tf        (ADD: users_yml + service_users locals)
      │
      └──▶ users.tf   (NEW: snowflake_user.service_user resource)
```

## Architecture

Two files are created or modified:

- `locals.tf` — add `users_yml` and `service_users` locals
- `users.tf` — new file containing the `snowflake_user` resource
- `config/users.yml` — new YAML config file

No changes are required to `roles.tf`, `grants.tf`, `warehouses.tf`, `providers.tf`, or `variables.tf`.

### Data Flow

1. `config/users.yml` defines service users under a `service_users` key
2. `locals.tf` decodes the file and exposes `local.service_users` as a map
3. `users.tf` iterates over `local.service_users` with `for_each` to create `snowflake_user` resources
4. The `name` and `login_name` are derived deterministically as `upper(join("_", ["SVC", user_key, var.environment]))`

## Components and Interfaces

### locals.tf — New Locals

Two new locals are added to the existing `locals` block:

```hcl
users_yml     = yamldecode(file("${var.config_dir}/users.yml"))
service_users = try(local.users_yml.service_users, {})
```

`try(..., {})` ensures that an absent file key or empty `service_users` map produces no resources without error.

### users.tf — Service User Resource

```hcl
resource "snowflake_user" "service_user" {
  for_each = local.service_users
  provider = snowflake.securityadmin

  name      = upper(join("_", ["SVC", each.key, var.environment]))
  login_name = upper(join("_", ["SVC", each.key, var.environment]))

  rsa_public_key    = try(sensitive(each.value.rsa_public_key), null)
  default_role      = try(upper(each.value.default_role), null)
  default_warehouse = try(upper(each.value.default_warehouse), null)
  comment           = try(each.value.comment, var.comment)
}
```

The `sensitive()` wrapper on `rsa_public_key` ensures the key material is redacted from Terraform output and logs.

### config/users.yml — New Config File

```yaml
service_users:
  dbt:
    rsa_public_key: |
      -----BEGIN PUBLIC KEY-----
      ...
      -----END PUBLIC KEY-----
    default_role: DEV_INGESTION
    default_warehouse: DEV_INGESTION
    comment: "dbt service user"
  # fivetran:
  #   rsa_public_key: |
  #     -----BEGIN PUBLIC KEY-----
  #     ...
  #     -----END PUBLIC KEY-----
  #   default_role: DEV_INGESTION
  #   default_warehouse: DEV_INGESTION
  #   comment: "fivetran service user"
  # airflow:
  #   default_role: DEV_INGESTION
  #   default_warehouse: DEV_INGESTION
  #   comment: "airflow service user"
```

## Data Models

### YAML Config Structure

```yaml
service_users:
  <user_key>:                  # logical short name, e.g. dbt, fivetran
    rsa_public_key: <string>   # optional — PEM-encoded RSA public key
    default_role: <string>     # optional — Snowflake role name
    default_warehouse: <string> # optional — Snowflake warehouse name
    comment: <string>          # optional — falls back to var.comment
```

All fields except the user key are optional. Absent fields are handled via `try(..., null)` or `try(..., var.comment)`.

### Terraform Local Structures

`local.service_users` (new, in `locals.tf`):

```
map(object)
  key:   user key from YAML (e.g. "dbt")
  value: object with optional fields rsa_public_key, default_role, default_warehouse, comment
```

### Naming Convention

| Component | Pattern | Example (env=DEV, key=dbt) |
|---|---|---|
| Service User Name | `SVC_<KEY>_<ENV>` | `SVC_DBT_DEV` |
| Login Name | `SVC_<KEY>_<ENV>` | `SVC_DBT_DEV` |

The name is derived from `upper(join("_", ["SVC", user_key, var.environment]))`. It does NOT use `local.object_prefix`, ensuring the pattern is always `SVC_<NAME>_<ENV>` regardless of whether `var.project` is set.

All names are fully uppercased via `upper()`.

## Correctness Properties

*A property is a characteristic or behavior that should hold true across all valid executions of a system — essentially, a formal statement about what the system should do. Properties serve as the bridge between human-readable specifications and machine-verifiable correctness guarantees.*

The Terraform locals in this feature are pure functions of their inputs (YAML config values and `var.environment`), making them well-suited to property-based testing without any Snowflake API calls.

### Property 1: Service User Naming Formula

*For any* user key string and environment string, the derived service user name must equal `upper("SVC_" + user_key + "_" + environment)`, and the `login_name` must equal the same value.

This covers determinism, full uppercasing, the `SVC_` prefix, the `_<ENV>` suffix, and the exclusion of `object_prefix` (and therefore `var.project`). Edge cases include user keys with mixed case, keys containing underscores, and environments with a project component set.

**Validates: Requirements 2.1, 2.2, 2.3, 2.4, 3.1, 3.2**

### Property 2: Optional Field Pass-Through

*For any* user config map, for each optional field (`rsa_public_key`, `default_role`, `default_warehouse`, `comment`): when the field is present in the config, the computed resource attribute must equal the config value (uppercased where applicable); when the field is absent, the computed attribute must be `null` (or `var.comment` for the `comment` field) without error.

**Validates: Requirements 1.4, 1.5, 3.3, 3.6, 4.3**

### Property 3: Optional String Fields Are Uppercased

*For any* user config entry where `default_role` or `default_warehouse` is provided, the computed attribute value must equal `upper(config_value)`, regardless of the original casing in the YAML.

**Validates: Requirements 3.4, 3.5**

## Error Handling

Since this feature operates entirely within Terraform's declarative model, errors manifest as plan/apply failures rather than runtime exceptions.

**Missing `config/users.yml`**: The `try(local.users_yml.service_users, {})` pattern handles an absent `service_users` key gracefully. However, if the file itself is missing, `yamldecode(file(...))` will fail at plan time. The file must exist (it can contain only `service_users: {}` or commented-out examples).

**Invalid RSA public key format**: Snowflake validates the PEM format at apply time. A malformed key will cause the apply to fail with a Snowflake API error. The key must be a valid PEM-encoded RSA public key without the `-----BEGIN/END PUBLIC KEY-----` header/footer stripped.

**Duplicate user keys**: YAML does not allow duplicate map keys; the YAML parser will error before Terraform evaluates any locals.

**Empty `service_users` map**: Handled gracefully — `try(local.users_yml.service_users, {})` returns an empty map, and `for_each` over an empty map creates no resources.

**Referenced role or warehouse does not exist**: If `default_role` or `default_warehouse` references a Snowflake object that does not exist, Snowflake will accept the user creation but the user will fail to connect. This is not validated at plan time.

## Testing Strategy

### Dual Testing Approach

Both unit tests and property-based tests are required. Unit tests cover specific known examples and integration points; property tests verify the local computation logic holds across arbitrary inputs.

### Unit Tests

Unit tests should cover:

- A user config with all fields present produces the correct `name`, `login_name`, `rsa_public_key`, `default_role`, `default_warehouse`, and `comment` values
- A user config with no optional fields produces `name` and `login_name` only, with `null` for optional attributes and `var.comment` for `comment`
- A user key of `dbt` with `var.environment = "dev"` produces `SVC_DBT_DEV`
- A user key of `dbt` with `var.project = "myproject"` and `var.environment = "dev"` still produces `SVC_DBT_DEV` (not `SVC_DBT_DEV_MYPROJECT`)
- An empty `service_users` map produces no resources

### Property-Based Tests

Use a property-based testing library appropriate for the implementation language. Since the core logic is HCL locals (pure string/collection transformations), the recommended approach is to extract and re-implement the naming and attribute-building logic in Python and test with [Hypothesis](https://hypothesis.readthedocs.io/), running a minimum of 100 iterations per property.

Each property test must be tagged with a comment referencing the design property:

```
# Feature: service-users, Property 1: Service User Naming Formula
# Feature: service-users, Property 2: Optional Field Pass-Through
# Feature: service-users, Property 3: Optional String Fields Are Uppercased
```

**Property test generators should produce:**

- Arbitrary lowercase user key strings (alphanumeric + underscores)
- Arbitrary environment strings (e.g. `dev`, `prod`, `staging`)
- Arbitrary project strings (including empty string) to verify naming is unaffected
- Arbitrary user config maps with any combination of optional fields present or absent
- Arbitrary string values for `default_role`, `default_warehouse`, `comment` (mixed case)
- Arbitrary PEM-like strings for `rsa_public_key`

Each correctness property must be implemented by a single property-based test. Property tests handle broad input coverage; unit tests handle the concrete Snowflake-specific examples.
