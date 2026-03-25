locals {
  warehouse_role_to_sysadmin_grants = {
    for warehouse, specs in local.warehouses : warehouse => upper(join("_", [local.object_prefix, warehouse, "WH"]))
  }

  warehouse_role_to_functional_role_grants = flatten([
    for warehouse, specs in local.warehouses : [
      for role, privileges in try(specs.roles, {}) : {
        unique          = join("_", [warehouse, role])
        warehouse_role  = upper(join("_", [local.object_prefix, warehouse, "WH"]))
        functional_role = upper(join("_", [local.object_prefix, role]))
      }
    ]
  ])

  functional_role_grants = flatten([
    for parent, children in local.functional_roles : [
      for child in children : {
        unique = join("_", [parent, child])
        parent = upper(join("_", [local.object_prefix, parent]))
        child  = upper(join("_", [local.object_prefix, child]))
      }
    ]
  ])

  account_role_grants = flatten([
    for parent, children in local.account_roles : [
      for child in children : {
        unique = join("_", [parent, child])
        parent = upper(parent)
        child  = upper(join("_", [local.object_prefix, child]))
      }
    ]
  ])
}

resource "snowflake_grant_account_role" "functional_role" {
  for_each = {
    for uni in local.functional_role_grants : uni.unique => uni
  }

  provider   = snowflake.securityadmin
  depends_on = [snowflake_account_role.functional_role, snowflake_account_role.account_role]

  role_name        = each.value.child
  parent_role_name = each.value.parent
}

resource "snowflake_grant_account_role" "account_role" {
  for_each = {
    for uni in local.account_role_grants : uni.unique => uni
  }

  provider   = snowflake.securityadmin
  depends_on = [snowflake_account_role.functional_role, snowflake_account_role.account_role]

  role_name        = each.value.child
  parent_role_name = each.value.parent
}

resource "snowflake_grant_account_role" "warehouse_role_to_functional_role" {
  for_each = {
    for uni in local.warehouse_role_to_functional_role_grants : uni.unique => uni
  }

  provider = snowflake.securityadmin

  role_name        = each.value.warehouse_role
  parent_role_name = each.value.functional_role

  depends_on = [snowflake_account_role.warehouse_role, snowflake_account_role.functional_role]
}

resource "snowflake_grant_account_role" "warehouse_role_to_sysadmin" {
  for_each = local.warehouse_role_to_sysadmin_grants

  provider = snowflake.securityadmin

  role_name        = each.value
  parent_role_name = "SYSADMIN"

  depends_on = [snowflake_account_role.warehouse_role]
}
