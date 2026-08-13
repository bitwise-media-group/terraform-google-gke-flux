# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "project" {
  description = "Project ID the cluster (and its workload identity pool) lives in."
  type        = string
  nullable    = false
}

variable "project_number" {
  description = "Project number, for composing principal:// workload identity members at plan time."
  type        = string
  nullable    = false
}

variable "namespace" {
  description = "Namespace for the flux-operator and Flux controllers."
  type        = string
  nullable    = false
  default     = "flux-system"
}

variable "operator_chart" {
  description = <<-EOT
    flux-operator helm chart location: the platform registry's charts/flux-operator, published by flux-containers
    (the artifact store must be populated before the first cluster bootstraps). A null version installs the latest
    available at create and pins it in state — later applies don't auto-upgrade.
  EOT
  type = object({
    repository = string # e.g. oci://<registry>/charts
    version    = optional(string)
  })
  nullable = false
}

variable "instance_chart" {
  description = <<-EOT
    flux-instance helm chart location (renders the FluxInstance CR; avoids the kubernetes_manifest plan-time CRD
    problem). A null version installs the latest available at create and pins it in state.
  EOT
  type = object({
    repository = string
    version    = optional(string)
  })
  nullable = false
}

variable "distribution" {
  description = <<-EOT
    Flux distribution: version constraint and the registry hosting the mirrored fluxcd controller images (and
    optionally the OCI artifact with the operator's manifests).
  EOT
  type = object({
    version  = string
    registry = string
    artifact = optional(string)
  })
  nullable = false
}

variable "sync" {
  description = "Cluster sync source: the flux-manifests artifact in the platform registry and the path within it."
  type = object({
    url      = string # oci://<registry>/flux-manifests
    ref      = string # channel tag (stable, staging) or exact version
    path     = string # stack (the single entrypoint all clusters share)
    interval = optional(string, "5m")
  })
  nullable = false
}

variable "signed_identity" {
  description = <<-EOT
    Cosign verification enforced on the generated flux-system OCIRepository, so an unsigned or tampered manifests
    artifact is never applied. Exactly one mode: keyless (issuer + manifests_subject, Go regexps over the Fulcio
    certificate) or a signing key's public half (kms_public_key_pem, distributed as the cosign-pub Secret the verify
    patch references — source-controller verifies against the public key and never calls KMS).
  EOT
  type = object({
    issuer             = optional(string)
    manifests_subject  = optional(string)
    kms_public_key_pem = optional(string)
  })
  nullable = false

  validation {
    condition = (var.signed_identity.kms_public_key_pem != null) != (
      var.signed_identity.issuer != null && var.signed_identity.manifests_subject != null
    )
    error_message = "signed_identity is keyless (issuer + manifests_subject) or keyed (kms_public_key_pem), never both or neither."
  }
}

variable "kustomize_patches" {
  description = <<-EOT
    Extra kustomize patches applied to the generated Flux instance objects, on top of the built-in controller
    nodeSelector and flux-system OCIRepository verify patches.
  EOT
  type        = list(any)
  nullable    = false
  default     = []
}

variable "cluster_vars" {
  description = <<-EOT
    The cluster-vars ConfigMap contents — every value the flux-manifests stack substitutes via
    postBuild.substituteFrom.
  EOT
  type        = map(string)
  nullable    = false
  default     = {}
}

variable "namespaces" {
  description = <<-EOT
    Namespaces pre-created by the cluster-inputs chart (e.g. workload namespaces that must exist before their secrets
    arrive out-of-band); flux kustomizations adopt them via server-side apply.
  EOT
  type        = list(string)
  nullable    = false
  default     = []
}

variable "grant_registry_read" {
  description = <<-EOT
    Grant the flux principals artifactregistry.reader on the cluster's project. On only when the platform registry is
    co-located; a central registry grants them via the artifact-store module's reader_members instead.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "web_config_secret_name" {
  description = <<-EOT
    Name of a Secret in the namespace whose config.yaml key carries the Web Config API document for the Flux Status web
    UI (SSO, base URL). The operator hot-reloads it, so the Secret may arrive after bootstrap. Null runs the web server
    unconfigured (anonymous, defaults).
  EOT
  type        = string
  default     = null
}
