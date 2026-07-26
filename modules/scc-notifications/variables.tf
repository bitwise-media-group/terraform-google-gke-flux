# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "project" {
  description = <<-EOT
    Project ID the topic, subscription and push identity live in. Null uses the provider's project, which is the
    common case: these resources belong beside the cluster that consumes them.
  EOT
  type        = string
  nullable    = true
  default     = null
}

variable "organization_id" {
  description = <<-EOT
    Numeric organization id the notification config is created under. Creating it requires
    roles/securitycenter.admin at the organization -- an org-scoped config is what makes one patchy deployment see
    every project's findings.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+$", var.organization_id))
    error_message = "organization_id must be the numeric organization id (e.g. \"123456789012\"), with no prefix."
  }
}

variable "location" {
  description = "Security Command Center location for the notification config. Only global is generally available."
  type        = string
  nullable    = false
  default     = "global"
}

variable "config_id" {
  description = "Notification config id, unique within the organization."
  type        = string
  nullable    = false
  default     = "patchy"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-_]{0,127}$", var.config_id))
    error_message = "config_id must start with a letter and contain only letters, digits, hyphens and underscores."
  }
}

variable "description" {
  description = "Human-facing description recorded on the notification config."
  type        = string
  nullable    = false
  default     = "Findings forwarded to patchy for triage and remediation."
}

variable "filter" {
  description = <<-EOT
    Which findings to publish, in Security Command Center's findings.list filter syntax. This is the cheapest place
    to control volume: a finding dropped here never becomes a Pub/Sub message, a webhook delivery, or a Finding
    resource. The default takes active, unmuted findings at HIGH or above.

    Two syntax traps the default works around: negation is a leading `-`, not `NOT` (there is no `!=` operator), and
    OR binds *tighter* than AND -- so the severity alternation is parenthesised to say what it looks like it says.
  EOT
  type        = string
  nullable    = false
  default     = "state=\"ACTIVE\" AND -mute=\"MUTED\" AND (severity=\"HIGH\" OR severity=\"CRITICAL\")"

  validation {
    condition     = length(trimspace(var.filter)) > 0
    error_message = "filter must not be empty -- an empty filter publishes every finding in the organization."
  }
}

variable "topic_name" {
  description = "Pub/Sub topic name findings are published to."
  type        = string
  nullable    = false
  default     = "patchy-scc-findings"
}

variable "subscription_name" {
  description = "Pub/Sub push subscription name."
  type        = string
  nullable    = false
  default     = "patchy-scc-push"
}

variable "push_service_account_id" {
  description = <<-EOT
    account_id of the service account whose identity Pub/Sub presents to patchy. Its email is what patchy is
    configured to trust, so changing it means reconfiguring the Integration.
  EOT
  type        = string
  nullable    = false
  default     = "patchy-scc-push"

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{4,28})[a-z0-9]$", var.push_service_account_id))
    error_message = "push_service_account_id must be 6-30 characters, lowercase alphanumerics and hyphens, starting with a letter."
  }
}

variable "push" {
  description = <<-EOT
    Where and how findings are delivered. endpoint is patchy's receiver, whose path is fixed by the provider name
    (/google-cloud/webhooks). audience defaults to the endpoint, which is the convention patchy's own default
    assumes -- set it explicitly only when the Integration says something else.
  EOT
  type = object({
    endpoint             = string
    audience             = optional(string)
    ack_deadline_seconds = optional(number, 30)
    minimum_backoff      = optional(string, "10s")
    maximum_backoff      = optional(string, "600s")
  })
  nullable = false

  validation {
    condition     = can(regex("^https://", var.push.endpoint))
    error_message = "push.endpoint must be an https URL -- Pub/Sub refuses to push an OIDC token over plaintext."
  }

  validation {
    condition     = endswith(var.push.endpoint, "/google-cloud/webhooks")
    error_message = "push.endpoint must end in /google-cloud/webhooks, the route patchy serves this provider on."
  }

  validation {
    condition     = var.push.ack_deadline_seconds >= 10 && var.push.ack_deadline_seconds <= 600
    error_message = "push.ack_deadline_seconds must be between 10 and 600."
  }
}

variable "dead_letter" {
  description = <<-EOT
    Where findings patchy never accepted end up. Without this a repeatedly failing delivery is retried until it
    expires and then disappears, leaving no record that a finding was lost.
  EOT
  type = object({
    enabled               = optional(bool, true)
    max_delivery_attempts = optional(number, 10)
    retention             = optional(string, "604800s")
  })
  nullable = false
  default  = {}

  validation {
    condition     = var.dead_letter.max_delivery_attempts >= 5 && var.dead_letter.max_delivery_attempts <= 100
    error_message = "dead_letter.max_delivery_attempts must be between 5 and 100."
  }
}

variable "asset_viewer_members" {
  description = <<-EOT
    IAM members granted roles/cloudasset.viewer on the project, for resolving a finding's repository from its
    resource's ownership labels. Pass patchy's context-controller workload identity principal; leave empty when the
    grant is owned centrally or repository resolution is not in use.
  EOT
  type        = list(string)
  nullable    = false
  default     = []
}

variable "labels" {
  description = "Labels applied to the topics and subscription."
  type        = map(string)
  nullable    = false
  default     = {}
}
