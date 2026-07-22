# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The per-cluster SSO client pairs between dex and its in-cluster relying
# parties (the Flux status web UI, the patchy status page). These are
# internal shared secrets with the cluster's lifecycle -- generated here,
# never entered out of band: each value is an ephemeral random_password
# written through write-only attributes, so it exists in Secret Manager and
# nowhere else (not in state, not in plan). The manifests stack syncs each
# container into its consumer namespaces under the same SECRET_PREFIX this
# module publishes.
#
# Two consumers need the value INLINE in a composed config document rather
# than as a raw key:
#   - flux-web-auth-config: the flux-operator Web Config API document
#     (the operator accepts no file or env indirection). Written from the
#     same ephemeral value as the raw dex-client-flux-web container in the
#     same apply, so the pair cannot drift.
#   - patchy-status-auth-config: patchy's status server DOES support
#     clientSecretFile, so its document is secretless and both sides read
#     the one dex-client-patchy-status version.
#
# Everything here follows the optional-tier election (stack_components) and
# requires the DNS surface (issuer and redirect URLs need the domain): an
# unelected relying party gets no client, no container, no grants.

locals {
  # Normalized container-name prefix (the variable is nullable; the
  # empty-string convention applies everywhere downstream).
  secret_prefix = var.secret_prefix != null ? var.secret_prefix : ""

  # client id -> the KSA subjects allowed to read its raw secret: always
  # dex (staticClients read via secretEnv), plus patchy's status server for
  # the client whose config points clientSecretFile at the synced key.
  # A pair exists only when sso deploys dex AND the relying party is
  # elected (dns is a validated prerequisite of sso, so patchy_domain is
  # never null here).
  dex_client_readers = var.sso.enabled ? merge(
    contains(var.stack_components, "flux-web") ? {
      flux-web = ["ns/dex/sa/dex-secrets"]
    } : {},
    contains(var.stack_components, "patchy") ? {
      patchy-status = ["ns/dex/sa/dex-secrets", "ns/patchy/sa/patchy-secrets"]
    } : {},
  ) : {}

  # projects/<project>/serviceAccounts/<email>, the project recovered from
  # the email (shape enforced by the sso.directory_sa validation) so callers
  # pass only the email.
  dex_directory_sa_name = var.sso.enabled ? format(
    "projects/%s/serviceAccounts/%s",
    split(".", split("@", var.sso.directory_sa)[1])[0],
    var.sso.directory_sa,
  ) : null
}

# Dex impersonates the directory-reader SA through the classic
# annotation-based Workload Identity flow (the KSA's
# iam.gke.io/gcp-service-account annotation resolves it from the metadata
# server), so the member is the <pool>[<ns>/<ksa>] form -- not the direct
# principal:// used in iam.tf. The SA itself lives in cloud-accounts (common
# root, dex.tf); the apply identity may write exactly this SA's policy
# through the get/setIamPolicy delegation granted there to the app's
# terraform-apply container, so enabling sso on a new cluster needs no
# cloud-accounts change.
resource "google_service_account_iam_member" "dex_directory" {
  count = var.sso.enabled ? 1 : 0

  service_account_id = local.dex_directory_sa_name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[${var.workload_identity.dex.namespace}/${var.workload_identity.dex.service_account}]"
}

# The generated client secrets. Ephemeral: re-opened every run, persisted
# nowhere; the write-only versions below only consume a fresh result when
# their rotation number (sso.client_rotation) moves.
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
  secret_data_wo_version = lookup(var.sso.client_rotation, each.key, 1)

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
# Synced to flux-system/flux-web-auth (the manifests contract's fixed name,
# wired to the operator in flux.tf) by the manifests' flux-web component
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
      baseURL = "https://flux.${local.patchy_domain}"
      authentication = {
        type = "OAuth2"
        oauth2 = {
          provider     = "OIDC"
          issuerURL    = "https://dex.${local.patchy_domain}"
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
  secret_data_wo_version = lookup(var.sso.client_rotation, "flux-web", 1)
}

resource "google_secret_manager_secret_iam_member" "flux_web_auth_config_reader" {
  count = length(google_secret_manager_secret.flux_web_auth_config)

  project   = var.project
  secret_id = google_secret_manager_secret.flux_web_auth_config[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "${local.wi_principal_prefix}/ns/flux-system/sa/flux-web-secrets"
}

# The patchy status server's auth config document: secretless
# (clientSecretFile points at the client-secret key the SecretSync places
# beside it), so a plain version keeps it visible in plan.
resource "google_secret_manager_secret" "patchy_status_auth_config" {
  count = contains(keys(local.dex_client_readers), "patchy-status") ? 1 : 0

  project   = var.project
  secret_id = "${local.secret_prefix}patchy-status-auth-config"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "patchy_status_auth_config" {
  count = length(google_secret_manager_secret.patchy_status_auth_config)

  secret = google_secret_manager_secret.patchy_status_auth_config[0].id

  deletion_policy = "DELETE"

  secret_data = yamlencode({
    mode = "oidc"
    oidc = {
      issuerURL        = "https://dex.${local.patchy_domain}"
      clientID         = "patchy-status"
      clientSecretFile = "/etc/patchy/auth/client-secret"
    }
  })
}

resource "google_secret_manager_secret_iam_member" "patchy_status_auth_config_reader" {
  count = length(google_secret_manager_secret.patchy_status_auth_config)

  project   = var.project
  secret_id = google_secret_manager_secret.patchy_status_auth_config[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "${local.wi_principal_prefix}/ns/patchy/sa/patchy-secrets"
}
