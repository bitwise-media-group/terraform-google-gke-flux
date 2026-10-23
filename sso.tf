# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The per-cluster SSO client pairs between dex and the platform's own relying
# parties (the Flux status web UI, the workforce identity provider kubectl
# signs in through). Application clients are not here: an application ships
# DexClient objects in its own image, and the platform's dex-client-controller
# registers them with dex and keeps their secrets in the application's
# namespace. The platform clients are internal shared secrets with the
# cluster's lifecycle -- generated here, never entered out of band: each value
# is an ephemeral random_password written through write-only attributes, so it
# exists in Secret Manager (and, for the workforce client, in IAM) and nowhere
# else (not in state, not in plan). The platform's dex component syncs each
# ${SECRET_PREFIX}dex-client-<id> container into dex's env.
#
# Two consumers need the value INLINE rather than as a raw key, each written
# from the same ephemeral value as its raw dex-client-<id> container in the
# same apply, so the pair cannot drift:
#   - flux-web-auth-config: the flux-operator Web Config API document (the
#     operator accepts no file or env indirection).
#   - the workforce pool provider's OIDC client secret (kubectl.tf), which
#     Google presents to dex in the authorization-code exchange.
#
# Everything here follows the elections (platform_components, sso.kubectl)
# and requires the DNS surface (issuer and redirect URLs need the domain): an
# unelected relying party gets no client, no container, no grants.
#
# dex federates to whatever upstream identity provider sso.connector
# declares; local.dex_connectors normalizes that declaration (defaulting id
# and name, injecting a shared redirectURI) into the shape flux.tf publishes
# as DEX_CONNECTORS. The dex-<id>-<field> credential containers the
# declaration implies live in modules/sso-secrets, instantiated in a durable
# root and fed the same sso value verbatim (applying the same
# id-defaults-to-type rule, so the naming cannot drift) -- an upstream OAuth
# client outlives any one cluster, so its out-of-band credentials must too.

locals {
  # Normalized container-name prefix (the variable is nullable; the
  # empty-string convention applies everywhere downstream).
  secret_prefix = var.secret_prefix != null ? var.secret_prefix : ""

  # The workforce pool kubectl signs in through (kubectl.tf), and the
  # callback Google's workforce sign-in returns to -- dex must list it as the
  # client's redirect URI.
  kubectl_enabled  = var.sso.enabled && var.sso.kubectl.enabled
  kubectl_pool_id  = coalesce(var.sso.kubectl.pool_id, "${var.name}-dex")
  kubectl_callback = "https://auth.cloud.google/signin-callback/locations/global/workforcePools/${local.kubectl_pool_id}/providers/${var.sso.kubectl.provider_id}"

  # The platform's own relying parties: the Flux status web UI when elected,
  # and the workforce identity client when sso.kubectl is on. Both
  # confidential; both exist only when sso deploys dex (dns is a validated
  # prerequisite of sso, so platform_domain is never null here).
  platform_dex_clients = var.sso.enabled ? merge(
    contains(var.platform_components, "flux-web") ? {
      flux-web = {
        name          = "Flux Status"
        public        = false
        redirect_uris = ["https://flux.${local.platform_domain}/oauth2/callback"]
        version       = try(var.sso.clients["flux-web"].version, 1)
      }
    } : {},
    local.kubectl_enabled ? {
      (var.sso.kubectl.client_id) = {
        name          = "Google Cloud"
        public        = false
        redirect_uris = [local.kubectl_callback]
        version       = try(var.sso.clients[var.sso.kubectl.client_id].version, 1)
      }
    } : {},
  ) : {}

  # client id -> the normalized client. This is what DEX_CLIENTS publishes
  # (flux.tf) and what the containers below are minted from, so the two
  # cannot drift.
  dex_clients = local.platform_dex_clients

  # The clients that carry a generated secret, with the KSA subjects allowed
  # to read it: dex alone (staticClients read via env). flux-web's own
  # consumer reads the composed flux-web-auth-config document instead, and
  # the workforce provider holds its copy in IAM.
  dex_client_readers = {
    for id, client in local.dex_clients : id => ["ns/dex/sa/dex-secrets"]
    if !client.public
  }

  # projects/<project>/serviceAccounts/<email>, the project recovered from
  # the email (shape enforced by the sso.directory_sa validation) so callers
  # pass only the email. Only meaningful when a caller actually sets
  # directory_sa (a google-typed connector); other connectors need no
  # directory delegation.
  dex_directory_sa_name = var.sso.enabled && var.sso.directory_sa != null ? format(
    "projects/%s/serviceAccounts/%s",
    split(".", split("@", var.sso.directory_sa)[1])[0],
    var.sso.directory_sa,
  ) : null

  # The normalized connector dex's config renders from (flux.tf), kept as
  # a one-entry map keyed by the effective id so the published
  # DEX_CONNECTORS JSON array -- and the manifests ranging over it -- is
  # unchanged from the map-shaped variable days. The connector shares the
  # cluster's callback endpoint; inject it as a default so callers don't
  # have to repeat their own domain, but let an explicit config.redirectURI
  # win.
  dex_connector_id = var.sso.connector != null ? coalesce(var.sso.connector.id, var.sso.connector.type) : null

  dex_connectors = var.sso.enabled ? {
    (local.dex_connector_id) = {
      type    = var.sso.connector.type
      name    = coalesce(var.sso.connector.name, local.dex_connector_id)
      secrets = var.sso.connector.secrets
      config  = merge({ redirectURI = "https://dex.${local.platform_domain}/callback" }, var.sso.connector.config)
    }
  } : {}
}

