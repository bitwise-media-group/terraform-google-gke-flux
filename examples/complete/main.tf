# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Every surface on: the DNS/TLS wiring (delegated zone lookup, ACME email,
# reserved Gateway address), NAP limits, control-plane access constraints,
# SSO with kubectl through dex (workforce identity), the staging sync
# channel, the electable platform components, extra cluster vars / kustomize
# patches and one seeded application (patchy) composed the way a real root
# composes it - the application's own module emits the maps, the cluster
# module consumes them, and nothing application-specific lives in the
# cluster module.

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

# The application, composed beside the cluster. A real root sources this
# from the application's own repository (patchy-app-manifests//modules/google),
# which emits exactly these maps from static root inputs - never from cluster
# outputs, so there is no cycle - and creates patchy's own Secret Manager
# containers with their accessor grants (resource-side, so the cluster
# module grants no secret reads):
#
#   module "patchy" {
#     source = "git::https://github.com/bitwise-media-group/patchy-app-manifests.git//modules/google?ref=v0.1.0"
#
#     project                 = var.project
#     platform_registry       = var.platform_registry
#     secret_prefix           = var.secret_prefix
#     domain                  = var.patchy_domain
#     harnesses               = ["claude"]
#     claude                  = { provider = "anthropic" }
#     sso_enabled             = var.sso.enabled
#     signed_identity_subject = "^https://github\\.com/bitwise-media-group/patchy-app-manifests/..."
#   }
#
# Until that module is published, the same maps are spelled out literally
# here so the example plans on its own; the values are what the module's
# outputs carry.
locals {
  patchy = {
    namespaces = ["patchy", "patchy-agents"]

    # patchy's egress-broker only needs a cloud grant on the vertex provider
    # (roles/aiplatform.user); on anthropic (this example) it carries none.
    # The shape, for a vertex deployment:
    #
    #   patchy-egress-broker = {
    #     namespace       = "patchy"
    #     service_account = "patchy-egress-broker"
    #     roles           = ["roles/aiplatform.user"]
    #   }
    workload_grants = {}

    application = {
      url        = "oci://${var.platform_registry}/manifests/patchy"
      semver     = "<1.0.0 >=0.1.0"
      timeout    = "10m"
      depends_on = concat(["kyverno-policies", "gateway"], var.sso.enabled ? ["dex"] : [])
      verify = {
        subject = "^https://github\\.com/bitwise-media-group/patchy-app-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
      }
    }

    vars = {
      AGENT_HARNESSES                  = "claude"
      AGENT_EGRESS_POLICY              = "cilium"
      PATCHY_EVALUATION                = "false"
      PATCHY_DOMAIN                    = var.patchy_domain
      CLAUDE_PROVIDER                  = "anthropic"
      CLAUDE_ANTHROPIC_AUTH            = "token"
      CLAUDE_VERTEX_REGION             = ""
      CLAUDE_VERTEX_PROJECT_ID         = ""
      CLAUDE_MODEL_MAP                 = ""
      PATCHY_MANIFESTS_SEMVER          = "<1.0.0 >=0.1.0"
      SIGNED_IDENTITY_PATCHY_MANIFESTS = "^https://github\\.com/bitwise-media-group/patchy-app-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    }
  }
}

module "cluster" {
  source = "../.."

  name    = var.name
  project = var.project

  # A region here builds a regional cluster; pass a zone (e.g. us-central1-a)
  # for a zonal one instead.
  location = var.region

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

  # RBAC subjects: Google Groups (the gke-security-groups@<domain> group and
  # the member groups are managed out-of-band in Workspace; this only points
  # the cluster authenticator at it) or, with sso.kubectl, workforce
  # principalSets binding dex groups directly
  # (module.cluster.kubectl_oidc.group_principal_prefix + "<dex group>").
  rbac = var.rbac

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

  # Per-cluster reusability knobs: distinct Secret Manager containers when
  # clusters share a project, the electable-tier component election, and the
  # SSO toggle that deploys dex and wires every relying party to it --
  # including kubectl, through a workforce pool trusting dex.
  secret_prefix       = var.secret_prefix
  platform_components = var.platform_components
  sso                 = var.sso

  # The application, wired from its module's outputs: its IAM grants, the
  # seed that installs it and its own vars.
  workload_grants = local.patchy.workload_grants
  applications = {
    patchy = local.patchy.application
  }
  application_vars = {
    patchy = local.patchy.vars
  }

  flux = {
    sync = {
      # this environment tracks the staging channel; production consumers
      # track stable (the default)
      ref = "staging"
    }

    # the application's namespaces exist from minute zero so its secrets
    # (GitHub App, webhook secret, Anthropic token) can land before it deploys
    namespaces = local.patchy.namespaces

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
