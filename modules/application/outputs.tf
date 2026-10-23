# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "release" {
  description = "The bootstrap-only seed release (application-<name>) in the flux namespace."
  value       = helm_release.seed.name
}

output "namespace" {
  description = "The flux namespace the seed objects (<name>-manifests) and the <name>-vars ConfigMap live in."
  value       = helm_release.seed.namespace
}

output "tag_provider" {
  description = "The tag-listing provider the registry selected: GARArtifactTag under the platform prefix, OCIArtifactTag elsewhere."
  value       = local.tag_provider
}

output "oci_provider" {
  description = "The OCIRepository provider the registry selected: gcp under the platform prefix, generic elsewhere."
  value       = local.oci_provider
}

output "path" {
  description = "The resolved Kustomization path inside the image."
  value       = local.path
}

output "workload_members" {
  description = <<-EOT
    The direct Workload Identity Federation principal of each workload_grants entry, keyed as workload_grants - for
    granting these identities further access resource-side (a secret container's accessor, a bucket's reader).
  EOT
  value       = local.workload_members
}
