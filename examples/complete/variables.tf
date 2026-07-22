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

variable "rbac" {
  description = "Google Groups for RBAC (module rbac input): the toggle, the Workspace domain hosting gke-security-groups, and the per-role subject groups published as RBAC_GROUP_* cluster vars. Off by default."
  type = object({
    enabled = optional(bool, false)
    domain  = optional(string)
    groups = optional(object({
      viewers    = optional(string)
      developers = optional(string)
      devops     = optional(string)
      admins     = optional(string)
    }), {})
  })
  default = {}
}

variable "observability_project" {
  description = "Optional central observability project for OTLP telemetry; null writes to the cluster project."
  type        = string
  default     = null
}

variable "secret_prefix" {
  description = "Secret Manager container-name prefix (module secret_prefix input), published as the SECRET_PREFIX cluster var. Unset keeps unprefixed names."
  type        = string
  default     = null
}

variable "stack_components" {
  description = "Optional-tier election (module stack_components input), published as the STACK_COMPONENTS cluster var. Defaults to the whole tier; [] elects none. dex rides the sso toggle."
  type        = set(string)
  default     = ["flux-web", "patchy"]
}

variable "sso" {
  description = "Platform SSO (module sso input): deploys dex and wires elected relying parties to it. directory_sa (the Workspace directory-reader SA) is required when enabled; client_rotation bumps mint new client secrets."
  type = object({
    enabled         = optional(bool, false)
    directory_sa    = optional(string)
    client_rotation = optional(map(number), {})
  })
  default = {}
}
