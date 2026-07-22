# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The terraform -> flux contract. reserved_cluster_vars is every value this
# cluster publishes to the flux-manifests stack (the cluster-vars ConfigMap,
# substituted into each Kustomization via postBuild.substituteFrom) — the
# authoritative table lives in the flux-manifests README. Optional surfaces
# use the empty-string convention so substitution never fails on an absent
# value; manifests guard on empties.

locals {
  # Charts, tag listings and the sync artifact all pull straight from the
  # platform registry; pods pull mirrored images from the same place (single
  # co-located registry — no pull-through cache, arc's local-registry mode).
  container_registry = var.platform_registry

  default_charts_repository     = "oci://${var.platform_registry}/charts"
  default_distribution_registry = "${local.container_registry}/images/ghcr.io/fluxcd"
  default_sync_url              = "oci://${var.platform_registry}/flux-manifests"

  # Values every cluster publishes to flux-manifests, merged OVER any
  # caller-provided extras (reserved keys always win).
  reserved_cluster_vars = merge({
    CLUSTER_NAME       = var.name
    GCP_PROJECT        = var.project
    GCP_PROJECT_NUMBER = data.google_project.cluster.number
    GCP_REGION         = var.region

    PLATFORM_REGISTRY  = var.platform_registry
    CONTAINER_REGISTRY = local.container_registry

    # Cosign keyless verification identities (Go regexps over the Fulcio
    # certificate): charts and mirrored images are signed by the
    # flux-containers publish workflow; the OCIRepository verify blocks and
    # the Kyverno image policy match these.
    SIGNED_IDENTITY_ISSUER = var.signed_identity.issuer
    SIGNED_IDENTITY_CHARTS = var.signed_identity.containers_subject
    SIGNED_IDENTITY_IMAGES = var.signed_identity.containers_subject

    # DNS/TLS surface (empty when var.dns.zone_name is unset).
    DNS_ZONE_NAME = var.dns.zone_name != null ? var.dns.zone_name : ""
    DNS_DOMAIN    = var.dns.zone_name != null ? local.dns_domain : ""
    PATCHY_DOMAIN = var.dns.zone_name != null ? local.patchy_domain : ""
    ACME_EMAIL    = var.dns.acme_email != null ? var.dns.acme_email : ""

    # Reserved Gateway address (empty when reservation is off).
    GATEWAY_ADDRESS_NAME = local.gateway_address_name
    GATEWAY_IP           = local.gateway_address

    # Where the otel-collector writes telemetry.
    OTEL_PROJECT = coalesce(var.observability.project, var.project)

    # Per-cluster Secret Manager naming: the manifests' secret-sync
    # resourceNames are all ${SECRET_PREFIX}<container>, so clusters
    # sharing a project can carry distinct secrets (empty-string
    # convention when unset).
    SECRET_PREFIX = local.secret_prefix

    # The optional-tier election, dex riding the sso toggle rather than the
    # component set. A fully-empty election publishes the reserved name
    # "none" -- a short name matching no component -- because an empty
    # string would re-trigger the manifests' elect-everything := default.
    STACK_COMPONENTS = coalesce(
      join(",", sort(setunion(var.stack_components, var.sso.enabled ? ["dex"] : []))),
      "none",
    )

    # The Workspace directory-reader SA dex impersonates for group claims
    # (typed through var.sso rather than a caller-supplied extra); the
    # manifests substitute it into the dex KSA's
    # iam.gke.io/gcp-service-account annotation.
    DEX_DIRECTORY_SA = var.sso.enabled ? var.sso.directory_sa : ""
    },
    # The GKE RBAC subject groups, one var per role key in rbac.groups
    # (RBAC_GROUP_VIEWERS, RBAC_GROUP_DEVELOPERS, RBAC_GROUP_DEVOPS,
    # RBAC_GROUP_ADMINS) — the
    # manifests bind Role/ClusterRoleBindings on them; empty when the role
    # is unbound or RBAC is off.
    {
      for role, group in var.rbac.groups :
      "RBAC_GROUP_${upper(role)}" => group != null ? group : ""
    },
  )
}

module "flux_operator" {
  source = "./modules/flux-operator"

  project        = var.project
  project_number = data.google_project.cluster.number

  operator_chart = {
    repository = coalesce(var.flux.operator_chart.repository, local.default_charts_repository)
    version    = var.flux.operator_chart.version
  }
  instance_chart = {
    repository = coalesce(var.flux.instance_chart.repository, local.default_charts_repository)
    version    = var.flux.instance_chart.version
  }
  distribution = {
    version  = var.flux.distribution.version
    registry = coalesce(var.flux.distribution.registry, local.default_distribution_registry)
    artifact = var.flux.distribution.artifact
  }
  sync = {
    url      = coalesce(var.flux.sync.url, local.default_sync_url)
    ref      = var.flux.sync.ref
    path     = var.flux.sync.path
    interval = var.flux.sync.interval
  }

  signed_identity = {
    issuer            = var.signed_identity.issuer
    manifests_subject = var.signed_identity.manifests_subject
  }

  kustomize_patches = var.flux.kustomize_patches
  cluster_vars      = merge(var.flux.cluster_vars, local.reserved_cluster_vars)
  namespaces        = var.flux.namespaces

  # The manifests contract's fixed name for the Flux status web UI's Web
  # Config Secret: composed in sso.tf, synced to flux-system by the
  # manifests' flux-web component, hot-reloaded by the operator (it may
  # arrive after bootstrap, or never on an SSO-less cluster -- harmless).
  web_config_secret_name = "flux-web-auth"

  grant_registry_read = local.registry_is_local

  # The system pool must exist so the operator's pods can schedule, and the
  # IAM grants (in-project workload grants, and the central-registry reader
  # bindings) must be live before the first reconcile needs them.
  depends_on = [
    google_container_node_pool.system,
    google_project_iam_member.workload,
    google_project_iam_member.registry_readers,
  ]
}
