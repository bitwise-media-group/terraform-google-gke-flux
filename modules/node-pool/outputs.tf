# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "name" {
  description = "The node pool's name - the value workloads pin with the cloud.google.com/gke-nodepool label."
  value       = google_container_node_pool.main.name
}

output "id" {
  description = "Node pool id (projects/<project>/locations/<location>/clusters/<cluster>/nodePools/<name>)."
  value       = google_container_node_pool.main.id
}

output "labels" {
  description = "Kubernetes labels every node in the pool carries - the selectors workloads pin with."
  value       = google_container_node_pool.main.node_config[0].labels
}

output "taints" {
  description = "Kubernetes taints every node in the pool carries (as configured; GKE's own Arm taint is not listed)."
  value       = google_container_node_pool.main.node_config[0].taint
}
