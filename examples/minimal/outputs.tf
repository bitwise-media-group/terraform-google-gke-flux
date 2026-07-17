# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "cluster" {
  description = "Cluster facts (endpoint, workload identity pool, node SA, flux namespace)."
  value = {
    name                   = module.cluster.name
    endpoint               = module.cluster.endpoint
    workload_identity_pool = module.cluster.workload_identity_pool
    flux_namespace         = module.cluster.flux.namespace
  }
}
