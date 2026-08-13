# kms-signing-key

An asymmetric Cloud KMS key appropriate for **cosign signing** of platform artifacts: `ASYMMETRIC_SIGN` purpose with a
sigstore-supported algorithm (ECDSA P-256 by default, cosign's own default). Publishers sign with
`cosign sign --key gcpkms://<key resource name>` (the `cosign_key_ref` output); verifiers only ever need the public
half.

The key lives in its own module because the **signing identity must outlive any one store or cluster** — artifacts
already published verify against this key forever. Feed `key_name` to the artifact-store module's
`signing_kms_key_name` (which grants the publisher service accounts `signerVerifier`) and to the cluster module's
`signed_identity.kms_key_name` (which selects KMS verification).

`verifier_members` grants **verification broadly**, mirroring the artifact store's `reader_members`: pass coarse
principal sets (the org-wide service-account set, a cluster project's whole workload-identity pool) so a new cluster
project onboards without editing this module — the grant carries `publicKeyViewer` + `viewer` and can never sign.
Out-of-module *signing* stays opt-in via `signer_members`; the artifact-store module grants its own publishers, so
that list is usually empty.

There is no automatic rotation — Cloud KMS cannot rotate asymmetric keys, and rotating a signing key is an identity
change (new key, re-sign, re-point verifiers), not a background task. Accordingly `destroy_scheduled_days` defaults to
the Cloud KMS maximum, since destroying the key permanently breaks verification of everything it ever signed — and the
key ring itself is permanent either way, as Cloud KMS never deletes rings.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| google | >= 7.0, < 8.0 |

## Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.0, < 8.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_kms_crypto_key.signing](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key) | resource |
| [google_kms_crypto_key_iam_member.signers](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_kms_crypto_key_iam_member.verifiers](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_kms_key_ring.signing](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_key_ring) | resource |
| [google_kms_crypto_key_version.signing](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/kms_crypto_key_version) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| project | Project ID the signing key lives in — a foundation/security project rather than any one app project, since the key must outlive every store and cluster that uses it. | `string` | n/a | yes |
| algorithm | Signing algorithm, immutable after creation. The default matches cosign's own default algorithm (ECDSA P-256 /<br/>SHA-256); the allowed set is the intersection of Cloud KMS signing algorithms and what cosign's GCP KMS provider<br/>supports — notably excluding EC\_SIGN\_SECP256K1\_SHA256, which sigstore does not accept. | `string` | `"EC_SIGN_P256_SHA256"` | no |
| destroy\_scheduled\_days | Days a destroyed key version spends in DESTROY\_SCHEDULED (still restorable) before the material is shredded.<br/>Defaults to the Cloud KMS maximum: destroying this key permanently breaks cosign verification of every artifact<br/>ever signed with it, so the window should stay as long as possible. | `number` | `120` | no |
| labels | Labels applied to the crypto key. | `map(string)` | `{}` | no |
| location | Cloud KMS location, immutable after creation. The default (global) serves signing and verification from anywhere —<br/>both are rare, tiny calls, so locality never matters — and the key's resource name works from any region<br/>regardless. Pick a specific region only when policy requires regional key material or protection\_level is HSM<br/>(global offers SOFTWARE only). | `string` | `"global"` | no |
| name | Name of the key ring and crypto key (both permanent once created — Cloud KMS never deletes rings or key names). | `string` | `"platform-artifact-signing"` | no |
| protection\_level | Protection level of the key material, immutable after creation. HSM requires a location that offers it (not global). | `string` | `"SOFTWARE"` | no |
| signer\_members | IAM members allowed to sign with this key (cloudkms.signerVerifier plus the viewer reads cosign needs) — for<br/>signers managed OUTSIDE the artifact-store module, which already grants its own publishers when handed this key's<br/>name via signing\_kms\_key\_name. Usually empty. | `list(string)` | `[]` | no |
| verifier\_members | IAM members granted public-key access for verification (cloudkms.publicKeyViewer + viewer). Verification is not a<br/>privilege (the public key is public), so coarse members are the intended shape, exactly like the artifact store's<br/>reader\_members: the org-wide service-account principal set<br/>("principalSet://cloudresourcemanager.googleapis.com/organizations/<org number>/type/ServiceAccount") plus one<br/>all-identities workload-identity-pool principalSet per cluster project — a new cluster onboards without editing<br/>this module, and the grant can never sign. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| cosign\_key\_ref | The --key argument for cosign sign/verify (gcpkms://<key resource name>; the resource name encodes project and location, so it works from anywhere with KMS access). |
| key\_name | The crypto key's full resource name — feed it to the artifact-store module's signing\_kms\_key\_name (grants the publishers signerVerifier) and to the cluster module's signed\_identity.kms\_key\_name (selects KMS verification). |
| key\_ring\_name | Full resource name of the key ring — permanent once created, since Cloud KMS never deletes rings. |
| public\_key\_pem | PEM-encoded public half of the signing key, for offline verification (cosign verify --key cosign.pub) or committing next to the artifacts it verifies. Not secret. |
<!-- END_TF_DOCS -->
