# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with a mocked google provider: no credentials, no
# API calls. These assert the shape of what would be created -- above all the
# authentication, since the push endpoint is internet-facing and the OIDC
# token is the only thing standing in front of it.

mock_provider "google" {}
mock_provider "google-beta" {}

# The push identity's email is computed, so a plan cannot see it and anything
# derived from it -- the token's service_account_email above all -- is unknown.
# Overriding it during the plan is what lets the authentication assertions say
# who the token is for, rather than only that a token block exists.
override_resource {
  target          = google_service_account.push
  override_during = plan

  # name as well as email: the token-creator grant addresses the account by
  # its full resource name, and the provider validates that shape, so a
  # generated mock value fails before any assertion runs.
  values = {
    email = "patchy-scc-push@x-patchy-app-ab12.iam.gserviceaccount.com"
    name  = "projects/x-patchy-app-ab12/serviceAccounts/patchy-scc-push@x-patchy-app-ab12.iam.gserviceaccount.com"
  }
}

# The Pub/Sub service agent, likewise: asking the API for it is the point, so
# its value is only known after apply.
override_resource {
  target          = google_project_service_identity.pubsub
  override_during = plan

  values = {
    email  = "service-123456789012@gcp-sa-pubsub.iam.gserviceaccount.com"
    member = "serviceAccount:service-123456789012@gcp-sa-pubsub.iam.gserviceaccount.com"
  }
}

variables {
  project         = "x-patchy-app-ab12"
  organization_id = "987654321098"

  push = {
    endpoint = "https://patchy.example.co.uk/google-cloud/webhooks"
  }
}

run "topic_and_subscription" {
  command = plan

  assert {
    condition     = google_pubsub_topic.findings.name == "patchy-scc-findings"
    error_message = "the findings topic must take its configured name"
  }

  assert {
    condition     = google_pubsub_subscription.push.name == "patchy-scc-push"
    error_message = "the push subscription must take its configured name"
  }

  assert {
    condition     = one(google_pubsub_subscription.push.push_config).push_endpoint == "https://patchy.example.co.uk/google-cloud/webhooks"
    error_message = "the subscription must push to the configured patchy endpoint"
  }

  # A subscription that expires after a quiet month would take the finding
  # pipeline with it, and a quiet month is a good month.
  assert {
    condition     = one(google_pubsub_subscription.push.expiration_policy).ttl == ""
    error_message = "the push subscription must never expire"
  }

  # patchy answers 202 as soon as a delivery is queued, so the deadline covers
  # the request rather than the work it triggers.
  assert {
    condition     = google_pubsub_subscription.push.ack_deadline_seconds == 30
    error_message = "the ack deadline must default to 30 seconds"
  }
}

run "push_authentication" {
  command = plan

  assert {
    condition     = length(one(google_pubsub_subscription.push.push_config).oidc_token) == 1
    error_message = "the push must present an OIDC token; an unauthenticated push endpoint is open to anyone"
  }

  # audience defaults to the endpoint, matching patchy's own default.
  assert {
    condition     = one(one(google_pubsub_subscription.push.push_config).oidc_token).audience == "https://patchy.example.co.uk/google-cloud/webhooks"
    error_message = "the token audience must default to the push endpoint"
  }

  # The identity patchy is told to trust must be the one Pub/Sub actually
  # presents; a mismatch here means every delivery is rejected.
  assert {
    condition     = one(one(google_pubsub_subscription.push.push_config).oidc_token).service_account_email == "patchy-scc-push@x-patchy-app-ab12.iam.gserviceaccount.com"
    error_message = "the token must be issued for the module's own push identity"
  }

  # (The same value on output.integration.service_account is only known after
  # apply, so the resource attribute above is where this is checkable.)

  # Pub/Sub cannot mint the token without token-creator on that account.
  assert {
    condition     = google_service_account_iam_member.push_token_creator.role == "roles/iam.serviceAccountTokenCreator"
    error_message = "Pub/Sub must hold token-creator on the push identity, or it cannot sign the token"
  }

  # The grant goes to Pub/Sub's service agent, as the API reports it — not to
  # the push identity, and not to an address composed by hand.
  assert {
    condition     = google_service_account_iam_member.push_token_creator.member == google_project_service_identity.pubsub.member
    error_message = "token-creator must be granted to the project's Pub/Sub service agent, not the push identity itself"
  }

  assert {
    condition     = google_project_service_identity.pubsub.service == "pubsub.googleapis.com"
    error_message = "the service identity fetched must be Pub/Sub's"
  }
}

run "explicit_audience" {
  command = plan

  variables {
    push = {
      endpoint = "https://patchy.example.co.uk/google-cloud/webhooks"
      audience = "patchy"
    }
  }

  assert {
    condition     = one(one(google_pubsub_subscription.push.push_config).oidc_token).audience == "patchy"
    error_message = "an explicit audience must supersede the endpoint default"
  }

  assert {
    condition     = output.integration.audience == "patchy"
    error_message = "the integration output must report the audience patchy has to be configured with"
  }
}

