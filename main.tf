# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# A minimum-viable GKE Standard cluster for the flux-operator platform:
# regional, VPC-native on a shared-VPC subnet, Dataplane V2 (built-in Cilium),
# Workload Identity, private nodes, a small always-on system node pool for
# platform controllers (label role=system) and node auto-provisioning for
# everything else. GKE manages what EKS delegated to addons (DNS, metrics, CSI,
# metadata server), so there is no addon surface here.

data "google_project" "cluster" {
  project_id = var.project
}

locals {
  workload_identity_pool = "${var.project}.svc.id.goog"

  # Direct Workload Identity Federation for GKE: in-cluster workloads are
  # granted IAM roles as federated principals — no GSAs, no
  # iam.gke.io/gcp-service-account annotations, no key material. The member for
  # a given workload is <prefix>/ns/<namespace>/sa/<service-account>.
  wi_principal_prefix = "principal://iam.googleapis.com/projects/${data.google_project.cluster.number}/locations/global/workloadIdentityPools/${local.workload_identity_pool}/subject"

  system_node_selector = { role = "system" }

  # Google Groups for RBAC. The fleet group's exact name is a GKE requirement;
  # the group and its memberships are managed out-of-band in Workspace — this
  # module only points the authenticator at it. "" is the explicit-disable
  # value for authenticator_groups_config.
  gke_security_group = var.rbac.enabled ? "gke-security-groups@${var.rbac.domain}" : ""

  # Registry-read grants can only be made here when the platform registry
  # lives in the cluster's own project (this module's apply identity has no
  # IAM rights elsewhere). For a central registry (e.g. o-foundation), feed
  # the registry_reader_members output to the artifact-store module's
  # reader_members instead.
  registry_project  = split("/", var.platform_registry)[1]
  registry_is_local = local.registry_project == var.project
}

# Dedicated minimal node service account — never the default compute SA. Both
# the system pool and every auto-provisioned pool run as this identity.
resource "google_service_account" "nodes" {
  project      = var.project
  account_id   = "${var.name}-nodes"
  display_name = "GKE nodes (${var.name})"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset(concat(
    [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
      "roles/monitoring.viewer",
      "roles/stackdriver.resourceMetadata.writer",
    ],
    # image pulls from the platform repository — grantable here only when the
    # registry is co-located (else via artifact-store reader_members)
    local.registry_is_local ? ["roles/artifactregistry.reader"] : [],
  ))

  project = var.project
  role    = each.value
  member  = google_service_account.nodes.member
}

