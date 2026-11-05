# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "registry_host" {
  description = "Registry hostname for docker/helm/crane login (oauth2accesstoken + access token)."
  value       = "${var.location}-docker.pkg.dev"
}

output "platform_registry" {
  description = "The platform registry prefix — the value of the cluster's platform_registry variable and the PLATFORM_REGISTRY cluster var."
  value       = "${var.location}-docker.pkg.dev/${var.project}/${google_artifact_registry_repository.platform.repository_id}"
}

output "chart_repository_prefix" {
  description = "OCI prefix mirrored charts are published under (charts/<name> appended per chart)."
  value       = "oci://${var.location}-docker.pkg.dev/${var.project}/${google_artifact_registry_repository.platform.repository_id}/charts"
}

output "image_repository_prefix" {
  description = "Registry prefix mirrored images are published under (images/<original-path> appended per image)."
  value       = "${var.location}-docker.pkg.dev/${var.project}/${google_artifact_registry_repository.platform.repository_id}/images"
}

output "manifest_artifact_url" {
  description = "OCI url of the platform entrypoint image the clusters sync (manifests/platform; the components and applications it seeds sit beside it under manifests/<name>)."
  value       = "oci://${var.location}-docker.pkg.dev/${var.project}/${google_artifact_registry_repository.platform.repository_id}/manifests/platform"
}

output "workload_identity_provider" {
  description = "Full WIF provider resource name — the workload_identity_provider input of google-github-actions/auth (set as the GCP_WIF_PROVIDER repo variable in the publishing repos)."
  value       = var.wif.provider_name
}

output "chart_publisher" {
  description = "Chart publisher service account (email is the service_account input of google-github-actions/auth in flux-containers, set as its GCP_CHART_PUBLISHER_SA variable)."
  value = {
    email  = google_service_account.chart_publisher.email
    member = google_service_account.chart_publisher.member
  }
}

output "manifest_publishers" {
  description = <<-EOT
    One manifest publisher per github.manifest_publishers key: its service account (email is the service_account
    input of google-github-actions/auth in that repo, its GCP_MANIFEST_PUBLISHER_SA variable), the paths it owns
    (declarative - see the github variable), and the Fulcio certificate-subject regexps of its publish workflows
    (release tags and the edge channel) - an application repo's release subject is what its image.verify.subject pins.
  EOT
  value = {
    for repo, account in google_service_account.manifest_publisher : repo => {
      email  = account.email
      member = account.member
      paths  = var.github.manifest_publishers[repo].paths
      subjects = {
        release = "^https://github\\.com/${var.github.org}/${repo}/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
        edge    = "^https://github\\.com/${var.github.org}/${repo}/\\.github/workflows/publish-edge\\.yaml@refs/heads/main$"
      }
    }
  }
}

output "signed_identity_subjects" {
  description = "Fulcio certificate-subject regexps for the chart mirror and the platform manifests publisher (github.platform; keyless mode) — feed these to the cluster module's signed_identity variable and the flux-manifests cluster vars. Irrelevant when signing_kms_key_name selects KMS signing. Application publishers' subjects ride in manifest_publishers."
  value = {
    containers = "^https://github\\.com/${var.github.org}/${var.github.containers}/\\.github/workflows/publish\\.yaml@refs/heads/main$"
    manifests  = "^https://github\\.com/${var.github.org}/${var.github.platform}/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    # edge channel: dev/sandbox clusters tracking trunk pass this as
    # signed_identity.manifests_subject instead of the release identity above
    manifests_edge = "^https://github\\.com/${var.github.org}/${var.github.platform}/\\.github/workflows/publish-edge\\.yaml@refs/heads/main$"
  }
}

output "signing_kms_key_name" {
  description = "The Cloud KMS signing key the publishers sign with (null in keyless mode) — feed it to the cluster module's signed_identity.kms_key_name so verification matches."
  value       = var.signing_kms_key_name
}
