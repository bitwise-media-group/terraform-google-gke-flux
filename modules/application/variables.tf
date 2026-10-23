# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "name" {
  description = <<-EOT
    The application's short name: the seed release is application-<name>, the seed objects <name>-manifests, the
    Kustomization <name> and the vars ConfigMap <name>-vars, all in the cluster's flux namespace. Must not be seeded
    by the cluster root as well (an applications key there) - an application lives in exactly one root.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$", var.name))
    error_message = "name must be a short lowercase RFC-1035 label of at most 32 characters (it names the seed objects <name>-manifests and Kustomization <name>)."
  }

  # The same list as the cluster root (and the AWS module), so an
  # application name is portable across clouds.
  validation {
    condition = !contains([
      "flux-system", "flux", "cilium", "kyverno", "kyverno-policies", "cert-manager", "cert-manager-issuers",
      "external-dns", "gateway", "gateway-api-crds", "aws-load-balancer-controller", "rbac", "secret-sync", "dex",
      "flux-web", "arc", "platform", "cluster-inputs",
    ], var.name)
    error_message = "name must not reuse a platform Kustomization or component name (flux-system, flux, cilium, kyverno, kyverno-policies, cert-manager, cert-manager-issuers, external-dns, gateway, gateway-api-crds, aws-load-balancer-controller, rbac, secret-sync, dex, flux-web, arc, platform, cluster-inputs) - the registry and the flux namespace are one flat namespace."
  }
}

variable "cluster" {
  description = <<-EOT
    The cluster to publish to: pass the cluster root's application_target output verbatim (through
    terraform_remote_state or any other channel) rather than composing it by hand.
      - name: the GKE cluster name.
      - namespace: the flux namespace the seed and vars live in.
      - platform_registry: the platform Artifact Registry prefix (<location>-docker.pkg.dev/<project>/<repository>);
        images beneath it are listed and pulled with the flux controllers' Workload Identity.
      - tree: the per-cloud tree the cluster syncs (flux.sync.path), the default image path ./deploy/<tree>.
      - issuer: the keyless signing issuer, the default for image.verify.issuer; null on a KMS-keyed cluster.
      - keyed: whether the cluster verifies with a KMS signing key (the cosign-pub Secret exists only then).
      - project / project_number / workload_pool: the cluster's project and its Workload Identity pool
        (<project>.svc.id.goog), which compose the direct principal:// members workload_grants bind.
      - secret_prefix: the SECRET_PREFIX the application's own Secret Manager containers are named under.
  EOT
  type = object({
    name              = string
    namespace         = string
    platform_registry = string
    tree              = string
    issuer            = optional(string)
    keyed             = bool
    project           = string
    project_number    = string
    workload_pool     = string
    secret_prefix     = string
  })
  nullable = false

  validation {
    condition     = var.cluster.keyed || var.cluster.issuer != null
    error_message = "cluster.issuer is required on a keyless cluster (cluster.keyed = false) - it is the default issuer every keyless image verifies against."
  }
}

