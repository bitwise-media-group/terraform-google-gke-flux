# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The delegated Cloud DNS zone (e.g. patchy.bitwisemedia.co.uk) is created by
# cloud-accounts and delegated from the parent domain once — it deliberately
# lives upstream of this module so cluster destroy/recreate never touches the
# zone or its NS delegation. This module only looks it up: validating it
# exists, deriving the domain for the Gateway/certificate wiring, and passing
# the name through to external-dns via cluster vars.

data "google_dns_managed_zone" "cluster" {
  for_each = toset(var.dns.zone_name != null ? ["this"] : [])

  project = var.project
  name    = var.dns.zone_name
}

locals {
  # Zone apex without the trailing dot (patchy.bitwisemedia.co.uk.).
  dns_domain = var.dns.zone_name != null ? trimsuffix(data.google_dns_managed_zone.cluster["this"].dns_name, ".") : null

  # The public host the patchy webhook is served on: the zone apex unless the
  # caller narrows it to a sub-host.
  patchy_domain = var.dns.zone_name != null ? coalesce(var.dns.host, local.dns_domain) : null
}
