resource "snowflake_user" "service_user" {
  for_each = local.service_users
  provider = snowflake.securityadmin

  name       = upper(join("_", ["SVC", each.key, var.environment]))
  login_name = upper(join("_", ["SVC", each.key, var.environment]))

  rsa_public_key    = try(sensitive(each.value.rsa_public_key), null)
  default_role      = try(upper(each.value.default_role), null)
  default_warehouse = try(upper(each.value.default_warehouse), null)
  comment           = try(each.value.comment, var.comment)
}
