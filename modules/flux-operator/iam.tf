# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Registry read for the flux controllers, as direct Workload Identity
# Federation grants (no GSA, no KSA annotation):
#
#   - source-controller pulls the sync artifact and every chart OCIRepository
#     (spec.provider: gcp resolves credentials from the GKE metadata server)
#   - flux-operator lists chart tags for GARArtifactTag
#     ResourceSetInputProviders, so it needs the same read access

# Grantable here only when the registry lives in the cluster's project (the
# apply identity has no IAM rights elsewhere); a central registry covers these
# principals via the artifact-store module's reader_members.
resource "google_project_iam_member" "registry_read" {
  for_each = toset(var.grant_registry_read ? ["source-controller", "flux-operator"] : [])

  project = var.project
  role    = "roles/artifactregistry.reader"
  member  = "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.project}.svc.id.goog/subject/ns/${var.namespace}/sa/${each.value}"
}
