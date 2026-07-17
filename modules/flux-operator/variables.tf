# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "project" {
  description = "Project ID the cluster (and its workload identity pool) lives in."
  type        = string
}

variable "project_number" {
  description = "Project number, for composing principal:// workload identity members at plan time."
  type        = string
}

variable "namespace" {
  description = "Namespace for the flux-operator and Flux controllers."
  type        = string
  default     = "flux-system"
}

variable "operator_chart" {
  description = "flux-operator helm chart location: the platform registry's charts/flux-operator, published by flux-containers (the artifact store must be populated before the first cluster bootstraps). A null version installs the latest available at create and pins it in state — later applies don't auto-upgrade."
  type = object({
    repository = string # e.g. oci://<registry>/charts
    version    = optional(string)
  })
}

variable "instance_chart" {
  description = "flux-instance helm chart location (renders the FluxInstance CR; avoids the kubernetes_manifest plan-time CRD problem). A null version installs the latest available at create and pins it in state."
  type = object({
    repository = string
    version    = optional(string)
  })
}

variable "distribution" {
  description = "Flux distribution: version constraint and the registry hosting the mirrored fluxcd controller images (and optionally the OCI artifact with the operator's manifests)."
  type = object({
    version  = string
    registry = string
    artifact = optional(string)
  })
}

variable "sync" {
  description = "Cluster sync source: the flux-manifests artifact in the platform registry and the path within it."
  type = object({
    url      = string # oci://<registry>/flux-manifests
    ref      = string # channel tag (stable, staging) or exact version
    path     = string # stack (the single entrypoint all clusters share)
    interval = optional(string, "5m")
  })
}

variable "signed_identity" {
  description = "Cosign keyless identity (Go regexps over the Fulcio certificate) enforced on the generated flux-system OCIRepository, so an unsigned or tampered manifests artifact is never applied."
  type = object({
    issuer            = string
    manifests_subject = string
  })
}

variable "kustomize_patches" {
  description = "Extra kustomize patches applied to the generated Flux instance objects, on top of the built-in controller nodeSelector and flux-system OCIRepository verify patches."
  type        = list(any)
  default     = []
}

variable "cluster_vars" {
  description = "The cluster-vars ConfigMap contents — every value the flux-manifests stack substitutes via postBuild.substituteFrom."
  type        = map(string)
  default     = {}
}

variable "namespaces" {
  description = "Namespaces pre-created by the cluster-inputs chart (e.g. workload namespaces that must exist before their secrets arrive out-of-band); flux kustomizations adopt them via server-side apply."
  type        = list(string)
  default     = []
}

variable "grant_registry_read" {
  description = "Grant the flux principals artifactregistry.reader on the cluster's project. On only when the platform registry is co-located; a central registry grants them via the artifact-store module's reader_members instead."
  type        = bool
  default     = true
}
