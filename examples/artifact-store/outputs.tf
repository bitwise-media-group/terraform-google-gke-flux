# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "platform_registry" {
  description = "PLATFORM_REGISTRY value for the cluster module and both publishing repos."
  value       = module.artifact_store.platform_registry
}

output "workload_identity_provider" {
  description = "GCP_WIF_PROVIDER repository variable for flux-containers and flux-manifests."
  value       = module.artifact_store.workload_identity_provider
}

output "chart_publisher" {
  description = "GCP_CHART_PUBLISHER_SA org variable for flux-containers."
  value       = module.artifact_store.chart_publisher
}

output "manifest_publisher" {
  description = "GCP_MANIFEST_PUBLISHER_SA org variable for flux-manifests."
  value       = module.artifact_store.manifest_publisher
}

output "signed_identity_subjects" {
  description = "Fulcio subject regexps for the cluster module's signed_identity variable."
  value       = module.artifact_store.signed_identity_subjects
}