variable "image" {
  description = <<-EOT
    The application's manifest image, exactly as a cluster root applications entry. Becomes one bootstrap-only
    seed: a ResourceSetInputProvider and ResourceSet named <name>-manifests that resolve the newest tag matching
    semver, verify the image's cosign signature and apply path from it as Kustomization <name>. The image ships the
    same two seed objects under flux/ and owns them from its first reconcile, so a new application release never
    needs a terraform apply; the seed is applied once and then ignored (ignore_changes). Destroying the module
    uninstalls the seed and prunes the application.
      - url: the image without a tag or digest. An Artifact Registry url must live under cluster.platform_registry
        (the flux controllers pull it with their Workload Identity and list its tags through the Artifact Registry
        API); any other registry is listed and pulled generically, optionally with pull_secret (a
        kubernetes.io/dockerconfigjson Secret in the flux namespace that both the tag listing and the pull read).
      - semver: the tag range the seed follows (default >=0.0.0); a range matching no tag prunes the application.
      - path: the Kustomization path inside the image (default ./deploy/<cluster.tree>).
      - depends_on: platform Kustomizations the application waits for (default kyverno-policies).
      - verify: keyless (subject, a Fulcio certificate-subject regexp; issuer defaults to cluster.issuer) XOR keyed
        (the cosign-pub public-key Secret, KMS-keyed clusters only).
  EOT
  type = object({
    url        = string
    semver     = optional(string, ">=0.0.0")
    path       = optional(string)
    interval   = optional(string, "30m")
    depends_on = optional(set(string), ["kyverno-policies"])
    verify = object({
      issuer  = optional(string)
      subject = optional(string)
      keyed   = optional(bool, false)
    })
    pull_secret = optional(string)
    prune       = optional(bool, true)
    wait        = optional(bool, true)
    timeout     = optional(string, "5m")
  })
  nullable = false

  validation {
    condition     = can(regex("^oci://[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$", var.image.url))
    error_message = "image.url must be oci://<host>/<repository> with no tag or digest (the seed resolves the tag from semver)."
  }

  validation {
    condition     = !can(regex("^oci://[a-z0-9-]+-docker\\.pkg\\.dev/", var.image.url)) || startswith(var.image.url, "oci://${var.cluster.platform_registry}/")
    error_message = "An Artifact Registry-hosted image.url must live under cluster.platform_registry - the flux controllers hold read rights on that repository alone, and its tags are listed through the Artifact Registry API with the same identity."
  }

  validation {
    condition     = (var.image.verify.subject != null) != var.image.verify.keyed
    error_message = "image.verify must be keyless (subject) or keyed, never both or neither - an unverified application image is never applied."
  }

  validation {
    condition     = !var.image.verify.keyed || var.cluster.keyed
    error_message = "image.verify.keyed requires a KMS-keyed cluster (cluster.keyed): the cosign-pub Secret only exists in KMS mode."
  }

  validation {
    condition     = var.image.verify.subject == null || var.image.verify.issuer != null || !var.cluster.keyed
    error_message = "A keyless image on a KMS-keyed cluster must set image.verify.issuer explicitly - there is no keyless issuer to default onto."
  }

  validation {
    condition     = var.image.pull_secret == null || !startswith(var.image.url, "oci://${var.cluster.platform_registry}/")
    error_message = "image.pull_secret only applies to images outside the platform registry - the platform registry is pulled with the flux controllers' Workload Identity."
  }
}

variable "vars" {
  description = <<-EOT
    The application's own substitution values, rendered as the <name>-vars ConfigMap in the flux namespace, which
    its Kustomization substitutes from beside cluster-vars. Terraform-reconciled (the inputs release), so changes
    flow through this root's applies. Keys must be SCREAMING_SNAKE_CASE, matching the substitution syntax.
  EOT
  type        = map(string)
  nullable    = false
  default     = {}

  validation {
    condition     = alltrue([for key in keys(var.vars) : can(regex("^[A-Z][A-Z0-9_]*$", key))])
    error_message = "vars must use SCREAMING_SNAKE_CASE keys (^[A-Z][A-Z0-9_]*$), the shape flux substitution reads."
  }
}

variable "namespaces" {
  description = <<-EOT
    Namespaces created ahead of the application (e.g. so out-of-band secrets can land before Flux deploys into
    them), labelled app.kubernetes.io/managed-by: application-<name>; the image's kustomizations adopt them via
    server-side apply. A namespace the cluster root already pre-creates (flux.namespaces) cannot be listed here too.
  EOT
  type        = set(string)
  nullable    = false
  default     = []

  validation {
    condition     = alltrue([for namespace in var.namespaces : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", namespace))])
    error_message = "namespaces entries must be RFC-1123 labels."
  }
}

variable "workload_grants" {
  description = <<-EOT
    Workload IAM grants, keyed by a short name: each (entry, role) pair becomes one project-level IAM member binding
    of the role to the namespace/service-account pair as a direct Workload Identity Federation principal, in
    project (default: cluster.project) - the same shape as the cluster root's workload_grants. Secret Manager reads
    are not a grant shape: create the application's containers in this root and grant their sync KSA accessor
    on each, resource-side.
  EOT
  type = map(object({
    namespace       = string
    service_account = string
    roles           = list(string)
    project         = optional(string)
  }))
  nullable = false
  default  = {}

  validation {
    condition     = alltrue([for key in keys(var.workload_grants) : can(regex("^[a-z]([a-z0-9-]{0,38})$", key))])
    error_message = "workload_grants keys must be short lowercase RFC-1035 labels."
  }

  validation {
    condition = alltrue([
      for key in keys(var.workload_grants) :
      !contains(["external-dns", "cert-manager", "otel-collector"], key) && !startswith(key, "kyverno-")
    ])
    error_message = "workload_grants keys must not collide with the platform grants (external-dns, cert-manager, otel-collector, kyverno-*)."
  }

  validation {
    condition = alltrue(flatten([
      for grant in values(var.workload_grants) : [
        for role in grant.roles : can(regex("^(roles/|projects/[^/]+/roles/|organizations/[0-9]+/roles/)", role))
      ]
    ]))
    error_message = "Each workload_grants role must be an IAM role name: roles/<role>, projects/<project>/roles/<role> or organizations/<id>/roles/<role>."
  }
}