# Dex impersonates the directory-reader SA through the classic
# annotation-based Workload Identity flow (the KSA's
# iam.gke.io/gcp-service-account annotation resolves it from the metadata
# server), so the member is the <pool>[<ns>/<ksa>] form -- not the direct
# principal:// used in iam.tf. The SA itself lives in cloud-accounts (common
# root, dex.tf); the apply identity may write exactly this SA's policy
# through the get/setIamPolicy delegation granted there to the app's
# terraform-apply container, so enabling sso on a new cluster needs no
# cloud-accounts change. Only created when a caller actually sets
# directory_sa -- a connector set that never uses google's group lookup
# (an OIDC-only deployment, say) needs no directory delegation at all.
resource "google_service_account_iam_member" "dex_directory" {
  count = var.sso.enabled && var.sso.directory_sa != null ? 1 : 0

  service_account_id = local.dex_directory_sa_name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[${var.workload_identity.dex.namespace}/${var.workload_identity.dex.service_account}]"
}

# The generated client secrets. Ephemeral: re-opened every run, persisted
# nowhere; the write-only consumers (the versions below, the workforce
# provider in kubectl.tf) only consume a fresh result when their rotation
# number (sso.clients[*].version) moves -- and since one counter drives
# every consumer of a client, a bump rewrites them all in the same apply.
ephemeral "random_password" "dex_client" {
  for_each = local.dex_client_readers

  length  = 48
  special = false
}

resource "google_secret_manager_secret" "dex_client" {
  for_each = local.dex_client_readers

  project   = var.project
  secret_id = "${local.secret_prefix}dex-client-${each.key}"

  # No version_destroy_ttl anywhere in this file: destroyed versions and
  # containers vanish immediately (no delayed-destroy cooldown), so a
  # destroyed cluster's containers can be recreated at once.

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "dex_client" {
  for_each = google_secret_manager_secret.dex_client

  secret                 = each.value.id
  secret_data_wo         = ephemeral.random_password.dex_client[each.key].result
  secret_data_wo_version = local.dex_clients[each.key].version

  # Immediate destruction on delete/rotation -- these are regenerated
  # internal values; nothing to recover, and a lingering disabled version
  # would only get in the way of cluster recreation.
  deletion_policy = "DELETE"
}

resource "google_secret_manager_secret_iam_member" "dex_client_reader" {
  for_each = {
    for pair in flatten([
      for client, subjects in local.dex_client_readers : [
        for subject in subjects : { client = client, subject = subject }
      ]
    ]) : "${pair.client}/${pair.subject}" => pair
  }

  project   = var.project
  secret_id = google_secret_manager_secret.dex_client[each.value.client].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "${local.wi_principal_prefix}/${each.value.subject}"
}

# The Flux status web UI's Web Config API document, client secret embedded.
# Synced to flux-system/flux-web-auth (the platform contract's fixed name,
# wired to the operator in flux.tf) by the platform's flux-web component
# and hot-reloaded by flux-operator.
resource "google_secret_manager_secret" "flux_web_auth_config" {
  count = contains(keys(local.dex_client_readers), "flux-web") ? 1 : 0

  project   = var.project
  secret_id = "${local.secret_prefix}flux-web-auth-config"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "flux_web_auth_config" {
  count = length(google_secret_manager_secret.flux_web_auth_config)

  secret = google_secret_manager_secret.flux_web_auth_config[0].id

  deletion_policy = "DELETE"

  secret_data_wo = yamlencode({
    apiVersion = "web.fluxcd.controlplane.io/v1"
    kind       = "Config"
    spec = {
      baseURL = "https://flux.${local.platform_domain}"
      authentication = {
        type = "OAuth2"
        oauth2 = {
          provider     = "OIDC"
          issuerURL    = "https://dex.${local.platform_domain}"
          clientID     = "flux-web"
          clientSecret = ephemeral.random_password.dex_client["flux-web"].result

          # The groups claim drives the UI's Kubernetes impersonation,
          # which the RBAC_GROUP_* bindings (flux-manifests rbac component)
          # authorize against -- dex resolves transitive Workspace
          # membership, so the same group emails work here and in kubectl.
          # Scopes and expressions mirror the operator's own defaults,
          # pinned so the RBAC contract survives upstream default drift.
          scopes = ["openid", "offline_access", "profile", "email", "groups"]
          impersonation = {
            username = "has(claims.email) ? claims.email : ''"
            groups   = "has(claims.groups) ? claims.groups : []"
          }
        }
      }
    }
  })
  secret_data_wo_version = local.dex_clients["flux-web"].version
}

resource "google_secret_manager_secret_iam_member" "flux_web_auth_config_reader" {
  count = length(google_secret_manager_secret.flux_web_auth_config)

  project   = var.project
  secret_id = google_secret_manager_secret.flux_web_auth_config[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "${local.wi_principal_prefix}/ns/flux-system/sa/flux-web-secrets"
}
