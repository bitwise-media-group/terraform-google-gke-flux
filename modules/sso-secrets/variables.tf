# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "project" {
  description = <<-EOT
    Project ID the secret containers live in -- necessarily the cluster's own project: the platform's dex component
    reads containers from the GCP_PROJECT cluster var, and its sync KSA authenticates through that project's
    <project>.svc.id.goog Workload Identity pool.
  EOT
  type        = string
  nullable    = false
}

variable "secret_prefix" {
  description = <<-EOT
    Prefix for every container name, matching the cluster module's secret_prefix input (its secret_prefix output;
    the platform syncs <prefix><container>, so the two must move together). Lets multiple clusters share one project
    with distinct secrets -- each cluster then needs its own prefixed set of containers and fresh out-of-band
    versions. Include the trailing separator (e.g. 'platform-x-'); null keeps the unprefixed names.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.secret_prefix == null || try(can(regex("^[A-Za-z0-9_-]*$", var.secret_prefix)), false)
    error_message = "secret_prefix must use Secret Manager id characters only ([A-Za-z0-9_-])."
  }
}

variable "sso" {
  description = <<-EOT
    Platform SSO election -- pass the cluster module's sso value verbatim (its attributes beyond enabled and the
    connector's id/type/secrets, e.g. kubectl and clients, are dropped by type conversion). enabled mirrors the cluster's dex toggle and gates
    the connector containers; the connector's secrets names its out-of-band credential fields, creating one
    dex-<id>-<field> Secret Manager container per field (id defaulting to type, matching the cluster module) --
    populate versions out of band (an OAuth client cannot be terraformed). On its own enabled creates nothing: no
    connector is declared by default.
  EOT
  type = object({
    enabled = optional(bool, false)
    connector = optional(object({
      id      = optional(string)
      type    = string
      secrets = optional(set(string), ["client-id", "client-secret"])
    }))
  })
  nullable = false
  default  = {}

  validation {
    condition = var.sso.connector == null || (
      can(regex("^[a-z0-9-]+$", coalesce(var.sso.connector.id, var.sso.connector.type))) &&
      coalesce(var.sso.connector.id, var.sso.connector.type) != "client"
    )
    error_message = "sso.connector.id (defaulting to type) must match ^[a-z0-9-]+$ and must not be \"client\" (reserved -- relying-party containers are already named dex-client-<id>)."
  }

  validation {
    condition = var.sso.connector == null || alltrue([
      for field in var.sso.connector.secrets : can(regex("^[a-z0-9-]+$", field))
    ])
    error_message = "sso.connector.secrets entries must match ^[a-z0-9-]+$."
  }
}

variable "labels" {
  description = "Labels applied to every secret container."
  type        = map(string)
  nullable    = false
  default     = {}
}
