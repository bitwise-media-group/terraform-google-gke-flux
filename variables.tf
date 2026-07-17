# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "name" {
  description = "Cluster name. Also prefixes the node service account and the default gateway address name."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,22})$", var.name))
    error_message = "name must be a short lowercase RFC-1035 label (it prefixes service-account ids with tight length limits)."
  }
}

variable "project" {
  description = "Project ID the cluster lives in (a shared-VPC service project, e.g. x-patchy-app-<rand4>)."
  type        = string
}

variable "region" {
  description = "Region for the (regional) cluster, e.g. us-central1."
  type        = string
}

variable "zones" {
  description = "Optional zone narrowing for node locations (cost control); null runs nodes in every zone of the region."
  type        = set(string)
  default     = null
}

variable "network" {
  description = "Shared-VPC wiring: network/subnetwork self-links into the HOST project and the names of the GKE secondary ranges on that subnet (all created by cloud-accounts)."
  type = object({
    network             = string
    subnetwork          = string
    pods_range_name     = string
    services_range_name = string
  })
}

variable "kubernetes_version" {
  description = "Optional minimum master version pin; null lets the release channel govern."
  type        = string
  default     = null
}

variable "release_channel" {
  description = "GKE release channel (RAPID, REGULAR, STABLE)."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "deletion_protection" {
  description = "Terraform-level destroy protection for the cluster. Off by default: this environment is disposable by design."
  type        = bool
  default     = false
}

variable "private_endpoint" {
  description = "Serve the control-plane endpoint privately only. Off by default so terraform/helm bootstrap works without a VPN path into the shared VPC."
  type        = bool
  default     = false
}

variable "master_authorized_networks" {
  description = "CIDRs allowed to reach the public control-plane endpoint. Empty leaves the endpoint open (PoC posture) — constrain it as soon as a stable egress CIDR exists."
  type = list(object({
    cidr_block   = string
    display_name = optional(string)
  }))
  default = []
}

variable "system_node_pool" {
  description = "The always-on system node pool platform controllers pin to (label role=system). Autoscaling counts are per zone in a regional pool."
  type = object({
    machine_type  = optional(string, "e2-standard-2")
    min_size      = optional(number, 1)
    max_size      = optional(number, 2)
    initial_size  = optional(number, 1)
    disk_size_gib = optional(number, 50)
  })
  default = {}
}

variable "node_auto_provisioning" {
  description = "Node auto-provisioning (NAP) limits for workload capacity — the cluster-wide ceilings across all auto-provisioned pools."
  type = object({
    min_cpu        = optional(number, 0)
    max_cpu        = optional(number, 64)
    min_memory_gib = optional(number, 0)
    max_memory_gib = optional(number, 256)
    disk_size_gib  = optional(number, 100)
  })
  default = {}
}

variable "platform_registry" {
  description = "The platform Artifact Registry prefix everything is consumed from (artifact-store module's platform_registry output), e.g. us-central1-docker.pkg.dev/o-foundation-7e43/platform (the central store) or a co-located one."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+-docker\\.pkg\\.dev/[^/]+/[^/]+$", var.platform_registry))
    error_message = "platform_registry must be an Artifact Registry docker repository prefix: <location>-docker.pkg.dev/<project>/<repository>."
  }
}

variable "signed_identity" {
  description = "Cosign keyless verification identities (Go regexps matched against the Fulcio certificate). The artifact-store module's signed_identity_subjects output provides the subjects; the issuer default matches GitHub Actions."
  type = object({
    issuer             = optional(string, "^https://token\\.actions\\.githubusercontent\\.com$")
    manifests_subject  = string
    containers_subject = string
  })
}

variable "dns" {
  description = "Existing delegated Cloud DNS zone (created by cloud-accounts; never owned here). zone_name enables the DNS/TLS surface: external-dns + cert-manager IAM grants and the DNS_* / PATCHY_DOMAIN cluster vars. host optionally narrows the served host below the zone apex."
  type = object({
    zone_name  = optional(string)
    host       = optional(string)
    acme_email = optional(string)
  })
  default = {}

  validation {
    condition     = var.dns.zone_name == null || var.dns.acme_email != null
    error_message = "dns.acme_email is required when dns.zone_name is set (Let's Encrypt registration for the cert-manager issuers)."
  }
}

variable "gateway" {
  description = "The platform Gateway's global static IP, stable across cluster recreation. Reserve one here (default; address_name defaults to <name>-gateway) or reference an existing address by name with reserve_static_ip = false (e.g. cloud-accounts' `ingress` address in x-patchy-app)."
  type = object({
    reserve_static_ip = optional(bool, true)
    address_name      = optional(string)
  })
  default = {}
}

variable "workload_identity" {
  description = "Namespace/service-account pairs the direct Workload Identity grants bind to — the terraform <-> flux-manifests contract. Override only to track a manifests change."
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
  })
  default = {}
}

variable "observability" {
  description = "Optional central observability project the otel-collector writes telemetry to; null targets the cluster's own project."
  type = object({
    project = optional(string)
  })
  default = {}
}

variable "managed_opentelemetry" {
  description = "Enable Managed OpenTelemetry for GKE (Preview): Google's in-cluster OTLP pipeline (HTTP endpoint opentelemetry-collector.gke-managed-otel:4318) shipping traces/logs/metrics to the CLUSTER project's Cloud Trace/Logging/Monitoring -- it cannot target observability.project. Per-cluster pilot toggle for retiring the self-hosted otel-collector component; requires GKE >= 1.34.1-gke.2178000."
  type        = bool
  default     = false
}

variable "secret_sync" {
  description = "Enable the Secret Manager CSI add-on plus GKE Integrated Secret Synchronization -- the SecretProviderClass and SecretSync CRDs flux-manifests' patchy component uses to materialise Secret Manager secrets as Kubernetes Secrets. Requires GKE >= 1.33 and Workload Identity (always on here). The secretmanager.secretAccessor grants live beside the secrets in cloud-accounts, not in this module."
  type        = bool
  default     = false
}

variable "flux" {
  description = "Flux bootstrap knobs. Chart repositories, the distribution registry and the sync url default onto platform_registry; sync.ref picks the release channel (stable, staging, or edge for dev clusters tracking trunk -- pair edge with the manifests_edge signing subject)."
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
  default = {}

  validation {
    condition     = contains(["stable", "staging", "edge"], var.flux.sync.ref) || can(regex("^v", var.flux.sync.ref))
    error_message = "flux.sync.ref must be a channel tag (stable, staging, edge) or a pinned version tag (vX.Y.Z)."
  }
}

variable "labels" {
  description = "Resource labels applied to the cluster."
  type        = map(string)
  default     = {}
}
