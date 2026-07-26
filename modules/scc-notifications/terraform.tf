# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0, < 8.0"
    }
    # google_project_service_identity alone rides the beta provider (a
    # lockstep superset of google): it has not been promoted to GA. It earns
    # the dependency by returning the Pub/Sub service agent's identity
    # directly, instead of composing "service-<project number>@gcp-sa-pubsub"
    # by hand -- a string that is wrong silently when it is wrong at all, and
    # that made the caller pass a project number for no other reason. Fold it
    # back into google when it lands there.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 7.0, < 8.0"
    }
  }
}
