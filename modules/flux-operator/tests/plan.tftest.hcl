# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time tests for the bootstrap chain: the FluxInstance values (gcp
# cluster type, gcp sync provider, the keyless verify patch) and the
# cluster-inputs contract are all plan-known helm values, so the whole
# terraform -> flux contract is assertable without a cluster.

mock_provider "google" {}
mock_provider "helm" {
  # The instance values interpolate the operator release's plan-computed
  # metadata (the bootstrap artifact pin tracks the installed chart
  # version), so the mock must resolve it at plan time for the values to be
  # assertable.
  mock_resource "helm_release" {
    override_during = plan
    defaults = {
      metadata = {
        version = "0.55.0"
      }
    }
  }
}

variables {
  project        = "x-patchy-app-ab12"
  project_number = "123456789012"

  operator_chart = {
    repository = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/charts"
  }
  instance_chart = {
    repository = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/charts"
  }
  distribution = {
    version  = "2.x"
    registry = "us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/images/ghcr.io/fluxcd"
  }
  sync = {
    url  = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/platform"
    ref  = "stable"
    path = "google"
  }
  signed_identity = {
    issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
    manifests_subject = "^https://github\\.com/bitwise-media-group/flux-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
  }
  cluster_vars = {
    CLUSTER_NAME      = "patchy-x"
    PLATFORM_REGISTRY = "us-central1-docker.pkg.dev/x-patchy-app-ab12/platform"
  }
  namespaces = ["demo", "demo-agents"]
}

run "flux_instance_contract" {
  command = plan

  assert {
    condition     = yamldecode(helm_release.flux_instance.values[0]).instance.cluster.type == "gcp"
    error_message = "the FluxInstance must declare a gcp cluster"
  }

  assert {
    condition     = yamldecode(helm_release.flux_instance.values[0]).instance.sync.provider == "gcp"
    error_message = "the sync OCIRepository must authenticate to Artifact Registry via the gcp provider"
  }

  assert {
    condition     = yamldecode(helm_release.flux_instance.values[0]).instance.sync.ref == "stable"
    error_message = "the sync ref must pass through"
  }

  assert {
    condition     = yamldecode(helm_release.flux_instance.values[0]).instance.distribution.artifact == "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:v0.55.0"
    error_message = "the bootstrap artifact must be pinned to the release tag matching the installed operator chart, never the chart's :latest default"
  }

  # The verify patch is the load-bearing keyless change: find the patch
  # targeting the flux-system OCIRepository and check its matchOIDCIdentity.
  assert {
    condition = anytrue([
      for p in yamldecode(helm_release.flux_instance.values[0]).instance.kustomize.patches :
      try(p.target.kind, "") == "OCIRepository"
      && try(yamldecode(p.patch)[0].value.matchOIDCIdentity[0].subject, "") == var.signed_identity.manifests_subject
    ])
    error_message = "the generated flux-system OCIRepository must verify the manifests artifact against the publish workflow identity"
  }

  assert {
    condition = anytrue([
      for p in yamldecode(helm_release.flux_instance.values[0]).instance.kustomize.patches :
      try(p.target.labelSelector, "") == "app.kubernetes.io/part-of=flux"
    ])
    error_message = "the flux controllers must be pinned to the system node pool via the controller patch"
  }
}

run "keyed_verification" {
  command = plan

  variables {
    signed_identity = {
      kms_public_key_pem = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----\n"
    }
  }

  assert {
    condition     = yamldecode(local.sync_verify_patches[0].patch)[0].value.secretRef.name == "cosign-pub"
    error_message = "keyed mode must verify against the cosign-pub public-key Secret — source-controller never calls KMS"
  }

  assert {
    condition     = !can(yamldecode(local.sync_verify_patches[0].patch)[0].value.matchOIDCIdentity)
    error_message = "keyed mode must not also carry a keyless identity match"
  }

  assert {
    condition     = strcontains(helm_release.cluster_inputs.values[0], "cosignPublicKey")
    error_message = "the cluster-inputs chart must receive the public key to render the cosign-pub Secret"
  }
}

run "cluster_inputs_contract" {
  command = plan

  assert {
    condition     = yamldecode(helm_release.cluster_inputs.values[0]).clusterVars.CLUSTER_NAME == "patchy-x"
    error_message = "cluster vars must flow into the cluster-inputs chart"
  }

  assert {
    condition     = contains(yamldecode(helm_release.cluster_inputs.values[0]).namespaces, "demo-agents")
    error_message = "pre-created namespaces must flow into the cluster-inputs chart"
  }
}

