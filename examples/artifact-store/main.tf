# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The once-per-project artifact store: apply this before anything else (the
# flux-containers / flux-manifests publish pipelines need its outputs, and a
# cluster cannot bootstrap until those pipelines have populated the registry).
#
# Auth follows the cloud-accounts convention: ADC plus impersonation of the
# project's terraform-apply service account via the
# GOOGLE_IMPERSONATE_SERVICE_ACCOUNT environment variable (dotty injects it) —
# no credentials in the provider block.

provider "google" {
  project = var.project
  region  = var.region
}

module "artifact_store" {
  source = "../../modules/artifact-store"

  project  = var.project
  location = var.region

  # The org's WIF trust anchor lives in cloud-accounts (common root, hosted in
  # o-foundation): pass its github_wif output through. The module never
  # creates a pool -- it only binds the publisher SAs to the central one.
  wif = var.github_wif

  # Cluster identities from other projects that read this registry: each
  # cluster's registry_reader_members output (deterministic from its inputs,
  # so it can be listed before the cluster exists).
  reader_members = var.reader_members
}
