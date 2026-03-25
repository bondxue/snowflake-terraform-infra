# Implementation Plan: Warehouse Roles

## Overview

Introduce warehouse roles (resource roles) to the Snowflake Terraform infrastructure by modifying `roles.tf`, `warehouses.tf`, and `grants.tf`. No new files and no YAML config changes are required. Property-based tests are implemented in Python using Hypothesis.

## Tasks

- [x] 1. Add `warehouse_roles` local and `snowflake_account_role.warehouse_role` resource to `roles.tf`
  - Add a `warehouse_roles` local inside the existing `locals` block in `roles.tf` that maps each warehouse key to its role name: `upper(join("_", [local.object_prefix, warehouse, "WH"]))`
  - Add a `snowflake_account_role.warehouse_role` resource using `for_each = local.warehouse_roles`, `provider = snowflake.securityadmin`, `name = each.value`, and `comment = var.comment`
  - Note: `local.warehouses` is defined in `warehouses.tf` and is accessible here
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 6.1, 6.2, 6.3_

  - [ ] 1.1 Write property test for warehouse role naming (Property 1)
    - **Property 1: Warehouse Role Naming**
    - For any warehouse key and object_prefix, `warehouse_role_name == upper(object_prefix + "_" + warehouse_key + "_WH")`
    - Test with mixed-case keys, keys with underscores, and multi-part prefixes (e.g. `DEV_MYPROJECT`)
    - **Validates: Requirements 1.2, 1.5, 6.1, 6.2, 6.3**

- [x] 2. Retarget privilege grants in `warehouses.tf` from functional role to warehouse role
  - In `warehouse_grants_wo_ownership` local: change `role = upper(join("_", [local.object_prefix, role]))` to `role = upper(join("_", [local.object_prefix, warehouse, "WH"]))` and change `unique = join("_", [warehouse, trimspace(role)])` to `unique = warehouse`
  - Apply the same `role` and `unique` changes to the `warehouse_ownership` local
  - Add `depends_on = [snowflake_account_role.warehouse_role]` to both `snowflake_grant_privileges_to_account_role.warehouse` and `snowflake_grant_ownership.warehouse` resources
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5_

  - [ ]* 2.1 Write property test for privilege grant targeting (Property 2)
    - **Property 2: Privilege Grants Target the Warehouse Role**
    - For any warehouse config with non-ownership privileges, every entry in `warehouse_grants_wo_ownership` must have `role == upper(object_prefix + "_" + warehouse_key + "_WH")` and privileges must be the non-ownership subset in sorted uppercase form
    - Edge cases: empty privilege list → no grant entry; all-ownership list → no entry in this local
    - **Validates: Requirements 2.1, 2.2, 2.4**

  - [ ]* 2.2 Write property test for ownership/non-ownership separation (Property 3)
    - **Property 3: Ownership and Non-Ownership Privileges Are Separated**
    - For any privilege list, `warehouse_ownership` contains the entry iff `"ownership"` is in the list, and `warehouse_grants_wo_ownership` never contains `"OWNERSHIP"` in its privilege field
    - **Validates: Requirements 2.3**

- [x] 3. Checkpoint — ensure `terraform validate` passes and all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 4. Add warehouse role → functional role grants to `grants.tf`
  - Add `warehouse_role_to_functional_role_grants` local using `flatten` over `local.warehouses`, iterating `for role, privileges in try(specs.roles, {})`, producing objects with `unique = join("_", [warehouse, role])`, `warehouse_role = upper(join("_", [local.object_prefix, warehouse, "WH"]))`, and `functional_role = upper(join("_", [local.object_prefix, role]))`
  - Add `snowflake_grant_account_role.warehouse_role_to_functional_role` resource with `for_each` over the local, `provider = snowflake.securityadmin`, `role_name = each.value.warehouse_role`, `parent_role_name = each.value.functional_role`, and `depends_on = [snowflake_account_role.warehouse_role, snowflake_account_role.functional_role]`
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 5.3_

  - [ ]* 4.1 Write property test for warehouse role → functional role grants (Property 4)
    - **Property 4: Warehouse Role Granted to Each Functional Role**
    - For any warehouse config where the `roles` map has N functional role keys, `warehouse_role_to_functional_role_grants` must contain exactly N entries, each with `warehouse_role == upper(object_prefix + "_" + warehouse_key + "_WH")` and `functional_role == upper(object_prefix + "_" + functional_role_key)`
    - Edge case: empty or absent `roles` map → zero entries for that warehouse
    - **Validates: Requirements 3.1, 3.5, 5.3**

- [x] 5. Add warehouse role → SYSADMIN grants to `grants.tf`
  - Add `warehouse_role_to_sysadmin_grants` local as a map: `for warehouse, specs in local.warehouses : warehouse => upper(join("_", [local.object_prefix, warehouse, "WH"]))`
  - Add `snowflake_grant_account_role.warehouse_role_to_sysadmin` resource with `for_each = local.warehouse_role_to_sysadmin_grants`, `provider = snowflake.securityadmin`, `role_name = each.value`, `parent_role_name = "SYSADMIN"`, and `depends_on = [snowflake_account_role.warehouse_role]`
  - _Requirements: 4.1, 4.2, 4.3, 4.4_

  - [ ]* 5.1 Write property test for SYSADMIN grants (Property 5)
    - **Property 5: Every Warehouse Role Is Granted to SYSADMIN**
    - For any set of N warehouses, `warehouse_role_to_sysadmin_grants` must contain exactly N entries, one per warehouse, with each value equal to the warehouse role name, regardless of functional roles or privileges configured
    - **Validates: Requirements 4.1**

- [ ] 6. Final checkpoint — ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Property tests re-implement the naming and collection-building logic as pure Python functions and test with Hypothesis (minimum 100 iterations per property)
- Each property test file must include a comment header: `# Feature: warehouse-roles, Property N: <title>`
- `local.warehouses` is defined in `warehouses.tf` and referenced freely from `roles.tf` and `grants.tf` — Terraform resolves cross-file locals within the same root module
