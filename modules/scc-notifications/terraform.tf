# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0, < 8.0"
    }
    # The two service-identity resources ride the beta provider (a lockstep
    # superset of google): neither has been promoted to GA -- the GA provider
    # ships the organization one as an empty stub. The project-scoped one
    # returns the Pub/Sub agent's identity directly, instead of composing
    # "service-<project number>@gcp-sa-pubsub" by hand and making the caller
    # pass a project number for no other reason. The organization one is there
    # only to generate SCC's agent, which no composed string can do; it
    # returns nothing usable (main.tf). Fold both back into google when they
    # land there.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 7.0, < 8.0"
    }
  }
}
