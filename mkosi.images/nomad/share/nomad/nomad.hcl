data_dir = "/var/lib/nomad/data"

acl {
  enabled = true
}

tls {
  http = true
  rpc  = true

  ca_file   = "/var/lib/nomad/ssl/ca.pem"
  cert_file = "/var/lib/nomad/ssl/nomad.crt"
  key_file  = "/var/lib/nomad/ssl/nomad.key"
}

vault {
  enabled               = true
  address               = "https://vault.service.consul:8200/"
  ca_file               = "/var/lib/nomad/ssl/ca.pem"
  jwt_auth_backend_path = "nomad-workload"
  default_identity {
    aud  = ["vault.io"]
    env  = false
    file = true
    ttl  = "1h"
  }
}

client {
  enabled                     = true
  bridge_network_hairpin_mode = true

  # During testing (in Github Actions), we're several levels deep:
  # Azure host (wholly unavailable to us, but listed for completeness)
  # Azure VM / Github Action runner VM (I *think* these are one and the same)
  # Mangos test VM
  # Container inside Mangos test VM
  #
  # We use ${attr.unique.network.ip-address} to the the host's IP address.
  # This generally works, but cloud provider fingerprinting logic in Nomad
  # overrides this with the detected cloud provider IP address, i.e. the IP
  # address of the Azure VM.
  #
  # To avoid this, we disable all cloud provider fingerprinting. If we need
  # to undo this, find a different way to determine the IP.
  options = {
    "fingerprint.denylist" = "env_aws,env_gce,env_azure,env_digitalocean"
  }

  host_network "default" {
    cidr = "{{ GetDefaultInterfaces | exclude \"type\" \"IPv6\" | attr \"string\" }}"
  }

  host_volume "ca-certificates" {
    path      = "/etc/ssl/certs"
    read_only = true
  }

  host_volume "docker" {
    path      = "/var/run/docker.sock"
    read_only = false
  }

  host_volume "localtime" {
    path      = "/etc/localtime"
    read_only = true
  }
}

consul {
  service_auth_method   = "nomad-workload"
  task_auth_method      = "nomad-workload"
  allow_unauthenticated = false

  service_identity {
    aud = ["consul.io"]
    ttl = "1h"
  }

  task_identity {
    aud = ["consul.io"]
    ttl = "1h"
  }
}

server {
  oidc_issuer = "https://nomad.service.consul:4646"
}
