# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "namespace" {
  description = "The flux namespace."
  value       = var.namespace
}

output "cluster_vars_configmap" {
  description = "Name of the cluster-vars ConfigMap the platform substitutes from."
  value       = "cluster-vars"
}

output "applications" {
  description = <<-EOT
    The application seeds, keyed as var.applications: the bootstrap-only helm release name, the namespace the seed
    objects (<key>-manifests) live in, and the providers the registry selected (GARArtifactTag / gcp under the
    platform prefix, OCIArtifactTag / generic elsewhere).
  EOT
  value = {
    for key, app in local.applications : key => {
      release      = helm_release.application[key].name
      namespace    = helm_release.application[key].namespace
      tag_provider = app.tag_provider
      oci_provider = app.oci_provider
    }
  }
}
