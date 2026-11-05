# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# One GKE node pool on an existing cluster: the cluster root builds its system
# pool (and any var.node_pools) through this module, and an application root
# that needs dedicated capacity calls it directly beside its modules/application
# call, fed from the cluster's application_target. Everything that is policy
# rather than sizing is fixed here, identically for every pool: Workload
# Identity metadata, Shielded VM, auto-repair/auto-upgrade and surge upgrades.

resource "google_container_node_pool" "main" {
  project  = var.project
  cluster  = var.cluster
  location = var.location
  name     = var.name

  # An empty set must land as unset (null) so the pool inherits the cluster's
  # node locations, exactly as the cluster's own node_locations does.
  node_locations = length(var.node_locations) > 0 ? var.node_locations : null

  # Per zone, whichever way min/max are expressed; see lifecycle below.
  initial_node_count = var.initial_size

  autoscaling {
    # GKE holds either per-zone or cluster-wide bounds, never both.
    min_node_count       = var.size_per_zone ? var.min_size : null
    max_node_count       = var.size_per_zone ? var.max_size : null
    total_min_node_count = var.size_per_zone ? null : var.min_size
    total_max_node_count = var.size_per_zone ? null : var.max_size
    location_policy      = var.location_policy
  }

  node_config {
    machine_type    = var.machine_type
    spot            = var.spot
    disk_size_gb    = var.disk_size_gib
    disk_type       = var.disk_type
    image_type      = var.image_type
    service_account = var.service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels          = var.labels
    resource_labels = var.resource_labels

    # GKE's taint effect enum is the same as the AWS node-group module's, so
    # the shape passes straight through; the API requires a value, so an
    # omitted one becomes the empty string Kubernetes treats as "no value".
    dynamic "taint" {
      for_each = var.taints

      content {
        key    = taint.value.key
        value  = taint.value.value == null ? "" : taint.value.value
        effect = taint.value.effect
      }
    }

    # The GKE metadata server: pods see their Workload Identity, never the
    # node service account.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Surge upgrades one node at a time without taking one away first - the GKE
  # default, pinned so it survives default drift and matches the cluster's
  # auto-provisioning defaults.
  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  lifecycle {
    # The node count is the autoscaler's to move once the pool is live;
    # terraform sets the initial size and then stops arguing about it
    # (initial_node_count is also immutable, so a change would replace the
    # pool).
    ignore_changes = [initial_node_count]

    # Deliberately NOT create_before_destroy. Terraform forces it onto every
    # dependency of a resource that sets it, and the pool depends on the
    # cluster, whose name is fixed - a cluster replacement would then try to
    # create the successor before destroying the original and fail. The pool
    # name is fixed too, so create-before-destroy could never succeed for the
    # pool itself either. A pool replacement is destroy-then-create.
  }
}
