# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "platform_registry" {
  description = "The platform registry: the cluster module's platform_registry and the publishing repos' GOOGLE_PLATFORM_REGISTRY variable."
  value       = module.artifact_store.platform_registry
}

output "workload_identity_provider" {
  description = "GOOGLE_WORKLOAD_IDENTITY_PROVIDER repository variable for flux-containers and flux-manifests."
  value       = module.artifact_store.workload_identity_provider
}

output "chart_publisher" {
  description = "GOOGLE_CHART_PUBLISHER_SA org variable for flux-containers."
  value       = module.artifact_store.chart_publisher
}

output "manifest_publishers" {
  description = "Per manifest-publishing repo: its GOOGLE_MANIFEST_PUBLISHER_SA (email), declared paths and signing subjects."
  value       = module.artifact_store.manifest_publishers
}

output "signed_identity_subjects" {
  description = "Fulcio subject regexps for the cluster module's signed_identity variable."
  value       = module.artifact_store.signed_identity_subjects
}
