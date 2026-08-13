# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "name" {
  description = "Cluster name. Also prefixes the node service account and the default gateway address name."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,22})$", var.name))
    error_message = "name must be a short lowercase RFC-1035 label (it prefixes service-account ids with tight length limits)."
  }
}

variable "project" {
  description = <<-EOT
    Project ID the cluster lives in (a shared-VPC service project, e.g. x-patchy-app-<rand4>). If not specified, the
    provider profile will be used.
  EOT
  type        = string
  nullable    = true
}

variable "region" {
  description = "Region for the (regional) cluster, e.g. us-central1."
  type        = string
  nullable    = false
}

variable "zones" {
  description = <<-EOT
    Optional zone narrowing for node locations (cost control); null runs nodes in every zone of the region.
  EOT
  type        = set(string)
  nullable    = false
  default     = []
}

variable "network" {
  description = <<-EOT
    Shared-VPC wiring: network/subnetwork self-links into the HOST project and the names of the GKE secondary ranges on
    that subnet (all created by cloud-accounts).
  EOT
  type = object({
    network             = string
    subnetwork          = string
    pods_range_name     = string
    services_range_name = string
  })
  nullable = false
}

variable "kubernetes_version" {
  description = "Optional minimum master version pin; null lets the release channel govern."
  type        = string
  nullable    = true
  default     = null
}

