# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "integration" {
  description = <<-EOT
    The two values patchy's google-cloud Integration must carry, ready to paste into
    spec.googleCloud.securityCommandCenter. A mismatch on either fails closed: patchy rejects the push rather than
    accepting an unexpected identity.
  EOT
  value = {
    audience        = coalesce(var.push.audience, var.push.endpoint)
    service_account = google_service_account.push.email
    organization    = var.organization_id
  }
}

output "topic" {
  description = "Full resource name of the findings topic, for granting other publishers or attaching more subscriptions."
  value       = google_pubsub_topic.findings.id
}

output "dead_letter_topic" {
  description = "Full resource name of the dead-letter topic, or null when disabled. Watch its message count: anything here is a finding patchy never accepted."
  value       = local.dead_letter_enabled ? google_pubsub_topic.dead_letter[0].id : null
}

output "subscription" {
  description = "Full resource name of the push subscription, for alerting on its oldest unacknowledged message age."
  value       = google_pubsub_subscription.push.id
}

output "push_service_account" {
  description = "Email of the identity Pub/Sub presents to patchy. Feed it to the Integration's serviceAccount field; patchy accepts no other."
  value       = google_service_account.push.email
}

output "notification_config" {
  description = "Full resource name of the Security Command Center notification config."
  value       = google_scc_v2_organization_notification_config.patchy.name
}
