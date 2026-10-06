# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# terraform-google-gke-flux — GKE cluster + Artifact Registry + flux-operator
# bootstrap for the patchy platform.
#
# Everything lives in mise tasks: common/ plus the terraform archetype
# (fmt/lint/docs/init/plan + pinned tools) come from the shared toolchain
# submodule at .mise/, selected in the root mise.toml, which also includes the
# repo-local `test` fan-out (tasks.toml). This Makefile is only the thin
# forwarding shim — `make <task>` == `mise run <task>`.
include .mise/archetypes/terraform/include.mk
