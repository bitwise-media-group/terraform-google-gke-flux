# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0, < 8.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0, < 4"
    }
  }
}
