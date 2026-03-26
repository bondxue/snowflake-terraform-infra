# Implementation Plan: Service Users

## Overview

Introduce config-driven Snowflake service user management by adding `users_yml` and `service_users` locals to `locals.tf`, creating `config/users.yml`, and creating a new `users.tf` with the `snowflake_user` resource. Property-based tests are implemented in Python using Hypothesis.

## Tasks

- [x] 1. Add `users_yml` and `service_users` locals to `locals.tf`
  - Inside the existing `locals` block, add `users_yml = yamldecode(file("${var.config_dir}/users.yml"))`
  - Add `service_users = try(local.users_yml.service_users, {})` so an absent key or empty map produces no resources without error
  - _Requirements: 1.1, 1.3, 8.2, 8.3_

- [x] 2. Create `config/users.yml` with commented-out examples
  - Create the file with a `service_users:` top-level key
  - Include one active example entry (e.g. `dbt`) and commented-out entries for `fivetran` and `airflow` to guide future additions
  - All optional fields (`rsa_public_key`, `default_role`, `default_warehouse`, `comment`) should be shown in the examples
  - _Requirements: 1.2, 1.4, 8.1, 8.4_

- [-] 3. Create `users.tf` with `snowflake_user.service_user` resource
  - Create `users.tf` with a `snowflake_user` resource using `for_each = local.service_users` and `provider = snowflake.securityadmin`
  - Set `name` and `login_name` to `upper(join("_", ["SVC", each.key, var.environment]))` — do NOT use `local.object_prefix`
  - Set `rsa_public_key = try(sensitive(each.value.rsa_public_key), null)`
  - Set `default_role = try(upper(each.value.default_role), null)`
  - Set `default_warehouse = try(upper(each.value.default_warehouse), null)`
  - Set `comment = try(each.value.comment, var.comment)`
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 4.1, 4.2, 4.3, 4.4, 5.1, 5.2, 7.1, 7.2, 7.3_

  - [ ] 3.1 Write property test for service user naming formula (Property 1)
    - **Property 1: Service User Naming Formula**
    - For any user key string and environment string, `name == login_name == upper("SVC_" + user_key + "_" + environment)`
    - Test with mixed-case keys, keys with underscores, and environments with a project component set (verify `var.project` has no effect on the name)
    - **Validates: Requirements 2.1, 2.2, 2.3, 2.4, 3.1, 3.2**

  - [ ]* 3.2 Write property test for optional field pass-through (Property 2)
    - **Property 2: Optional Field Pass-Through**
    - For any user config map, when a field is present the computed attribute equals the config value (uppercased where applicable); when absent the attribute is `null` (or `var.comment` for `comment`) without error
    - **Validates: Requirements 1.4, 1.5, 3.3, 3.6, 4.3**

  - [ ]* 3.3 Write property test for uppercasing of optional string fields (Property 3)
    - **Property 3: Optional String Fields Are Uppercased**
    - For any user config entry where `default_role` or `default_warehouse` is provided, the computed attribute equals `upper(config_value)` regardless of original casing
    - **Validates: Requirements 3.4, 3.5**

- [ ] 4. Checkpoint — ensure `terraform validate` passes and all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Property tests re-implement the naming and attribute-building logic as pure Python functions and test with Hypothesis (minimum 100 iterations per property)
- Each property test file must include a comment header: `# Feature: service-users, Property N: <title>`
- No changes are required to `roles.tf`, `grants.tf`, `warehouses.tf`, `providers.tf`, or `variables.tf`