run "registry_read_grants" {
  command = plan

  assert {
    condition     = google_project_iam_member.registry_read["source-controller"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/flux-system/sa/source-controller"
    error_message = "source-controller must read the registry as a direct federated principal"
  }

  assert {
    condition     = contains(keys(google_project_iam_member.registry_read), "flux-operator")
    error_message = "flux-operator must read the registry (GARArtifactTag tag listings)"
  }
}

run "no_applications_by_default" {
  command = plan

  assert {
    condition     = length(helm_release.application) == 0 && length(output.applications) == 0
    error_message = "a cluster with no applications must seed nothing - the platform alone is a complete deployment"
  }

  assert {
    condition     = !strcontains(helm_release.cluster_inputs.values[0], "-vars")
    error_message = "without application_vars no <key>-vars ConfigMap may be rendered"
  }
}

run "application_seeds" {
  command = plan

  variables {
    applications = {
      demo = {
        url        = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/demo"
        platform   = true
        semver     = "<1.0.0 >=0.1.0"
        path       = "./deploy/google"
        interval   = "30m"
        depends_on = ["kyverno-policies", "gateway"]
        verify = {
          keyed   = false
          issuer  = "^https://token\\.actions\\.githubusercontent\\.com$"
          subject = "^https://github\\.com/org/demo/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
        }
        prune   = true
        wait    = true
        timeout = "10m"
      }
      external = {
        url         = "oci://ghcr.io/org/external-manifests"
        platform    = false
        semver      = ">=0.0.0"
        path        = "./deploy/google"
        interval    = "1h"
        depends_on  = ["kyverno-policies"]
        verify      = { keyed = false, issuer = "^https://token\\.actions\\.githubusercontent\\.com$", subject = "^https://github\\.com/org/external/.+$" }
        pull_secret = "ghcr-pull"
        prune       = true
        wait        = false
        timeout     = "5m"
      }
    }
    application_vars = {
      demo = { DEMO_DOMAIN = "demo.example.com" }
    }
  }

  # One bootstrap-only release per application, from the shared seed chart
  # in modules/application, named so the release list reads as the
  # application inventory.
  assert {
    condition     = helm_release.application["demo"].name == "application-demo" && helm_release.application["demo"].chart == "${path.module}/../application/charts/application"
    error_message = "each application must be one release of the shared application chart, named application-<key>"
  }

  assert {
    condition     = helm_release.application["demo"].namespace == "flux-system"
    error_message = "the seed objects live in flux-system, where the image's own flux/ copy expects to adopt them"
  }

  # The registry, never the cloud, picks the listing and pull dialect: the
  # platform prefix is reached with the controllers' Workload Identity
  # through the Artifact Registry API; anywhere else is a generic OCI
  # listing and pull.
  assert {
    condition     = output.applications["demo"].tag_provider == "GARArtifactTag" && output.applications["demo"].oci_provider == "gcp"
    error_message = "an image under the platform registry must be listed with GARArtifactTag and pulled as provider gcp"
  }

  assert {
    condition     = output.applications["external"].tag_provider == "OCIArtifactTag" && output.applications["external"].oci_provider == "generic"
    error_message = "an image outside the platform registry must be listed with OCIArtifactTag and pulled as provider generic"
  }

  assert {
    condition     = yamldecode(helm_release.application["demo"].values[0]).tagProvider == "GARArtifactTag" && yamldecode(helm_release.application["demo"].values[0]).ociProvider == "gcp"
    error_message = "the providers must reach the chart"
  }

  assert {
    condition     = yamldecode(helm_release.application["external"].values[0]).pullSecret == "ghcr-pull" && yamldecode(helm_release.application["demo"].values[0]).pullSecret == ""
    error_message = "the pull secret must reach the chart for the external image only"
  }

  assert {
    condition     = yamldecode(helm_release.application["demo"].values[0]).verify.subject == var.applications["demo"].verify.subject
    error_message = "the keyless subject must reach the chart verbatim (a Go regexp full of backslashes)"
  }

  assert {
    condition     = join(",", yamldecode(helm_release.application["demo"].values[0]).dependsOn) == "gateway,kyverno-policies"
    error_message = "dependsOn must reach the chart as a sorted list"
  }

  assert {
    condition     = yamldecode(helm_release.cluster_inputs.values[0]).applicationVars.demo.DEMO_DOMAIN == "demo.example.com"
    error_message = "application_vars must reach the cluster-inputs chart, which renders the <key>-vars ConfigMaps"
  }
}

run "keyed_application_verification" {
  command = plan

  variables {
    signed_identity = {
      kms_public_key_pem = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----\n"
    }
    applications = {
      demo = {
        url        = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/demo"
        platform   = true
        semver     = ">=0.0.0"
        path       = "./deploy/google"
        interval   = "30m"
        depends_on = ["kyverno-policies"]
        verify     = { keyed = true }
        prune      = true
        wait       = true
        timeout    = "5m"
      }
    }
  }

  assert {
    condition     = yamldecode(helm_release.application["demo"].values[0]).verify.keyed == true && yamldecode(helm_release.application["demo"].values[0]).verify.subject == ""
    error_message = "keyed mode must hand the chart the keyed flag and no keyless identity - the chart then verifies against the cosign-pub Secret"
  }
}

run "keyed_application_requires_keyed_mode" {
  command = plan

  variables {
    applications = {
      demo = {
        url        = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/demo"
        platform   = true
        semver     = ">=0.0.0"
        path       = "./deploy/google"
        interval   = "30m"
        depends_on = ["kyverno-policies"]
        verify     = { keyed = true }
        prune      = true
        wait       = true
        timeout    = "5m"
      }
    }
  }

  expect_failures = [var.applications]
}
