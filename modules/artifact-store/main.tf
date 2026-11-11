# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The platform artifact store: one Artifact Registry docker repository holding
# every artifact the clusters consume, under path namespaces —
#
#   charts/<name>            helm charts mirrored by flux-containers
#   images/<original-path>   digest-pinned container images mirrored by flux-containers
#   manifests/platform       the signed platform entrypoint image synced by
#                            FluxInstance (flux-manifests publishes it)
#   manifests/<name>         the signed per-component and per-application
#                            manifest images (manifests/<component> from
#                            flux-manifests, manifests/<app> from each
#                            application's own repository)
#
# Artifact Registry allows arbitrary slash-separated paths beneath a single
# docker repository, so unlike ECR no per-path repository creation is needed:
# publishers hold repo-level writer (their declared paths are not
# IAM-enforceable here -- see iam.tf) and the pipeline never creates
# repositories at runtime (arc's ensure-repo.sh has no analogue here).
#
# There is no signing key anywhere in this module: artifacts are cosign-signed
# KEYLESSLY by the publishing GitHub Actions workflows (OIDC -> Fulcio/Rekor),
# and consumers verify against the workflows' certificate identities. The only
# infrastructure signing needs is the Workload Identity Federation trust
# (iam.tf), which controls who may PUSH -- the pool/provider itself is owned
# centrally and passed in via var.wif.

# Every tag is immutable by contract, the channels included: no tag ever
# moves. A channel is its newest immutable build -- <base>-edge.<UTC
# yyyymmddhhmmss>.g<short commit> on every merge to main, X.Y.Z-staging.<...>
# on every release, and the plain vX.Y.Z promotion adds to a staging build --
# which consumers follow as a semver range. Every build also carries
# sha-<commit>.
#
# The registry does not enforce that contract: Artifact Registry's
# immutable_tags is repository-wide and, once on, stops cleanup policies
# deleting any tagged artifact, so old builds could never age out. The
# publish workflows refuse to overwrite an existing tag instead, and the
# cleanup policies below keep every promoted release and the newest builds
# and expire the rest.

locals {
  # Keep policies win over delete policies, so the keeps are the protection:
  # promoted releases (vX.Y.Z, and mirrored upstream v-tags) are kept forever,
  # and the newest build_retention_count versions of every package regardless
  # of age. Artifact Registry matches tags by prefix only and counts versions
  # per package, not per tag pattern, so unlike ECR the newest edge and staging
  # builds share one count: the newest edge build is always within it, an
  # unpromoted staging build only until build_retention_count newer builds of
  # the same package land and it passes build_expiry_days.
  build_expiry = "${var.build_expiry_days * 24 * 60 * 60}s"

  # A package name prefix with no slash, so it matches the manifest images
  # whether Artifact Registry presents nested docker paths as manifests/<name>
  # or URL-encoded as manifests%2F<name>. Mirrored charts and images (which
  # the manifests pin by digest) are never aged out.
  manifests_package_prefix = "manifests"
}

resource "google_artifact_registry_repository" "platform" {
  project       = var.project
  location      = var.location
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = "Platform artifact store: mirrored charts + images and the signed manifest images"

  # Immutable by contract, not by the registry -- see above.
  docker_config {
    immutable_tags = false
  }

  cleanup_policies {
    id     = "keep-releases"
    action = "KEEP"

    condition {
      tag_state    = "TAGGED"
      tag_prefixes = ["v"]
    }
  }

  cleanup_policies {
    id     = "keep-recent-builds"
    action = "KEEP"

    most_recent_versions {
      keep_count = var.build_retention_count
    }
  }

  # Edge, staging and commit-only builds of the manifest images that no keep
  # policy shields.
  cleanup_policies {
    id     = "expire-builds"
    action = "DELETE"

    condition {
      tag_state             = "TAGGED"
      package_name_prefixes = [local.manifests_package_prefix]
      older_than            = local.build_expiry
    }
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
