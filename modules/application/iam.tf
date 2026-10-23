# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The application's cloud permissions, minted exactly as the cluster root
# mints its own workload grants (iam.tf there): direct Workload Identity
# Federation -- no GSA, no iam.gke.io/gcp-service-account annotation, no key
# material -- so each (grant, role) pair is one project IAM member for
# principal://.../subject/ns/<namespace>/sa/<service_account>.
#
# An IAM member binding is shared, not owned: two roots declaring the same
# (member, role) pair both "own" it, nothing fails, and destroying either one
# removes it for both. That is the one collision this module cannot make
# loud (the helm releases in main.tf collide loudly), and the reason an
# application lives in the cluster root or in its own root, never both.

locals {
  wi_prefix = "principal://iam.googleapis.com/projects/${var.cluster.project_number}/locations/global/workloadIdentityPools/${var.cluster.workload_pool}/subject"

  workload_members = {
    for key, grant in var.workload_grants : key => "${local.wi_prefix}/ns/${grant.namespace}/sa/${grant.service_account}"
  }

  workload_role_grants = merge([
    for key, grant in var.workload_grants : {
      for role in grant.roles :
      "${key}:${role}" => {
        project = coalesce(grant.project, var.cluster.project)
        role    = role
        member  = local.workload_members[key]
      }
    }
  ]...)
}

resource "google_project_iam_member" "workload" {
  for_each = local.workload_role_grants

  project = each.value.project
  role    = each.value.role
  member  = each.value.member
}
