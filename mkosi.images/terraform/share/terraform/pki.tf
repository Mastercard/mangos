#
# The comments show the commands from https://developer.hashicorp.com/vault/docs/secrets/pki/quick-start-intermediate-ca
# that the Terraform resources correspond to.
#
# `vault secrets enable pki`
# `vault secrets tune -max-lease-ttl=87600h pki`
#
resource "vault_mount" "pki-root" {
  description           = "Mangos Root CA"
  path                  = var.root-pki-path
  type                  = "pki"
  max_lease_ttl_seconds = var.root-max-lease-ttl
}

#
# `vault secrets enable -path=pki_int pki`
# `vault secrets tune -max-lease-ttl=43800h pki_int`
#
resource "vault_mount" "pki-svc" {
  description           = "Mangos Intermediate CA - Services"
  path                  = var.intermediate-pki-svc-path
  type                  = "pki"
  max_lease_ttl_seconds = var.intermediate-max-lease-ttl
}

resource "vault_mount" "pki-nodes" {
  description           = "Mangos Intermediate CA - Nodes"
  path                  = var.intermediate-pki-nodes-path
  type                  = "pki"
  max_lease_ttl_seconds = var.intermediate-max-lease-ttl
}

#
# `vault write pki/root/generate/internal common_name=myvault.com ttl=87600h`
#
resource "vault_pki_secret_backend_root_cert" "root" {
  backend      = vault_mount.pki-root.path
  type         = "internal"
  issuer_name  = "root-2025"
  common_name  = var.root-ca-common-name
  ttl          = var.root-max-lease-ttl
  organization = var.root-cert-organization != "" ? var.root-cert-organization : null
}

#
# `vault write pki_int/intermediate/generate/internal common_name="myvault.com Intermediate Authority" ttl=43800h`
#
resource "vault_pki_secret_backend_intermediate_cert_request" "svc-intermediate" {
  backend      = vault_mount.pki-svc.path
  type         = "internal"
  common_name  = var.intermediate-svc-ca-common-name
  organization = var.intermediate-svc-cert-organization != "" ? var.intermediate-svc-cert-organization : null
}

resource "vault_pki_secret_backend_intermediate_cert_request" "nodes-intermediate" {
  backend      = vault_mount.pki-nodes.path
  type         = "internal"
  common_name  = var.intermediate-nodes-ca-common-name
  organization = var.intermediate-nodes-cert-organization != "" ? var.intermediate-nodes-cert-organization : null
}

#
# `vault write pki/root/sign-intermediate csr=@pki_int.csr format=pem_bundle ttl=43800h`
#
resource "vault_pki_secret_backend_root_sign_intermediate" "svc-ca-signature" {
  lifecycle {
    replace_triggered_by = [vault_pki_secret_backend_root_cert.root]
  }

  backend              = vault_mount.pki-root.path
  csr                  = vault_pki_secret_backend_intermediate_cert_request.svc-intermediate.csr
  common_name          = vault_pki_secret_backend_intermediate_cert_request.svc-intermediate.common_name
  ttl                  = var.intermediate-max-lease-ttl
  exclude_cn_from_sans = true
  revoke               = true
  issuer_ref           = vault_pki_secret_backend_root_cert.root.issuer_id
}

resource "vault_pki_secret_backend_root_sign_intermediate" "nodes-ca-signature" {
  lifecycle {
    replace_triggered_by = [vault_pki_secret_backend_root_cert.root]
  }

  backend              = vault_mount.pki-root.path
  csr                  = vault_pki_secret_backend_intermediate_cert_request.nodes-intermediate.csr
  common_name          = vault_pki_secret_backend_intermediate_cert_request.nodes-intermediate.common_name
  ttl                  = var.intermediate-max-lease-ttl
  exclude_cn_from_sans = true
  revoke               = true
  issuer_ref           = vault_pki_secret_backend_root_cert.root.issuer_id
}

#
# `vault write pki_int/intermediate/set-signed certificate=@signed_certificate.pem`
#
resource "vault_pki_secret_backend_intermediate_set_signed" "svc-intermediate" {
  backend     = vault_mount.pki-svc.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.svc-ca-signature.certificate
}

resource "vault_pki_secret_backend_intermediate_set_signed" "nodes-intermediate" {
  backend     = vault_mount.pki-nodes.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.nodes-ca-signature.certificate
}

locals {
  svc-ca = vault_pki_secret_backend_intermediate_set_signed.svc-intermediate.certificate
  nodes-ca = vault_pki_secret_backend_intermediate_set_signed.nodes-intermediate.certificate
}

resource "vault_pki_secret_backend_issuer" "root" {
  backend     = vault_pki_secret_backend_root_cert.root.backend
  issuer_ref  = vault_pki_secret_backend_root_cert.root.issuer_id
  lifecycle {
    ignore_changes = [issuer_name]
  }
}

