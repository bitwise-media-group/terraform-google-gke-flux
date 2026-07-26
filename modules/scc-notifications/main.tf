# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Security Command Center findings -> Pub/Sub -> patchy's webhook.
#
# SCC has no webhook of its own. Its only egress is a NotificationConfig
# publishing to a Pub/Sub topic, so reaching an HTTP consumer takes a push
# subscription in between. That shape is why this module exists at all: the
# topic, the config, and the subscription are one unit and pointless apart.
#
# The push authenticates with an OIDC token Pub/Sub signs, not a shared
# secret. A push subscription cannot compute an HMAC over the body — Pub/Sub
# composes the message, the sender never sees it — and the token is the
# stronger primitive anyway: asymmetric, short-lived, and bound to both a
# service account and an audience. Nothing secret is stored here, which is
# also why this module needs no Secret Manager entry and no random_password.
#
# Rejected: a Cloud Run function between the topic and patchy, to enrich each
# finding with its resource's labels. It would have kept the Asset Inventory
# credential inside Google Cloud, but it makes the notification path a
# deployable service with its own lifecycle. patchy looks the labels up
# itself, from the cluster, with workload identity.

locals {
  # SCC publishes as this per-organization service agent, created by Google
  # rather than by this module.
  #
  # The notification config exports the same identity as .service_account, but
  # that is unusable here: SCC rejects the config unless the agent can already
  # publish, so the grant has to exist before the resource that would name it.
  # The address is well-known and derived from the organization id, which is
  # what makes the ordering resolvable at all.
  scc_service_agent = "serviceAccount:service-org-${var.organization_id}@gcp-sa-scc-notification.iam.gserviceaccount.com"

  # A dead-letter topic is how an operator sees deliveries patchy never
  # accepted. Without one a finding that fails repeatedly is retried until it
  # expires and then vanishes silently.
  dead_letter_enabled = var.dead_letter.enabled
}

resource "google_pubsub_topic" "findings" {
  project = var.project
  name    = var.topic_name

  labels = var.labels
}

# Findings patchy never acknowledged. Retained longer than the live topic:
# the point of the queue is to still be there when someone comes looking.
resource "google_pubsub_topic" "dead_letter" {
  count = local.dead_letter_enabled ? 1 : 0

  project                    = var.project
  name                       = "${var.topic_name}-dead-letter"
  message_retention_duration = var.dead_letter.retention

  labels = var.labels
}

# The notification config itself. The filter is the first line of volume
# control -- an organization's SCC emits far more than patchy should triage,
# and dropping findings here costs nothing downstream.
resource "google_scc_v2_organization_notification_config" "patchy" {
  organization = var.organization_id
  location     = var.location
  config_id    = var.config_id
  description  = var.description
  pubsub_topic = google_pubsub_topic.findings.id

  streaming_config {
    filter = var.filter
  }

  # The service agent must be able to publish before the config is created,
  # or SCC rejects it.
  depends_on = [google_pubsub_topic_iam_member.scc_publisher]
}

resource "google_pubsub_subscription" "push" {
  project = var.project
  name    = var.subscription_name
  topic   = google_pubsub_topic.findings.id

  # patchy answers 202 as soon as a delivery is queued, so the deadline only
  # needs to cover the request itself, not the work it triggers.
  ack_deadline_seconds = var.push.ack_deadline_seconds

  push_config {
    push_endpoint = var.push.endpoint

    # The authentication. audience must match the Integration's
    # spec.googleCloud.securityCommandCenter.audience, and the service
    # account its serviceAccount -- patchy checks both, so a mismatch fails
    # closed rather than silently accepting anything Google signed.
    oidc_token {
      service_account_email = google_service_account.push.email
      audience              = coalesce(var.push.audience, var.push.endpoint)
    }
  }

  # patchy answers 503 when its queue is full, which is a nack: backing off
  # and retrying is exactly the behaviour wanted there.
  retry_policy {
    minimum_backoff = var.push.minimum_backoff
    maximum_backoff = var.push.maximum_backoff
  }

  dynamic "dead_letter_policy" {
    for_each = local.dead_letter_enabled ? ["this"] : []

    content {
      dead_letter_topic     = google_pubsub_topic.dead_letter[0].id
      max_delivery_attempts = var.dead_letter.max_delivery_attempts
    }
  }

  expiration_policy {
    # Never expire. A subscription that quietly disappears after 31 days of
    # no traffic would take the whole finding pipeline with it, and "no
    # findings for a month" is a good month, not an unused subscription.
    ttl = ""
  }

  labels = var.labels
}
