# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Every surface on: the DNS/TLS wiring (delegated zone lookup, ACME email,
# reserved Gateway address), NAP limits, control-plane access constraints,
# staging sync channel, pre-created workload namespaces and extra cluster
# vars / kustomize patches. This is the shape the real patchy deployment root
# will take.

provider "google" {
  project = var.project
  region  = var.region
}

data "google_client_config" "default" {}

provider "helm" {
  kubernetes = {
    host                   = "https://${module.cluster.endpoint}"
    cluster_ca_certificate = base64decode(module.cluster.ca_certificate)
    token                  = data.google_client_config.default.access_token
  }

  registries = [
    {
      url      = "oci://${split("/", var.platform_registry)[0]}"
      username = "oauth2accesstoken"
      password = data.google_client_config.default.access_token
    }
  ]
}

module "cluster" {
  source = "../.."

  name    = var.name
  project = var.project
  region  = var.region

  network = {
    network             = "projects/${var.host_project_id}/global/networks/${var.network_name}"
    subnetwork          = "projects/${var.host_project_id}/regions/${var.region}/subnetworks/${var.subnetwork_name}"
    pods_range_name     = var.pods_range_name
    services_range_name = var.services_range_name
  }

  platform_registry = var.platform_registry

  signed_identity = {
    manifests_subject  = var.signed_identity_subjects.manifests
    containers_subject = var.signed_identity_subjects.containers
  }

  # The delegated zone is created by cloud-accounts; this only wires it up.
  # Destroy/recreate of the cluster serves the same domain again: the zone,
  # its delegation and the reserved Gateway IP all live outside the cluster.
  dns = {
    zone_name  = var.dns_zone_name
    acme_email = var.acme_email
  }

  # cloud-accounts reserves the `ingress` global address next to the DNS zone
  # (both deliberately outside the disposable cluster's lifecycle); reference
  # it instead of reserving a second one.
  gateway = {
    reserve_static_ip = false
    address_name      = var.gateway_address_name
  }

  master_authorized_networks = var.master_authorized_networks

  system_node_pool = {
    machine_type = "e2-standard-2"
    min_size     = 1
    max_size     = 2
  }

  node_auto_provisioning = {
    max_cpu        = 128
    max_memory_gib = 512
  }

  observability = {
    project = var.observability_project
  }

  flux = {
    sync = {
      # this environment tracks the staging channel; production consumers
      # track stable (the default)
      ref = "staging"
    }

    # patchy's namespaces exist from minute zero so its secrets (GitHub App,
    # webhook secret, Anthropic key) can land before patchy itself deploys.
    namespaces = ["patchy", "patchy-agents"]

    cluster_vars = {
      # pin a component's chart range without a manifests release
      CERT_MANAGER_SEMVER = ">=1.18.0 <2.0.0"
    }

    kustomize_patches = [
      {
        patch = yamlencode([
          {
            op    = "add"
            path  = "/spec/template/spec/tolerations"
            value = [{ key = "platform.bitwisemedia.co.uk/system", operator = "Exists" }]
          }
        ])
        target = {
          kind          = "Deployment"
          labelSelector = "app.kubernetes.io/part-of=flux"
        }
      }
    ]
  }

  labels = {
    env = "x"
    app = "patchy"
  }
}
