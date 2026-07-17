// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Same shape as cloud-accounts: the terraform preset with the documentation
// and naming rules pinned on. No provider ruleset — the org convention keeps
// tflint plugin-free (validation depth comes from terraform validate + the
// plan-time test suites).

tflint {
  required_version = ">= 0.55"
}

config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
}
