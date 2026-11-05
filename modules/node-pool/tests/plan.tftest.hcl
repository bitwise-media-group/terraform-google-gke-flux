# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with a mocked provider: the fixed policy every pool
# carries (Workload Identity metadata, Shielded VM, auto-repair/upgrade, surge
# upgrades), the sizing translation (cluster-wide totals by default, per-zone
# on request), node locations, labels, taints and the name limit.

mock_provider "google" {}

variables {
  project         = "x-patchy-app-ab12"
  cluster         = "patchy-x"
  location        = "us-central1-a"
  name            = "workers"
  service_account = "patchy-x-nodes@x-patchy-app-ab12.iam.gserviceaccount.com"
}

run "fixed_policy" {
  command = plan

  assert {
    condition     = google_container_node_pool.main.name == "workers" && google_container_node_pool.main.cluster == "patchy-x" && google_container_node_pool.main.location == "us-central1-a"
    error_message = "the pool must take the fixed name and join the given cluster at its location"
  }

  assert {
    condition     = google_container_node_pool.main.node_config[0].service_account == var.service_account
    error_message = "nodes must run as the given service account, never the default compute one"
  }

  assert {
    condition     = google_container_node_pool.main.node_config[0].workload_metadata_config[0].mode == "GKE_METADATA"
    error_message = "the GKE metadata server must front every node (Workload Identity)"
  }

  assert {
    condition     = google_container_node_pool.main.node_config[0].shielded_instance_config[0].enable_secure_boot && google_container_node_pool.main.node_config[0].shielded_instance_config[0].enable_integrity_monitoring
    error_message = "every node must be a Shielded VM with secure boot and integrity monitoring"
  }

  assert {
    condition     = google_container_node_pool.main.management[0].auto_repair && google_container_node_pool.main.management[0].auto_upgrade
    error_message = "auto-repair and auto-upgrade must be on"
  }

  assert {
    condition     = google_container_node_pool.main.upgrade_settings[0].strategy == "SURGE" && google_container_node_pool.main.upgrade_settings[0].max_surge == 1 && google_container_node_pool.main.upgrade_settings[0].max_unavailable == 0
    error_message = "upgrades must surge one node at a time without taking one away first"
  }

  assert {
    condition     = google_container_node_pool.main.node_config[0].spot == false && google_container_node_pool.main.node_config[0].machine_type == "e2-standard-2"
    error_message = "the default pool is on-demand e2-standard-2"
  }

  assert {
    condition     = length(google_container_node_pool.main.node_config[0].taint) == 0
    error_message = "no taints unless asked for"
  }
}

run "total_sizing_by_default" {
  command = plan

  variables {
    min_size     = 0
    max_size     = 5
    initial_size = 0
  }

  assert {
    condition     = google_container_node_pool.main.autoscaling[0].total_min_node_count == 0 && google_container_node_pool.main.autoscaling[0].total_max_node_count == 5
    error_message = "min_size/max_size must be cluster-wide totals by default (scale-to-zero must be expressible)"
  }

  assert {
    condition     = google_container_node_pool.main.autoscaling[0].min_node_count == null && google_container_node_pool.main.autoscaling[0].max_node_count == null
    error_message = "per-zone bounds must stay unset alongside total bounds - GKE holds one or the other"
  }

  assert {
    condition     = google_container_node_pool.main.initial_node_count == 0
    error_message = "initial_size must land as the initial node count"
  }
}

run "per_zone_sizing" {
  command = plan

  variables {
    size_per_zone = true
    min_size      = 1
    max_size      = 2
  }

  assert {
    condition     = google_container_node_pool.main.autoscaling[0].min_node_count == 1 && google_container_node_pool.main.autoscaling[0].max_node_count == 2
    error_message = "size_per_zone must map min_size/max_size onto the per-zone bounds"
  }

  assert {
    condition     = google_container_node_pool.main.autoscaling[0].total_min_node_count == null && google_container_node_pool.main.autoscaling[0].total_max_node_count == null
    error_message = "total bounds must stay unset alongside per-zone bounds"
  }
}

run "dedicated_arm_spot_pool" {
  command = plan

  variables {
    name            = "arc-arm64"
    machine_type    = "t2a-standard-4"
    spot            = true
    location_policy = "ANY"
    node_locations  = ["us-central1-a"]
    disk_type       = "pd-balanced"
    image_type      = "COS_CONTAINERD"
    labels          = { workload = "arc" }
    resource_labels = { team = "platform" }
    taints = [
      { key = "workload", value = "arc", effect = "NO_SCHEDULE" },
      { key = "dedicated", effect = "PREFER_NO_SCHEDULE" },
    ]
  }

  assert {
    condition     = google_container_node_pool.main.node_config[0].machine_type == "t2a-standard-4" && google_container_node_pool.main.node_config[0].spot
    error_message = "machine type and spot must pass through"
  }

  assert {
    condition     = google_container_node_pool.main.autoscaling[0].location_policy == "ANY"
    error_message = "location_policy must pass through"
  }

  assert {
    condition     = google_container_node_pool.main.node_locations == toset(["us-central1-a"])
    error_message = "node_locations must pass through when set"
  }

  assert {
    condition     = google_container_node_pool.main.node_config[0].disk_type == "pd-balanced" && google_container_node_pool.main.node_config[0].image_type == "COS_CONTAINERD"
    error_message = "disk and image type must pass through"
  }

  assert {
    condition     = output.labels["workload"] == "arc" && google_container_node_pool.main.node_config[0].resource_labels["team"] == "platform"
    error_message = "labels and resource labels must pass through"
  }

  assert {
    condition     = length(output.taints) == 2 && output.taints[0].key == "workload" && output.taints[0].value == "arc" && output.taints[0].effect == "NO_SCHEDULE"
    error_message = "taints must pass through in order with their GKE effect"
  }

  assert {
    condition     = output.taints[1].value == "" && output.taints[1].effect == "PREFER_NO_SCHEDULE"
    error_message = "a taint without a value must land with the empty value"
  }
}

run "rejects_long_name" {
  command = plan

  variables {
    name = "a-node-pool-name-well-beyond-forty-characters"
  }

  expect_failures = [var.name]
}

run "rejects_unknown_taint_effect" {
  command = plan

  variables {
    taints = [{ key = "workload", value = "arc", effect = "NoSchedule" }]
  }

  expect_failures = [var.taints]
}

run "rejects_inverted_bounds" {
  command = plan

  variables {
    min_size = 3
    max_size = 2
  }

  expect_failures = [var.max_size]
}

run "rejects_unknown_location_policy" {
  command = plan

  variables {
    location_policy = "ZONAL"
  }

  expect_failures = [var.location_policy]
}
