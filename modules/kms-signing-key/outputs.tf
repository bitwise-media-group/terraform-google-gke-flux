# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "key_name" {
  description = "The crypto key's full resource name — feed it to the artifact-store module's signing_kms_key_name (grants the publishers signerVerifier) and to the cluster module's signed_identity.kms_key_name (selects KMS verification)."
  value       = google_kms_crypto_key.signing.id
}

output "key_ring_name" {
  description = "Full resource name of the key ring — permanent once created, since Cloud KMS never deletes rings."
  value       = google_kms_key_ring.signing.id
}

output "cosign_key_ref" {
  description = "The --key argument for cosign sign/verify (gcpkms://<key resource name>; the resource name encodes project and location, so it works from anywhere with KMS access)."
  value       = "gcpkms://${google_kms_crypto_key.signing.id}"
}

output "public_key_pem" {
  description = "PEM-encoded public half of the signing key, for offline verification (cosign verify --key cosign.pub) or committing next to the artifacts it verifies. Not secret."
  value       = data.google_kms_crypto_key_version.signing.public_key[0].pem
}
