# artifact-store

One Artifact Registry docker repository holding everything the platform consumes — mirrored charts (`charts/<name>`),
digest-pinned mirrored images (`images/<original-path>`) and the signed manifest images (`manifests/platform`, the
entrypoint the clusters sync, and `manifests/<component>` / `manifests/<app>` beside it) — plus the GitHub
Actions publishing trust: impersonatable publisher service accounts (the chart publisher, and one manifest publisher per
manifest-publishing repo) bound to the org's central Workload Identity Federation pool. The pool/provider are owned by
cloud-accounts and passed in via the required `wif` input — never created here.

| Path | Published by |
| --- | --- |
| `charts/<name>`, `images/<original-path>` | flux-containers (the chart publisher) |
| `manifests/platform`, `manifests/<component>` | the platform repo (`github.platform`, paths `manifests/*`) |
| `manifests/<application>` | that application's repo (paths `manifests/<application>`) |

**One publisher per repo.** `github.manifest_publishers` declares one service account per manifest-publishing repo,
impersonable from its `main` branch alone, where the publish job of its release workflow pushes every edge build and
promotes every release. Each repo sets `manifest_publishers[<repo>].email` as its `GOOGLE_MANIFEST_PUBLISHER_SA`
variable, and an application's cluster-side `image.verify.subject` pins `manifest_publishers[<repo>].subject`. The
platform publisher keeps its `<name>-manifest-publisher` service account (and email); every other repo's account id is
`<name>-mp-<first 8 hex of sha256(repo)>`, since service account ids cap at 30 characters.

**Paths are declarative, not IAM-enforced.** Unlike ECR (where the AWS module scopes push per path), Artifact Registry
authorizes a docker push against the repository (`artifactregistry.repositories.uploadArtifacts`), only repositories
accept allow policies, and Artifact Registry is not among the services whose `resource.name` IAM Conditions recognize —
a `startsWith(resource.name, ".../packages/<path>")` condition would never match and would deny every push. So every
publisher holds unconditional `roles/artifactregistry.writer` on the whole repository. Path ownership rests on the
consumer, and is only as narrow as the subject it verifies against. `signed_identity_subjects.manifests` admits the
release workflow of every repo `github.manifest_signers` matches (every org repo by default), so a cluster verifying the
platform against it trusts those repos with every path. A consumer pinning one repo's `manifest_publishers[<repo>].subject`
(as every application seed does, and as a cluster may for the platform) rejects anything another publisher pushes to
that path. IAM-enforced separation would need a repository per publisher, a layout change this module does not make.

Before this release the store knew a single manifests publisher (`github.manifests` / `github.manifests_id`); `moved`
blocks carry that service account and its grants to the `flux-manifests` key in place (same account id, same email).

Apply this once per project, before anything else: the `flux-containers` and `flux-manifests` publish workflows need its
outputs (as the `GOOGLE_WORKLOAD_IDENTITY_PROVIDER` / `GOOGLE_CHART_PUBLISHER_SA` / `GOOGLE_MANIFEST_PUBLISHER_SA` /
`GOOGLE_PLATFORM_REGISTRY` Actions variables), and a cluster
cannot bootstrap until those pipelines have populated the registry.

**No tag ever moves.** A channel is its newest immutable build: every push to `main` that cuts no release publishes an
edge build (`<next version>-edge.<UTC yyyymmddhhmmss>.g<short commit>`), and cutting a release adds the stable `vX.Y.Z`
tag to the newest edge build of that version, never rebuilding it. Every build also carries `sha-<commit>`. The registry
does not enforce this: Artifact Registry's repository-wide `immutable_tags` stops cleanup policies deleting any tagged
artifact, so the publish workflows refuse to overwrite a tag instead, and the repository's cleanup policies age old
builds out:

| Policy               | Action | Selects                                                                              |
| -------------------- | ------ | ------------------------------------------------------------------------------------ |
| `keep-releases`      | keep   | every version tagged `v*` (promoted releases, and mirrored upstream v-tags)          |
| `keep-recent-builds` | keep   | the newest `build_retention_count` (20) versions of every package, regardless of age |
| `expire-builds`      | delete | tagged versions under `manifests` older than `build_expiry_days` (30)                |
| `expire-untagged`    | delete | untagged versions older than `untagged_expiry_days` (14)                             |

