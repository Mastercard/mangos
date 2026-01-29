variable "namespace" {
  type = string
}

job "falco" {
  type      = "system"
  namespace = var.namespace

  group "falco" {
    volume "kernel-debug" {
      type            = "host"
      source          = "kernel-debug"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      read_only       = true
    }

    volume "host-proc" {
      type            = "host"
      source          = "host-proc"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      read_only       = true
    }

    volume "host-etc" {
      type            = "host"
      source          = "host-etc"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      read_only       = true
    }

    volume "docker" {
      type            = "host"
      source          = "docker"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      read_only       = true
    }

    volume "containerd" {
      type            = "host"
      source          = "containerd"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      read_only       = true
    }

    task "falco" {
      driver = "docker"
      config {
        image    = "falcosecurity/falco:0.42.1"
        cap_add  = ["sys_admin", "sys_resource", "sys_ptrace"]
        cap_drop = ["all"]
      }

      volume_mount {
        volume      = "kernel-debug"
        destination = "/sys/kernel/debug"
      }

      volume_mount {
        volume      = "host-proc"
        destination = "/host/proc"
      }

      volume_mount {
        volume      = "host-etc"
        destination = "/host/etc"
      }

      volume_mount {
        volume      = "docker"
        destination = "/host/var/run/docker.sock"
      }

      volume_mount {
        volume      = "containerd"
        destination = "/host/run/containerd/containerd.sock"
      }
    }
  }
}
