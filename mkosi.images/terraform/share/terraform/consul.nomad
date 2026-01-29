variable "namespace" {
  type = string
}

job "consul" {
  namespace = var.namespace

  group "client" {
    service {
      tags         = ["api"]
      name         = "consul"
      port         = "http"
      address_mode = "alloc"
      connect {
        sidecar_service {}
      }
    }

    service {
      tags         = ["dns"]
      name         = "consul"
      port         = "dns"
      address_mode = "host"
    }

    network {
      mode = "bridge"
      port "http" {
        to = 8500
      }
      port "dns" {
        static       = 8600
        host_network = "default"
      }
    }

    task "main" {
      # Get a Vault token to use in templates
      vault {
        role = "consul"
      }

      # Get Consul token
      consul {}

      template {
        data        = <<-EOF
        encrypt   = "{{ with secret "secrets/mangos/consul/gossip" }}{{ .Data.encryption_key | trimSpace }}{{ end }}"
        addresses {
          dns = "0.0.0.0"
        }
        node_name = "consul-api-{{ env "NOMAD_SHORT_ALLOC_ID" }}"
        acl {
          enabled = true
          tokens {
            default = "{{ env "CONSUL_HTTP_TOKEN" }}"
            agent   = "{{ env "CONSUL_HTTP_TOKEN" }}"
          }
        }
        ui_config {
          enabled = true
        }
        EOF
        destination = "${NOMAD_SECRETS_DIR}/consul.hcl"
        change_mode = "restart"
      }

      driver = "docker"

      env {
        HOST_IP = "${attr.unique.network.ip-address}"
      }

      config {
        image = "hashicorp/consul"
        args = [
          "agent",
          "-retry-join", "${HOST_IP}",
          "-datacenter", "${NOMAD_REGION}-${NOMAD_DC}",
          "-config-file", "${NOMAD_SECRETS_DIR}/consul.hcl"
        ]
      }
    }
  }
}
