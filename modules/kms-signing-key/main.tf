# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# An asymmetric Cloud KMS key for cosign signing of platform artifacts.
#
# This is the key the artifact-store module's signing_kms_key_name and the
# cluster module's signed_identity.kms_key_name both point at when signing is
# KMS-based rather than keyless. It lives in its own module because the signing
# identity must outlive any one store or cluster: artifacts already published
# verify against THIS key forever, so its lifecycle is deliberately decoupled
# from the infrastructure that signs with or verifies against it.
#
# Two properties make a Cloud KMS key cosign-appropriate, and both are
# immutable after creation:
#
#   - purpose ASYMMETRIC_SIGN — an ENCRYPT_DECRYPT key (the KMS default)
#     cannot sign at all.
#   - an algorithm cosign supports — EC_SIGN_P256_SHA256 by default, matching
#     cosign's own default algorithm (ECDSA P-256 / SHA-256).
#
# Publishers sign with `cosign sign --key gcpkms://<key resource name>`;
# verifiers need only the public half (viewPublicKey, or the exported PEM),
# never the private key, which never leaves KMS.
#
# There is deliberately no rotation_period here: Cloud KMS cannot auto-rotate
# asymmetric keys, and rotating a signing key is not an operational nicety but
# an identity change — every consumer must be re-pointed and existing
# signatures no longer match. Rotation, when needed, is a new key plus
# re-signing, coordinated by humans. For the same reason
# destroy_scheduled_duration defaults to the maximum: destroying this key's
# versions permanently breaks verification of everything ever signed with it.

# Key rings cannot be deleted in Cloud KMS, so the ring (and every key name
# ever created inside it) is permanent. A dedicated ring per signing identity
# keeps that permanence self-contained instead of accreting in a shared ring.
resource "google_kms_key_ring" "signing" {
  project  = var.project
  name     = var.name
  location = var.location
}

resource "google_kms_crypto_key" "signing" {
  name     = var.name
  key_ring = google_kms_key_ring.signing.id
  purpose  = "ASYMMETRIC_SIGN"

  version_template {
    algorithm        = var.algorithm
    protection_level = var.protection_level
  }

  destroy_scheduled_duration = "${var.destroy_scheduled_days * 24 * 60 * 60}s"

  labels = var.labels
}

# Unlike AWS KMS there is no key policy to own here: Cloud KMS IAM is additive
# and key-scoped, and the artifact-store module attaches signerVerifier +
# viewer to its own publishers when handed this key's name (the grant works
# from wherever the store lives). These members exist for signers managed
# OUTSIDE that module, so the list is usually empty.
resource "google_kms_crypto_key_iam_member" "signers" {
  for_each = {
    for pair in setproduct(var.signer_members, ["signerVerifier", "viewer"]) :
    "${pair[0]}:${pair[1]}" => pair
  }

  crypto_key_id = google_kms_crypto_key.signing.id
  role          = "roles/cloudkms.${each.value[1]}"
  member        = each.value[0]
}

# Verification is not a privilege — the public key is public. Coarse members
# (the org-wide service-account principalSet, a cluster project's whole
# workload-identity pool) mirror the artifact store's read grant: a new
# cluster project onboards without editing this module, and the grant can
# never sign. publicKeyViewer carries viewPublicKey; viewer the get/list
# reads cosign performs around a versionless key reference.
resource "google_kms_crypto_key_iam_member" "verifiers" {
  for_each = {
    for pair in setproduct(var.verifier_members, ["publicKeyViewer", "viewer"]) :
    "${pair[0]}:${pair[1]}" => pair
  }

  crypto_key_id = google_kms_crypto_key.signing.id
  role          = "roles/cloudkms.${each.value[1]}"
  member        = each.value[0]
}

# The public half, exported for offline distribution (committing a cosign.pub,
# verifying without GCP credentials). Consumers with verifier grants can
# equally fetch it themselves via viewPublicKey.
data "google_kms_crypto_key_version" "signing" {
  crypto_key = google_kms_crypto_key.signing.id
}
