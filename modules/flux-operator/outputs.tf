# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "namespace" {
  description = "The flux namespace."
  value       = var.namespace
}

output "cluster_vars_configmap" {
  description = "Name of the cluster-vars ConfigMap the stack substitutes from."
  value       = "cluster-vars"
}
