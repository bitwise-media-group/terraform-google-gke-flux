# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with a mocked google provider: no credentials, no
# API calls. These assert the dex secret-sync contract — which containers the
# connector declaration creates and, most importantly, which KSA subject may
# read each one. The names and the subject are the platform manifests' half
# of the contract; a mismatch here is exactly the drift this module exists to
# prevent.

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

run "nothing_by_default" {
  command = plan

  assert {
    condition     = length(google_secret_manager_secret.main) == 0 && length(output.secrets) == 0
    error_message = "without sso there is no out-of-band credential to hold - the module knows no application"
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
    condition     = sort(keys(google_secret_manager_secret.main)) == tolist(["dex-google-admin-email", "dex-google-client-id", "dex-google-client-secret"])
    error_message = "sso must create exactly one dex-<id>-<field> container per declared connector field"
  }

  assert {
    condition     = google_secret_manager_secret.main["dex-google-client-id"].secret_id == "dex-google-client-id"
    error_message = "an unset secret_prefix must keep the unprefixed container names"
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.sync["dex-google-client-secret"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/dex/sa/dex-secrets"
    error_message = "the dex credentials are read by the dex-secrets sync KSA in the dex namespace"
  }

  assert {
    condition = alltrue([
      for grant in values(google_secret_manager_secret_iam_member.sync) : grant.role == "roles/secretmanager.secretAccessor"
    ])
    error_message = "sync grants carry accessor only — versions are added out of band, never written by a cluster identity"
  }

  assert {
    condition     = output.secrets["dex-google-client-id"].secret_id == "dex-google-client-id"
    error_message = "the secrets output must expose each container's secret_id for caller-side IAM wiring"
  }
}

run "sso_connector_mechanism_is_generic" {
  command = plan

  # The cluster module's full sso declaration passes verbatim: the
  # attributes this module doesn't consume (name, config, kubectl, clients)
  # are dropped by type conversion, an unset secrets defaults to the client
  # pair, and an explicit id wins over the type default for the container
  # stem.
  variables {
    sso = {
      enabled   = true
      connector = { id = "okta", type = "oidc", name = "Okta", config = { issuer = "https://example.okta.com" } }
      kubectl   = { enabled = true, organization_id = "123456789012" }
      clients   = { flux-web = { version = 2 } }
    }
  }

  assert {
    condition     = sort(keys(google_secret_manager_secret.main)) == tolist(["dex-okta-client-id", "dex-okta-client-secret"])
    error_message = "a non-google connector id must create the same dex-<id>-<field> container shape as google"
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.sync["dex-okta-client-secret"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/dex/sa/dex-secrets"
    error_message = "every connector's credentials are read by the same dex-secrets sync KSA in the dex namespace"
  }
}

run "sso_enabled_no_connector_no_containers" {
  command = plan

  variables {
    sso = {
      enabled = true
    }
  }

  assert {
    condition     = length(google_secret_manager_secret.main) == 0
    error_message = "sso.enabled alone (no connector) must create no dex credential containers -- no connector is declared by default"
  }
}

run "sso_disabled_ignores_connector" {
  command = plan

  variables {
    sso = {
      connector = { type = "google" }
    }
  }

  assert {
    condition     = length(google_secret_manager_secret.main) == 0
    error_message = "a connector declared on a cluster without sso syncs nothing, so no container may exist"
  }
}

run "prefix_applies_to_every_container" {
  command = plan

  variables {
    secret_prefix = "patchy-x-"
    sso = {
      enabled   = true
      connector = { type = "google" }
    }
  }

  assert {
    condition = alltrue([
      for secret in values(google_secret_manager_secret.main) : startswith(secret.secret_id, "patchy-x-")
    ])
    error_message = "secret_prefix must prefix every container name (the platform syncs <prefix><container>)"
  }

  assert {
    condition     = output.secrets["dex-google-client-id"].secret_id == "patchy-x-dex-google-client-id"
    error_message = "the secrets output keys stay unprefixed; the prefixed name rides in secret_id"
  }
}

run "reserved_connector_id" {
  command = plan

  variables {
    sso = {
      enabled   = true
      connector = { id = "client", type = "oidc" }
    }
  }

  expect_failures = [var.sso]
}
