# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with mocked providers: no credentials, no API
# calls. These assert the cluster shape (shared-VPC wiring, Dataplane V2,
# Workload Identity, Gateway API, NAP) and the terraform -> flux contract
# (workload identity grants, cluster vars).

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }

  mock_data "google_dns_managed_zone" {
    defaults = {
      dns_name     = "patchy.bitwisemedia.co.uk."
      name_servers = ["ns-cloud-a1.googledomains.com."]
    }
  }

  mock_data "google_compute_global_address" {
    defaults = {
      address = "203.0.113.10"
    }
  }
}

mock_provider "google-beta" {}

mock_provider "helm" {}

variables {
  name    = "patchy-x"
  project = "x-patchy-app-ab12"
  region  = "us-central1"

  network = {
    network             = "projects/x-vpc-host-cd34/global/networks/x-vpc-shared"
    subnetwork          = "projects/x-vpc-host-cd34/regions/us-central1/subnetworks/x-patchy-primary-iowa"
    pods_range_name     = "x-patchy-gke-pods-iowa"
    services_range_name = "x-patchy-gke-svc-iowa"
  }

  platform_registry = "us-central1-docker.pkg.dev/x-patchy-app-ab12/platform"

  signed_identity = {
    manifests_subject  = "^https://github\\.com/bitwise-media-group/flux-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    containers_subject = "^https://github\\.com/bitwise-media-group/flux-containers/\\.github/workflows/publish\\.yaml@refs/heads/main$"
  }
}

run "cluster_shape" {
  command = plan

  assert {
    condition     = google_container_cluster.main.datapath_provider == "ADVANCED_DATAPATH"
    error_message = "the cluster must run Dataplane V2 (built-in Cilium)"
  }

  assert {
    condition     = google_container_cluster.main.workload_identity_config[0].workload_pool == "x-patchy-app-ab12.svc.id.goog"
    error_message = "workload identity must be enabled with the project pool"
  }

  assert {
    condition     = google_container_cluster.main.gateway_api_config[0].channel == "CHANNEL_STANDARD"
    error_message = "the GKE Gateway controller must be enabled (patchy webhook HTTPS rides on it)"
  }

  assert {
    condition     = google_container_cluster.main.private_cluster_config[0].enable_private_nodes == true
    error_message = "nodes must be private (egress via Cloud NAT on the shared VPC)"
  }

  assert {
    condition     = google_container_cluster.main.ip_allocation_policy[0].cluster_secondary_range_name == "x-patchy-gke-pods-iowa"
    error_message = "the pods secondary range must be referenced by its cloud-accounts name"
  }

  assert {
    condition     = google_container_cluster.main.ip_allocation_policy[0].services_secondary_range_name == "x-patchy-gke-svc-iowa"
    error_message = "the services secondary range must be referenced by its cloud-accounts name"
  }

  assert {
    condition     = google_container_cluster.main.cluster_autoscaling[0].enabled == true
    error_message = "node auto-provisioning must be enabled (the platform's workload scaling)"
  }

  assert {
    condition     = google_container_node_pool.system.node_config[0].labels["role"] == "system"
    error_message = "the system pool must carry the role=system label platform controllers pin to"
  }

  assert {
    condition     = google_container_cluster.main.deletion_protection == false
    error_message = "the cluster must be disposable by default (destroy/recreate is a design requirement)"
  }

  assert {
    condition     = google_container_cluster.main.managed_opentelemetry_config[0].scope == "NONE"
    error_message = "managed OpenTelemetry must be explicitly NONE by default (the self-hosted otel-collector is the platform OTLP endpoint)"
  }
}

run "managed_opentelemetry_pilot" {
  command = plan

  variables {
    managed_opentelemetry = true
  }

  assert {
    condition     = google_container_cluster.main.managed_opentelemetry_config[0].scope == "COLLECTION_AND_INSTRUMENTATION_COMPONENTS"
    error_message = "the pilot toggle must enable collection and instrumentation components"
  }
}

run "workload_identity_grants" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy-bitwisemedia-co-uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
  }

  assert {
    condition     = google_project_iam_member.workload["external-dns:roles/dns.admin"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/external-dns/sa/external-dns"
    error_message = "external-dns must get dns.admin as a direct federated principal"
  }

  assert {
    condition     = contains(keys(google_project_iam_member.workload), "cert-manager:roles/dns.admin")
    error_message = "cert-manager must get dns.admin for DNS-01 solving"
  }

  assert {
    condition     = contains(keys(google_project_iam_member.workload), "otel-collector:roles/monitoring.metricWriter")
    error_message = "the otel-collector must be able to write metrics"
  }

  assert {
    condition     = contains(keys(google_project_iam_member.workload), "kyverno-kyverno-admission-controller:roles/artifactregistry.reader")
    error_message = "kyverno's admission controller must read the registry to fetch signatures"
  }
}

run "no_dns_no_grants" {
  command = plan

  assert {
    condition     = !contains(keys(google_project_iam_member.workload), "external-dns:roles/dns.admin")
    error_message = "without a zone there must be no dns.admin grants"
  }

  assert {
    condition     = length(data.google_dns_managed_zone.cluster) == 0
    error_message = "without a zone there must be no zone lookup"
  }
}

run "observability_project_override" {
  command = plan

  variables {
    observability = {
      project = "o-o11y-ef56"
    }
  }

  assert {
    condition     = google_project_iam_member.workload["otel-collector:roles/monitoring.metricWriter"].project == "o-o11y-ef56"
    error_message = "otel grants must follow the observability project override"
  }
}

run "gateway_reservation" {
  command = plan

  assert {
    condition     = google_compute_global_address.gateway["this"].name == "patchy-x-gateway"
    error_message = "the gateway address must default to <name>-gateway"
  }
}

run "central_registry" {
  command = plan

  variables {
    platform_registry = "us-central1-docker.pkg.dev/o-foundation-7e43/platform"
  }

  assert {
    condition     = !contains(keys(google_project_iam_member.nodes), "roles/artifactregistry.reader")
    error_message = "a central registry cannot be covered by an in-project node grant (feed reader_members instead)"
  }

  assert {
    condition     = length([for k in keys(google_project_iam_member.workload) : k if startswith(k, "kyverno-")]) == 0
    error_message = "kyverno registry reads on a central registry come from artifact-store reader_members, not in-project grants"
  }

  assert {
    condition     = output.registry_reader_members[1] == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/flux-system/sa/source-controller"
    error_message = "the reader members must be exported"
  }

  assert {
    condition     = google_project_iam_member.registry_readers["principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/flux-system/sa/source-controller"].project == "o-foundation-7e43"
    error_message = "central-registry reader bindings must target the registry's project"
  }

  assert {
    condition     = contains(keys(google_project_iam_member.registry_readers), "serviceAccount:patchy-x-nodes@x-patchy-app-ab12.iam.gserviceaccount.com")
    error_message = "the node service account must be bound on the central registry too"
  }
}

run "local_registry_no_central_grants" {
  command = plan

  assert {
    condition     = length(google_project_iam_member.registry_readers) == 0
    error_message = "a co-located registry is covered by in-project grants; no central bindings"
  }
}

run "gateway_existing_address" {
  command = plan

  variables {
    gateway = {
      reserve_static_ip = false
      address_name      = "ingress"
    }
  }

  assert {
    condition     = length(google_compute_global_address.gateway) == 0
    error_message = "no address may be reserved when referencing an existing one"
  }

  assert {
    condition     = output.gateway.address_name == "ingress"
    error_message = "the existing address name (cloud-accounts' ingress) must flow through to the cluster vars"
  }
}
