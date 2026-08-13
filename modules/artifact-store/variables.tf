# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "project" {
  description = "Project ID the artifact store lives in (e.g. the x-patchy-app project)."
  type        = string
  nullable    = false
}

variable "location" {
  description = "Artifact Registry location. Keep it in the cluster's region so image pulls stay regional."
  type        = string
  nullable    = false
  default     = "us-central1"
}

variable "name" {
  description = "Base name for the publisher service accounts (account_id prefix, so keep it short)."
  type        = string
  nullable    = false
  default     = "platform"

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,10})$", var.name))
    error_message = "name must be a lowercase account_id prefix of at most 11 characters (leaves room for the -chart-publisher / -manifest-publisher suffixes within the 30-character account_id limit)."
  }
}

variable "repository_id" {
  description = <<-EOT
    Artifact Registry repository id. Charts land under charts/<name>, images under images/<original-path>, and the
    manifests artifact at flux-manifests within it.
  EOT
  type        = string
  nullable    = false
  default     = "platform"
}

variable "github" {
  description = <<-EOT
    GitHub org and repository names the publisher trust is pinned to, plus the immutable numeric ids GitHub embeds in
    the OIDC subjects of post-2026-07-15 repos (org_id from GET /orgs/<org>, repo ids from GET /repos/<org>/<repo>).
    manifests_id may stay null until that repo exists on GitHub.
  EOT
  type = object({
    org           = optional(string, "bitwise-media-group")
    org_id        = optional(number, 282673588)
    containers    = optional(string, "flux-containers")
    containers_id = optional(number, 1303643498)
    manifests     = optional(string, "flux-manifests")
    manifests_id  = optional(number)
  })
  nullable = false
  default  = {}
}

variable "promotion_environment" {
  description = "GitHub environment (protected, reviewer-gated) whose jobs may move the stable channel tag."
  type        = string
  nullable    = false
  default     = "production"
}

variable "wif" {
  description = <<-EOT
    The org's existing Workload Identity Federation pool/provider for GitHub OIDC, as full resource names. The trust
    anchor is owned centrally (cloud-accounts' o-foundation) -- this module only binds publishers to it.
  EOT
  type = object({
    pool_name     = string
    provider_name = string
  })
  nullable = false

  validation {
    condition = (
      can(regex("^projects/[^/]+/locations/global/workloadIdentityPools/[^/]+$", var.wif.pool_name)) &&
      can(regex("^projects/[^/]+/locations/global/workloadIdentityPools/[^/]+/providers/[^/]+$", var.wif.provider_name))
    )
    error_message = "wif.pool_name and wif.provider_name must be full resource names: projects/<number>/locations/global/workloadIdentityPools/<pool>[/providers/<provider>]."
  }
}

variable "signing_kms_key_name" {
  description = <<-EOT
    Asymmetric SIGN Cloud KMS crypto key the publish workflows sign artifacts with (cosign sign --key gcpkms://<name>),
    instead of keyless Fulcio identities. When set, both publisher service accounts get cloudkms signerVerifier +
    viewer on the key; feed the same name to the cluster module's signed_identity.kms_key_name so verification
    matches. Null keeps signing keyless (the signed_identity_subjects output). The key itself lives outside this
    module — signing identity should outlive any one store.
  EOT
  type        = string
  nullable    = true
  default     = null

  validation {
    condition = var.signing_kms_key_name == null || can(
      regex("^projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+$", var.signing_kms_key_name)
    )
    error_message = "signing_kms_key_name must be a Cloud KMS crypto key resource name: projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>."
  }
}

variable "reader_members" {
  description = <<-EOT
    IAM members granted artifactregistry.reader on the repository. Coarse grants are the intended shape (content
    security is cosign verification, not read denial): the org-wide service-account principal set plus one
    all-identities workload-identity-pool principalSet per cluster project. Per-identity least privilege remains
    possible via each cluster's registry_reader_members output.
  EOT
  type        = list(string)
  nullable    = false
  default     = []
}

variable "untagged_expiry_days" {
  description = "Days after which untagged manifests (failed/superseded pushes) are deleted."
  type        = number
  nullable    = false
  default     = 14
}

variable "labels" {
  description = "Labels applied to the Artifact Registry repository."
  type        = map(string)
  nullable    = false
  default     = {}
}
