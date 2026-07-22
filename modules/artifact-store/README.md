# artifact-store

One Artifact Registry docker repository holding everything the platform consumes — mirrored charts (`charts/<name>`),
digest-pinned mirrored images (`images/<original-path>`) and the signed `flux-manifests` sync artifact — plus the GitHub
Actions publishing trust: two impersonatable publisher service accounts bound to the org's central Workload Identity
Federation pool. The pool/provider are owned by cloud-accounts and passed in via the required `wif` input — never
created here.

Apply this once per project, before anything else: the `flux-containers` and `flux-manifests` publish workflows need its
outputs (as the `GCP_WIF_PROVIDER` / `GCP_CHART_PUBLISHER_SA` / `GCP_MANIFEST_PUBLISHER_SA` /
`PLATFORM_REGISTRY` org-level Actions variables), and a cluster
cannot bootstrap until those pipelines have populated the registry.

Signing is cosign **keyless** (GitHub OIDC → Fulcio/Rekor, public transparency log): there is no KMS key and no
public-key distribution. Consumers verify artifacts against the publishing workflows' certificate identities — the
`signed_identity_subjects` output has the exact regexps.

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
| [google_artifact_registry_repository.platform](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository) | resource |
| [google_artifact_registry_repository_iam_member.chart_publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository_iam_member) | resource |
| [google_artifact_registry_repository_iam_member.manifest_publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository_iam_member) | resource |
| [google_artifact_registry_repository_iam_member.readers](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository_iam_member) | resource |
| [google_service_account.chart_publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.manifest_publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.chart_publisher_wif](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.manifest_publisher_wif](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| project | Project ID the artifact store lives in (e.g. the x-patchy-app project). | `string` | n/a | yes |
| wif | The org's existing Workload Identity Federation pool/provider for GitHub OIDC, as full resource names. The trust<br/>anchor is owned centrally (cloud-accounts' o-foundation) -- this module only binds publishers to it. | <pre>object({<br/>    pool_name     = string<br/>    provider_name = string<br/>  })</pre> | n/a | yes |
| github | GitHub org and repository names the publisher trust is pinned to, plus the immutable numeric ids GitHub embeds in<br/>the OIDC subjects of post-2026-07-15 repos (org\_id from GET /orgs/<org>, repo ids from GET /repos/<org>/<repo>).<br/>manifests\_id may stay null until that repo exists on GitHub. | <pre>object({<br/>    org           = optional(string, "bitwise-media-group")<br/>    org_id        = optional(number, 282673588)<br/>    containers    = optional(string, "flux-containers")<br/>    containers_id = optional(number, 1303643498)<br/>    manifests     = optional(string, "flux-manifests")<br/>    manifests_id  = optional(number)<br/>  })</pre> | `{}` | no |
| labels | Labels applied to the Artifact Registry repository. | `map(string)` | `{}` | no |
| location | Artifact Registry location. Keep it in the cluster's region so image pulls stay regional. | `string` | `"us-central1"` | no |
| name | Base name for the publisher service accounts (account\_id prefix, so keep it short). | `string` | `"platform"` | no |
| promotion\_environment | GitHub environment (protected, reviewer-gated) whose jobs may move the stable channel tag. | `string` | `"production"` | no |
| reader\_members | IAM members granted artifactregistry.reader on the repository. Coarse grants are the intended shape (content<br/>security is cosign verification, not read denial): the org-wide service-account principal set plus one<br/>all-identities workload-identity-pool principalSet per cluster project. Per-identity least privilege remains<br/>possible via each cluster's registry\_reader\_members output. | `list(string)` | `[]` | no |
| repository\_id | Artifact Registry repository id. Charts land under charts/<name>, images under images/<original-path>, and the<br/>manifests artifact at flux-manifests within it. | `string` | `"platform"` | no |
| untagged\_expiry\_days | Days after which untagged manifests (failed/superseded pushes) are deleted. | `number` | `14` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| chart\_publisher | Chart publisher service account (email is the service\_account input of google-github-actions/auth in flux-containers, set as the GCP\_CHART\_PUBLISHER\_SA / GCP\_MANIFEST\_PUBLISHER\_SA org variables). |
| chart\_repository\_prefix | OCI prefix mirrored charts are published under (charts/<name> appended per chart). |
| image\_repository\_prefix | Registry prefix mirrored images are published under (images/<original-path> appended per image). |
| manifest\_artifact\_url | OCI url of the flux-manifests artifact the clusters sync. |
| manifest\_publisher | Manifest publisher service account (email is the service\_account input of google-github-actions/auth in flux-manifests, set as the GCP\_CHART\_PUBLISHER\_SA / GCP\_MANIFEST\_PUBLISHER\_SA org variables). |
| platform\_registry | The platform registry prefix — the value of the cluster's platform\_registry variable and the PLATFORM\_REGISTRY cluster var. |
| registry\_host | Registry hostname for docker/helm/crane login (oauth2accesstoken + access token). |
| signed\_identity\_subjects | Fulcio certificate-subject regexps for the publishing workflows — feed these to the cluster module's signed\_identity variable and the flux-manifests cluster vars. |
| workload\_identity\_provider | Full WIF provider resource name — the workload\_identity\_provider input of google-github-actions/auth (set as the GCP\_WIF\_PROVIDER repo variable in the publishing repos). |
<!-- END_TF_DOCS -->
