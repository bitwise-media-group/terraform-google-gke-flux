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
  description = "OCI url of the flux-manifests artifact the clusters sync."
  value       = "oci://${var.location}-docker.pkg.dev/${var.project}/${google_artifact_registry_repository.platform.repository_id}/flux-manifests"
}

output "workload_identity_provider" {
  description = "Full WIF provider resource name — the workload_identity_provider input of google-github-actions/auth (set as the GCP_WIF_PROVIDER repo variable in the publishing repos)."
  value       = var.wif.provider_name
}

output "chart_publisher" {
  description = "Chart publisher service account (email is the service_account input of google-github-actions/auth in flux-containers, set as the GCP_CHART_PUBLISHER_SA / GCP_MANIFEST_PUBLISHER_SA org variables)."
  value = {
    email  = google_service_account.chart_publisher.email
    member = google_service_account.chart_publisher.member
  }
}

output "manifest_publisher" {
  description = "Manifest publisher service account (email is the service_account input of google-github-actions/auth in flux-manifests, set as the GCP_CHART_PUBLISHER_SA / GCP_MANIFEST_PUBLISHER_SA org variables)."
  value = {
    email  = google_service_account.manifest_publisher.email
    member = google_service_account.manifest_publisher.member
  }
}

output "signed_identity_subjects" {
  description = "Fulcio certificate-subject regexps for the publishing workflows — feed these to the cluster module's signed_identity variable and the flux-manifests cluster vars."
  value = {
    containers = "^https://github\\.com/${var.github.org}/${var.github.containers}/\\.github/workflows/publish\\.yaml@refs/heads/main$"
    manifests  = "^https://github\\.com/${var.github.org}/${var.github.manifests}/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
  }
}