resource "vault_pki_secret_backend_issuer" "svc-intermediate" {
  backend     = vault_mount.pki-svc.path
  issuer_ref  = vault_pki_secret_backend_intermediate_set_signed.svc-intermediate.imported_issuers[0]
}

resource "vault_pki_secret_backend_issuer" "nodes-intermediate" {
  backend     = vault_mount.pki-nodes.path
  issuer_ref  = vault_pki_secret_backend_intermediate_set_signed.nodes-intermediate.imported_issuers[0]
}

resource "vault_pki_secret_backend_role" "node-cert" {
  backend             = vault_mount.pki-nodes.path
  name                = "node-cert"
  ttl                 = var.node-cert-issuer-period
  issuer_ref          = vault_pki_secret_backend_issuer.nodes-intermediate.issuer_ref
  use_csr_common_name = false
  allow_bare_domains  = false
  allow_subdomains    = true
  allowed_domains     = flatten([
    "mangos",
  ])
}

resource "vault_policy" "node-cert-signer" {
  name   = "node-cert-signer"
  policy = <<-EOP
    path "${vault_pki_secret_backend_role.node-cert.backend}/sign/${vault_pki_secret_backend_role.node-cert.name}" {
      capabilities = ["update"]
    }
    EOP
}

resource "vault_pki_secret_backend_role" "node-cert-self" {
  backend             = vault_mount.pki-nodes.path
  name                = "node-cert-self"
  ttl                 = var.node-cert-issuer-period
  issuer_ref          = vault_pki_secret_backend_issuer.nodes-intermediate.issuer_ref
  use_csr_common_name = false
  allow_bare_domains  = true
  allow_subdomains    = false
  allowed_domains_template = true
  allowed_domains = [
    "{{identity.entity.aliases.${vault_auth_backend.node-cert.accessor}.name}}",
  ]
}

resource "vault_pki_secret_backend_role" "vault-server" {
  backend            = vault_mount.pki-svc.path
  name               = "vault-server"
  ttl                = var.vault-issuer-period
  issuer_ref         = vault_pki_secret_backend_issuer.svc-intermediate.issuer_ref
  allow_subdomains   = false
  allow_bare_domains = true
  allow_glob_domains = true
  allowed_domains = flatten([
    "active.vault.service.consul",
    "standby.vault.service.consul",
    "vault.service.consul"])
}

locals {
  root-ca-cert = vault_pki_secret_backend_root_cert.root.certificate
}

output "root-ca" {
  value = local.root-ca-cert
}

resource "vault_pki_secret_backend_role" "consul-server" {
  backend            = vault_mount.pki-svc.path
  name               = "consul-server"
  ttl                = var.consul-server-issuer-period
  allow_bare_domains = true
  allow_glob_domains = true
  allowed_domains = flatten([
    "server.${local.consul-datacenter}.consul",
    "client.${local.consul-datacenter}.consul",
    "cli.client.${local.consul-datacenter}.consul",
  ])
}

resource "vault_pki_secret_backend_role" "consul-client" {
  backend            = vault_mount.pki-svc.path
  name               = "consul-client"
  ttl                = var.consul-client-issuer-period
  allow_bare_domains = true
  allow_glob_domains = true
  allowed_domains = flatten([
    "client.${local.consul-datacenter}.consul",
  ])
}

resource "terraform_data" "bootstrap-pki" {
  depends_on = [
    vault_pki_secret_backend_role.vault-server,
    vault_pki_secret_backend_role.consul-server,
    vault_pki_secret_backend_role.nomad-server,
  ]
}

resource "vault_pki_secret_backend_role" "nomad-server" {
  backend            = vault_mount.pki-svc.path
  name               = "nomad-server"
  ttl                = var.nomad-server-issuer-period
  allow_bare_domains = true
  allow_glob_domains = true
  allowed_domains = flatten([
    "nomad.service.consul",
    "server.${var.region}.nomad",
  ])
}

resource "vault_pki_secret_backend_role" "nomad-client" {
  backend            = vault_mount.pki-svc.path
  name               = "nomad-client"
  ttl                = var.nomad-client-issuer-period
  allow_bare_domains = true
  allow_glob_domains = true
  allowed_domains = flatten([
    "client.${var.region}.nomad",
  ])
}

resource "vault_auth_backend" "node-cert" {
    path = "node-cert"
    type = "cert"
}

resource "vault_policy" "sys-auth-node-cert-reader" {
  name   = "sys-auth-node-cert-reader"
  policy = <<-EOP
    path "sys/mounts/auth/${vault_auth_backend.node-cert.path}" {
      capabilities = ["read"]
    }
    EOP
}

