# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The out-of-band dex connector credential containers the platform's dex
# component syncs into the cluster (GKE Integrated Secret Synchronization),
# plus the accessor grants for its sync KSA. This is the terraform half of
# the dex secret-sync contract whose other half lives in the platform
# manifests (the dex component's resourceset-secrets.yaml): the container
# names (dex-<id>-<field>, id defaulting to type exactly as the cluster
# module's sso.tf does) and the consuming KSA subject (dex/dex-secrets) are
# mirrored here, versioned with the module release that tracks those
# manifests. Application containers are not here: an application's own
# module creates them and grants its own sync KSA, resource-side.
#
# Instantiate this from a DURABLE root, not beside the cluster: an upstream
# OAuth client outlives any one cluster, and the secret VERSIONS are added
# out of band (gcloud secrets versions add -- never terraform state) and must
# survive cluster destroy/recreate with no manual re-entry. There is no
# ordering problem in the other direction -- a Workload Identity principal
# string depends only on the project number and pool name, so IAM stores the
# grant before the pool exists and it sits inert until the cluster and its
# KSAs arrive.

data "google_project" "main" {
  project_id = var.project
}

locals {
  prefix = var.secret_prefix != null ? var.secret_prefix : ""

  # container name -> the KSA subject GKE Integrated Secret Synchronization
  # reads it as: one container per field declared in sso.connector.secrets,
  # named by the effective id. A container no sync references is never
  # created, and every referenced container exists (a SecretProviderClass
  # naming an absent container syncs nothing but errors forever).
  containers = var.sso.enabled && var.sso.connector != null ? {
    for field in var.sso.connector.secrets :
    "dex-${coalesce(var.sso.connector.id, var.sso.connector.type)}-${field}" => "ns/dex/sa/dex-secrets"
  } : {}

  wi_prefix = "principal://iam.googleapis.com/projects/${data.google_project.main.number}/locations/global/workloadIdentityPools/${var.project}.svc.id.goog/subject"
}

resource "google_secret_manager_secret" "main" {
  for_each = local.containers

  project   = var.project
  secret_id = "${local.prefix}${each.key}"
  labels    = var.labels

  replication {
    auto {}
  }
}

# Accessor only: the sync KSAs read versions, nothing else. Version WRITES
# stay a human/out-of-band concern -- grant rotation paths
# (secretVersionAdder) in the caller against the secrets output.
resource "google_secret_manager_secret_iam_member" "sync" {
  for_each = local.containers

  project   = var.project
  secret_id = google_secret_manager_secret.main[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "${local.wi_prefix}/${each.value}"
}
