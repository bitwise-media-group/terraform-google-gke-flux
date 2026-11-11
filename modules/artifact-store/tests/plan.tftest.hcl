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
    condition     = endswith(output.manifest_artifact_url, "/platform/manifests/platform") && startswith(output.manifest_artifact_url, "oci://")
    error_message = "the clusters sync the platform entrypoint image at manifests/platform (flux-manifests 4.x), not the old flux-manifests artifact"
  }

  assert {
    condition     = google_artifact_registry_repository.platform.format == "DOCKER"
    error_message = "platform repository must be a docker repository"
  }

  # No tag moves, but the registry cannot enforce it: immutable_tags stops
  # cleanup policies deleting any tagged artifact, so old builds would never
  # age out.
  assert {
    condition     = google_artifact_registry_repository.platform.docker_config[0].immutable_tags == false
    error_message = "immutable_tags stays off so cleanup policies can age out old builds; tags are immutable by contract"
  }

  # Keep policies win over delete policies: promoted releases and the newest
  # builds of every package are the protection.
  assert {
    condition = (
      one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "keep-releases"]).action == "KEEP"
      && one(one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "keep-releases"]).condition).tag_state == "TAGGED"
      && one(one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "keep-releases"]).condition).tag_prefixes == tolist(["v"])
    )
    error_message = "every promoted release (v* tag) must be kept"
  }

  assert {
    condition = (
      one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "keep-recent-builds"]).action == "KEEP"
      && one(one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "keep-recent-builds"]).most_recent_versions).keep_count == 20
    )
    error_message = "the newest 20 versions of every package must be kept regardless of age"
  }

  assert {
    condition = (
      one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "expire-builds"]).action == "DELETE"
      && one(one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "expire-builds"]).condition).tag_state == "TAGGED"
      && one(one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "expire-builds"]).condition).package_name_prefixes == tolist(["manifests"])
      && one(one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "expire-builds"]).condition).older_than == "2592000s"
    )
    error_message = "tagged manifest builds no keep policy shields must expire after 30 days, and only under manifests (mirrored charts and images are pinned by digest)"
  }

  assert {
    condition = (
      one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "expire-untagged"]).action == "DELETE"
      && one(one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "expire-untagged"]).condition).tag_state == "UNTAGGED"
      && one(one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "expire-untagged"]).condition).older_than == "1209600s"
    )
    error_message = "untagged manifests must expire after 14 days"
  }

  assert {
    condition     = length(google_artifact_registry_repository.platform.cleanup_policies) == 4
    error_message = "exactly the two keep and two delete policies"
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
    condition     = keys(google_service_account_iam_member.manifest_publisher_wif) == ["flux-manifests:main"]
    error_message = "manifest publishing must admit the main branch alone: no release-tag or promotion-environment principal"
  }

  assert {
    condition     = google_service_account_iam_member.manifest_publisher_wif["flux-manifests:main"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/subject/repo:bitwise-media-group/flux-manifests:ref:refs/heads/main"
    error_message = "the flux-manifests release workflow on main must be able to publish edge builds and promote releases"
  }

  assert {
    condition     = output.workload_identity_provider == "projects/123456789012/locations/global/workloadIdentityPools/github-actions/providers/github-oidc"
    error_message = "the provider output must pass through the central provider name"
  }
}

