# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The out-of-band credential containers the flux-manifests stack syncs into
# the cluster (GKE Integrated Secret Synchronization), plus the accessor
# grants for the sync KSAs. This is the terraform half of the secret-sync
# contract whose other half lives in flux-manifests (the patchy component's
# secret-sync.yaml / resourceset-secrets.yaml and the dex component's
# resourceset-secrets.yaml): the container names, the consuming KSA subjects
# and the election gating are mirrored here, versioned with the module
# release that tracks those manifests -- when a sync moves, both halves move
# in one release instead of drifting apart in a caller's hand-rolled copy.
#
# Instantiate this from a DURABLE root, not beside the cluster: the secret
# VERSIONS are added out of band (gcloud secrets versions add -- never
# terraform state) and must survive cluster destroy/recreate with no manual
# re-entry. There is no ordering problem in the other direction -- a Workload
# Identity principal string depends only on the project number and pool name,
# so IAM stores the grant before the pool exists and it sits inert until the
# cluster and its KSAs arrive.

data "google_project" "main" {
  project_id = var.project
}

locals {
  prefix = var.secret_prefix != null ? var.secret_prefix : ""

  patchy = contains(var.stack_components, "patchy")

  # container name -> the KSA subject GKE Integrated Secret Synchronization
  # reads it as. The gating mirrors the manifests exactly: a container no
  # sync references is never created, and every referenced container exists
  # (a SecretProviderClass naming an absent container syncs nothing but
  # errors forever).
  containers = merge(
    # The patchy GitHub App credential (webhook validation, issue projection,
    # repository clone/push), synced unconditionally with the patchy
    # component.
    local.patchy ? {
      patchy-github-app-id          = "ns/patchy/sa/patchy-secrets"
      patchy-github-app-private-key = "ns/patchy/sa/patchy-secrets"
      patchy-webhook-secret         = "ns/patchy/sa/patchy-secrets"
    } : {},

    # The Anthropic credential, consumed by the egress broker in the patchy
    # namespace (since chart 0.10.0 -- formerly the agent namespace) and only
    # when the claude runner's provider is anthropic: a vertex cluster
    # authenticates with its cloud identity and needs no container at all.
    local.patchy && contains(var.agent_harnesses, "claude") && var.claude_provider == "anthropic" ? {
      patchy-anthropic-token = "ns/patchy/sa/patchy-secrets"
    } : {},

    # The non-brokered runners' model credentials, mounted into the agent
    # pods themselves -- hence the agent namespace.
    local.patchy && contains(var.agent_harnesses, "codex") ? {
      patchy-openai-token = "ns/patchy-agents/sa/patchy-secrets"
    } : {},
    local.patchy && contains(var.agent_harnesses, "copilot") ? {
      patchy-copilot-token = "ns/patchy-agents/sa/patchy-secrets"
    } : {},

    # Per-connector out-of-band credentials (arbitrary SSO federation): one
    # container per (connector, field) pair declared in sso_connectors.
    var.sso_enabled ? merge([
      for id, fields in var.sso_connectors : {
        for field in fields : "dex-${id}-${field}" => "ns/dex/sa/dex-secrets"
      }
    ]...) : {},
  )

  wi_prefix = "principal://iam.googleapis.com/projects/${data.google_project.main.number}/locations/global/workloadIdentityPools/${var.project}.svc.id.goog/subject"
}

resource "google_secret_manager_secret" "main" {
  for_each = local.containers

  project   = var.project
  secret_id = "${local.prefix}${each.key}"
  labels    = var.labels

  replication {
    auto {}
  }
}

# Accessor only: the sync KSAs read versions, nothing else. Version WRITES
# stay a human/out-of-band concern -- grant rotation paths
# (secretVersionAdder) in the caller against the secrets output.
resource "google_secret_manager_secret_iam_member" "sync" {
  for_each = local.containers

  project   = var.project
  secret_id = google_secret_manager_secret.main[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "${local.wi_prefix}/${each.value}"
}