variable "release_channel" {
  description = "GKE release channel (RAPID, REGULAR, STABLE)."
  type        = string
  nullable    = false
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "deletion_protection" {
  description = <<-EOT
    Terraform-level destroy protection for the cluster. Off by default: this environment is disposable by design.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "private_endpoint" {
  description = <<-EOT
    Serve the control-plane endpoint privately only. Off by default so terraform/helm bootstrap works without a VPN path
    into the shared VPC.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "master_authorized_networks" {
  description = <<-EOT
    CIDRs allowed to reach the public control-plane endpoint. Empty leaves the endpoint open (PoC posture) — constrain
    it as soon as a stable egress CIDR exists.
  EOT
  type = list(object({
    cidr_block   = string
    display_name = optional(string)
  }))
  nullable = false
  default  = []
}

variable "rbac" {
  description = <<-EOT
    Google Groups for RBAC, off by default. When enabled, the cluster authenticator trusts gke-security-groups@<domain>
    — the exact name is a GKE requirement. The group itself and the member groups usable as Role/ClusterRoleBinding
    subjects are managed out-of-band in Workspace, never here. groups names the per-role subject groups published to
    flux-manifests as RBAC_GROUP_<ROLE> cluster vars — each must be nested under the fleet group (out-of-band) for the
    authenticator to honour it.
  EOT
  type = object({
    enabled = optional(bool, false)
    domain  = optional(string)
    groups = optional(object({
      viewers    = optional(string)
      developers = optional(string)
      devops     = optional(string)
      admins     = optional(string)
    }), {})
  })
  nullable = false
  default  = {}

  validation {
    condition     = !var.rbac.enabled || var.rbac.domain != null
    error_message = "rbac.domain is required when rbac.enabled is set (the Workspace domain hosting gke-security-groups)."
  }

  validation {
    condition     = var.rbac.enabled || alltrue([for group in values(var.rbac.groups) : group == null])
    error_message = "rbac.groups requires rbac.enabled — without Google Groups RBAC the cluster ignores group subjects."
  }

  validation {
    condition     = alltrue([for group in values(var.rbac.groups) : group == null || can(regex("^[^@\\s]+@[^@\\s]+$", group))])
    error_message = "Each rbac.groups entry must be a group email address (e.g. gcp-x-app-developers@example.com)."
  }
}

variable "system_node_pool" {
  description = <<-EOT
    The always-on system node pool platform controllers pin to (label role=system). Autoscaling counts are per zone in
    a regional pool.
  EOT
  type = object({
    machine_type  = optional(string, "e2-standard-2")
    min_size      = optional(number, 1)
    max_size      = optional(number, 2)
    initial_size  = optional(number, 1)
    disk_size_gib = optional(number, 50)
  })
  nullable = false
  default  = {}
}

variable "node_auto_provisioning" {
  description = <<-EOT
    Node auto-provisioning (NAP) limits for workload capacity — the cluster-wide ceilings across all auto-provisioned
    pools.
  EOT
  type = object({
    min_cpu        = optional(number, 0)
    max_cpu        = optional(number, 64)
    min_memory_gib = optional(number, 0)
    max_memory_gib = optional(number, 256)
    disk_size_gib  = optional(number, 100)
  })
  nullable = false
  default  = {}
}

variable "platform_registry" {
  description = <<-EOT
    The platform Artifact Registry prefix everything is consumed from (artifact-store module's platform_registry
    output), e.g. us-central1-docker.pkg.dev/o-foundation-7e43/platform (the central store) or a co-located one.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9-]+-docker\\.pkg\\.dev/[^/]+/[^/]+$", var.platform_registry))
    error_message = "platform_registry must be an Artifact Registry docker repository prefix: <location>-docker.pkg.dev/<project>/<repository>."
  }
}

variable "signed_identity" {
  description = <<-EOT
    Cosign verification identity for every platform artifact — exactly one of two modes.

    KEYLESS (subjects set, kms_key_name null): Go regexps matched against the Fulcio certificate of GitHub Actions OIDC
    signatures. The artifact-store module's signed_identity_subjects output provides the subjects; the issuer default
    matches GitHub Actions. Cloud agnostic — the signing identities are GitHub's, not Google's, so the same values
    serve clusters on any cloud.

    KMS (kms_key_name set, subjects null): the publish workflows sign with an asymmetric SIGN Cloud KMS key
    (cosign sign --key gcpkms://<name>; the artifact-store module's signing_kms_key_name grants the publishers
    signerVerifier). The key's public half is distributed to the cluster as the flux-system cosign-pub Secret for the
    bootstrap verify patch, the key name is published as the SIGNED_IDENTITY_KMS_KEY cluster var, and kyverno's
    controllers get cloudkms verifier/viewer on the key to resolve it at admission time.
  EOT
  type = object({
    issuer             = optional(string, "^https://token\\.actions\\.githubusercontent\\.com$")
    manifests_subject  = optional(string)
    containers_subject = optional(string)
    kms_key_name       = optional(string)
  })
  nullable = false

  validation {
    condition = var.signed_identity.kms_key_name != null || (
      var.signed_identity.manifests_subject != null && var.signed_identity.containers_subject != null
    )
    error_message = "Keyless verification needs both manifests_subject and containers_subject (or set kms_key_name for KMS mode)."
  }

  validation {
    condition = var.signed_identity.kms_key_name == null || (
      var.signed_identity.manifests_subject == null && var.signed_identity.containers_subject == null
    )
    error_message = "kms_key_name and the keyless subjects are mutually exclusive — verification is keyless or KMS, never both."
  }

  validation {
    condition = var.signed_identity.kms_key_name == null || can(
      regex("^projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+$", var.signed_identity.kms_key_name)
    )
    error_message = "signed_identity.kms_key_name must be a Cloud KMS crypto key resource name: projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>."
  }
}

variable "dns" {
  description = <<-EOT
    Existing delegated Cloud DNS zone (created by cloud-accounts; never owned here). zone_name enables the DNS/TLS
    surface: external-dns + cert-manager IAM grants and the DNS_* / PATCHY_DOMAIN cluster vars. host optionally narrows
    the served host below the zone apex.
  EOT
  type = object({
    zone_name  = optional(string)
    host       = optional(string)
    acme_email = optional(string)
  })
  nullable = false
  default  = {}

  validation {
    condition     = var.dns.zone_name == null || var.dns.acme_email != null
    error_message = "dns.acme_email is required when dns.zone_name is set (Let's Encrypt registration for the cert-manager issuers)."
  }
}

variable "gateway" {
  description = <<-EOT
    The platform Gateway's global static IP, stable across cluster recreation. Reserve one here (default; address_name
    defaults to <name>-gateway) or reference an existing address by name with reserve_static_ip = false (e.g.
    cloud-accounts' `ingress` address in x-patchy-app).
  EOT
  type = object({
    reserve_static_ip = optional(bool, true)
    address_name      = optional(string)
  })
  nullable = false
  default  = {}
}

variable "workload_identity" {
  description = <<-EOT
    Namespace/service-account pairs the direct Workload Identity grants bind to — the terraform <-> flux-manifests
    contract. Override only to track a manifests change.
  EOT
  type = object({
    external_dns = optional(object({
      namespace       = optional(string, "external-dns")
      service_account = optional(string, "external-dns")
    }), {})
    cert_manager = optional(object({
      namespace       = optional(string, "cert-manager")
      service_account = optional(string, "cert-manager")
    }), {})
    otel_collector = optional(object({
      namespace       = optional(string, "otel-collector")
      service_account = optional(string, "otel-collector")
    }), {})
    kyverno = optional(object({
      namespace = optional(string, "kyverno")
      # the controllers that fetch image signatures from the registry at
      # admission/report time
      service_accounts = optional(list(string), ["kyverno-admission-controller", "kyverno-reports-controller"])
    }), {})
    # dex impersonates the directory-reader SA via the classic
    # annotation-based flow, so its pair binds workloadIdentityUser on that
    # SA (sso.tf) instead of receiving a direct principal:// grant
    dex = optional(object({
      namespace       = optional(string, "dex")
      service_account = optional(string, "dex")
    }), {})
  })
  nullable = false
  default  = {}
}

variable "observability" {
  description = <<-EOT
    Optional central observability project the otel-collector writes telemetry to; null targets the cluster's own
    project.
  EOT
  type = object({
    project = optional(string)
  })
  nullable = false
  default  = {}
}

variable "managed_opentelemetry" {
  description = <<-EOT
    Enable Managed OpenTelemetry for GKE (Preview): Google's in-cluster OTLP pipeline (HTTP endpoint
    opentelemetry-collector.gke-managed-otel:4318) shipping traces/logs/metrics to the CLUSTER project's Cloud
    Trace/Logging/Monitoring -- it cannot target observability.project. Per-cluster pilot toggle for retiring the
    self-hosted otel-collector component; requires GKE >= 1.34.1-gke.2178000.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "secret_sync" {
  description = <<-EOT
    Enable the Secret Manager CSI add-on plus GKE Integrated Secret Synchronization -- the SecretProviderClass and
    SecretSync CRDs flux-manifests' patchy component uses to materialise Secret Manager secrets as Kubernetes Secrets.
    Requires GKE >= 1.33 and Workload Identity (always on here). The secretmanager.secretAccessor grants live beside the
    secrets in cloud-accounts, not in this module.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "secret_prefix" {
  description = <<-EOT
    Prefix for every Secret Manager container name the manifests stack syncs, published as the SECRET_PREFIX cluster var
    (resourceNames become <prefix><container>). Lets multiple clusters share one project with distinct secrets; the
    containers and accessor grants in cloud-accounts must be created under the same prefix. Include the trailing
    separator (e.g. 'patchy-x-'); empty keeps the unprefixed names.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.secret_prefix == null || try(can(regex("^[A-Za-z0-9_-]*$", var.secret_prefix)), false)
    error_message = "secret_prefix must use Secret Manager id characters only ([A-Za-z0-9_-])."
  }
}

variable "stack_components" {
  description = <<-EOT
    The flux-manifests optional-tier components (short names: flux-web, patchy) this cluster elects, published as the
    STACK_COMPONENTS cluster var. The default elects the whole tier; electing none is explicit -- set []. dex is not
    elected here: it deploys exactly when sso is enabled, and without it the elected components still run, just with no
    SSO auth and no human-facing HTTPRoute (kubectl port-forward to reach). The core tier (kyverno, cert-manager,
    external-dns, gateway, rbac) is not electable.
  EOT
  type        = set(string)
  nullable    = false
  default     = ["flux-web", "patchy"]

  validation {
    condition = alltrue([
      for component in var.stack_components : contains(["flux-web", "patchy"], component)
    ])
    error_message = "stack_components entries must be optional-tier short names: flux-web, patchy (dex rides the sso toggle)."
  }
}

variable "sso" {
  description = <<-EOT
    Platform SSO: deploys dex as the OIDC identity provider (Google Workspace upstream) and wires every elected relying
    party to it -- generated client pairs (sso.tf), the DEX_DIRECTORY_SA cluster var, and the human-facing HTTPRoutes.
    directory_sa is the keyless Workspace directory-reader service account dex impersonates for group claims
    (domain-wide delegation) -- required when enabled. This module binds workloadIdentityUser on it for the cluster's
    dex KSA (sso.tf): the applying identity needs the get/setIamPolicy delegation cloud-accounts grants the app's
    terraform-apply container on that SA. Requires the DNS surface: the issuer and redirect URLs need the served
    domain. client_rotation holds the
    per-client rotation counters (keys: flux-web, patchy-status; absent keys default to 1) -- bump one to mint a new
    client secret; the raw dex-client-* container and any config document embedding the same value rewrite in one apply,
    so the pair cannot drift (then restart dex: it reads client secrets from env at startup)."
  EOT
  type = object({
    enabled         = optional(bool, false)
    directory_sa    = optional(string)
    client_rotation = optional(map(number), {})
  })
  nullable = false
  default  = {}

  validation {
    condition     = !var.sso.enabled || var.sso.directory_sa != null
    error_message = "sso.directory_sa is required when sso is enabled (the Workspace directory-reader SA dex impersonates for group claims)."
  }

  validation {
    condition     = var.sso.directory_sa == null || can(regex("^[a-z0-9-]+@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.sso.directory_sa))
    error_message = "sso.directory_sa must be a service-account email (<name>@<project>.iam.gserviceaccount.com) -- the workloadIdentityUser binding derives the SA's project from it."
  }

  validation {
    condition     = !var.sso.enabled || var.dns.zone_name != null
    error_message = "sso requires dns.zone_name -- dex's issuer and the relying parties' redirect URLs need the served domain."
  }

  validation {
    condition     = alltrue([for client in keys(var.sso.client_rotation) : contains(["flux-web", "patchy-status"], client)])
    error_message = "sso.client_rotation keys must be generated client ids: flux-web, patchy-status."
  }
}

variable "flux" {
  description = <<-EOT
    Flux bootstrap knobs. Chart repositories, the distribution registry and the sync url default onto platform_registry;
    sync.ref picks the release channel (stable, staging, or edge for dev clusters tracking trunk -- pair edge with the
    manifests_edge signing subject).
  EOT
  type = object({
    operator_chart = optional(object({
      repository = optional(string)
      version    = optional(string)
    }), {})
    instance_chart = optional(object({
      repository = optional(string)
      version    = optional(string)
    }), {})
    distribution = optional(object({
      version  = optional(string, "2.x")
      registry = optional(string)
      artifact = optional(string)
    }), {})
    sync = optional(object({
      url      = optional(string)
      ref      = optional(string, "stable")
      path     = optional(string, "stack")
      interval = optional(string, "5m")
    }), {})
    kustomize_patches = optional(list(any), [])
    cluster_vars      = optional(map(string), {})
    namespaces        = optional(list(string), [])
  })
  nullable = false
  default  = {}

  validation {
    condition     = contains(["stable", "staging", "edge"], var.flux.sync.ref) || can(regex("^v", var.flux.sync.ref))
    error_message = "flux.sync.ref must be a channel tag (stable, staging, edge) or a pinned version tag (vX.Y.Z)."
  }
}

variable "labels" {
  description = "Resource labels applied to the cluster."
  type        = map(string)
  nullable    = false
  default     = {}
}
