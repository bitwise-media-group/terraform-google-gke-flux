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
    signed manifest images under manifests/<name> within it (manifests/platform, the entrypoint the clusters sync;
    manifests/<component> and manifests/<app> beside it).
  EOT
  type        = string
  nullable    = false
  default     = "platform"
}

variable "github" {
  description = <<-EOT
    GitHub org and repository names the publisher trust is pinned to, plus the immutable numeric ids GitHub embeds in
    the OIDC subjects of post-2026-07-15 repos (org_id from GET /orgs/<org>, repo ids from GET /repos/<org>/<repo>).
    containers is the chart/image mirror (flux-containers). manifest_publishers is every repo that publishes manifest
    images, keyed by repo name: the platform's (paths ["manifests/*"], the platform authority) and one per application
    repo (paths ["manifests/<app>"]). Each gets its own service account, impersonable from its main branch, its v*
    release tags and the promotion environment; repository_id may stay null until that repo exists on GitHub.
    paths is declarative here, NOT enforced by IAM: Artifact Registry authorizes pushes per repository and its IAM
    Conditions cannot match package paths, so every publisher holds artifactregistry.writer on the whole repository
    and path ownership is enforced by consumer-side signature verification (each consumer pins the signer workflow
    of the repo that owns the path). platform names the key that publishes the platform entrypoint: its workflow
    identities are what signed_identity_subjects exports, and it keeps the <name>-manifest-publisher service account;
    every other key gets <name>-mp-<8 hex of sha256(repo)> (service account ids cap at 30 characters).
  EOT
  type = object({
    org           = optional(string, "bitwise-media-group")
    org_id        = optional(number, 282673588)
    containers    = optional(string, "flux-containers")
    containers_id = optional(number, 1303643498)
    platform      = optional(string, "flux-manifests")
    manifest_publishers = optional(map(object({
      repository_id = optional(number)
      paths         = list(string)
    })), { flux-manifests = { paths = ["manifests/*"] } })
  })
  nullable = false
  default  = {}

  validation {
    condition     = contains(keys(var.github.manifest_publishers), var.github.platform)
    error_message = "github.platform must name a key of github.manifest_publishers - the platform entrypoint's publisher is what the clusters' signed_identity_subjects pin."
  }

  validation {
    condition = alltrue([
      for repo in keys(var.github.manifest_publishers) : can(regex("^[A-Za-z0-9._-]+$", repo))
    ])
    error_message = "github.manifest_publishers keys must be GitHub repository names."
  }

  validation {
    condition = alltrue(flatten([
      for publisher in values(var.github.manifest_publishers) : concat(
        [length(publisher.paths) > 0],
        [for path in publisher.paths : can(regex("^manifests/(\\*|[a-z0-9._-]+(/[a-z0-9._-]+)*(/\\*)?)$", path))],
      )
    ]))
    error_message = "Each github.manifest_publishers entry needs at least one path beneath manifests/ (e.g. manifests/* or manifests/<app>): lowercase docker path segments, with at most a trailing /* wildcard."
  }
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
    instead of keyless Fulcio identities. When set, every publisher service account gets cloudkms signerVerifier +
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
