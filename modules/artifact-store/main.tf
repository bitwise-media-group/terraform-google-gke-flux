# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The platform artifact store: one Artifact Registry docker repository holding
# every artifact the clusters consume, under path namespaces —
#
#   charts/<name>            helm charts mirrored by flux-containers
#   images/<original-path>   digest-pinned container images mirrored by flux-containers
#   flux-manifests           the signed OCI manifests artifact synced by FluxInstance
#
# Artifact Registry allows arbitrary slash-separated paths beneath a single
# docker repository, so unlike ECR no per-path repository creation is needed:
# publishers hold repo-level writer and the pipeline never creates repositories
# at runtime (arc's ensure-repo.sh has no analogue here).
#
# There is no signing key anywhere in this module: artifacts are cosign-signed
# KEYLESSLY by the publishing GitHub Actions workflows (OIDC -> Fulcio/Rekor),
# and consumers verify against the workflows' certificate identities. The only
# infrastructure signing needs is the Workload Identity Federation trust
# (iam.tf), which controls who may PUSH -- the pool/provider itself is owned
# centrally and passed in via var.wif.

resource "google_artifact_registry_repository" "platform" {
  project       = var.project
  location      = var.location
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = "Platform artifact store: mirrored charts + images and the signed flux-manifests artifact"

  # Channel tags (staging/stable) on the manifests artifact must move between
  # releases, and tag immutability is repository-wide, so it stays off. Version
  # tags are protected from reuse by the publish workflows refusing to
  # overwrite an existing digest, not by the registry.
  docker_config {
    immutable_tags = false
  }

  # Failed/superseded pushes leave untagged manifests behind; expire them.
  cleanup_policies {
    id     = "expire-untagged"
    action = "DELETE"

    condition {
      tag_state  = "UNTAGGED"
      older_than = "${var.untagged_expiry_days * 24 * 60 * 60}s"
    }
  }

  labels = var.labels
}
