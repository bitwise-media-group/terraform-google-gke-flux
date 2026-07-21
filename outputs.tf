# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "name" {
  description = "Cluster name."
  value       = google_container_cluster.main.name
}

output "endpoint" {
  description = "Control-plane endpoint IP (host for the helm/kubernetes providers)."
  value       = google_container_cluster.main.endpoint
}

output "ca_certificate" {
  description = "Base64-encoded cluster CA certificate."
  # try(): master_auth is only populated by the real API, so mocked plans (the
  # test suite) see an empty list here.
  value = try(google_container_cluster.main.master_auth[0].cluster_ca_certificate, null)
}

output "kubernetes_version" {
  description = "Current master version."
  value       = google_container_cluster.main.master_version
}

output "workload_identity_pool" {
  description = "The cluster's workload identity pool (<project>.svc.id.goog)."
  value       = local.workload_identity_pool
}

output "node_service_account" {
  description = "The dedicated node service account (system pool + auto-provisioned pools)."
  value = {
    email  = google_service_account.nodes.email
    member = google_service_account.nodes.member
  }
}

output "platform_registry" {
  description = "The platform registry prefix (pass-through of var.platform_registry)."
  value       = var.platform_registry
}

output "dns" {
  description = "Delegated zone wiring (null when dns.zone_name is unset): zone name, apex domain, served host and the zone's name servers."
  value = var.dns.zone_name == null ? null : {
    zone_name    = var.dns.zone_name
    domain       = local.dns_domain
    host         = local.patchy_domain
    name_servers = data.google_dns_managed_zone.cluster["this"].name_servers
  }
}

output "gateway" {
  description = "The Gateway address in use — reserved here or referenced from an existing reservation (null when neither)."
  value = local.gateway_address_name != "" ? {
    address_name = local.gateway_address_name
    address      = local.gateway_address
  } : null
}

output "rbac" {
  description = "Google Groups for RBAC (null unless rbac.enabled): the fleet group the cluster authenticator trusts. Groups must be nested under it (out-of-band, in Workspace) to be usable as Role/ClusterRoleBinding subjects."
  value = var.rbac.enabled ? {
    security_group = local.gke_security_group
  } : null
}

output "flux" {
  description = "Flux bootstrap facts."
  value = {
    namespace = module.flux_operator.namespace
  }
}

output "registry_reader_members" {
  description = "Every identity that reads the platform registry (node SA, flux controllers, kyverno controllers). Granted automatically either way: in-project when the registry is co-located, or on the registry's project (registry_readers, via the org's reader-constrained delegation) when it is central. Exported for visibility and for feeding artifact-store reader_members where the delegation is not in place."
  value       = local.registry_reader_members
}
