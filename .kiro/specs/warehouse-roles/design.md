# Design Document: Warehouse Roles

## Overview

This feature introduces warehouse roles (resource roles) to the Snowflake Terraform infrastructure. Each warehouse defined in `config/warehouses.yml` will automatically get a corresponding Snowflake account role named `<OBJECT_PREFIX>_<WAREHOUSE_NAME>_WH`. Warehouse privileges are granted to this warehouse role rather than directly to functional roles, and the warehouse role is then granted to the relevant functional roles and to SYSADMIN.

This follows Snowflake's RBAC best practice of separating resource roles from functional roles, creating a clean privilege hierarchy:

```
WAREHOUSE → WAREHOUSE_ROLE (resource role)
WAREHOUSE_ROLE → FUNCTIONAL_ROLE
WAREHOUSE_ROLE → SYSADMIN
```

The implementation is entirely config-driven via the existing `config/warehouses.yml` structure with no new top-level YAML keys required.

## Architecture

The change touches four existing Terraform files, each with a focused responsibility:

```
config/warehouses.yml   (unchanged - existing structure drives everything)
        │
        ▼
locals.tf               (no changes needed - warehouse_yml already decoded)
        │
        ├──▶ roles.tf        (ADD: warehouse_role local + snowflake_account_role.warehouse_role)
        │
        ├──▶ warehouses.tf   (MODIFY: privilege grants target warehouse_role instead of functional_role)
        │
        └──▶ grants.tf       (ADD: warehouse_role → functional_role grants + warehouse_role → SYSADMIN grants)
```

No new files are created. No changes to `locals.tf`, `providers.tf`, `variables.tf`, or `config/warehouses.yml` are required.

### Data Flow

1. `config/warehouses.yml` defines warehouses with a `roles` map (functional role name → privilege list)
2. `roles.tf` derives warehouse role names from warehouse keys and creates `snowflake_account_role` resources
3. `warehouses.tf` grants warehouse privileges to the warehouse role (not the functional role)
4. `grants.tf` grants each warehouse role to its associated functional roles and to SYSADMIN

## Components and Interfaces

### roles.tf — Warehouse Role Creation

