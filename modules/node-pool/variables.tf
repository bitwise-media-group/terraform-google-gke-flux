# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "project" {
  description = "Project ID the cluster lives in."
  type        = string
  nullable    = false
}

variable "cluster" {
  description = "Name of the GKE cluster the pool joins."
  type        = string
  nullable    = false
}

variable "location" {
  description = "The cluster's location (a region for a regional cluster, a zone for a zonal one)."
  type        = string
  nullable    = false
}

variable "name" {
  description = <<-EOT
    Node pool name, unique within the cluster. A fixed name rather than a prefix: GKE caps pool names at 40
    characters and a generated suffix would eat most of them. Changing it replaces the pool.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,38}[a-z0-9])?$", var.name))
    error_message = "name must be a lowercase RFC-1035 label of at most 40 characters (GKE's node pool name limit)."
  }
}

variable "service_account" {
  description = <<-EOT
    Email of the service account the nodes run as - the cluster's dedicated node service account, never the default
    compute one.
  EOT
  type        = string
  nullable    = false
}

variable "node_locations" {
  description = <<-EOT
    Zones the pool's nodes run in. Empty inherits the cluster's node locations (every zone of a regional cluster, or
    the control-plane zone of a zonal one).
  EOT
  type        = set(string)
  nullable    = false
  default     = []
}

variable "machine_type" {
  description = "Compute Engine machine type of every node (e.g. e2-standard-4, or t2a-standard-4 for arm64)."
  type        = string
  nullable    = false
  default     = "e2-standard-2"
}

variable "spot" {
  description = <<-EOT
    Run the pool on Spot VMs (preemptible, deeply discounted). Pair with location_policy = "ANY" so the autoscaler
    chases spare capacity across zones.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "min_size" {
  description = <<-EOT
    Minimum node count. A cluster-wide total across node_locations unless size_per_zone is set. 0 lets the pool
    scale to zero when nothing schedules on it.
  EOT
  type        = number
  nullable    = false
  default     = 1

  validation {
    condition     = var.min_size >= 0
    error_message = "min_size must not be negative."
  }
}

variable "max_size" {
  description = "Maximum node count. A cluster-wide total across node_locations unless size_per_zone is set."
  type        = number
  nullable    = false
  default     = 3

  validation {
    condition     = var.max_size >= 1 && var.max_size >= var.min_size
    error_message = "max_size must be at least 1 and no smaller than min_size."
  }
}

variable "size_per_zone" {
  description = <<-EOT
    Interpret min_size and max_size as per-zone counts (autoscaling min/max_node_count) instead of cluster-wide
    totals (total_min/max_node_count). GKE holds one or the other, and moving between them is an in-place update.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "initial_size" {
  description = <<-EOT
    Node count per zone at creation. Set once and never argued about again (ignore_changes) - the count is the
    autoscaler's to move on a live cluster.
  EOT
  type        = number
  nullable    = false
  default     = 1

  validation {
    condition     = var.initial_size >= 0
    error_message = "initial_size must not be negative."
  }
}

variable "disk_size_gib" {
  description = "Boot disk size in GiB."
  type        = number
  nullable    = false
  default     = 50
}

variable "disk_type" {
  description = "Boot disk type (pd-standard, pd-balanced, pd-ssd, hyperdisk-balanced, ...). Null takes the GKE default."
  type        = string
  nullable    = true
  default     = null
}

variable "image_type" {
  description = "Node image type (e.g. COS_CONTAINERD, UBUNTU_CONTAINERD). Null takes the GKE default (COS_CONTAINERD)."
  type        = string
  nullable    = true
  default     = null
}

variable "labels" {
  description = "Kubernetes labels applied to every node in the pool - the selectors workloads pin with."
  type        = map(string)
  nullable    = false
  default     = {}
}

variable "taints" {
  description = <<-EOT
    Kubernetes taints applied to every node in the pool. Effects use GKE's (and the AWS node-group module's) enum:
    NO_SCHEDULE, PREFER_NO_SCHEDULE or NO_EXECUTE. GKE adds kubernetes.io/arch=arm64:NoSchedule to Arm nodes on its
    own; it need not be listed here.
  EOT
  type = list(object({
    key    = string
    value  = optional(string)
    effect = string
  }))
  nullable = false
  default  = []

  validation {
    condition = alltrue([
      for taint in var.taints : contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], taint.effect)
    ])
    error_message = "Each taint effect must be NO_SCHEDULE, NO_EXECUTE or PREFER_NO_SCHEDULE."
  }
}

variable "location_policy" {
  description = <<-EOT
    Autoscaler location policy: BALANCED spreads nodes evenly across zones, ANY prefers zones with spare capacity
    (recommended for spot). Null takes the GKE default (BALANCED, or ANY for spot pools).
  EOT
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.location_policy == null || contains(["BALANCED", "ANY"], coalesce(var.location_policy, "BALANCED"))
    error_message = "location_policy must be BALANCED or ANY (or null for the GKE default)."
  }
}

variable "resource_labels" {
  description = "GCP resource labels applied to the pool's Compute Engine instances (billing attribution)."
  type        = map(string)
  nullable    = false
  default     = {}
}
