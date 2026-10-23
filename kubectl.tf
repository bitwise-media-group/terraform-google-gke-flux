# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# kubectl through dex, by Workforce Identity Federation (sso.kubectl). Identity
# Service for GKE -- the in-cluster OIDC authenticator -- is deprecated
# (unsupported from GKE 1.37), so dex is instead the OIDC provider of an
# organization-level workforce pool: a user signs in to Google Cloud through
# dex (gcloud's workforce login config), becomes a federated principal
# (principal://.../workforcePools/<pool>/subject/<email>) carrying their dex
# groups (principalSet://.../workforcePools/<pool>/group/<group>), and reaches
# the cluster with an ordinary get-credentials. GKE RBAC authorizes those
# principals: rbac.groups binds the principalSet strings directly, no Google
# Groups RBAC involved.
#
# Google presents itself to dex as a confidential client (the
# authorization-code flow web sign-in needs), so its secret is minted in
# sso.tf beside flux-web's and written here write-only from the same
# ephemeral value as the dex-client-<id> container dex reads -- one rotation
# counter (sso.clients[<client_id>].version) rewrites both in one apply.
# Replacing the provider on its own (a provider_id or pool_id change) writes
# a fresh value to it alone, so bump the client's version in the same apply.
#
# The workforce pool lives under the organization, not the project, so the
# apply identity needs roles/iam.workforcePoolAdmin on organization_id; the
# one project grant below (container.clusterViewer, for get-credentials)
# needs the usual project IAM rights.

locals {
  # The pool's principal-set root: <root>/* is every principal of the pool,
  # <root>/group/<group> one dex group (what rbac.groups binds).
  kubectl_pool_principal = "principalSet://iam.googleapis.com/locations/global/workforcePools/${local.kubectl_pool_id}"
}

resource "google_iam_workforce_pool" "dex" {
  for_each = toset(local.kubectl_enabled ? ["true"] : [])

  parent            = "organizations/${var.sso.kubectl.organization_id}"
  location          = "global"
  workforce_pool_id = local.kubectl_pool_id
  display_name      = "${var.name} (dex)"
  description       = "kubectl through dex for GKE cluster ${var.name} (${var.project})."
}

resource "google_iam_workforce_pool_provider" "dex" {
  for_each = google_iam_workforce_pool.dex

  location          = "global"
  workforce_pool_id = each.value.workforce_pool_id
  provider_id       = var.sso.kubectl.provider_id
  display_name      = "dex"
  description       = "dex at https://dex.${local.platform_domain} (cluster ${var.name})."

  # The subject is the email dex asserts, the groups its groups claim: the
  # same identity and groups the flux-web UI impersonates with, so one
  # rbac.groups binding reads the same in both.
  attribute_mapping = {
    "google.subject"      = "assertion.email"
    "google.groups"       = "assertion.groups"
    "google.display_name" = "assertion.name"
  }

  oidc {
    issuer_uri = "https://dex.${local.platform_domain}"
    client_id  = var.sso.kubectl.client_id

    client_secret {
      value {
        plain_text_wo         = ephemeral.random_password.dex_client[var.sso.kubectl.client_id].result
        plain_text_wo_version = tostring(local.dex_clients[var.sso.kubectl.client_id].version)
      }
    }

    # The authorization-code flow, with dex's userinfo merged over the ID
    # token's claims. dex emits a groups claim only when asked for the
    # groups scope; openid, profile and email are requested by default.
    web_sso_config {
      response_type             = "CODE"
      assertion_claims_behavior = "MERGE_USER_INFO_OVER_ID_TOKEN_CLAIMS"
      additional_scopes         = ["groups"]
    }
  }
}

# get-credentials reads the cluster's endpoint and CA through the GKE API, so
# every principal of the pool may view clusters in this project; what they
# can do inside the cluster is RBAC's call alone.
resource "google_project_iam_member" "kubectl_cluster_viewer" {
  for_each = google_iam_workforce_pool.dex

  project = var.project
  role    = "roles/container.clusterViewer"
  member  = "${local.kubectl_pool_principal}/*"
}
