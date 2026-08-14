# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Direct Workload Identity Federation grants for the flux-deployed platform
# workloads. The namespace/service-account pairs are the terraform <->
# flux-manifests contract (overridable via var.workload_identity so this repo
# can track a manifests change without a schema change).
#
# flux-system's own grants (source-controller, flux-operator) live in
# modules/flux-operator/iam.tf next to the workloads they serve.

locals {
  # kyverno fetches image signatures from the registry at admission time, so
  # its controllers read the platform repository like the flux controllers do.
  # Grantable here only when the registry is co-located; a central registry
  # covers these principals via artifact-store reader_members (see the
  # registry_reader_members output).
  kyverno_grants = !local.registry_is_local ? {} : {
    for sa in var.workload_identity.kyverno.service_accounts :
    "kyverno-${sa}" => {
      namespace       = var.workload_identity.kyverno.namespace
      service_account = sa
      roles           = ["roles/artifactregistry.reader"]
      project         = var.project
    }
  }

  dns_grants = var.dns.zone_name == null ? {} : {
    external-dns = {
      namespace       = var.workload_identity.external_dns.namespace
      service_account = var.workload_identity.external_dns.service_account
      roles           = ["roles/dns.admin"]
      project         = var.project
    }
    cert-manager = {
      namespace       = var.workload_identity.cert_manager.namespace
      service_account = var.workload_identity.cert_manager.service_account
      roles           = ["roles/dns.admin"]
      project         = var.project
    }
  }

  otel_grants = {
    otel-collector = {
      namespace       = var.workload_identity.otel_collector.namespace
      service_account = var.workload_identity.otel_collector.service_account
      roles = [
        "roles/monitoring.metricWriter",
        "roles/logging.logWriter",
        "roles/cloudtrace.agent",
      ]
      # Telemetry may target a central observability project later; defaults to
      # the cluster's own project.
      project = coalesce(var.observability.project, var.project)
    }
  }

  # The patchy egress-broker terminates all claude-runner model traffic; on
  # the vertex provider it calls the Vertex AI API itself, so its KSA gets
  # aiplatform.user in the serving project (the configured vertex project, or
  # the cluster's own) as a direct federated principal. The anthropic provider
  # authenticates with an API key/token instead — no grant.
  patchy_grants = var.patchy.claude.provider.name != "vertex" ? {} : {
    patchy-egress-broker = {
      namespace       = var.workload_identity.patchy_egress_broker.namespace
      service_account = var.workload_identity.patchy_egress_broker.service_account
      roles           = ["roles/aiplatform.user"]
      project         = coalesce(var.patchy.claude.provider.vertex_project_id, var.project)
    }
  }

  workload_grants = merge(local.kyverno_grants, local.dns_grants, local.otel_grants, local.patchy_grants)

  workload_role_grants = merge([
    for name, grant in local.workload_grants : {
      for role in grant.roles :
      "${name}:${role}" => {
        project = grant.project
        role    = role
        member  = "${local.wi_principal_prefix}/ns/${grant.namespace}/sa/${grant.service_account}"
      }
    }
  ]...)
}

resource "google_project_iam_member" "workload" {
  for_each = local.workload_role_grants

  project = each.value.project
  role    = each.value.role
  member  = each.value.member

  # The implicit workload identity pool (<project>.svc.id.goog) only exists
  # once the project's first Workload Identity cluster does, and IAM rejects
  # members of nonexistent pools -- the member strings are composed from
  # plan-known inputs, so the ordering must be explicit (same reasoning as
  # registry_readers below).
  depends_on = [google_container_cluster.main]
}

# kyverno's image policy verifies signatures at admission/report time: always
# a registry reader (above), and in KMS signing mode also allowed to resolve
# the signing key — cosign's gcpkms://<name> path lists the key's versions,
# fetches the public key and may verify remotely, so each controller gets
# verifier + viewer on the key itself. Key-scoped, so the grant works wherever
# the key lives; a key outside this project needs the apply identity delegated
# setIamPolicy on it there (same delegation shape as the central-registry
# reader grants below).
resource "google_kms_crypto_key_iam_member" "kyverno_verifiers" {
  for_each = {
    for pair in setproduct(
      local.signing_kms ? var.workload_identity.kyverno.service_accounts : [],
      ["verifier", "viewer"],
    ) : "${pair[0]}:${pair[1]}" => pair
  }

  crypto_key_id = var.signed_identity.kms_key_name
  role          = "roles/cloudkms.${each.value[1]}"
  member        = "${local.wi_principal_prefix}/ns/${var.workload_identity.kyverno.namespace}/sa/${each.value[0]}"

  # the implicit workload identity pool must exist before IAM accepts its
  # principals as members (same reasoning as the workload grants above)
  depends_on = [google_container_cluster.main]
}

locals {
  # Every identity that must read the platform registry, composed statically
  # (the node SA email format is fixed) so the strings work as plan-time
  # for_each keys. When the registry is co-located these are covered by the
  # in-project grants above / in the flux-operator module; when it is central
  # (e.g. o-foundation) the registry_readers resource below binds them there.
  registry_reader_members = concat(
    ["serviceAccount:${var.name}-nodes@${var.project}.iam.gserviceaccount.com"],
    [
      for sa in ["source-controller", "flux-operator"] :
      "${local.wi_principal_prefix}/ns/flux-system/sa/${sa}"
    ],
    [
      for sa in var.workload_identity.kyverno.service_accounts :
      "${local.wi_principal_prefix}/ns/${var.workload_identity.kyverno.namespace}/sa/${sa}"
    ],
  )
}

# Registry reads for a CENTRAL registry (one living in another project). Two
# facts force the grant to happen here, after cluster creation, rather than
# centrally at project birth:
#
#   - the project's implicit workload identity pool (<project>.svc.id.goog)
#     only exists once its first Workload Identity cluster does, and IAM
#     rejects members of nonexistent pools
#   - the identities are only deterministic from this module's inputs
#
# The apply identity therefore needs a modifiedGrantsByRole-conditioned
# projectIamAdmin on the registry project admitting exactly
# artifactregistry.reader (cloud-accounts grants this to the org's service
# accounts as the registry-reader delegation).
resource "google_project_iam_member" "registry_readers" {
  for_each = toset(local.registry_is_local ? [] : local.registry_reader_members)

  project = local.registry_project
  role    = "roles/artifactregistry.reader"
  member  = each.value

  # the pool (WI principals) and the node SA must exist before IAM will
  # accept them as members
  depends_on = [
    google_container_cluster.main,
    google_service_account.nodes,
  ]
}
