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
  description = "Cluster sync source: the platform entrypoint image in the platform registry and the per-cloud tree within it."
  type = object({
    url      = string # oci://<registry>/manifests/platform
    ref      = string # channel tag (stable, staging) or exact version
    path     = string # the per-cloud tree ("google" for this module)
    interval = optional(string, "5m")
  })
  nullable = false
}

variable "applications" {
  description = <<-EOT
    Application manifest images to seed, keyed by short name, with every default already resolved by the caller.
    Each entry becomes one bootstrap-only helm release of the local application chart: a ResourceSetInputProvider
    and ResourceSet named <key>-manifests in the namespace, which resolve the newest tag matching semver, verify
    the image (keyless issuer + subject, or keyed against the cosign-pub Secret) and apply path from it as
    Kustomization <key>. platform says whether the image lives in the platform registry: then the flux controllers
    list its tags through the Artifact Registry API (GARArtifactTag) and pull it with their Workload Identity
    (provider gcp); otherwise the generic OCI listing and pull apply (OCIArtifactTag / generic), with pull_secret
    naming a kubernetes.io/dockerconfigjson Secret in the namespace when the registry needs credentials. The image
    ships the same two seed objects and owns them from its first reconcile; the release is never reconciled again
    (ignore_changes), and uninstalling it (removing the key) is what removes the application.
  EOT
  type = map(object({
    url        = string
    platform   = bool
    semver     = string
    path       = string
    interval   = string
    depends_on = set(string)
    verify = object({
      keyed   = bool
      issuer  = optional(string)
      subject = optional(string)
    })
    pull_secret = optional(string)
    prune       = bool
    wait        = bool
    timeout     = string
  }))
  nullable = false
  default  = {}

  validation {
    condition = alltrue([
      for app in values(var.applications) : app.verify.keyed ? (
        var.signed_identity.kms_public_key_pem != null && app.verify.subject == null
        ) : (
        app.verify.issuer != null && app.verify.subject != null
      )
    ])
    error_message = "Each applications entry verifies keyless (issuer + subject) or keyed (the cosign-pub Secret, which only exists in keyed signed_identity mode), never both or neither."
  }
}

variable "application_vars" {
  description = <<-EOT
    Per-application substitution ConfigMaps rendered by the cluster-inputs chart: one <key>-vars ConfigMap per
    entry, which the application's Kustomization substitutes from beside cluster-vars. Terraform-reconciled, so
    changes flow through applies.
  EOT
  type        = map(map(string))
  nullable    = false
  default     = {}
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
    The cluster-vars ConfigMap contents — every value the platform manifests (and applications) substitute via
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