A keep policy always wins over a delete policy. Artifact Registry matches tags by prefix only and counts versions per
package, so `build_retention_count` covers every build of a package: an edge build that was never promoted ages out once
that many newer builds of the same package have landed and it is older than `build_expiry_days`. A release is cut from
the newest edge build, which is always within the count, and is then kept by its `v*` tag. Mirrored charts and images
are never aged out (the manifests pin them by digest).

Signing is cosign **keyless** by default (GitHub OIDC → Fulcio/Rekor, public transparency log), with no public-key
distribution; `signing_kms_key_name` switches the publishers to a Cloud KMS key. Keyless consumers verify artifacts
against the publishing workflows' certificate identities — the `signed_identity_subjects` and `manifest_publishers`
outputs have the exact regexps.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2 |
| google | >= 7.0, < 9 |

## Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.0, < 9 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_artifact_registry_repository.platform](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository) | resource |
| [google_artifact_registry_repository_iam_member.chart_publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository_iam_member) | resource |
| [google_artifact_registry_repository_iam_member.manifest_publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository_iam_member) | resource |
| [google_artifact_registry_repository_iam_member.readers](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository_iam_member) | resource |
| [google_kms_crypto_key_iam_member.publisher_signing](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_service_account.chart_publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.manifest_publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.chart_publisher_wif](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.manifest_publisher_wif](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| project | Project ID the artifact store lives in (e.g. the x-patchy-app project). | `string` | n/a | yes |
| wif | The org's existing Workload Identity Federation pool/provider for GitHub OIDC, as full resource names. The trust<br/>anchor is owned centrally (cloud-accounts' o-foundation) -- this module only binds publishers to it. | <pre>object({<br/>    pool_name     = string<br/>    provider_name = string<br/>  })</pre> | n/a | yes |
| build\_expiry\_days | Days after push at which a tagged manifest image -- an edge or sha-<commit> build -- outside the newest<br/>build\_retention\_count of its package and never promoted (no v* tag) is deleted. Mirrored charts and images are<br/>never aged out. | `number` | `30` | no |
| build\_retention\_count | How many of the newest versions of each package (manifests/<name>, and every mirrored chart and image) are kept<br/>regardless of age. Artifact Registry counts per package, not per channel, so the count covers every version of the<br/>package; the newest edge build is always within it. Promoted releases (v* tags) are kept regardless. | `number` | `20` | no |
| github | GitHub org and repository names the publisher trust is pinned to, plus the immutable numeric ids GitHub embeds in<br/>the OIDC subjects of post-2026-07-15 repos (org\_id from GET /orgs/<org>, repo ids from GET /repos/<org>/<repo>).<br/>containers is the chart/image mirror (flux-containers). manifest\_publishers is every repo that publishes manifest<br/>images, keyed by repo name: the platform's (paths ["manifests/*"], the platform authority) and one per application<br/>repo (paths ["manifests/<app>"]). Each gets its own service account, impersonable from its main branch alone (its<br/>release workflow publishes every edge build and promotes every release there); repository\_id may stay null until<br/>that repo exists on GitHub. paths is declarative here, NOT enforced by IAM: Artifact Registry authorizes pushes<br/>per repository and its IAM Conditions cannot match package paths, so every publisher holds<br/>artifactregistry.writer on the whole repository and path ownership rests on consumer-side signature verification.<br/>manifest\_signers is a Go regexp over a repository name (no org, no anchors; group any alternation) choosing whose<br/>release workflows signed\_identity\_subjects.manifests admits: every repo in the org by default, or a subset such as<br/>aip-[^/]+. A cluster verifying the platform against that subject trusts every matching repo with every path; one<br/>that must hold the platform to its own repo pins manifest\_publishers[github.platform].subject instead. platform<br/>names the key that publishes the platform entrypoint, which keeps the <name>-manifest-publisher service account;<br/>every other key gets <name>-mp-<8 hex of sha256(repo)> (service account ids cap at 30 characters). | <pre>object({<br/>    org              = optional(string, "bitwise-media-group")<br/>    org_id           = optional(number, 282673588)<br/>    containers       = optional(string, "flux-containers")<br/>    containers_id    = optional(number, 1303643498)<br/>    platform         = optional(string, "flux-manifests")<br/>    manifest_signers = optional(string, "[^/]+")<br/>    manifest_publishers = optional(map(object({<br/>      repository_id = optional(number)<br/>      paths         = list(string)<br/>    })), { flux-manifests = { paths = ["manifests/*"] } })<br/>  })</pre> | `{}` | no |
| labels | Labels applied to the Artifact Registry repository. | `map(string)` | `{}` | no |
| location | Artifact Registry location. Keep it in the cluster's region so image pulls stay regional. | `string` | `"us-central1"` | no |
| name | Base name for the publisher service accounts (account\_id prefix, so keep it short). | `string` | `"platform"` | no |
| reader\_members | IAM members granted artifactregistry.reader on the repository. Coarse grants are the intended shape (content<br/>security is cosign verification, not read denial): the org-wide service-account principal set plus one<br/>all-identities workload-identity-pool principalSet per cluster project. Per-identity least privilege remains<br/>possible via each cluster's registry\_reader\_members output. | `list(string)` | `[]` | no |
| repository\_id | Artifact Registry repository id. Charts land under charts/<name>, images under images/<original-path>, and the<br/>signed manifest images under manifests/<name> within it (manifests/platform, the entrypoint the clusters sync;<br/>manifests/<component> and manifests/<app> beside it). | `string` | `"platform"` | no |
| signing\_kms\_key\_name | Asymmetric SIGN Cloud KMS crypto key the publish workflows sign artifacts with (cosign sign --key gcpkms://<name>),<br/>instead of keyless Fulcio identities. When set, every publisher service account gets cloudkms signerVerifier +<br/>viewer on the key; feed the same name to the cluster module's signed\_identity.kms\_key\_name so verification<br/>matches. Null keeps signing keyless (the signed\_identity\_subjects output). The key itself lives outside this<br/>module — signing identity should outlive any one store. | `string` | `null` | no |
| untagged\_expiry\_days | Days after which untagged manifests (failed/superseded pushes) are deleted. | `number` | `14` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| chart\_publisher | Chart publisher service account (email is the service\_account input of google-github-actions/auth in flux-containers, set as its GOOGLE\_CHART\_PUBLISHER\_SA variable). |
| chart\_repository\_prefix | OCI prefix mirrored charts are published under (charts/<name> appended per chart). |
| image\_repository\_prefix | Registry prefix mirrored images are published under (images/<original-path> appended per image). |
| manifest\_artifact\_url | OCI url of the platform entrypoint image the clusters sync (manifests/platform; the components and applications it seeds sit beside it under manifests/<name>). |
| manifest\_publishers | One manifest publisher per github.manifest\_publishers key: its service account (email is the service\_account<br/>input of google-github-actions/auth in that repo, its GOOGLE\_MANIFEST\_PUBLISHER\_SA variable), the paths it owns<br/>(declarative - see the github variable), and the Fulcio certificate-subject regexp of its release workflow on main<br/>(which signs edge builds and the releases promoted from them) - what an image.verify.subject pins to trust that<br/>repo alone. |
| platform\_registry | The platform registry prefix — the value of the cluster's platform\_registry variable and the PLATFORM\_REGISTRY cluster var. |
| registry\_host | Registry hostname for docker/helm/crane login (oauth2accesstoken + access token). |
| signed\_identity\_subjects | Fulcio certificate-subject regexps for the chart mirror and the manifests publishers (keyless mode) — feed these to the cluster module's signed\_identity variable and the flux-manifests cluster vars. manifests admits the release workflow on main of every repo github.manifest\_signers matches, whichever channel (edge or stable) a cluster follows. Irrelevant when signing\_kms\_key\_name selects KMS signing. Each publisher's own subject rides in manifest\_publishers. |
| signing\_kms\_key\_name | The Cloud KMS signing key the publishers sign with (null in keyless mode) — feed it to the cluster module's signed\_identity.kms\_key\_name so verification matches. |
| workload\_identity\_provider | Full WIF provider resource name — the workload\_identity\_provider input of google-github-actions/auth (set as the GOOGLE\_WORKLOAD\_IDENTITY\_PROVIDER repo variable in the publishing repos). |
<!-- END_TF_DOCS -->