# Until a publishing repo exists on GitHub, its repository_id stays null and
# its subject members fall back to the name-only form (asserted in wif_trust
# above). Once the id is set, subject-matched members must pin it — GitHub's
# post-2026-07-15 immutable subjects never present the name-only form.
run "repository_id_pinned" {
  command = plan

  variables {
    github = {
      manifest_publishers = {
        flux-manifests = { repository_id = 1310000042, paths = ["manifests/*"] }
      }
    }
  }

  assert {
    condition     = google_service_account_iam_member.manifest_publisher_wif["flux-manifests:main"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/subject/repo:bitwise-media-group@282673588/flux-manifests@1310000042:ref:refs/heads/main"
    error_message = "with repository_id set, subject members must pin the immutable org/repo ids"
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

run "kms_signing_grants_publishers" {
  command = plan

  variables {
    signing_kms_key_name = "projects/o-foundation-7e43/locations/us-central1/keyRings/platform/cryptoKeys/cosign"
  }

  assert {
    condition     = google_kms_crypto_key_iam_member.publisher_signing["chart:signerVerifier"].role == "roles/cloudkms.signerVerifier"
    error_message = "KMS signing mode must grant the chart publisher signerVerifier on the signing key"
  }

  assert {
    condition = alltrue([
      for grant in values(google_kms_crypto_key_iam_member.publisher_signing) :
      grant.crypto_key_id == "projects/o-foundation-7e43/locations/us-central1/keyRings/platform/cryptoKeys/cosign"
    ])
    error_message = "every signing grant must be scoped to the signing key itself"
  }

  assert {
    condition     = sort(keys(google_kms_crypto_key_iam_member.publisher_signing)) == tolist(["chart:signerVerifier", "chart:viewer", "manifest:flux-manifests:signerVerifier", "manifest:flux-manifests:viewer"])
    error_message = "every publisher must get signerVerifier + viewer (cosign's get/list reads around a versionless key reference)"
  }

  assert {
    condition     = output.signing_kms_key_name == "projects/o-foundation-7e43/locations/us-central1/keyRings/platform/cryptoKeys/cosign"
    error_message = "the signing key must be exported for wiring into the cluster module's signed_identity"
  }
}

run "keyless_signing_grants_no_kms" {
  command = plan

  assert {
    condition     = length(google_kms_crypto_key_iam_member.publisher_signing) == 0
    error_message = "keyless mode must grant the publishers no KMS access"
  }
}

run "signed_identities" {
  command = plan

  assert {
    condition     = output.signed_identity_subjects.containers == "^https://github\\.com/bitwise-media-group/flux-containers/\\.github/workflows/publish\\.yaml@refs/heads/main$"
    error_message = "containers signing identity must pin the publish workflow on main"
  }

  assert {
    condition     = output.signed_identity_subjects.manifests == "^https://github\\.com/bitwise-media-group/[^/]+/\\.github/workflows/release\\.yaml@refs/heads/main$"
    error_message = "manifests signing identity must admit the release workflow on main of every org repo by default"
  }
}

# One publisher per manifest-publishing repo: the platform repo keeps its
# service account (and email) and the wide manifests/* path, an application
# repo gets its own service account, trust and declared path.
run "manifest_publisher_per_repo" {
  command = plan

  variables {
    github = {
      manifest_publishers = {
        flux-manifests           = { repository_id = 1310000042, paths = ["manifests/*"] }
        github-arc-app-manifests = { repository_id = 1320000077, paths = ["manifests/github-arc"] }
      }
    }
    signing_kms_key_name = "projects/o-foundation-7e43/locations/us-central1/keyRings/platform/cryptoKeys/cosign"
  }

  assert {
    condition     = sort(keys(google_service_account.manifest_publisher)) == tolist(["flux-manifests", "github-arc-app-manifests"])
    error_message = "every manifest_publishers key must get its own service account"
  }

  assert {
    condition     = google_service_account.manifest_publisher["flux-manifests"].account_id == "platform-manifest-publisher"
    error_message = "the platform publisher must keep its account id, so its email survives the move to one publisher per repo"
  }

  assert {
    condition = (
      can(regex("^platform-mp-[0-9a-f]{8}$", google_service_account.manifest_publisher["github-arc-app-manifests"].account_id))
      && length(google_service_account.manifest_publisher["github-arc-app-manifests"].account_id) <= 30
    )
    error_message = "an application publisher's account id must be <name>-mp-<hash>, within the 30-character limit"
  }

  assert {
    condition     = google_service_account_iam_member.manifest_publisher_wif["github-arc-app-manifests:main"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/subject/repo:bitwise-media-group@282673588/github-arc-app-manifests@1320000077:ref:refs/heads/main"
    error_message = "an application publisher must be impersonable from its own repo's main branch (immutable-id subject)"
  }

  assert {
    condition     = length(google_service_account_iam_member.manifest_publisher_wif) == 2
    error_message = "each publisher is trusted from exactly one context, its main branch"
  }

  assert {
    condition = alltrue([
      for grant in values(google_artifact_registry_repository_iam_member.manifest_publisher) :
      grant.role == "roles/artifactregistry.writer" && length(grant.condition) == 0
    ])
    error_message = "every publisher holds unconditional repository-level writer (Artifact Registry cannot scope pushes to package paths)"
  }

  assert {
    condition     = sort(keys(google_artifact_registry_repository_iam_member.manifest_publisher)) == tolist(["flux-manifests", "github-arc-app-manifests"])
    error_message = "every publisher must get push access to the repository"
  }

  assert {
    condition     = contains(keys(google_kms_crypto_key_iam_member.publisher_signing), "manifest:github-arc-app-manifests:signerVerifier")
    error_message = "KMS signing mode must grant every manifest publisher signerVerifier"
  }

  assert {
    condition     = output.manifest_publishers["github-arc-app-manifests"].paths == tolist(["manifests/github-arc"])
    error_message = "the output must carry each publisher's declared paths"
  }

  assert {
    condition     = output.manifest_publishers["github-arc-app-manifests"].subject == "^https://github\\.com/bitwise-media-group/github-arc-app-manifests/\\.github/workflows/release\\.yaml@refs/heads/main$"
    error_message = "the output must carry each publisher's own release-workflow subject (what its image.verify.subject pins)"
  }

  assert {
    condition     = output.manifest_publishers["flux-manifests"].subject == "^https://github\\.com/bitwise-media-group/flux-manifests/\\.github/workflows/release\\.yaml@refs/heads/main$"
    error_message = "the platform publisher's own subject must be exported, for a cluster that holds the platform to its own repo"
  }
}

# A fork trusting a subset of the org's repos narrows the signer pattern;
# each publisher's own subject is unaffected.
run "manifest_signers_narrow_the_subject" {
  command = plan

  variables {
    github = {
      platform         = "aip-platform-manifests"
      manifest_signers = "aip-[^/]+"
      manifest_publishers = {
        aip-platform-manifests = { paths = ["manifests/*"] }
      }
    }
  }

  assert {
    condition     = output.signed_identity_subjects.manifests == "^https://github\\.com/bitwise-media-group/aip-[^/]+/\\.github/workflows/release\\.yaml@refs/heads/main$"
    error_message = "github.manifest_signers must replace the repository part of the manifests subject"
  }

  assert {
    condition = (
      can(regex(output.signed_identity_subjects.manifests, "https://github.com/bitwise-media-group/aip-platform-manifests/.github/workflows/release.yaml@refs/heads/main"))
      && !can(regex(output.signed_identity_subjects.manifests, "https://github.com/bitwise-media-group/patchy-app-manifests/.github/workflows/release.yaml@refs/heads/main"))
    )
    error_message = "the narrowed subject must admit an aip-* repo's release workflow and nothing else"
  }
}

run "manifest_signers_reject_anchors" {
  command = plan

  variables {
    github = { manifest_signers = "^aip-[^/]+$" }
  }

  expect_failures = [var.github]
}

run "platform_must_be_a_publisher" {
  command = plan

  variables {
    github = {
      platform = "platform-manifests"
    }
  }

  expect_failures = [var.github]
}

run "publisher_paths_stay_under_manifests" {
  command = plan

  variables {
    github = {
      manifest_publishers = {
        flux-manifests = { paths = ["manifests/*"] }
        rogue          = { paths = ["charts/*"] }
      }
    }
  }

  expect_failures = [var.github]
}

run "publisher_needs_a_path" {
  command = plan

  variables {
    github = {
      manifest_publishers = {
        flux-manifests = { paths = [] }
      }
    }
  }

  expect_failures = [var.github]
}

run "retention_is_tunable" {
  command = plan

  variables {
    build_retention_count = 50
    build_expiry_days     = 7
  }

  assert {
    condition = (
      one(one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "keep-recent-builds"]).most_recent_versions).keep_count == 50
      && one(one([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.id == "expire-builds"]).condition).older_than == "604800s"
    )
    error_message = "the retention count and build expiry must come from their variables"
  }
}

run "retention_keeps_the_newest_build" {
  command = plan

  variables {
    build_retention_count = 0
  }

  expect_failures = [var.build_retention_count]
}
