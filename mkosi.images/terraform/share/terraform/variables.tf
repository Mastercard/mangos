#
# Cluster configuration
#
variable "datacenter" {
  type        = string
  default     = "test"
  description = "Datacenter name for this deployment"
}

variable "region" {
  type        = string
  default     = "global"
  description = "Region name for this deployment"
}

variable "domain" {
  type        = string
  default     = "test"
  description = "Domain for this deployment"
}

variable "consul-datacenter" {
  type        = string
  default     = ""
  description = "Datacenter value for Consul (defaults to $${region}-$${datacenter})"
}

locals {
  consul-datacenter = var.consul-datacenter != "" ? var.consul-datacenter : "${var.region}-${var.datacenter}"
}

variable "auto-host-pattern" {
  type        = string
  default     = "*.*.compute.internal"
  description = "A glob pattern matching the hostnames dished out by your cloud. Default works for EC2."
}

variable "root-pki-path" {
  type        = string
  description = "Path to mount the root PKI"
  default     = "pki-root"
}

variable "root-ca-common-name" {
  type    = string
  default = "Mangos Root CA"
}

variable "intermediate-pki-svc-path" {
  type        = string
  description = "Path to mount the Services PKI"
  default     = "pki-svc"
}

variable "intermediate-pki-nodes-path" {
  type        = string
  description = "Path to mount the Nodes PKI"
  default     = "pki-nodes"
}

variable "intermediate-svc-ca-common-name" {
  type    = string
  default = "Intermediate CA - Services"
}

variable "intermediate-nodes-ca-common-name" {
  type    = string
  default = "Intermediate CA - Nodes"
}

variable "root-cert-organization" {
  type    = string
  default = ""
}

variable "intermediate-svc-cert-organization" {
  type    = string
  default = ""
}

variable "intermediate-nodes-cert-organization" {
  type    = string
  default = ""
}

variable "root-max-lease-ttl" {
  type        = number
  description = "Max lease TTL for root CA (default 10 years)"
  default     = 10 * 365 * 24 * 60 * 60
}

variable "intermediate-max-lease-ttl" {
  type        = number
  description = "Max lease TTL for intermediate CAs (default 5 years)"
  default     = 5 * 365 * 24 * 60 * 60
}

variable "nomad-server-issuer-period" {
  type        = number
  description = "Validity period (in seconds) for Nomad server certificates. Default is 12 hours."
  default     = 12 * 60 * 60
}

variable "nomad-client-issuer-period" {
  type        = number
  description = "Validity period (in seconds) for Nomad server certificates. Default is 12 hours."
  default     = 12 * 60 * 60
}

variable "vault-issuer-period" {
  type        = number
  description = "Validity period (in seconds) for Vault certificates. Default is 12 hours."
  default     = 12 * 60 * 60
}

variable "node-cert-issuer-period" {
  type        = number
  description = "Validity period (in seconds) for node certificates. Default is 48 hours."
  default     = 48 * 60 * 60
}

variable "consul-server-issuer-period" {
  type        = number
  description = "Validity period (in seconds) for Consul server certificates. Default is 12 hours."
  default     = 12 * 60 * 60
}

variable "consul-client-issuer-period" {
  type        = number
  description = "Validity period (in seconds) for Consul client certificates. Default is 12 hours."
  default     = 12 * 60 * 60
}

#
# Input variables
#
variable "nomad-address" {
  description = "Nomad address"
  type        = string
  default     = "https://nomad.service.consul:4646/"
}

variable "nomad-vault-path" {
  default     = "nomad"
  description = "The Vault path where the Nomad backend should be mounted"
}

variable "nomad-vault-default-lease-ttl" {
  description = "The default lease time (in seconds) for the Vault Nomad backend"
  type        = string
  default     = "3600"
}

variable "nomad-vault-max-lease-ttl" {
  description = "The max lease time (in seconds) for the Vault Nomad backend"
  type        = string
  default     = "7200"
}

variable "nomad-vault-max-ttl" {
  description = "The max TTL (in seconds) for the Vault Nomad backend"
  type        = string
  default     = "600"
}

variable "nomad-vault-ttl" {
  description = "The TTL (in seconds) for the Vault Nomad backend"
  type        = string
  default     = "240"
}
