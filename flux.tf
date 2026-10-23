# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The terraform -> flux contract. reserved_cluster_vars is every value this
# cluster publishes to the platform manifests (the cluster-vars ConfigMap,
# substituted into each Kustomization via postBuild.substituteFrom) -- the
# authoritative table lives in the flux-manifests README. Optional surfaces
# use the empty-string convention so substitution never fails on an absent
# value; manifests guard on empties. Applications may read any of these too,
# but nothing application-specific is published here: an application's own
# values ride in its <key>-vars ConfigMap (var.application_vars).
#
# The keys are deliberately cloud-neutral wherever the meaning is shared
# (CLUSTER_NAME, SIGNED_IDENTITY_*, PLATFORM_COMPONENTS, RBAC_GROUP_*, ...);
# the manifests are per-cloud trees (flux.sync.path selects "google"), so
# google-only facts publish as GCP-prefixed or google-shaped keys and nothing
# branches on a cloud var.

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

  # The platform entrypoint image: one small artifact whose ResourceSet
  # ranges over PLATFORM_COMPONENTS and emits an OCIRepository +
  # Kustomization per component (oci://<registry>/manifests/<name>). The
  # FluxInstance's single sync points here.
  default_sync_url = "oci://${var.platform_registry}/manifests/platform"
  sync_url         = coalesce(var.flux.sync.url, local.default_sync_url)

  # The electable tier in force, dex riding the sso toggle rather than the
  # component set.
  platform_components = sort(setunion(var.platform_components, var.sso.enabled ? ["dex"] : []))

  # The application seeds. Defaults that depend on cluster-level facts are
  # resolved here (the keyless issuer onto the platform's, the path onto the
  # per-cloud tree the platform itself syncs); the registry decides how the
  # image is listed and pulled: under the platform prefix the flux
  # controllers' Workload Identity reaches it through the Artifact Registry
  # API, anywhere else the generic OCI listing (and an optional pull secret)
  # does.
  applications = {
    for key, app in var.applications : key => {
      url        = app.url
      platform   = startswith(app.url, "oci://${var.platform_registry}/")
      semver     = app.semver
      path       = coalesce(app.path, "./deploy/${var.flux.sync.path}")
      interval   = app.interval
      depends_on = app.depends_on
      verify = {
        keyed   = app.verify.keyed
        issuer  = app.verify.keyed ? null : coalesce(app.verify.issuer, var.signed_identity.issuer)
        subject = app.verify.subject
      }
      pull_secret = app.pull_secret
      prune       = app.prune
      wait        = app.wait
      timeout     = app.timeout
    }
  }

  # Values every cluster publishes to the platform, merged OVER any
  # caller-provided extras (reserved keys always win).
  reserved_cluster_vars = merge({
    CLUSTER_NAME       = var.name
    GCP_PROJECT        = var.project
    GCP_PROJECT_NUMBER = data.google_project.cluster.number
    GCP_REGION         = local.region

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

    # KMS mode also publishes the signing key's public half (base64 PEM,
    # dropping straight into Secret data): the manifests render it into each
    # verified component namespace as a cosign-pub Secret, so the chart
    # OCIRepositories' secretRef verify resolves without any cross-namespace
    # secret machinery. Public material — safe in a ConfigMap.
    COSIGN_PUBLIC_KEY = local.signing_kms ? base64encode(data.google_kms_crypto_key_latest_version.signing["true"].public_key[0].pem) : ""

    # The platform's flux component (flux managing flux) re-renders the
    # FluxInstance this module bootstraps: it needs the manifests signing
    # subject for the sync verify patch, the release channel for sync.ref
    # (and for every component source the entrypoint emits), the sync url
    # and the per-cloud tree -- all otherwise trapped inside this module's
    # bootstrap-only helm values. Publishing FLUX_SYNC_URL is what lets a
    # running cluster be re-pointed: the flux component asserts it on the
    # FluxInstance, so a changed var moves the sync without a kubectl patch.
    SIGNED_IDENTITY_MANIFESTS = local.signing_kms ? "" : var.signed_identity.manifests_subject
    FLUX_SYNC_CHANNEL         = var.flux.sync.ref
    FLUX_SYNC_URL             = local.sync_url
    PLATFORM_TREE             = var.flux.sync.path

    # DNS/TLS surface (empty when var.dns.zone_name is unset). PLATFORM_DOMAIN
    # is the served host the platform's own hosts (dex., flux.) hang off.
    DNS_ZONE_NAME   = var.dns.zone_name != null ? var.dns.zone_name : ""
    DNS_DOMAIN      = var.dns.zone_name != null ? local.dns_domain : ""
    PLATFORM_DOMAIN = var.dns.zone_name != null ? local.platform_domain : ""
    ACME_EMAIL      = var.dns.acme_email != null ? var.dns.acme_email : ""

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

    # The electable-tier election, dex riding the sso toggle rather than the
    # component set. The platform entrypoint's ResourceSet ranges over this
    # list (the list IS the component graph's election). A fully-empty
    # election publishes the reserved name "none" -- a short name matching no
    # component -- because an empty string would re-trigger the manifests'
    # elect-everything := default.
    PLATFORM_COMPONENTS = coalesce(join(",", local.platform_components), "none")

    # Arbitrary SSO federation: the non-secret half of each connector,
    # JSON-encoded since a cluster var is a flat string. Defaults to "[]"
    # rather than "" (unlike the rest of this map's empty-string convention)
    # because the manifests unconditionally mustFromJson-parse it.
    DEX_CONNECTORS = var.sso.enabled ? jsonencode([
      for id, c in local.dex_connectors : merge({ id = id }, c)
    ]) : "[]"

    # The Workspace directory-reader SA dex's google connector impersonates
    # for group claims (typed through var.sso rather than a caller-supplied
    # extra; independently optional -- empty unless a caller sets it). The
    # manifests substitute it into the dex KSA's
    # iam.gke.io/gcp-service-account annotation.
    DEX_DIRECTORY_SA = var.sso.enabled && var.sso.directory_sa != null ? var.sso.directory_sa : ""

    # The platform's own OIDC relying parties: the flux-web client (when
    # elected) and the confidential workforce identity client (sso.kubectl,
    # the authorization-code flow Google's workforce sign-in drives),
    # JSON-encoded like DEX_CONNECTORS and for the same reason. Application
    # clients are DexClient objects, registered by the platform's
    # dex-client-controller, and never appear here. The dex component renders
    # staticClients from it and syncs ${SECRET_PREFIX}dex-client-<id> for
    # every confidential client; the containers are minted from the same
    # local (sso.tf), so the ids cannot drift.
    DEX_CLIENTS = var.sso.enabled ? jsonencode([
      for id, c in local.dex_clients : {
        id           = id
        name         = c.name
        public       = c.public
        redirectURIs = c.redirect_uris
      }
    ]) : "[]"
    },
    # The RBAC subject groups, one var per role key in rbac.groups
    # (RBAC_GROUP_VIEWERS, RBAC_GROUP_DEVELOPERS, RBAC_GROUP_DEVOPS,
    # RBAC_GROUP_ADMINS) -- the manifests bind Role/ClusterRoleBindings on
    # them; empty when the role is unbound. Published as given: a Google
    # Group email or a workforce principalSet, the manifests never see the
    # subject type behind them.
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
    url      = local.sync_url
    ref      = var.flux.sync.ref
    path     = var.flux.sync.path
    interval = var.flux.sync.interval
  }

  applications     = local.applications
  application_vars = var.application_vars

  signed_identity = {
    issuer             = local.signing_kms ? null : var.signed_identity.issuer
    manifests_subject  = local.signing_kms ? null : var.signed_identity.manifests_subject
    kms_public_key_pem = local.signing_kms ? data.google_kms_crypto_key_latest_version.signing["true"].public_key[0].pem : null
  }

  kustomize_patches = var.flux.kustomize_patches
  cluster_vars      = merge(var.flux.cluster_vars, local.reserved_cluster_vars)
  namespaces        = var.flux.namespaces

  # The platform contract's fixed name for the Flux status web UI's Web
  # Config Secret: composed in sso.tf, synced to flux-system by the
  # platform's flux-web component, hot-reloaded by the operator (it may
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
