# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "region" {
  description = "Default region for the google provider."
  type        = string
  default     = "us-central1"
}

variable "location" {
  description = "The cluster's location (its region, or its zone for a zonal cluster)."
  type        = string
  default     = "us-central1"
}

variable "cluster" {
  description = "The cluster root's application_target output, verbatim."
  type = object({
    name              = string
    namespace         = string
    platform_registry = string
    tree              = string
    issuer            = optional(string)
    keyed             = bool
    project           = string
    project_number    = string
    workload_pool     = string
    secret_prefix     = string
  })
}

variable "domain" {
  description = "The domain the application serves, handed to it as DEMO_DOMAIN."
  type        = string
}
