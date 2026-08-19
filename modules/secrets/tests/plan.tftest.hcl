# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with a mocked google provider: no credentials, no
# API calls. These assert the secret-sync contract — which containers each
# election creates and, most importantly, which KSA subject may read each
# one. The subjects are flux-manifests' half of the contract; a mismatch
# here is exactly the drift this module exists to prevent.

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
}

variables {
  project = "x-patchy-app-ab12"
}

run "default_election" {
  command = plan

  assert {
    condition     = sort(keys(google_secret_manager_secret.main)) == tolist(["patchy-anthropic-token", "patchy-github-app-id", "patchy-github-app-private-key", "patchy-webhook-secret"])
    error_message = "the default election (patchy elected, claude on anthropic, no sso) must create exactly the GitHub App trio plus the anthropic token"
  }

  assert {
    condition     = google_secret_manager_secret.main["patchy-github-app-id"].secret_id == "patchy-github-app-id"
    error_message = "an unset secret_prefix must keep the unprefixed container names"
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.sync["patchy-anthropic-token"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/patchy/sa/patchy-secrets"
    error_message = "the anthropic token is read by the egress broker's sync in the patchy namespace (since chart 0.10.0), never patchy-agents"
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.sync["patchy-github-app-private-key"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/patchy/sa/patchy-secrets"
    error_message = "the GitHub App credential is read by the patchy-namespace sync KSA"
  }

  assert {
    condition = alltrue([
      for grant in values(google_secret_manager_secret_iam_member.sync) : grant.role == "roles/secretmanager.secretAccessor"
    ])
    error_message = "sync grants carry accessor only — versions are added out of band, never written by a cluster identity"
  }

  assert {
    condition     = output.secrets["patchy-anthropic-token"].secret_id == "patchy-anthropic-token"
    error_message = "the secrets output must expose each container's secret_id for caller-side IAM wiring"
  }
}

run "vertex_needs_no_anthropic_container" {
  command = plan

  variables {
    claude_provider = "vertex"
  }

  assert {
    condition     = !contains(keys(google_secret_manager_secret.main), "patchy-anthropic-token")
    error_message = "a vertex cluster's broker authenticates with its cloud identity: no anthropic container may exist for a sync to wedge on"
  }
}

run "harness_election" {
  command = plan

  variables {
    agent_harnesses = ["claude", "codex", "copilot"]
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.sync["patchy-openai-token"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/patchy-agents/sa/patchy-secrets"
    error_message = "the codex credential mounts into agent pods, so its sync KSA lives in the agent namespace"
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.sync["patchy-copilot-token"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/patchy-agents/sa/patchy-secrets"
    error_message = "the copilot credential mounts into agent pods, so its sync KSA lives in the agent namespace"
  }
}

run "sso_adds_dex_credentials" {
  command = plan

  variables {
    sso = {
      enabled = true
      connector = {
        type    = "google"
        secrets = ["client-id", "client-secret", "admin-email"]
      }
    }
  }

  assert {
    condition = alltrue([
      for name in ["dex-google-client-id", "dex-google-client-secret", "dex-google-admin-email"] :
      contains(keys(google_secret_manager_secret.main), name)
    ])
    error_message = "sso must add the google connector's OAuth client pair and the directory admin email"
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.sync["dex-google-client-secret"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/dex/sa/dex-secrets"
    error_message = "the dex credentials are read by the dex-secrets sync KSA in the dex namespace"
  }
}

run "sso_connector_mechanism_is_generic" {
  command = plan

  # The cluster module's full connector declaration passes verbatim: the
  # attributes this module doesn't consume (name, config) are dropped by
  # type conversion, an unset secrets defaults to the client pair, and an
  # explicit id wins over the type default for the container stem.
  variables {
    sso = {
      enabled   = true
      connector = { id = "okta", type = "oidc", name = "Okta" }
    }
  }

  assert {
    condition = alltrue([
      for name in ["dex-okta-client-id", "dex-okta-client-secret"] :
      contains(keys(google_secret_manager_secret.main), name)
    ])
    error_message = "a non-google connector id must create the same dex-<id>-<field> container shape as google"
  }

  assert {
    condition     = !contains(keys(google_secret_manager_secret.main), "dex-google-client-id")
    error_message = "a connector not declared in sso.connector must create no container -- google is no longer automatic"
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.sync["dex-okta-client-secret"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/dex/sa/dex-secrets"
    error_message = "every connector's credentials are read by the same dex-secrets sync KSA in the dex namespace"
  }
}

run "sso_enabled_no_connector_no_containers" {
  command = plan

  variables {
    stack_components = []
    sso = {
      enabled = true
    }
  }

  assert {
    condition     = length(google_secret_manager_secret.main) == 0
    error_message = "sso.enabled alone (no connector) must create no dex credential containers -- no connector is declared by default"
  }
}

run "prefix_applies_to_every_container" {
  command = plan

  variables {
    secret_prefix = "patchy-x-"
  }

  assert {
    condition = alltrue([
      for secret in values(google_secret_manager_secret.main) : startswith(secret.secret_id, "patchy-x-")
    ])
    error_message = "secret_prefix must prefix every container name (the manifests sync <prefix><container>)"
  }

  assert {
    condition     = output.secrets["patchy-github-app-id"].secret_id == "patchy-x-patchy-github-app-id"
    error_message = "the secrets output keys stay unprefixed; the prefixed name rides in secret_id"
  }
}

run "no_patchy_no_containers" {
  command = plan

  variables {
    stack_components = ["flux-web"]
  }

  assert {
    condition     = length(google_secret_manager_secret.main) == 0
    error_message = "without the patchy component (and without sso) there is no out-of-band credential to hold"
  }
}
