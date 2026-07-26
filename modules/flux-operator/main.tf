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
#
# The operator and instance releases are BOOTSTRAP-ONLY (ignore_changes):
# the manifests' flux component adopts both by release name and follows the
# newest mirrored charts from then on, so a flux-containers publish -- never
# a terraform apply -- is what upgrades flux on a running cluster.
# cluster_inputs stays terraform-reconciled: cluster-vars changes flow
# through applies.

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
    },
    # helm-controller appends the OCI artifact digest to the chart version as
    # semver build metadata (0.56.0+<digest12>) for every chartRef
    # OCIRepository, so a moved tag still triggers an upgrade. Once the stack
    # adopts the releases below, that synthetic version is what the helm
    # release storage carries -- and the provider reads it back into state as
    # the version to plan against, then fails to locate a chart tag that was
    # never published (ignore_changes keeps the poisoned value). The gate rides
    # the bootstrap FluxInstance, not just the stack's, so no ungated
    # helm-controller ever adopts these releases. Safe because every chart
    # OCIRepository takes its tag from a semver ResourceSetInputProvider
    # (limit 1): a real upgrade always moves the version itself.
    {
      patch = yamlencode([
        {
          op    = "add"
          path  = "/spec/template/spec/containers/0/args/-"
          value = "--feature-gates=DisableChartDigestTracking=true"
        }
      ])
      target = {
        kind = "Deployment"
        name = "helm-controller"
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
    yamlencode(merge(
      {
        nodeSelector = local.system_node_selector
      },
      # The web server reads its Web Config API document (SSO, base URL)
      # from this Secret and hot-reloads on change, so the Secret may be
      # delivered after bootstrap.
      var.web_config_secret_name == null ? {} : {
        web = { configSecretName = var.web_config_secret_name }
      },
    ))
  ]

  wait    = true
  timeout = 300

  # Bootstrap-only: the stack's flux component adopts this release (same
  # name/namespace) and upgrades it from the mirror; terraform must never
  # fight it back.
  lifecycle {
    ignore_changes = all
  }
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
        distribution = {
          version  = var.distribution.version
          registry = var.distribution.registry
          # Never the chart default (upstream's :latest, an ungated channel
          # that can reference controller images the mirror doesn't carry
          # yet -- a fresh bootstrap would wedge in ImagePullBackOff).
          # Chart version == operator version == manifests tag, so this pin
          # is release-frozen content identical to the manifests embedded in
          # the operator image just installed. Post-adoption, the stack's
          # flux component drops the field entirely (embedded-only).
          artifact = coalesce(
            var.distribution.artifact,
            "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:v${helm_release.flux_operator.metadata.version}",
          )
        }
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

  # Bootstrap-only, as flux_operator above.
  lifecycle {
    ignore_changes = all
  }

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