resource "vault_cert_auth_backend_role" "node" {
    name           = "node"
    certificate    = local.nodes-ca
    backend        = vault_auth_backend.node-cert.path
    token_ttl      = 300
    token_max_ttl  = 600
    token_policies = [
      vault_policy.lookup-self.name,
      vault_policy.node-cert-self-renew.name,
      vault_policy.ssh-host-self-signer.name,
      vault_policy.consul-gossip.name,
      vault_policy.node-recovery-keys.name,
    ]
}

resource "vault_policy" "node-cert-self-renew" {
    name = "node-cert-self-renew"

    policy = <<-EOP
        path "${vault_mount.pki-nodes.path}/sign/node-cert-self" {
            capabilities = ["update"]
        }
    EOP
}

resource "vault_policy" "node-recovery-keys" {
    name = "node-recovery-keys"

    policy = <<-EOP
        # Allow nodes to create recovery keys for their own machine-id only (write-once, no read/update)
        # No read allowed because node does not need to read its own recovery key,
        #   it is only needed to be read by admins to recover the node
        # No update allowed to avoid compromised node may update recovery key
        #  Any update of recovery keys (even for rotating recovery keys) need admin actions
        #  For which admin key should be used
        path "secrets/mangos/recovery-keys/{{identity.entity.metadata.machine_id}}/*" {
            capabilities = ["create"]
        }
    EOP
}

resource "vault_identity_group" "vault-servers" {
  name        = "vault-servers"
  type        = "internal"
  policies    = [
    vault_policy.vault-issuer.name
  ]
  lifecycle {
    ignore_changes = [member_entity_ids]
  }
}

resource "vault_policy" "vault-issuer" {
  name   = "vault-issuer"
  policy = <<-EOP
    path "${vault_pki_secret_backend_role.vault-server.backend}/issue/${vault_pki_secret_backend_role.vault-server.name}" {
      capabilities = ["update"]
    }
    EOP
}

resource "vault_identity_group" "nomad-servers" {
  name        = "nomad-servers"
  type        = "internal"
  policies    = [
    vault_policy.nomad-server-issuer.name
  ]
  lifecycle {
    ignore_changes = [member_entity_ids]
  }
}

resource "vault_policy" "nomad-server-issuer" {
  name   = "nomad-server-issuer"
  policy = <<-EOP
    path "${vault_pki_secret_backend_role.nomad-server.backend}/issue/${vault_pki_secret_backend_role.nomad-server.name}" {
      capabilities = ["update"]
    }
    EOP
}

resource "vault_identity_group" "nomad-clients" {
  name        = "nomad-clients"
  type        = "internal"
  policies    = [
    vault_policy.nomad-client-issuer.name
  ]
  lifecycle {
    ignore_changes = [member_entity_ids]
  }
}

resource "vault_policy" "vault-identity-group-nomad-clients-rw" {
  name   = "vault-identity-group-nomad-clients-rw"
  policy = <<-EOP
    path "identity/group/name/${vault_identity_group.nomad-clients.name}" {
      capabilities = ["read", "update"]
    }
    EOP
}

resource "vault_policy" "nomad-client-issuer" {
  name   = "nomad-client-issuer"
  policy = <<-EOP
    path "${vault_pki_secret_backend_role.nomad-client.backend}/issue/${vault_pki_secret_backend_role.nomad-client.name}" {
      capabilities = ["update"]
    }
    EOP
}

resource "vault_identity_group" "consul-servers" {
  name        = "consul-servers"
  type        = "internal"
  policies    = [
    vault_policy.consul-server-issuer.name
  ]
  lifecycle {
    ignore_changes = [member_entity_ids]
  }
}

resource "vault_policy" "consul-server-issuer" {
  name   = "consul-server-issuer"
  policy = <<-EOP
    path "${vault_pki_secret_backend_role.consul-server.backend}/issue/${vault_pki_secret_backend_role.consul-server.name}" {
      capabilities = ["update"]
    }
    EOP
}

resource "vault_identity_group" "consul-clients" {
  name        = "consul-clients"
  type        = "internal"
  policies    = [
    vault_policy.consul-client-issuer.name
  ]
  lifecycle {
    ignore_changes = [member_entity_ids]
  }
}

resource "vault_policy" "vault-identity-group-consul-clients-rw" {
  name   = "vault-identity-group-consul-clients-rw"
  policy = <<-EOP
    path "identity/group/name/${vault_identity_group.consul-clients.name}" {
      capabilities = ["read", "update"]
    }
    EOP
}


resource "vault_policy" "consul-client-issuer" {
  name   = "consul-client-issuer"
  policy = <<-EOP
    path "${vault_pki_secret_backend_role.consul-client.backend}/issue/${vault_pki_secret_backend_role.consul-client.name}" {
      capabilities = ["update"]
    }
    EOP
}