A new `warehouse_roles` local is derived from `local.warehouses` (already available from `warehouses.tf`'s local block). Since `local.warehouses` is defined in `warehouses.tf`, the `warehouse_roles` local in `roles.tf` references it directly.

```hcl
locals {
  warehouse_roles = {
    for warehouse, specs in local.warehouses : warehouse => upper(join("_", [local.object_prefix, warehouse, "WH"]))
  }
}

resource "snowflake_account_role" "warehouse_role" {
  for_each = local.warehouse_roles
  provider = snowflake.securityadmin

  name    = each.value
  comment = var.comment
}
```

The map key is the warehouse key from YAML (e.g. `ingestion`), and the value is the fully-formed role name (e.g. `DEV_INGESTION_WH`).

### warehouses.tf — Privilege Grants Retargeted to Warehouse Role

The existing `warehouse_grants_wo_ownership` and `warehouse_ownership` locals are modified so the `role` field resolves to the warehouse role name instead of the functional role name.

Before:
```hcl
role = upper(join("_", [local.object_prefix, role]))  # e.g. DEV_INGESTION
```

After:
```hcl
role = upper(join("_", [local.object_prefix, warehouse, "WH"]))  # e.g. DEV_INGESTION_WH
```

The `unique` key for each grant also changes — since multiple functional roles can share the same warehouse, the old `join("_", [warehouse, role])` key was unique per functional role. The new grants are per-warehouse (one warehouse role per warehouse), so the key becomes simply `warehouse`.

The `snowflake_grant_privileges_to_account_role.warehouse` and `snowflake_grant_ownership.warehouse` resources gain a `depends_on` reference to `snowflake_account_role.warehouse_role`.

### grants.tf — Warehouse Role → Functional Role and SYSADMIN Grants

Two new locals and two new `snowflake_grant_account_role` resources are added.

**Warehouse role → functional role grants:**

```hcl
locals {
  warehouse_role_to_functional_role_grants = flatten([
    for warehouse, specs in local.warehouses : [
      for role, privileges in try(specs.roles, {}) : {
        unique           = join("_", [warehouse, role])
        warehouse_role   = upper(join("_", [local.object_prefix, warehouse, "WH"]))
        functional_role  = upper(join("_", [local.object_prefix, role]))
      }
    ]
  ])
}
```

**Warehouse role → SYSADMIN grants:**

```hcl
locals {
  warehouse_role_to_sysadmin_grants = {
    for warehouse, specs in local.warehouses :
      warehouse => upper(join("_", [local.object_prefix, warehouse, "WH"]))
  }
}
```

## Data Models

### YAML Config (unchanged)

The existing `config/warehouses.yml` structure is fully reused:

```yaml
warehouses:
  <warehouse_key>:
    size: <string>           # optional
    auto_suspend: <number>   # optional
    max_cluster_count: <number>  # optional
    roles:
      <functional_role_key>:
        - <privilege>        # usage | operate | monitor | modify | ownership
```

Example with the current `ingestion` warehouse:

```yaml
warehouses:
  ingestion:
    auto_suspend: 60
    max_cluster_count: 10
    roles:
      ingestion:
        - usage
        - operate
```

This produces:
- Warehouse role: `DEV_INGESTION_WH`
- Privilege grants: `USAGE`, `OPERATE` → `DEV_INGESTION_WH` on warehouse `DEV_INGESTION`
- Role grant: `DEV_INGESTION_WH` → `DEV_INGESTION`
- Role grant: `DEV_INGESTION_WH` → `SYSADMIN`

### Terraform Local Structures

**`local.warehouse_roles`** (new, in `roles.tf`):
```
map(string)
  key:   warehouse key from YAML (e.g. "ingestion")
  value: warehouse role name (e.g. "DEV_INGESTION_WH")
```

**`local.warehouse_grants_wo_ownership`** (modified, in `warehouses.tf`):
```
list(object)
  unique:    warehouse key (e.g. "ingestion")
  warehouse: warehouse key (e.g. "ingestion")
  role:      warehouse role name (e.g. "DEV_INGESTION_WH")
  privilege: sorted list of non-ownership privileges (e.g. ["OPERATE", "USAGE"])
```

**`local.warehouse_ownership`** (modified, in `warehouses.tf`):
```
list(object)
  unique:    warehouse key (e.g. "ingestion")
  warehouse: warehouse key (e.g. "ingestion")
  role:      warehouse role name (e.g. "DEV_INGESTION_WH")
  privilege: ["OWNERSHIP"]
```

**`local.warehouse_role_to_functional_role_grants`** (new, in `grants.tf`):
```
list(object)
  unique:          join of warehouse + functional role key (e.g. "ingestion_ingestion")
  warehouse_role:  warehouse role name (e.g. "DEV_INGESTION_WH")
  functional_role: functional role name (e.g. "DEV_INGESTION")
```

**`local.warehouse_role_to_sysadmin_grants`** (new, in `grants.tf`):
```
map(string)
  key:   warehouse key (e.g. "ingestion")
  value: warehouse role name (e.g. "DEV_INGESTION_WH")
```

### Naming Convention

| Component | Pattern | Example (env=DEV, warehouse=ingestion) |
|---|---|---|
| Warehouse | `<OBJECT_PREFIX>_<WAREHOUSE_KEY>` | `DEV_INGESTION` |
| Warehouse Role | `<OBJECT_PREFIX>_<WAREHOUSE_KEY>_WH` | `DEV_INGESTION_WH` |
| Functional Role | `<OBJECT_PREFIX>_<FUNCTIONAL_ROLE_KEY>` | `DEV_INGESTION` |

All names are fully uppercased via `upper()`.


## Correctness Properties

*A property is a characteristic or behavior that should hold true across all valid executions of a system — essentially, a formal statement about what the system should do. Properties serve as the bridge between human-readable specifications and machine-verifiable correctness guarantees.*

The Terraform locals in this feature are pure functions of their inputs (YAML config values and the `object_prefix` string), making them well-suited to property-based testing without any Snowflake API calls.

### Property 1: Warehouse Role Naming

*For any* warehouse key string and object_prefix string, the derived warehouse role name must equal `upper(object_prefix + "_" + warehouse_key + "_WH")`.

This covers the determinism, uppercasing, and suffix requirements. Edge cases include warehouse keys with mixed case, keys containing underscores, and object_prefix values with a project component (e.g. `DEV_MYPROJECT`).

**Validates: Requirements 1.2, 1.5, 6.1, 6.2, 6.3**

### Property 2: Privilege Grants Target the Warehouse Role

*For any* warehouse config map where a warehouse has non-ownership privileges listed, every entry in the computed `warehouse_grants_wo_ownership` local must have its `role` field equal to the warehouse role name (not any functional role name), and the `privilege` list must contain exactly the non-ownership privileges from the config in sorted uppercase form.

Edge cases: empty privilege list produces no grant entry (Requirement 2.4); all-ownership privilege list produces no entry in this local (Requirement 2.3).

**Validates: Requirements 2.1, 2.2, 2.4**

### Property 3: Ownership and Non-Ownership Privileges Are Separated

*For any* privilege list associated with a warehouse, the `warehouse_ownership` local must contain the entry if and only if `"ownership"` is in the list, and the `warehouse_grants_wo_ownership` local must never contain `"OWNERSHIP"` in its privilege field.

**Validates: Requirements 2.3**

### Property 4: Warehouse Role Granted to Each Functional Role

*For any* warehouse config where the `roles` map contains N functional role keys, the `warehouse_role_to_functional_role_grants` local must contain exactly N entries, each with `warehouse_role` equal to the warehouse role name and `functional_role` equal to `upper(object_prefix + "_" + functional_role_key)`.

Edge cases: empty or absent `roles` map produces zero entries for that warehouse (Requirement 5.3).

**Validates: Requirements 3.1, 3.5, 5.3**

### Property 5: Every Warehouse Role Is Granted to SYSADMIN

*For any* set of warehouses defined in the config, the `warehouse_role_to_sysadmin_grants` local must contain exactly one entry per warehouse, with the value equal to the warehouse role name, regardless of what functional roles or privileges are configured.

**Validates: Requirements 4.1**

## Error Handling

Since this feature operates entirely within Terraform's declarative model, "errors" manifest as plan/apply failures rather than runtime exceptions. The key error scenarios are:

**Invalid privilege values**: If a privilege value in `warehouses.yml` is not one of `usage`, `operate`, `monitor`, `modify`, `ownership`, Snowflake will reject the grant at apply time. The `setsubtract` and `setintersection` calls in the locals are case-insensitive at the Terraform level since we apply `upper()` before passing to Snowflake.

**Missing functional role**: If a functional role key listed under a warehouse's `roles` map does not exist as a `snowflake_account_role.functional_role` resource, the `depends_on` in the grant resource will catch this at plan time via a reference error.

**Duplicate warehouse keys**: YAML does not allow duplicate keys; the YAML parser will error before Terraform evaluates any locals.

**Empty roles map**: Handled gracefully — `try(specs.roles, {})` returns an empty map, producing no grant entries while still creating the warehouse role.

## Testing Strategy

### Dual Testing Approach

Both unit tests and property-based tests are required. Unit tests cover specific known examples and integration points; property tests verify the local computation logic holds across arbitrary inputs.

### Unit Tests

Unit tests should cover:
- The `ingestion` warehouse from the current `config/warehouses.yml` produces the expected role name `DEV_INGESTION_WH`, privilege grants, functional role grant, and SYSADMIN grant
- A warehouse with an empty `roles` map produces a warehouse role but no grants
- A warehouse with `ownership` in the privilege list produces an ownership grant entry and no non-ownership grant entry
- A warehouse with multiple functional roles produces one grant entry per functional role plus one SYSADMIN grant

Since Terraform locals are HCL expressions, unit testing is done by extracting the logic into a testable form. The recommended approach is using [Terraform's built-in test framework](https://developer.hashicorp.com/terraform/language/tests) (`terraform test`) with mock provider data, or testing the equivalent logic as pure functions in a scripting language.

### Property-Based Tests

Use a property-based testing library appropriate for the implementation language. Since the core logic is HCL locals (pure string/collection transformations), the recommended approach is to extract and re-implement the naming and collection-building logic in Python or Go and test with [Hypothesis](https://hypothesis.readthedocs.io/) (Python) or [rapid](https://github.com/flyingmutant/rapid) (Go), running a minimum of 100 iterations per property.

Each property test must be tagged with a comment referencing the design property:

```
# Feature: warehouse-roles, Property 1: Warehouse Role Naming
# Feature: warehouse-roles, Property 2: Privilege Grants Target the Warehouse Role
# Feature: warehouse-roles, Property 3: Ownership and Non-Ownership Privileges Are Separated
# Feature: warehouse-roles, Property 4: Warehouse Role Granted to Each Functional Role
# Feature: warehouse-roles, Property 5: Every Warehouse Role Is Granted to SYSADMIN
```

**Property test generators should produce:**
- Arbitrary lowercase warehouse key strings (alphanumeric + underscores)
- Arbitrary object_prefix strings (e.g. `DEV`, `PROD_MYPROJECT`)
- Arbitrary subsets of `{usage, operate, monitor, modify, ownership}` as privilege lists
- Arbitrary maps of functional role keys to privilege lists (including empty maps)
- Arbitrary sets of warehouse entries (1 to N warehouses)

Each correctness property must be implemented by a single property-based test. Property tests handle broad input coverage; unit tests handle the concrete Snowflake-specific examples.
