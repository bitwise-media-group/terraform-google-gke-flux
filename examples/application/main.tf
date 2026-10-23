# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# An application published to an existing cluster from a root of its own -
# another state, another repository, another team. Nothing here touches the
# cluster root: the seed, the application's vars, its namespaces and its
# cloud permissions are all this root's, keyed to the cluster through the
# cluster root's application_target output.
#
# That output arrives here as a plain variable so the example plans on its
# own. A real root usually reads it from the cluster's state instead:
#
#   data "terraform_remote_state" "cluster" {
#     backend = "gcs"
#     config  = { bucket = "...", prefix = "clusters/patchy-x" }
#   }
#
#   cluster = data.terraform_remote_state.cluster.outputs.application_target
#
# Its dex client, if it has one, is not here either: the application ships a
# DexClient in its own image, and the platform's dex-client-controller
# registers it. Its Secret Manager containers, if any, are created in this
# root with an accessor grant for their sync KSA (see the secret below) --
# the cluster module grants no secret reads.

provider "google" {
  project = var.cluster.project
  region  = var.region
}

data "google_client_config" "default" {}

data "google_container_cluster" "target" {
  project  = var.cluster.project
  location = var.location
  name     = var.cluster.name
}

# The same token auth as examples/minimal. Both charts are local to the
# module, so no registry credentials are needed.
provider "helm" {
  kubernetes = {
    host                   = "https://${data.google_container_cluster.target.endpoint}"
    cluster_ca_certificate = base64decode(data.google_container_cluster.target.master_auth[0].cluster_ca_certificate)
    token                  = data.google_client_config.default.access_token
  }
}

module "demo" {
  source = "../../modules/application"

  name    = "demo"
  cluster = var.cluster

  image = {
    url    = "oci://${var.cluster.platform_registry}/manifests/demo"
    semver = "<1.0.0 >=0.1.0"
    verify = {
      subject = "^https://github\\.com/example-org/demo-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    }
  }

  # The <name>-vars ConfigMap the image's Kustomization substitutes from.
  vars = {
    DEMO_DOMAIN = var.domain
  }

  namespaces = ["demo"]

  # The demo's API server calls Vertex AI as a direct federated principal.
  workload_grants = {
    demo-api = {
      namespace       = "demo"
      service_account = "demo-api"
      roles           = ["roles/aiplatform.user"]
    }
  }
}

# An application-owned secret: created here, under the cluster's prefix, and
# readable by the KSA the application's SecretSync runs as -- resource-side,
# so nothing about it lives in the cluster root. The version is added out of
# band (gcloud secrets versions add).
resource "google_secret_manager_secret" "demo_api_key" {
  project   = var.cluster.project
  secret_id = "${var.cluster.secret_prefix}demo-api-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "demo_api_key" {
  project   = var.cluster.project
  secret_id = google_secret_manager_secret.demo_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "principal://iam.googleapis.com/projects/${var.cluster.project_number}/locations/global/workloadIdentityPools/${var.cluster.workload_pool}/subject/ns/demo/sa/demo-secrets"
}
