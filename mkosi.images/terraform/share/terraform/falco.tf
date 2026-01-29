resource "nomad_job" "falco" {
  jobspec = file("${path.module}/falco.nomad")
  hcl2 {
    vars = {
      "namespace" = nomad_namespace.admin.name
    }
  }
}
