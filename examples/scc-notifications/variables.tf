# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "project" {
  description = "Project ID the topic, subscription and push identity live in."
  type        = string
  nullable    = false
  default     = "x-patchy-app-ab12"
}

variable "region" {
  description = "Default region for the google provider."
  type        = string
  nullable    = false
  default     = "europe-west2"
}

variable "organization_id" {
  description = "Numeric organization id the notification config is created under."
  type        = string
  nullable    = false
  default     = "123456789012"
}

variable "patchy_host" {
  description = "Hostname patchy's webhook receiver is served on; the provider route is appended to it."
  type        = string
  nullable    = false
  default     = "patchy.example.co.uk"
}
