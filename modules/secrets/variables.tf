# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "project" {
  description = <<-EOT
    Project ID the secret containers live in -- necessarily the cluster's own project: the manifests read containers
    from the GCP_PROJECT cluster var, and the sync KSAs authenticate through that project's <project>.svc.id.goog
    Workload Identity pool.
  EOT
  type        = string
  nullable    = false
}

variable "secret_prefix" {
  description = <<-EOT
    Prefix for every container name, matching the cluster module's secret_prefix input (the manifests sync
    <prefix><container>, so the two must move together). Lets multiple clusters share one project with distinct
    secrets -- each cluster then needs its own prefixed set of containers and fresh out-of-band versions. Include the
    trailing separator (e.g. 'patchy-x-'); null keeps the unprefixed names.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.secret_prefix == null || try(can(regex("^[A-Za-z0-9_-]*$", var.secret_prefix)), false)
    error_message = "secret_prefix must use Secret Manager id characters only ([A-Za-z0-9_-])."
  }
}

variable "stack_components" {
  description = <<-EOT
    The flux-manifests optional-tier components the cluster elects -- pass the cluster module's stack_components
    value. Only patchy carries out-of-band credentials today: electing it creates the GitHub App containers plus the
    elected harnesses' model credentials; flux-web is accepted for symmetric passing and creates nothing (dex rides
    sso.enabled, mirroring the cluster module's sso toggle).
  EOT
  type        = set(string)
  nullable    = false
  default     = ["flux-web", "patchy"]

  validation {
    condition = alltrue([
      for component in var.stack_components : contains(["flux-web", "patchy"], component)
    ])
    error_message = "stack_components entries must be optional-tier short names: flux-web, patchy (dex rides sso.enabled)."
  }
}

variable "sso" {
  description = <<-EOT
    Platform SSO election -- pass the cluster module's sso value verbatim (its attributes beyond enabled and
    connectors[*].secrets are dropped by type conversion). enabled mirrors the cluster's dex toggle and gates the
    per-connector containers; each connector's secrets names its out-of-band credential fields, creating one
    dex-<id>-<field> Secret Manager container per (connector, field) pair -- populate versions out of band (an OAuth
    client cannot be terraformed). On its own enabled creates nothing: no connector is declared by default.
  EOT
  type = object({
    enabled = optional(bool, false)
    connectors = optional(map(object({
      secrets = optional(set(string), ["client-id", "client-secret"])
    })), {})
  })
  nullable = false
  default  = {}

  validation {
    condition     = alltrue([for id in keys(var.sso.connectors) : can(regex("^[a-z0-9-]+$", id)) && id != "client"])
    error_message = "sso.connectors keys must match ^[a-z0-9-]+$ and must not be \"client\" (reserved -- relying-party containers are already named dex-client-<id>)."
  }

  validation {
    condition = alltrue(flatten([
      for c in values(var.sso.connectors) : [
        for field in c.secrets : can(regex("^[a-z0-9-]+$", field))
      ]
    ]))
    error_message = "sso.connectors[*].secrets entries must match ^[a-z0-9-]+$."
  }
}

variable "agent_harnesses" {
  description = <<-EOT
    The agent harnesses the cluster elects -- pass the cluster module's patchy.harnesses value (published to the
    manifests as AGENT_HARNESSES). Each harness brings its credential container: claude's rides claude_provider
    (anthropic only), codex adds patchy-openai-token, copilot adds patchy-copilot-token.
  EOT
  type        = set(string)
  nullable    = false
  default     = ["claude"]

  validation {
    condition = alltrue([
      for harness in var.agent_harnesses : contains(["claude", "codex", "copilot"], harness)
    ])
    error_message = "agent_harnesses entries must be harness short names: claude, codex, copilot."
  }
}

variable "claude_provider" {
  description = <<-EOT
    The claude runner's model provider -- pass the cluster module's patchy.claude.provider.name value. Only anthropic
    needs a credential container (patchy-anthropic-token); a vertex cluster's egress broker authenticates with its
    cloud identity and gets none.
  EOT
  type        = string
  nullable    = false
  default     = "anthropic"

  validation {
    condition     = contains(["anthropic", "vertex"], var.claude_provider)
    error_message = "claude_provider must be anthropic or vertex, matching the cluster module's patchy.claude.provider.name."
  }
}

variable "labels" {
  description = "Labels applied to every secret container."
  type        = map(string)
  nullable    = false
  default     = {}
}
