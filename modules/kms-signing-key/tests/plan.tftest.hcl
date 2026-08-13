# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with a mocked provider. These assert what makes the
# key cosign-appropriate (ASYMMETRIC_SIGN purpose, an algorithm cosign
# supports, no hair-trigger destruction) and the IAM shape the platform's
# onboarding story rests on (verification grants that can never sign, opt-in
# out-of-module signers).

mock_provider "google" {
  mock_data "google_kms_crypto_key_version" {
    defaults = {
      public_key = [{
        pem       = "-----BEGIN PUBLIC KEY-----\nMFkw\n-----END PUBLIC KEY-----\n"
        algorithm = "EC_SIGN_P256_SHA256"
      }]
    }
  }
}

variables {
  project = "test-project"
}

run "key_is_cosign_appropriate" {
  command = plan

  # Both of these are immutable after creation, and both are what "appropriate
  # for cosign" means: an ENCRYPT_DECRYPT key (the KMS default) cannot sign,
  # and the default algorithm matches cosign's own default.
  assert {
    condition     = google_kms_crypto_key.signing.purpose == "ASYMMETRIC_SIGN"
    error_message = "the key must be an ASYMMETRIC_SIGN key — an encryption key cannot sign"
  }

  assert {
    condition     = google_kms_crypto_key.signing.version_template[0].algorithm == "EC_SIGN_P256_SHA256"
    error_message = "the default algorithm must be EC_SIGN_P256_SHA256, cosign's default"
  }

  # Destroying a signing key permanently breaks verification of everything it
  # ever signed, so the destroy window defaults to the Cloud KMS maximum.
  assert {
    condition     = google_kms_crypto_key.signing.destroy_scheduled_duration == "10368000s"
    error_message = "the destroy window must default to the maximum (120 days)"
  }

  assert {
    condition     = google_kms_key_ring.signing.name == "platform-artifact-signing"
    error_message = "the ring must share the key's default name"
  }
}

run "secp256k1_is_rejected" {
  command = plan

  # Cloud KMS offers EC_SIGN_SECP256K1_SHA256 for signing, but sigstore does
  # not accept secp256k1 — a key created with it would sign artifacts nothing
  # verifies.
  variables {
    algorithm = "EC_SIGN_SECP256K1_SHA256"
  }

  expect_failures = [var.algorithm]
}

run "iam_is_delegated_by_default" {
  command = plan

  # No grants by default: Cloud KMS IAM is additive, and the artifact-store
  # module attaches its publishers' signerVerifier + viewer itself when handed
  # this key's name — the GCP analogue of the AWS module's delegate-to-IAM
  # root statement.
  assert {
    condition = (
      length(google_kms_crypto_key_iam_member.signers) == 0 &&
      length(google_kms_crypto_key_iam_member.verifiers) == 0
    )
    error_message = "the module must grant nothing by default — signer grants belong to artifact-store"
  }
}

run "verification_grant_never_signs" {
  command = plan

  variables {
    verifier_members = ["principalSet://cloudresourcemanager.googleapis.com/organizations/123456789012/type/ServiceAccount"]
  }

  # A coarse org-wide principalSet, exactly like the artifact store's read
  # grant: a new cluster project onboards without editing this module.
  # publicKeyViewer serves cosign's viewPublicKey; viewer its get/list reads
  # around a versionless key reference.
  assert {
    condition = alltrue([
      for grant in values(google_kms_crypto_key_iam_member.verifiers) :
      contains(["roles/cloudkms.publicKeyViewer", "roles/cloudkms.viewer"], grant.role)
    ])
    error_message = "verifier members may verify, never sign"
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.verifiers) == 2
    error_message = "each verifier member must get exactly publicKeyViewer + viewer"
  }
}

run "out_of_module_signing_is_opt_in" {
  command = plan

  variables {
    signer_members = ["serviceAccount:publisher@other-project.iam.gserviceaccount.com"]
  }

  # Signers outside the artifact-store module (which grants its own
  # publishers) must be nameable here; naming one adds exactly signerVerifier
  # plus the viewer reads cosign needs.
  assert {
    condition = anytrue([
      for grant in values(google_kms_crypto_key_iam_member.signers) :
      grant.role == "roles/cloudkms.signerVerifier" &&
      grant.member == "serviceAccount:publisher@other-project.iam.gserviceaccount.com"
    ])
    error_message = "named signer members must get a signerVerifier grant"
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.signers) == 2
    error_message = "each signer member must get exactly signerVerifier + viewer"
  }
}
