# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The smallest useful cluster: shared-VPC wiring + the platform registry and
# signing identities. No DNS/TLS surface (add dns = { zone_name = ... } for
# that — see examples/complete). This provider wiring is what a consuming
# root module (e.g. the patchy repo's deployment) should copy.

provider "google" {
  project = var.project
  region  = var.region
}

data "google_client_config" "default" {}

# helm bootstraps flux against the new cluster's endpoint, and must pull
# oci:// charts from Artifact Registry during that bootstrap — hence the
# registries login with the caller's own access token.
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

  # A region here builds a regional cluster; pass a zone (e.g. us-central1-a)
  # for a zonal one instead.
  location = var.region

  # Names from cloud-accounts (environments/google/patchy → modules/app-env):
  # the subnet lives in the HOST project; secondary ranges are referenced by
  # name.
  network = {
    network             = "projects/${var.host_project_id}/global/networks/${var.network_name}"
    subnetwork          = "projects/${var.host_project_id}/regions/${var.region}/subnetworks/${var.subnetwork_name}"
    pods_range_name     = var.pods_range_name
    services_range_name = var.services_range_name
  }

  platform_registry = var.platform_registry

  # From the artifact-store module's signed_identity_subjects output.
  signed_identity = {
    manifests_subject  = var.signed_identity_subjects.manifests
    containers_subject = var.signed_identity_subjects.containers
  }
}
