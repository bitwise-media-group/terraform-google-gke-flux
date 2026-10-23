# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    # 7.46 is the oldest release this module is verified against with the
    # workforce pool provider's write-only client secret (kubectl.tf).
    google = {
      source  = "hashicorp/google"
      version = ">= 7.46, < 8.6"
    }
    # The cluster resource alone rides the beta provider (a lockstep superset
    # of google): managed_opentelemetry_config has not been promoted to GA.
    # Fold it back into google when it lands there. 7.33 added
    # secret_sync_config to the cluster resource.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 7.33, < 8.6"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    # The ephemeral dex client secrets (sso.tf, kubectl.tf).
    random = {
      source  = "hashicorp/random"
      version = ">= 3.7, < 4.0"
    }
  }
}
