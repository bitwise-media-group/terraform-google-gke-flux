# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Forward Security Command Center findings to a patchy deployment.
#
# Apply this after the cluster: the push endpoint has to answer before the
# subscription has anywhere to deliver, and the context-controller's workload
# identity has to exist before it can be granted asset access. Undelivered
# findings are retried and then dead-lettered rather than lost, so applying
# early is untidy rather than dangerous.
#
# Creating an organization-scoped notification config needs
# roles/securitycenter.admin at the organization, which the project's usual
# terraform-apply identity may not hold. Auth otherwise follows the
# cloud-accounts convention: ADC plus impersonation via the
# GOOGLE_IMPERSONATE_SERVICE_ACCOUNT environment variable (dotty injects it) --
# no credentials in the provider block.

provider "google" {
  project = var.project
  region  = var.region
}

# One resource in the module rides the beta provider; it is a lockstep
# superset of google and takes the same configuration.
provider "google-beta" {
  project = var.project
  region  = var.region
}

data "google_project" "this" {}

module "scc_notifications" {
  source = "../../modules/scc-notifications"

  # project is omitted deliberately: the module falls back to the provider's,
  # which is where these resources belong.
  organization_id = var.organization_id

  push = {
    endpoint = "https://${var.patchy_host}/google-cloud/webhooks"
  }

  # patchy's context-controller resolves each finding's repository from the
  # affected resource's ownership labels, which takes read-only Asset
  # Inventory access. Drop this when the grant is owned centrally.
  asset_viewer_members = [
    "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${data.google_project.this.project_id}.svc.id.goog/subject/ns/patchy/sa/patchy-context-controller",
  ]
}
