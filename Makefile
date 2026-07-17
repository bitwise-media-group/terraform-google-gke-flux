# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# terraform-google-gke-flux — GKE cluster + Artifact Registry + flux-operator
# bootstrap for the patchy platform.
#
# Everything lives in mise tasks: the terraform archetype (init/plan/validate
# machinery + pinned tools) comes from the shared toolchain submodule at
# .mise/, selected in the root mise.toml, which also includes the repo-local
# fan-out tasks (validate/test across root, modules/* and examples/*). This
# Makefile is only the thin forwarding shim — `make <task>` == `mise run <task>`.
include .mise/mise.mk
