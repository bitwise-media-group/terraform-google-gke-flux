# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with a mocked google provider: no credentials, no
# API calls. These assert the shape of what would be created — the repository
# configuration and, most importantly, the publishing trust (who may push).

mock_provider "google" {}

variables {
  project = "x-patchy-app-ab12"

  wif = {
    pool_name     = "projects/123456789012/locations/global/workloadIdentityPools/github-actions"
    provider_name = "projects/123456789012/locations/global/workloadIdentityPools/github-actions/providers/github-oidc"
  }
}

run "repository" {
  command = plan

  assert {
    condition     = google_artifact_registry_repository.platform.format == "DOCKER"
    error_message = "platform repository must be a docker repository"
  }

  assert {
    condition     = google_artifact_registry_repository.platform.docker_config[0].immutable_tags == false
    error_message = "channel tags (staging/stable) must be able to move: immutable_tags stays off"
  }

  assert {
    condition     = one(google_artifact_registry_repository.platform.cleanup_policies).id == "expire-untagged"
    error_message = "untagged manifests must expire via the cleanup policy"
  }

  assert {
    condition     = output.platform_registry == "us-central1-docker.pkg.dev/x-patchy-app-ab12/platform"
    error_message = "platform_registry must compose location/project/repository"
  }
}

run "wif_trust" {
  command = plan

  assert {
    condition     = google_service_account_iam_member.chart_publisher_wif.member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/subject/repo:bitwise-media-group@282673588/flux-containers@1303643498:ref:refs/heads/main"
    error_message = "chart publishing must be pinned to the flux-containers default branch via the immutable-id subject"
  }

  assert {
    condition     = sort(keys(google_service_account_iam_member.manifest_publisher_wif)) == tolist(["env", "main", "tag"])
    error_message = "manifest publishing must admit exactly the release-tag, edge-channel and promotion-environment principals"
  }

  assert {
    condition     = google_service_account_iam_member.manifest_publisher_wif["main"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/subject/repo:bitwise-media-group/flux-manifests:ref:refs/heads/main"
    error_message = "merges to the flux-manifests default branch must be able to publish the edge channel"
  }

  assert {
    condition     = google_service_account_iam_member.manifest_publisher_wif["tag"].member == "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/attribute.publish/bitwise-media-group/flux-manifests:tag"
    error_message = "release tags must be able to publish the manifests artifact"
  }

  assert {
    condition     = google_service_account_iam_member.manifest_publisher_wif["env"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/subject/repo:bitwise-media-group/flux-manifests:environment:production"
    error_message = "only the protected production environment may move the stable channel"
  }

  assert {
    condition     = output.workload_identity_provider == "projects/123456789012/locations/global/workloadIdentityPools/github-actions/providers/github-oidc"
    error_message = "the provider output must pass through the central provider name"
  }
}

# Until flux-manifests exists on GitHub, manifests_id stays null and its
# subject members fall back to the name-only form (asserted in wif_trust
# above). Once the id is set, subject-matched members must pin it — GitHub's
# post-2026-07-15 immutable subjects never present the name-only form.
run "manifests_id_pinned" {
  command = plan

  variables {
    github = {
      manifests_id = 1310000042
    }
  }

  assert {
    condition     = google_service_account_iam_member.manifest_publisher_wif["main"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/subject/repo:bitwise-media-group@282673588/flux-manifests@1310000042:ref:refs/heads/main"
    error_message = "with manifests_id set, subject members must pin the immutable org/repo ids"
  }

  assert {
    condition     = google_service_account_iam_member.manifest_publisher_wif["env"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/subject/repo:bitwise-media-group@282673588/flux-manifests@1310000042:environment:production"
    error_message = "the promotion-environment member must pin the immutable org/repo ids too"
  }

  assert {
    condition     = google_service_account_iam_member.manifest_publisher_wif["tag"].member == "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/attribute.publish/bitwise-media-group/flux-manifests:tag"
    error_message = "attribute.publish matches assertion.repository, which stays name-only regardless of manifests_id"
  }
}

run "cluster_readers" {
  command = plan

  variables {
    reader_members = [
      "principal://iam.googleapis.com/projects/999999999999/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/flux-system/sa/source-controller",
    ]
  }

  assert {
    condition     = google_artifact_registry_repository_iam_member.readers["principal://iam.googleapis.com/projects/999999999999/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/flux-system/sa/source-controller"].role == "roles/artifactregistry.reader"
    error_message = "cross-project cluster identities must get repository-scoped read access"
  }
}

run "signed_identities" {
  command = plan

  assert {
    condition     = output.signed_identity_subjects.containers == "^https://github\\.com/bitwise-media-group/flux-containers/\\.github/workflows/publish\\.yaml@refs/heads/main$"
    error_message = "containers signing identity must pin the publish workflow on main"
  }

  assert {
    condition     = output.signed_identity_subjects.manifests == "^https://github\\.com/bitwise-media-group/flux-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    error_message = "manifests signing identity must pin the publish workflow on release tags"
  }
}
