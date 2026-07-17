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
