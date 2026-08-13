# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The global static IP for the platform Gateway
# (gke-l7-global-external-managed = global external Application Load
# Balancer). Living outside the Gateway's lifecycle means cluster
# destroy/recreate serves the same address again: external-dns records barely
# blip and the domain comes back without manual action. The flux-manifests
# gateway component attaches it by name (spec.addresses type NamedAddress,
# via the GATEWAY_ADDRESS_NAME cluster var).
#
# Two shapes: reserve one here (reserve_static_ip, default), or — like the
# x-patchy-app deployment, where cloud-accounts reserves `ingress` next to
# the DNS zone — reference an existing address by name
# (reserve_static_ip = false + address_name).

resource "google_compute_global_address" "gateway" {
  for_each = toset(var.gateway.reserve_static_ip ? ["true"] : [])

  project = var.project
  name    = coalesce(var.gateway.address_name, "${var.name}-gateway")
}

# The instance key used to be "this"; keep existing reservations (and their
# IPs) in place across the rename.
moved {
  from = google_compute_global_address.gateway["this"]
  to   = google_compute_global_address.gateway["true"]
}

data "google_compute_global_address" "gateway" {
  for_each = toset(!var.gateway.reserve_static_ip && var.gateway.address_name != null ? ["true"] : [])

  project = var.project
  name    = var.gateway.address_name
}

locals {
  gateway_address_name = (
    var.gateway.reserve_static_ip
    ? google_compute_global_address.gateway["true"].name
    : coalesce(var.gateway.address_name, "")
  )
  gateway_address = (
    var.gateway.reserve_static_ip
    ? google_compute_global_address.gateway["true"].address
    : (var.gateway.address_name != null ? data.google_compute_global_address.gateway["true"].address : "")
  )
}