resource "google_container_cluster" "main" {
  # beta-only for managed_opentelemetry_config (see terraform.tf); switching
  # providers is config-only -- no replacement, no state surgery
  provider = google-beta

  project  = var.project
  name     = var.name
  location = var.region

  # An empty set must land as unset (null): explicitly-empty node_locations
  # fights the API-populated zone list on regional clusters, and the
  # provider's shrink-to-empty update serializes to an empty ClusterUpdate
  # the API rejects ("Must specify a field to update").
  node_locations = length(var.zones) > 0 ? var.zones : null

  # Shared VPC: self-links into the host project; secondary ranges by NAME
  # (created by cloud-accounts alongside the subnet).
  network    = var.network.network
  subnetwork = var.network.subnetwork

  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = var.network.pods_range_name
    services_secondary_range_name = var.network.services_range_name
  }

  # Dataplane V2 — GKE's built-in Cilium (eBPF dataplane, NetworkPolicy
  # enforcement without Calico).
  datapath_provider = "ADVANCED_DATAPATH"

  workload_identity_config {
    workload_pool = local.workload_identity_pool
  }

  # Google Groups for RBAC: lets Role/ClusterRoleBindings bind the Workspace
  # groups nested under gke-security-groups. Always declared with an explicit
  # "" so flipping the toggle off actually turns the authenticator down, same
  # reasoning as managed_opentelemetry_config.
  authenticator_groups_config {
    security_group = local.gke_security_group
  }

  private_cluster_config {
    # Nodes have no public IPs; egress requires Cloud NAT on the shared VPC.
    enable_private_nodes = true
    # The control-plane endpoint stays public (constrained by
    # master_authorized_networks) so terraform/helm bootstrap works from CI and
    # workstations without a VPN path; flip on when the org grows one.
    enable_private_endpoint = var.private_endpoint
  }

  dynamic "master_authorized_networks_config" {
    for_each = length(var.master_authorized_networks) > 0 ? ["this"] : []

    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_networks

        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  # The GKE Gateway controller (gke-l7-* GatewayClasses) — HTTPS for the
  # patchy webhook rides on a Gateway, so this is load-bearing.
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  release_channel {
    channel = var.release_channel
  }

  min_master_version = var.kubernetes_version

  # The system pool below replaces it; keeping the default pool would run
  # nodes as the default compute SA.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Governs only the TRANSIENT default pool GKE creates at cluster birth
  # (removed above; real pools carry their own node_config). Without an
  # explicit service account that pool requests the project's default
  # compute SA -- disabled in these projects (project-factory
  # default_service_account = "disable") -- and cluster creation fails with
  # "Service account ... is disabled".
  node_config {
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  # This environment is disposable by design (destroy/recreate must work
  # unattended); production consumers can flip it on.
  deletion_protection = var.deletion_protection

  # Node auto-provisioning scales workload capacity (arc's Karpenter
  # equivalent); the system pool below carries the platform controllers.
  cluster_autoscaling {
    enabled             = true
    autoscaling_profile = "BALANCED"

    resource_limits {
      resource_type = "cpu"
      minimum       = var.node_auto_provisioning.min_cpu
      maximum       = var.node_auto_provisioning.max_cpu
    }

    resource_limits {
      resource_type = "memory"
      minimum       = var.node_auto_provisioning.min_memory_gib
      maximum       = var.node_auto_provisioning.max_memory_gib
    }

    auto_provisioning_defaults {
      service_account = google_service_account.nodes.email
      oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
      disk_size       = var.node_auto_provisioning.disk_size_gib

      management {
        auto_repair  = true
        auto_upgrade = true
      }

      shielded_instance_config {
        enable_secure_boot          = true
        enable_integrity_monitoring = true
      }

      upgrade_settings {
        max_surge       = 1
        max_unavailable = 0
      }
    }
  }

  logging_config {
    # Workload stderr logs flow to Cloud Logging alongside system components;
    # application telemetry additionally rides OTLP through the otel-collector.
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  # Managed OpenTelemetry (Preview) -- the Google-managed replacement for the
  # self-hosted otel-collector component. Always declared, with an explicit
  # NONE when disabled, so flipping the toggle off after a pilot actually
  # turns the pipeline down instead of orphaning it outside terraform's view.
  managed_opentelemetry_config {
    scope = var.managed_opentelemetry ? "COLLECTION_AND_INSTRUMENTATION_COMPONENTS" : "NONE"
  }

  # Secret Manager -> Kubernetes secret sync (patchy's credentials). Both
  # blocks always declared with an explicit disable, same reasoning as
  # managed_opentelemetry_config: flipping the toggle off actually turns the
  # feature down instead of orphaning it outside terraform's view.
  # secret_sync_config (Integrated Secret Synchronization) rides on the
  # secret_manager_config CSI add-on, so one toggle governs both.
  # Rotation makes `versions/latest` a live pointer: without it a SecretSync
  # resolves the version once at create/spec-change and new Secret Manager
  # versions never reach the cluster. The interval is pinned (provider
  # default is the same 120s) so the refresh cadence survives default drift.
  secret_manager_config {
    enabled = var.secret_sync

    rotation_config {
      enabled           = var.secret_sync
      rotation_interval = "120s"
    }
  }

  secret_sync_config {
    enabled = var.secret_sync

    rotation_config {
      enabled           = var.secret_sync
      rotation_interval = "120s"
    }
  }

  resource_labels = var.labels
}

# The always-on system node pool: flux controllers, kyverno, cert-manager and
# the other platform components pin here via nodeSelector role=system, away
# from auto-provisioned workload capacity.
resource "google_container_node_pool" "system" {
  project  = var.project
  cluster  = google_container_cluster.main.name
  location = var.region
  name     = "system"

  initial_node_count = var.system_node_pool.initial_size

  autoscaling {
    # per-zone counts in a regional pool
    min_node_count = var.system_node_pool.min_size
    max_node_count = var.system_node_pool.max_size
  }

  node_config {
    machine_type    = var.system_node_pool.machine_type
    disk_size_gb    = var.system_node_pool.disk_size_gib
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = local.system_node_selector

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
}
