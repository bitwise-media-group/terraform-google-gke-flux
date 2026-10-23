# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "secrets" {
  description = <<-EOT
    The created containers, keyed by unprefixed container name: the full resource id, the (prefixed) secret_id for
    wiring further IAM in the caller (e.g. a maintainer's secretVersionAdder rotation grant), and the sync principal
    granted accessor. Every container's versions are added out of band: gcloud secrets versions add <secret_id>
    --data-file=-.
  EOT
  value = {
    for name, subject in local.containers : name => {
      id        = google_secret_manager_secret.main[name].id
      secret_id = google_secret_manager_secret.main[name].secret_id
      member    = "${local.wi_prefix}/${subject}"
    }
  }
}
