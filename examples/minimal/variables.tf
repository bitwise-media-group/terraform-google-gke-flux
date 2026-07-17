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
