# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "integration" {
  description = "The audience, service account and organization patchy's google-cloud Integration must be configured with."
  value       = module.scc_notifications.integration
}

output "dead_letter_topic" {
  description = "Dead-letter topic to alert on: anything here is a finding patchy never accepted."
  value       = module.scc_notifications.dead_letter_topic
}

output "subscription" {
  description = "Push subscription, for alerting on its oldest unacknowledged message age."
  value       = module.scc_notifications.subscription
}
