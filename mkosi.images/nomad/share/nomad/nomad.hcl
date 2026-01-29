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

  host_network "default" {
    cidr = "{{ GetDefaultInterfaces | exclude \"type\" \"IPv6\" | attr \"string\" }}"
  }

  host_volume "host-etc" {
    path      = "/etc"
    read_only = true
  }

  host_volume "host-proc" {
    path      = "/proc"
    read_only = true
  }

  host_volume "containerd" {
    path = "/run/containerd/containerd.sock"
    # Nothing has needed r/w access yet
    read_only = true
  }

  host_volume "kernel-debug" {
    path      = "/sys/kernel/debug"
    read_only = true
  }

  host_volume "ca-certificates" {
    path      = "/etc/ssl/certs"
    read_only = true
  }

  host_volume "docker" {
    path      = "/var/run/docker.sock"
    read_only = false
  }

  host_volume "journal" {
    path      = "/var/log/journal"
    read_only = true
  }

  host_volume "localtime" {
    path      = "/etc/localtime"
    read_only = true
  }
}

plugin "docker" {
  config {
    allow_caps = [
      "audit_write",
      "chown",
      "dac_override",
      "fowner",
      "fsetid",
      "kill",
      "mknod",
      "net_bind_service",
      "setfcap",
      "setgid",
      "setpcap",
      "setuid",
      "sys_chroot",
      "sys_admin",
      "sys_ptrace",
      "sys_resource"
    ]

    extra_labels = ["*"]
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