run "scc_publisher_grant" {
  command = plan

  assert {
    condition     = google_pubsub_topic_iam_member.scc_publisher.role == "roles/pubsub.publisher"
    error_message = "SCC's service agent must be able to publish to the topic"
  }

  # The agent address is well-known and org-scoped; Google creates it, this
  # module only binds it.
  assert {
    condition     = google_pubsub_topic_iam_member.scc_publisher.member == "serviceAccount:service-org-987654321098@gcp-sa-scc-notification.iam.gserviceaccount.com"
    error_message = "the publisher grant must name the organization's SCC notification service agent"
  }
}

run "notification_config" {
  command = plan

  assert {
    condition     = google_scc_v2_organization_notification_config.patchy.organization == "987654321098"
    error_message = "the notification config must be created at the organization, so one deployment sees every project"
  }

  # An empty filter would publish every finding in the organization; the
  # default also has to survive SCC's grammar, where negation is a leading `-`
  # and OR binds tighter than AND.
  assert {
    condition     = one(google_scc_v2_organization_notification_config.patchy.streaming_config).filter == "state=\"ACTIVE\" AND -mute=\"MUTED\" AND (severity=\"HIGH\" OR severity=\"CRITICAL\")"
    error_message = "the notification config must carry the default filter verbatim"
  }

  assert {
    condition     = google_scc_v2_organization_notification_config.patchy.config_id == "patchy"
    error_message = "the notification config must take its configured id"
  }
}

run "dead_letter_enabled_by_default" {
  command = plan

  assert {
    condition     = length(google_pubsub_topic.dead_letter) == 1
    error_message = "a dead-letter topic must exist by default, or a finding patchy never accepted disappears silently"
  }

  assert {
    condition     = google_pubsub_topic.dead_letter[0].name == "patchy-scc-findings-dead-letter"
    error_message = "the dead-letter topic must be named after the topic it backs"
  }

  assert {
    condition     = length(google_pubsub_subscription.push.dead_letter_policy) == 1
    error_message = "the subscription must route undeliverable findings to the dead-letter topic"
  }

  assert {
    condition     = one(google_pubsub_subscription.push.dead_letter_policy).max_delivery_attempts == 10
    error_message = "the subscription must give up after a bounded number of attempts, not retry forever"
  }

  assert {
    condition     = length(google_pubsub_topic_iam_member.dead_letter) == 1 && length(google_pubsub_subscription_iam_member.dead_letter) == 1
    error_message = "Pub/Sub's service agent must be able to publish to the dead-letter topic and acknowledge on the subscription"
  }
}

run "dead_letter_disabled" {
  command = plan

  variables {
    dead_letter = { enabled = false }
  }

  assert {
    condition     = length(google_pubsub_topic.dead_letter) == 0
    error_message = "no dead-letter topic must exist when it is disabled"
  }

  assert {
    condition     = length(google_pubsub_subscription.push.dead_letter_policy) == 0
    error_message = "the subscription must carry no dead-letter policy when it is disabled"
  }

  assert {
    condition     = length(google_pubsub_topic_iam_member.dead_letter) == 0 && length(google_pubsub_subscription_iam_member.dead_letter) == 0
    error_message = "no dead-letter grants must exist when it is disabled"
  }
}

# These resources belong beside the cluster that consumes them, so the common
# case is naming no project at all and letting the provider's stand.
run "project_falls_back_to_the_provider" {
  command = plan

  variables {
    project = null
  }

  # The resolved project is deliberately not asserted: leaving it unset is
  # what makes the provider fill it, so it is unknown until apply. What this
  # proves is that the plan succeeds at all with no project named -- that the
  # variable is genuinely optional rather than merely defaulted -- and that
  # the org-scoped notification config, which never had a project, is
  # unaffected either way.
  assert {
    condition     = google_pubsub_topic.findings.name == "patchy-scc-findings"
    error_message = "the module must plan cleanly with no project named"
  }

  assert {
    condition     = google_scc_v2_organization_notification_config.patchy.organization == "987654321098"
    error_message = "the notification config is organization-scoped and must not depend on a project"
  }
}

run "no_asset_viewers_by_default" {
  command = plan

  assert {
    condition     = length(google_project_iam_member.asset_viewers) == 0
    error_message = "no asset-viewer grant must be created unless members are supplied"
  }
}

run "asset_viewers" {
  command = plan

  variables {
    asset_viewer_members = [
      "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/patchy/sa/patchy-context-controller",
    ]
  }

  assert {
    condition     = google_project_iam_member.asset_viewers["viewer-0"].role == "roles/cloudasset.viewer"
    error_message = "repository resolution needs read-only asset access, and no more"
  }
}

run "endpoint_must_be_https" {
  command = plan

  variables {
    push = { endpoint = "http://patchy.example.co.uk/google-cloud/webhooks" }
  }

  expect_failures = [var.push]
}

run "endpoint_must_be_the_provider_route" {
  command = plan

  variables {
    push = { endpoint = "https://patchy.example.co.uk/github/webhooks" }
  }

  expect_failures = [var.push]
}

run "organization_id_must_be_numeric" {
  command = plan

  variables {
    organization_id = "organizations/987654321098"
  }

  expect_failures = [var.organization_id]
}

run "filter_must_not_be_empty" {
  command = plan

  variables {
    filter = "   "
  }

  expect_failures = [var.filter]
}
