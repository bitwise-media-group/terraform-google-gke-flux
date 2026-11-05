# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "application" {
  description = "The seed release, where it lives, and how the image is listed, pulled and applied."
  value = {
    release      = module.demo.release
    namespace    = module.demo.namespace
    tag_provider = module.demo.tag_provider
    oci_provider = module.demo.oci_provider
    path         = module.demo.path
  }
}

output "workload_members" {
  description = "The federated principal of each workload grant, keyed as workload_grants."
  value       = module.demo.workload_members
}

output "node_pool" {
  description = "The application's own node pool: the name its workloads pin with (cloud.google.com/gke-nodepool), labels and taints."
  value = {
    name   = module.node_pool.name
    labels = module.node_pool.labels
    taints = module.node_pool.taints
  }
}
