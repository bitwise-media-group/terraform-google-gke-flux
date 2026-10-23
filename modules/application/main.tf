# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# One application, published to an existing cluster's Flux instance from a
# root of its own - everything the cluster root would otherwise do for it:
#
#   1. inputs            the <name>-vars ConfigMap and pre-created namespaces
#                        (local chart charts/inputs), terraform-reconciled
#   2. seed              the ResourceSetInputProvider + ResourceSet that
#                        resolve, verify and apply the image (local chart
#                        charts/application, shared with the cluster root's
#                        own applications), bootstrap-only
#   3. workload grants   project IAM members for direct Workload Identity
#                        Federation principals (iam.tf)
#
# Every name matches what the cluster root mints for an application it seeds
# itself (release application-<name>, ConfigMap <name>-vars), so the
# manifests can't tell the two apart. The same names make a helm collision
# loud rather than silent: helm refuses a release or object another release
# owns. The IAM members do not collide loudly -- see iam.tf. An application
# lives in the cluster root or in its own root, never both.
#
# Dex clients are not here: the application ships DexClient objects in its own
# image, and the platform's dex-client-controller registers them. Nor are
# Secret Manager reads: whoever creates a container grants its sync KSA
# accessor on it, resource-side (the workload_members output names the
# principals).

locals {
  # Under the platform prefix the flux controllers reach the image with their
  # Workload Identity: tags are listed through the Artifact Registry API and
  # the OCIRepository authenticates as provider gcp. Anywhere else the
  # generic listing and pull apply, with an optional pull secret. Keyed on
  # the registry, never the cloud.
  platform = startswith(var.image.url, "oci://${var.cluster.platform_registry}/")

  tag_provider = local.platform ? "GARArtifactTag" : "OCIArtifactTag"
  oci_provider = local.platform ? "gcp" : "generic"

  # The same per-cloud tree selector the platform itself syncs.
  path = coalesce(var.image.path, "./deploy/${var.cluster.tree}")

  # Keyless images default onto the cluster's own issuer (the variable
  # validations guarantee there is one whenever this is reached).
  verify = {
    keyed   = var.image.verify.keyed
    issuer  = var.image.verify.keyed ? "" : coalesce(var.image.verify.issuer, var.cluster.issuer)
    subject = var.image.verify.keyed ? "" : var.image.verify.subject
  }
}

# The terraform-reconciled half: vars and namespaces change through this
# root's applies. Absent when the application has neither.
resource "helm_release" "inputs" {
  for_each = toset(length(var.vars) > 0 || length(var.namespaces) > 0 ? ["true"] : [])

  name      = "application-${var.name}-inputs"
  namespace = var.cluster.namespace

  chart = "${path.module}/charts/inputs"

  values = [
    yamlencode({
      name       = var.name
      vars       = var.vars
      namespaces = sort(tolist(var.namespaces))
    })
  ]

  wait    = true
  timeout = 120
}

# The seed. The image carries the same two objects and takes them over on its
# first reconcile, so from then on the application owns itself. No
# helm.sh/resource-policy: keep -- uninstalling the release IS the removal path
# (the ResourceSet's finalizer garbage-collects the Kustomization, whose own
# finalizer prunes the application).
resource "helm_release" "seed" {
  name      = "application-${var.name}"
  namespace = var.cluster.namespace

  chart = "${path.module}/charts/application"

  values = [
    yamlencode({
      name        = var.name
      url         = var.image.url
      semver      = var.image.semver
      path        = local.path
      interval    = var.image.interval
      tagProvider = local.tag_provider
      ociProvider = local.oci_provider
      pullSecret  = var.image.pull_secret != null ? var.image.pull_secret : ""
      timeout     = var.image.timeout
      prune       = var.image.prune
      wait        = var.image.wait
      dependsOn   = sort(tolist(var.image.depends_on))
      verify      = local.verify
    })
  ]

  wait    = true
  timeout = 120

  # Bootstrap-only: the image's own copy of these objects wins every field from
  # the first reconcile on, and a terraform re-apply would fight it back. Never
  # lift this.
  lifecycle {
    ignore_changes = all
  }

  # The <name>-vars ConfigMap (and the namespaces) must be in place for the
  # Kustomization's first substitution.
  depends_on = [helm_release.inputs]
}
