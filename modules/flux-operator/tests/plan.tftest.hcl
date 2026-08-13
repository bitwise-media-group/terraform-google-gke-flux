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
    url  = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/flux-manifests"
    ref  = "stable"
    path = "stack"
  }
  signed_identity = {
    issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
    manifests_subject = "^https://github\\.com/bitwise-media-group/flux-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
  }
  cluster_vars = {
    CLUSTER_NAME      = "patchy-x"
    PLATFORM_REGISTRY = "us-central1-docker.pkg.dev/x-patchy-app-ab12/platform"
  }
  namespaces = ["patchy", "patchy-agents"]
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
    condition     = contains(yamldecode(helm_release.cluster_inputs.values[0]).namespaces, "patchy-agents")
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
