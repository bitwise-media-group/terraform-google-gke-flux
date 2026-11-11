# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Publisher service accounts. These are the only real GSAs in the platform —
# in-cluster workloads use direct Workload Identity Federation for GKE grants
# (no GSA), but google-github-actions/auth needs a service account to
# impersonate through the WIF provider.

locals {
  # repo:<org>@<org id>/<repo>@<repo id>:ref:refs/heads/main -- the exact
  # GitHub OIDC subjects admitted to each publisher. principal:// members match
  # google.subject exactly.
  wif_principal_prefix = "principal://iam.googleapis.com/${var.wif.pool_name}/subject"

  # GitHub mints immutable subjects for repos created (or renamed/transferred)
  # after 2026-07-15: repo:<org>@<org id>/<repo>@<repo id>:<context>. Both
  # publishing repos are post-cutoff, so subject-matched members must pin the
  # numeric ids — the name-only form never matches and impersonation fails
  # with a 403.
  containers_subject_repo = "${var.github.org}@${var.github.org_id}/${var.github.containers}@${var.github.containers_id}"

  # A manifest-publishing repo may not exist on GitHub yet when the store is
  # first applied. Until its repository_id is set, its subject members fall
  # back to the name-only form -- which a post-cutoff repo will never present
  # -- so set the id and re-apply as soon as the repo is created.
  manifest_subject_repos = {
    for repo, publisher in var.github.manifest_publishers : repo => (
      publisher.repository_id != null
      ? "${var.github.org}@${var.github.org_id}/${repo}@${publisher.repository_id}"
      : "${var.github.org}/${repo}"
    )
  }

  # Every manifest publisher is trusted from main alone: its release
  # workflow's publish job pushes an edge build on every push that cuts no
  # release, and promotes the newest edge build of the version (adding the
  # stable vX.Y.Z tag) when one is cut. No tag ever moves. Keyed
  # <repo>:<context> by fixed labels rather than member strings, so keys stay
  # plan-known even when var.wif carries computed values (e.g. the pool
  # resource's name output).
  manifest_publisher_members = {
    for repo, subject_repo in local.manifest_subject_repos :
    "${repo}:main" => "${local.wif_principal_prefix}/repo:${subject_repo}:ref:refs/heads/main"
  }

  # service account ids cap at 30 characters, too few for <name>-<repo>-...
  # The platform publisher keeps the id it has always had (its email, and so
  # the platform repo's GOOGLE_MANIFEST_PUBLISHER_SA variable, survive the move
  # to one publisher per repo); every other repo gets a stable short hash of
  # its name. The display name carries the repo either way.
  manifest_publisher_ids = {
    for repo in keys(var.github.manifest_publishers) : repo => (
      repo == var.github.platform
      ? "${var.name}-manifest-publisher"
      : "${var.name}-mp-${substr(sha256(repo), 0, 8)}"
    )
  }
}

resource "google_service_account" "chart_publisher" {
  project      = var.project
  account_id   = "${var.name}-chart-publisher"
  display_name = "Chart publisher (${var.github.org}/${var.github.containers})"
  description  = "Pushes mirrored charts and images to the ${var.repository_id} repository from GitHub Actions"
}

# One publisher per manifest-publishing repo (the platform's, and each
# application's), each the service account its repo's publish workflows
# impersonate.
resource "google_service_account" "manifest_publisher" {
  for_each = var.github.manifest_publishers

  project      = var.project
  account_id   = local.manifest_publisher_ids[each.key]
  display_name = "Manifest publisher (${var.github.org}/${each.key})"
  description  = "Pushes ${join(", ", each.value.paths)} in the ${var.repository_id} repository and promotes releases from GitHub Actions"
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

  service_account_id = google_service_account.manifest_publisher[split(":", each.key)[0]].name
  role               = "roles/iam.workloadIdentityUser"
  member             = each.value
}

# Artifact Registry IAM is repository-scoped, so every publisher holds writer
# on the whole platform repository and the declared paths are NOT enforced by
# IAM. Only repositories accept allow policies, docker pushes are authorized
# against the repository (artifactregistry.repositories.uploadArtifacts), and
# Artifact Registry is not among the services whose resource.name IAM
# Conditions recognize -- a startsWith(resource.name, ".../packages/<path>")
# condition would never match and deny every push. The effective control is
# consumer-side verification, only as narrow as the subject a consumer pins:
# signed_identity_subjects.manifests admits every repo github.manifest_signers
# matches, so those repos are trusted with every path; a cluster that pins
# manifest_publishers[<repo>].subject instead (as an application seed does)
# rejects a fake manifests/platform (or another application's image) pushed
# by any other publisher. A repository per publisher would make the
# separation IAM-enforced; that is a layout change this module does not make.
resource "google_artifact_registry_repository_iam_member" "chart_publisher" {
  project    = var.project
  location   = google_artifact_registry_repository.platform.location
  repository = google_artifact_registry_repository.platform.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.chart_publisher.member
}

resource "google_artifact_registry_repository_iam_member" "manifest_publisher" {
  for_each = google_service_account.manifest_publisher

  project    = var.project
  location   = google_artifact_registry_repository.platform.location
  repository = google_artifact_registry_repository.platform.name
  role       = "roles/artifactregistry.writer"
  member     = each.value.member
}

# KMS signing mode: cosign signs with gcpkms://<key> from the publish
# workflows — signerVerifier carries useToSign/viewPublicKey, and viewer the
# get/list reads cosign performs around a versionless key reference. Absent
# entirely in keyless mode. Key-scoped, so the grant works wherever the key
# lives; the apply identity needs setIamPolicy delegated on it there.
resource "google_kms_crypto_key_iam_member" "publisher_signing" {
  for_each = {
    for pair in setproduct(
      var.signing_kms_key_name != null ? concat(["chart"], [for repo in keys(var.github.manifest_publishers) : "manifest:${repo}"]) : [],
      ["signerVerifier", "viewer"],
    ) : "${pair[0]}:${pair[1]}" => pair
  }

  crypto_key_id = var.signing_kms_key_name
  role          = "roles/cloudkms.${each.value[1]}"
  member = (
    each.value[0] == "chart"
    ? google_service_account.chart_publisher.member
    : google_service_account.manifest_publisher[trimprefix(each.value[0], "manifest:")].member
  )
}

# Before one publisher per repo, the single flux-manifests publisher and its
# grants were singletons (and the WIF members keyed by context alone). The
# platform publisher keeps its account id, so these moves are in-place: no
# new service account, no new email.
moved {
  from = google_service_account.manifest_publisher
  to   = google_service_account.manifest_publisher["flux-manifests"]
}

moved {
  from = google_artifact_registry_repository_iam_member.manifest_publisher
  to   = google_artifact_registry_repository_iam_member.manifest_publisher["flux-manifests"]
}

moved {
  from = google_service_account_iam_member.manifest_publisher_wif["main"]
  to   = google_service_account_iam_member.manifest_publisher_wif["flux-manifests:main"]
}

moved {
  from = google_kms_crypto_key_iam_member.publisher_signing["manifest:signerVerifier"]
  to   = google_kms_crypto_key_iam_member.publisher_signing["manifest:flux-manifests:signerVerifier"]
}

moved {
  from = google_kms_crypto_key_iam_member.publisher_signing["manifest:viewer"]
  to   = google_kms_crypto_key_iam_member.publisher_signing["manifest:flux-manifests:viewer"]
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
