# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "name" {
  description = "Cluster name."
  type        = string
  default     = "patchy-x"
}

variable "project" {
  description = "Shared-VPC service project the cluster lives in (x-patchy-app-<rand4>)."
  type        = string
}

variable "region" {
  description = "Cluster region."
  type        = string
  default     = "us-central1"
}

variable "host_project_id" {
  description = "Shared-VPC host project (x-vpc-host-<rand4>)."
  type        = string
}

variable "network_name" {
  description = "Shared VPC network name."
  type        = string
  default     = "x-vpc-shared"
}

variable "subnetwork_name" {
  description = "Subnet carrying the GKE secondary ranges."
  type        = string
  default     = "x-patchy-primary-iowa"
}

variable "pods_range_name" {
  description = "Pods secondary range name."
  type        = string
  default     = "x-patchy-gke-pods-iowa"
}

variable "services_range_name" {
  description = "Services secondary range name."
  type        = string
  default     = "x-patchy-gke-svc-iowa"
}

variable "platform_registry" {
  description = "artifact-store platform_registry output."
  type        = string
}

variable "signed_identity_subjects" {
  description = "artifact-store signed_identity_subjects output."
  type = object({
    containers = string
    manifests  = string
  })
}

variable "dns_zone_name" {
  description = "Cloud DNS zone name of the delegated subdomain created in cloud-accounts (its dns output: `patchy`)."
  type        = string
  default     = "patchy"
}

variable "gateway_address_name" {
  description = "Name of the existing global static IP reserved in cloud-accounts (its ingress_ip output: `ingress`)."
  type        = string
  default     = "ingress"
}

variable "acme_email" {
  description = "Let's Encrypt registration email for the cert-manager cluster issuers."
  type        = string
}

variable "master_authorized_networks" {
  description = "CIDRs allowed to reach the control-plane endpoint."
  type = list(object({
    cidr_block   = string
    display_name = optional(string)
  }))
  default = []
}

variable "observability_project" {
  description = "Optional central observability project for OTLP telemetry; null writes to the cluster project."
  type        = string
  default     = null
}
