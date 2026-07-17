# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Publisher service accounts. These are the only real GSAs in the platform —
# in-cluster workloads use direct Workload Identity Federation for GKE grants
# (no GSA), but google-github-actions/auth needs a service account to
# impersonate through the WIF provider.

locals {
  # repo:<org>@<org id>/<repo>@<repo id>:ref:refs/heads/main etc. — the exact
  # GitHub OIDC subjects admitted to each publisher. principal:// members match
  # google.subject exactly; the principalSet:// member matches the
  # attribute.publish mapping.
  wif_principal_prefix = "principal://iam.googleapis.com/${var.wif.pool_name}/subject"
  wif_publish_prefix   = "principalSet://iam.googleapis.com/${var.wif.pool_name}/attribute.publish"

  # GitHub mints immutable subjects for repos created (or renamed/transferred)
  # after 2026-07-15: repo:<org>@<org id>/<repo>@<repo id>:<context>. Both
  # publishing repos are post-cutoff, so subject-matched members must pin the
  # numeric ids — the name-only form never matches and impersonation fails
  # with a 403. Only google.subject changes: assertion.repository (the
  # attribute.publish source) still carries plain names.
  containers_subject_repo = "${var.github.org}@${var.github.org_id}/${var.github.containers}@${var.github.containers_id}"

  # flux-manifests may not exist on GitHub yet when the store is first
  # applied. Until manifests_id is set, its subject member falls back to the
  # name-only form — which a post-cutoff repo will never present — so set the
  # id and re-apply as soon as the repo is created.
  manifests_subject_repo = (
    var.github.manifests_id != null
    ? "${var.github.org}@${var.github.org_id}/${var.github.manifests}@${var.github.manifests_id}"
    : "${var.github.org}/${var.github.manifests}"
  )

  # Keyed by fixed labels, not member strings: keys stay plan-known even when
  # var.wif carries computed values (e.g. the pool resource's name output).
  manifest_publisher_members = {
    # Release tags publish versioned artifacts and move `staging`.
    tag = "${local.wif_publish_prefix}/${var.github.org}/${var.github.manifests}:tag"
    # The protected promotion environment moves `stable`.
    env = "${local.wif_principal_prefix}/repo:${local.manifests_subject_repo}:environment:${var.promotion_environment}"
  }
}

resource "google_service_account" "chart_publisher" {
  project      = var.project
  account_id   = "${var.name}-chart-publisher"
  display_name = "Chart publisher (${var.github.org}/${var.github.containers})"
  description  = "Pushes mirrored charts and images to the ${var.repository_id} repository from GitHub Actions"
}

resource "google_service_account" "manifest_publisher" {
  project      = var.project
  account_id   = "${var.name}-manifest-publisher"
  display_name = "Manifest publisher (${var.github.org}/${var.github.manifests})"
  description  = "Pushes the signed flux-manifests artifact and moves channel tags from GitHub Actions"
}

# IAM rejects members for a workload identity pool that does not exist yet;
# callers passing the pool resource's name output get that ordering for free.
#
# flux-containers publishes (and keyless-signs) charts + images from its
# default branch only — PR validation never gets push credentials.
resource "google_service_account_iam_member" "chart_publisher_wif" {
  service_account_id = google_service_account.chart_publisher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.wif_principal_prefix}/repo:${local.containers_subject_repo}:ref:refs/heads/main"
}

resource "google_service_account_iam_member" "manifest_publisher_wif" {
  for_each = local.manifest_publisher_members

  service_account_id = google_service_account.manifest_publisher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = each.value
}

# Artifact Registry IAM is repository-scoped, so both publishers hold writer on
# the whole platform repository — arc's per-namespace push separation has no AR
# equivalent. The effective control is consumer-side verification: every
# OCIRepository and the Kyverno policy pin the exact signer workflow identity,
# so a compromised chart publisher pushing a fake manifests artifact still
# fails verification on the cluster.
resource "google_artifact_registry_repository_iam_member" "chart_publisher" {
  project    = var.project
  location   = google_artifact_registry_repository.platform.location
  repository = google_artifact_registry_repository.platform.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.chart_publisher.member
}

resource "google_artifact_registry_repository_iam_member" "manifest_publisher" {
  project    = var.project
  location   = google_artifact_registry_repository.platform.location
  repository = google_artifact_registry_repository.platform.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.manifest_publisher.member
}

# Read access for cluster identities living in OTHER projects (the store is
# central — o-foundation — while clusters run in app projects whose apply
# identities cannot grant IAM here). Content security comes from cosign
# verification, not from denying reads, so coarse members are the intended
# shape:
#
#   # every service account in the org (node SAs of all current/future clusters;
#   # domain: members would NOT work — they exclude service accounts)
#   "principalSet://cloudresourcemanager.googleapis.com/organizations/<org number>/type/ServiceAccount",
#   # all GKE workload identities of one cluster project (flux + kyverno
#   # principals are pool identities, not service accounts, so the org
#   # service-account set does not cover them)
#   "principalSet://iam.googleapis.com/projects/<app project number>/locations/global/workloadIdentityPools/<app project id>.svc.id.goog/*",
#
# Per-identity least privilege remains possible: feed each cluster's
# registry_reader_members output through instead.
resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each = toset(var.reader_members)

  project    = var.project
  location   = google_artifact_registry_repository.platform.location
  repository = google_artifact_registry_repository.platform.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}
