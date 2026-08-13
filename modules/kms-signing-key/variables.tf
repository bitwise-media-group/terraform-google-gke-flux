# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "project" {
  description = "Project ID the signing key lives in — a foundation/security project rather than any one app project, since the key must outlive every store and cluster that uses it."
  type        = string
  nullable    = false
}

variable "location" {
  description = <<-EOT
    Cloud KMS location, immutable after creation. The default (global) serves signing and verification from anywhere —
    both are rare, tiny calls, so locality never matters — and the key's resource name works from any region
    regardless. Pick a specific region only when policy requires regional key material or protection_level is HSM
    (global offers SOFTWARE only).
  EOT
  type        = string
  nullable    = false
  default     = "global"
}

variable "name" {
  description = "Name of the key ring and crypto key (both permanent once created — Cloud KMS never deletes rings or key names)."
  type        = string
  nullable    = false
  default     = "platform-artifact-signing"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,63}$", var.name))
    error_message = "name must contain only alphanumerics, hyphens and underscores (KMS resource id, at most 63 characters)."
  }
}

variable "algorithm" {
  description = <<-EOT
    Signing algorithm, immutable after creation. The default matches cosign's own default algorithm (ECDSA P-256 /
    SHA-256); the allowed set is the intersection of Cloud KMS signing algorithms and what cosign's GCP KMS provider
    supports — notably excluding EC_SIGN_SECP256K1_SHA256, which sigstore does not accept.
  EOT
  type        = string
  nullable    = false
  default     = "EC_SIGN_P256_SHA256"

  validation {
    condition = contains([
      "EC_SIGN_P256_SHA256",
      "EC_SIGN_P384_SHA384",
      "RSA_SIGN_PSS_2048_SHA256",
      "RSA_SIGN_PSS_3072_SHA256",
      "RSA_SIGN_PSS_4096_SHA256",
      "RSA_SIGN_PSS_4096_SHA512",
      "RSA_SIGN_PKCS1_2048_SHA256",
      "RSA_SIGN_PKCS1_3072_SHA256",
      "RSA_SIGN_PKCS1_4096_SHA256",
      "RSA_SIGN_PKCS1_4096_SHA512",
    ], var.algorithm)
    error_message = "algorithm must be a cosign-supported signing algorithm: EC_SIGN_P256_SHA256, EC_SIGN_P384_SHA384, or an RSA_SIGN_PSS/PKCS1 2048-4096 variant."
  }
}

variable "protection_level" {
  description = "Protection level of the key material, immutable after creation. HSM requires a location that offers it (not global)."
  type        = string
  nullable    = false
  default     = "SOFTWARE"

  validation {
    condition     = contains(["SOFTWARE", "HSM"], var.protection_level)
    error_message = "protection_level must be SOFTWARE or HSM."
  }
}

variable "destroy_scheduled_days" {
  description = <<-EOT
    Days a destroyed key version spends in DESTROY_SCHEDULED (still restorable) before the material is shredded.
    Defaults to the Cloud KMS maximum: destroying this key permanently breaks cosign verification of every artifact
    ever signed with it, so the window should stay as long as possible.
  EOT
  type        = number
  nullable    = false
  default     = 120

  validation {
    condition     = var.destroy_scheduled_days >= 1 && var.destroy_scheduled_days <= 120
    error_message = "destroy_scheduled_days must be between 1 and 120 (Cloud KMS limits)."
  }
}

variable "signer_members" {
  description = <<-EOT
    IAM members allowed to sign with this key (cloudkms.signerVerifier plus the viewer reads cosign needs) — for
    signers managed OUTSIDE the artifact-store module, which already grants its own publishers when handed this key's
    name via signing_kms_key_name. Usually empty.
  EOT
  type        = list(string)
  nullable    = false
  default     = []
}

variable "verifier_members" {
  description = <<-EOT
    IAM members granted public-key access for verification (cloudkms.publicKeyViewer + viewer). Verification is not a
    privilege (the public key is public), so coarse members are the intended shape, exactly like the artifact store's
    reader_members: the org-wide service-account principal set
    ("principalSet://cloudresourcemanager.googleapis.com/organizations/<org number>/type/ServiceAccount") plus one
    all-identities workload-identity-pool principalSet per cluster project — a new cluster onboards without editing
    this module, and the grant can never sign.
  EOT
  type        = list(string)
  nullable    = false
  default     = []
}

variable "labels" {
  description = "Labels applied to the crypto key."
  type        = map(string)
  nullable    = false
  default     = {}
}
