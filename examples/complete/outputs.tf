# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "cluster" {
  description = "Cluster facts."
  value = {
    name           = module.cluster.name
    endpoint       = module.cluster.endpoint
    flux_namespace = module.cluster.flux.namespace
  }
}

output "dns" {
  description = "Zone wiring: confirm the parent-domain NS delegation matches name_servers."
  value       = module.cluster.dns
}

output "gateway" {
  description = "The reserved Gateway address — stable across cluster recreation."
  value       = module.cluster.gateway
}

output "kubectl_oidc" {
  description = "kubectl through dex (null unless sso.kubectl.enabled): the workforce pool/provider, the group principal-set prefix for rbac.groups and the login steps."
  value       = module.cluster.kubectl_oidc
}

output "application_target" {
  description = "What a second root publishes an application to this cluster with (examples/application's cluster input)."
  value       = module.cluster.application_target
}
