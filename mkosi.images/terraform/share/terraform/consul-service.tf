resource "vault_consul_secret_backend_role" "consul-api" {
  name    = "consul-api"
  backend = vault_consul_secret_backend.consul.path
  consul_policies = [
    "consul-api",
  ]
}

resource "vault_jwt_auth_backend_role" "consul" {
  backend   = vault_jwt_auth_backend.nomad-workload.path
  role_type = "jwt"
  role_name = "consul"

  bound_audiences         = ["vault.io"]
  user_claim              = "/nomad_job_id"
  user_claim_json_pointer = true
  bound_claims = {
    "nomad_namespace" = "admin"
    "nomad_job_id"    = "consul"
  }
  claim_mappings = {
    nomad_namespace = "nomad_namespace"
    nomad_job_id    = "nomad_job_id"
    nomad_task      = "nomad_task"
  }
  token_type             = "service"
  token_policies         = [vault_policy.consul-gossip.name]
  token_period           = 30 * 60
  token_explicit_max_ttl = 0
}

resource "consul_acl_binding_rule" "consul-service" {
  auth_method = consul_acl_auth_method.nomad-workload.name
  bind_type   = "service"
  bind_name   = "consul"
  selector    = "value.nomad_namespace==\"admin\" and value.nomad_service==\"consul\""
}

resource "consul_acl_binding_rule" "consul-job" {
  auth_method = consul_acl_auth_method.nomad-workload.name
  bind_type   = "policy"
  bind_name   = consul_acl_policy.consul-api.name
  selector    = "value.nomad_namespace==\"admin\" and value.nomad_job_id==\"consul\""
}

resource "consul_acl_policy" "consul-api" {
  name  = "consul-api"
  rules = <<-EOP
    node_prefix "consul-api-" {
      policy = "write"
    }
    EOP
}
resource "consul_config_entry_service_intentions" "consul" {
  name = "consul"

  sources {
    name       = "admin--test"
    type       = "consul"
    action     = "allow"
    precedence = 9
  }
}

resource "nomad_job" "consul" {
  jobspec = file("${path.module}/consul.nomad")
  hcl2 {
    vars = {
      namespace = nomad_namespace.admin.name
    }
  }
  depends_on = [
    vault_consul_secret_backend_role.consul-api,
    vault_jwt_auth_backend_role.consul,
    consul_acl_binding_rule.consul-service,
    consul_acl_binding_rule.consul-job,
    consul_acl_policy.consul-api,
  ]
}
