# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The terraform -> flux contract. reserved_cluster_vars is every value this
# cluster publishes to the flux-manifests stack (the cluster-vars ConfigMap,
# substituted into each Kustomization via postBuild.substituteFrom) — the
# authoritative table lives in the flux-manifests README. Optional surfaces
# use the empty-string convention so substitution never fails on an absent
# value; manifests guard on empties.

locals {
  # Which cosign mode verifies the platform artifacts: keyless (Fulcio
  # identities) or a KMS signing key. var.signed_identity's validations
  # guarantee exactly one.
  signing_kms = var.signed_identity.kms_key_name != null

  # Charts, tag listings and the sync artifact all pull straight from the
  # platform registry; pods pull mirrored images from the same place (single
  # co-located registry — no pull-through cache, arc's local-registry mode).
  container_registry = var.platform_registry

  default_charts_repository     = "oci://${var.platform_registry}/charts"
  default_distribution_registry = "${local.container_registry}/images/ghcr.io/fluxcd"
  default_sync_url              = "oci://${var.platform_registry}/flux-manifests"

  # The claude runner's model-provider config, consumed by the patchy
  # egress-broker (the in-cluster proxy every claude-runner's model traffic
  # terminates at).
  claude_provider = var.patchy.claude.provider

  # Values every cluster publishes to flux-manifests, merged OVER any
  # caller-provided extras (reserved keys always win).
  reserved_cluster_vars = merge({
    CLUSTER_NAME       = var.name
    GCP_PROJECT        = var.project
    GCP_PROJECT_NUMBER = data.google_project.cluster.number
    GCP_REGION         = var.region

    PLATFORM_REGISTRY  = var.platform_registry
    CONTAINER_REGISTRY = local.container_registry

    # Cosign verification, one mode or the other (the empty-string convention
    # marks the inactive one). Keyless publishes the Fulcio identities (Go
    # regexps): charts and mirrored images are signed by the flux-containers
    # publish workflow; the OCIRepository verify blocks and the Kyverno image
    # policy match these. KMS publishes the signing key's resource name
    # instead, which Kyverno resolves as gcpkms://<name> and the
    # OCIRepositories verify via the cosign-pub public-key Secret the
    # bootstrap distributes.
    SIGNED_IDENTITY_ISSUER  = local.signing_kms ? "" : var.signed_identity.issuer
    SIGNED_IDENTITY_CHARTS  = local.signing_kms ? "" : var.signed_identity.containers_subject
    SIGNED_IDENTITY_IMAGES  = local.signing_kms ? "" : var.signed_identity.containers_subject
    SIGNED_IDENTITY_KMS_KEY = local.signing_kms ? var.signed_identity.kms_key_name : ""

    # The stack's flux component (flux managing flux) re-renders the
    # FluxInstance this module bootstraps: it needs the manifests-artifact
    # signing subject for the sync verify patch, and the release channel for
    # sync.ref -- both otherwise trapped inside this module's helm values.
    SIGNED_IDENTITY_MANIFESTS = local.signing_kms ? "" : var.signed_identity.manifests_subject
    FLUX_SYNC_CHANNEL         = var.flux.sync.ref

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

    # The claude runner's model provider for the patchy egress-broker.
    # Harness-scoped names (CLAUDE_*): the provider belongs to the claude
    # runner alone — a future codex/copilot surface adds CODEX_* siblings —
    # and the knobs are provider-prefixed (VERTEX_REGION, not a generic
    # REGION), mirroring the broker's own PATCHY_VERTEX_* env names; clarity
    # over brevity. The bedrock vars are always empty on GKE (the broker has
    # no AWS ambient credentials here), the vertex vars default onto the
    # cluster's own region/project, and the model map publishes as sorted
    # comma-joined canonical=providerID pairs (empty-string convention
    # throughout).
    CLAUDE_PROVIDER              = local.claude_provider.name
    CLAUDE_ANTHROPIC_AUTH        = local.claude_provider.anthropic_auth
    CLAUDE_BEDROCK_REGION        = ""
    CLAUDE_BEDROCK_REGION_PREFIX = ""
    CLAUDE_VERTEX_REGION         = local.claude_provider.name == "vertex" ? coalesce(local.claude_provider.vertex_region, var.region) : ""
    CLAUDE_VERTEX_PROJECT_ID     = local.claude_provider.name == "vertex" ? coalesce(local.claude_provider.vertex_project_id, var.project) : ""
    CLAUDE_MODEL_MAP             = join(",", [for k in sort(keys(local.claude_provider.model_map)) : "${k}=${local.claude_provider.model_map[k]}"])
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

# The signing key's public half — cosign verification inside the cluster
# never needs the private key, and Flux verifies against a public-key Secret
# rather than calling KMS, so this is the only key material that travels. The
# latest enabled version matches how cosign resolves a versionless gcpkms://
# reference.
data "google_kms_crypto_key_latest_version" "signing" {
  for_each = toset(local.signing_kms ? ["true"] : [])

  crypto_key = var.signed_identity.kms_key_name
  filter     = "state:ENABLED"
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
    issuer             = local.signing_kms ? null : var.signed_identity.issuer
    manifests_subject  = local.signing_kms ? null : var.signed_identity.manifests_subject
    kms_public_key_pem = local.signing_kms ? data.google_kms_crypto_key_latest_version.signing["true"].public_key[0].pem : null
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
