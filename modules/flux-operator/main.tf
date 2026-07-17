# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The flux bootstrap chain: three helm releases, so a single terraform apply
# takes an empty cluster to a reconciling GitOps platform without any
# kubernetes_manifest plan-time CRD problems —
#
#   1. flux-operator     the operator + its CRDs (FluxInstance, ResourceSet, ...)
#   2. cluster-inputs    the terraform -> flux-manifests contract (local chart):
#                        the cluster-vars ConfigMap and pre-created namespaces
#   3. flux-instance     renders the FluxInstance CR; the operator materialises
#                        the Flux controllers and the sync OCIRepository from it
#
# Everything is pulled from the platform registry (charts/flux-operator,
# charts/flux-instance, mirrored fluxcd controller images), so the artifact
# store must be populated by flux-containers before the first bootstrap.

locals {
  # Platform controllers run on the always-on system node pool, never on
  # auto-provisioned workload capacity. The operator is pinned via chart
  # values; the Flux controllers via a kustomize patch on the generated
  # flux-system Deployments.
  system_node_selector = { role = "system" }

  controller_patches = [
    {
      patch = yamlencode([
        {
          op    = "add"
          path  = "/spec/template/spec/nodeSelector"
          value = local.system_node_selector
        }
      ])
      target = {
        kind          = "Deployment"
        labelSelector = "app.kubernetes.io/part-of=flux"
      }
    }
  ]

  # FluxInstance spec.sync has no verify field, so signature enforcement on
  # the manifests artifact rides in as a patch on the generated OCIRepository
  # (named after the namespace, matching flux bootstrap). Verification is
  # cosign KEYLESS: the artifact must carry a Fulcio certificate whose
  # issuer/subject match the flux-manifests publish workflow — no key
  # material is distributed anywhere.
  sync_verify_patches = [
    {
      patch = yamlencode([
        {
          op   = "add"
          path = "/spec/verify"
          value = {
            provider = "cosign"
            matchOIDCIdentity = [
              {
                issuer  = var.signed_identity.issuer
                subject = var.signed_identity.manifests_subject
              }
            ]
          }
        }
      ])
      target = {
        kind = "OCIRepository"
        name = var.namespace
      }
    }
  ]
}

resource "helm_release" "flux_operator" {
  name             = "flux-operator"
  namespace        = var.namespace
  create_namespace = true

  repository = var.operator_chart.repository
  chart      = "flux-operator"
  version    = var.operator_chart.version

  values = [
    yamlencode({
      nodeSelector = local.system_node_selector
    })
  ]

  wait    = true
  timeout = 300
}

resource "helm_release" "flux_instance" {
  name      = "flux"
  namespace = var.namespace

  repository = var.instance_chart.repository
  chart      = "flux-instance"
  version    = var.instance_chart.version

  values = [
    yamlencode({
      instance = {
        distribution = merge(
          {
            version  = var.distribution.version
            registry = var.distribution.registry
          },
          var.distribution.artifact != null ? { artifact = var.distribution.artifact } : {},
        )
        cluster = {
          type          = "gcp"
          networkPolicy = true
        }
        sync = {
          kind     = "OCIRepository"
          provider = "gcp" # Artifact Registry auth via Workload Identity (iam.tf)
          url      = var.sync.url
          ref      = var.sync.ref
          path     = var.sync.path
          interval = var.sync.interval
        }
        kustomize = {
          patches = concat(local.controller_patches, local.sync_verify_patches, var.kustomize_patches)
        }
      }
    })
  ]

  wait    = true
  timeout = 300

  # cluster_inputs delivers the cluster-vars ConfigMap the stack substitutes
  # from; installing it first means the first reconcile can succeed immediately.
  depends_on = [helm_release.flux_operator, helm_release.cluster_inputs]
}

resource "helm_release" "cluster_inputs" {
  name      = "cluster-inputs"
  namespace = var.namespace

  chart = "${path.module}/charts/cluster-inputs"

  values = [
    yamlencode({
      clusterVars = var.cluster_vars
      namespaces  = var.namespaces
    })
  ]

  wait    = true
  timeout = 120

  depends_on = [helm_release.flux_operator]
}
