# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Who may publish, who may push, and who patchy will accept a push from.
#
# Three identities, deliberately separate: SCC's own service agent publishes,
# a service account this module owns signs the push tokens, and patchy accepts
# only that second one. Reusing a single identity would mean anything able to
# publish could also impersonate the pusher.

# Pub/Sub's own service agent, which mints the push token and moves
# undeliverable messages to the dead-letter topic. Asking the API for it beats
# composing its address from a project number: the resource is a no-op when
# the identity already exists, and a wrong composed string fails at apply with
# nothing to point at.
resource "google_project_service_identity" "pubsub" {
  provider = google-beta

  project = var.project
  service = "pubsub.googleapis.com"
}

# The push identity. Its email is the only thing patchy is configured to
# trust, so it is the module's most consequential output.
resource "google_service_account" "push" {
  project      = var.project
  account_id   = var.push_service_account_id
  display_name = "patchy SCC push"
  description  = "Signs the OIDC tokens Pub/Sub presents to patchy's webhook. patchy accepts no other identity."
}

# SCC's service agent must publish to the topic before a notification config
# naming it can be created.
resource "google_pubsub_topic_iam_member" "scc_publisher" {
  project = var.project
  topic   = google_pubsub_topic.findings.name
  role    = "roles/pubsub.publisher"
  member  = local.scc_service_agent
}

# Pub/Sub's own service agent publishes undeliverable messages to the
# dead-letter topic and acknowledges them on the live subscription. Both
# grants are on the service agent, not on the push identity.
#
# Keyed by fixed labels rather than by role: the keys stay plan-known even
# though the member is computed.
resource "google_pubsub_topic_iam_member" "dead_letter" {
  for_each = local.dead_letter_enabled ? { publisher = "roles/pubsub.publisher" } : {}

  project = var.project
  topic   = google_pubsub_topic.dead_letter[0].name
  role    = each.value
  member  = google_project_service_identity.pubsub.member
}

resource "google_pubsub_subscription_iam_member" "dead_letter" {
  for_each = local.dead_letter_enabled ? { subscriber = "roles/pubsub.subscriber" } : {}

  project      = var.project
  subscription = google_pubsub_subscription.push.name
  role         = each.value
  member       = google_project_service_identity.pubsub.member
}

# Pub/Sub mints the OIDC token as the push service account, which requires
# token-creator on that account. Granted narrowly, on the one account, rather
# than at project level.
resource "google_service_account_iam_member" "push_token_creator" {
  service_account_id = google_service_account.push.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_project_service_identity.pubsub.member
}

# Read-only Asset Inventory access for whoever resolves a finding's
# repository from its resource labels -- patchy's context-controller, via
# workload identity. Optional because the binding may be owned centrally, and
# because a deployment that never resolves repositories does not need it.
#
# Keyed by fixed labels, not member strings, so the keys stay plan-known when
# the members come from another module's outputs.
resource "google_project_iam_member" "asset_viewers" {
  for_each = { for i, m in var.asset_viewer_members : "viewer-${i}" => m }

  project = var.project
  role    = "roles/cloudasset.viewer"
  member  = each.value
}
