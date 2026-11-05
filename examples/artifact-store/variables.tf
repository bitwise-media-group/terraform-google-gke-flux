# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "project" {
  description = "Project ID the artifact store lives in (e.g. x-patchy-app-<rand4>)."
  type        = string
}

variable "region" {
  description = "Artifact Registry location; keep it in the cluster's region."
  type        = string
  default     = "us-central1"
}

variable "github_wif" {
  description = "cloud-accounts' github_wif output (the org WIF trust anchor in o-foundation): full pool/provider resource names."
  type = object({
    pool_name     = string
    provider_name = string
  })
}

variable "reader_members" {
  description = "IAM members that read this registry. Recommended: the org-wide service-account principal set + one all-identities workload-identity-pool principalSet per cluster project (see modules/artifact-store/iam.tf); or per-identity lists from each cluster's registry_reader_members output."
  type        = list(string)
  default     = []
}

variable "manifest_publishers" {
  description = "Manifest-publishing repos, keyed by name: the paths each owns beneath the repository and its numeric repository id (GET /repos/<org>/<repo>; null until the repo exists, and its OIDC subject cannot match without it)."
  type = map(object({
    repository_id = optional(number)
    paths         = list(string)
  }))
  default = {
    flux-manifests           = { paths = ["manifests/*"] }
    github-arc-app-manifests = { paths = ["manifests/github-arc"] }
  }
}
