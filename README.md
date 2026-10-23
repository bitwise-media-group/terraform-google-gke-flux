# terraform-google-gke-flux

A GKE Standard cluster that bootstraps [flux-operator] and syncs a cosign-signed platform entrypoint image from Artifact
Registry — a generic platform substrate on Google Cloud that any number of applications (such as [patchy]) are
published onto as their own signed manifest images. The GKE analogue of [terraform-aws-eks-flux], sharing its
cloud-neutral contract.

Three repos make the platform:

| repo                                 | role                                                                                              |
| ------------------------------------ | ------------------------------------------------------------------------------------------------- |
| **terraform-google-gke-flux** (this) | the cluster, the artifact store, the flux bootstrap and the application seeds                     |
| [flux-containers]                    | vendors, scans, mirrors and signs charts + images into the artifact store                         |
| [flux-manifests]                     | the platform every cluster syncs (`manifests/platform` and one `manifests/<component>` per piece) |

Applications live in their own repositories and publish `manifests/<app>` images beside the platform's. Nothing
application-specific lives here: the `patchy` and `stack_components` inputs that earlier, unreleased drafts carried
moved to [patchy-app-manifests] (its `modules/google`), along with `modules/scc-notifications`.

## Design

- **GKE Standard, regional or zonal, VPC-native** on a shared-VPC subnet (created by cloud-accounts), Dataplane V2
  (built-in Cilium), Workload Identity, private nodes behind Cloud NAT. A small always-on **system node pool**
  (`role=system`) carries the platform controllers; **node auto-provisioning** scales everything else.
- **One Artifact Registry docker repository** (`platform`) holds mirrored charts (`charts/<name>`), digest-pinned
  mirrored images (`images/<original-path>`) and the signed manifest images (`manifests/platform`, the entrypoint the
  FluxInstance syncs, plus `manifests/<component>` and `manifests/<app>`).
- **A platform entrypoint, an election and applications.** The FluxInstance syncs one small image whose `ResourceSet`
  ranges over `PLATFORM_COMPONENTS` and emits an `OCIRepository` + `Kustomization` per component. The core tier is
  always on; `platform_components` elects the rest (`flux-web`, `arc`; dex rides `sso.enabled`). Applications arrive
  through `applications` as bootstrap-only seeds and own themselves from their first reconcile.
- **Cosign verification, keyless or KMS.** Keyless (default): artifacts are signed by GitHub Actions OIDC identities
  (Fulcio/Rekor) and verified with `matchOIDCIdentity`. KMS (`signed_identity.kms_key_name`): the publishers sign
  with a Cloud KMS key; the bootstrap distributes its public half as the `cosign-pub` Secret, and kyverno's
  controllers get verifier/viewer on the key. Exactly one mode per cluster.
- **Direct Workload Identity Federation grants** for in-cluster workloads (`principal://…/ns/<ns>/sa/<ksa>`): no GSAs,
  no `iam.gke.io/gcp-service-account` annotations (dex's directory-reader impersonation is the one exception).
  Applications hand their grants in as `workload_grants`; Secret Manager reads stay resource-side — whoever creates a
  container grants its sync KSA accessor on it.
- **RBAC subjects, two ways.** Google Groups for RBAC (off by default): `rbac.enabled` + `rbac.domain` point the
  cluster authenticator at `gke-security-groups@<domain>` (the exact name is a GKE requirement; the group and its
  nested member groups are managed out-of-band in Workspace). Or **kubectl through dex** (`sso.kubectl`): a workforce
  pool trusting dex makes dex groups usable as `principalSet://…/group/<group>` subjects. Either way `rbac.groups`
  names the per-role subjects (viewers, developers, devops, admins), each published verbatim as `RBAC_GROUP_<ROLE>`.
- **DNS/TLS survives cluster recreation**: the delegated Cloud DNS zone lives in cloud-accounts and the Gateway's global
  static IP lives beside it (referenced here by name) — destroy/recreate serves the same domain again with no manual
  action.

## Bootstrap order

There is no blueprints repo; this is the canonical ordering:

1. **cloud-accounts**: the project with shared-VPC subnet + GKE secondary ranges, **Cloud NAT** on the shared VPC
   (private nodes need egress for Sigstore/ACME/GitHub), the APIs (`dns`, `artifactregistry`, `cloudtrace`, plus `iam`
   and `sts` for workforce identity), the delegated Cloud DNS zone (NS records at the parent added once), the `ingress`
   global static IP, and the org WIF trust anchor (`github_wif` output — the artifact-store module's required `wif`
   input; the pool/provider are never created outside cloud-accounts).
2. **artifact store** (`examples/artifact-store`): apply as the project's `terraform-apply` SA. Feed its outputs to the
   publishing repos as the `GCP_WIF_PROVIDER` / `GCP_CHART_PUBLISHER_SA` / `GCP_MANIFEST_PUBLISHER_SA` /
   `PLATFORM_REGISTRY` org-level Actions variables.
3. **flux-containers**: publish every chart + image the platform uses.
4. **flux-manifests** (>= 4.0.0): cut the first release; its publish workflow pushes the signed `manifests/platform`
   and `manifests/<component>` images and moves the `staging` channel tag (promote moves `stable`).
5. **sso-secrets** (only with `sso`): instantiate [`modules/sso-secrets`](modules/sso-secrets/) in a durable root with
   the same `sso` and `secret_prefix` values, then add the connector credentials out of band
   (`gcloud secrets versions add`).
6. **cluster** (`examples/complete` is the shape): `terraform apply` — one apply bootstraps flux-operator, which syncs
   the platform entrypoint and brings up the elected components and every seeded application. The operator/instance
   releases are bootstrap-only (`ignore_changes`): the platform's flux component adopts them and follows the newest
   mirrored charts, so flux upgrades ship by publishing to the registry, never by terraform. With `sso.kubectl` the
   same apply creates the workforce pool and provider (the applying identity needs `roles/iam.workforcePoolAdmin` on
   the organization); sign-in works once dex serves `https://dex.<PLATFORM_DOMAIN>`. Creating the provider is not
   expected to contact the issuer — if Google ever rejects it because dex is not up yet, apply again once it is.
7. **applications from other roots** (optional): `modules/application` against the cluster's `application_target`
   output (`examples/application`).

## The terraform ↔ flux contract

The `cluster-vars` ConfigMap (flux-system) publishes these to the platform; the authoritative consumer table lives in
the flux-manifests README. Optional surfaces use the empty-string convention so substitution never fails on an absent
value. The cluster syncs the manifests' google tree (`flux.sync.path`, default `google`), so no cloud selector is
published and the aws-only keys simply do not exist here. Callers may add extras (e.g. `*_SEMVER` range pins) via
`flux.cluster_vars`; reserved keys always win. The published contract is exported as `flux.cluster_vars`.

**Cloud-neutral keys** (the same names and meaning as terraform-aws-eks-flux):

| key                                                                    | source / meaning                                                                                                             |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `CLUSTER_NAME`                                                         | `name`                                                                                                                       |
| `PLATFORM_REGISTRY`, `CONTAINER_REGISTRY`                              | `platform_registry` (charts, tag listings, the sync artifact and mirrored images all come from it)                           |
| `SIGNED_IDENTITY_ISSUER`, `_CHARTS`, `_IMAGES`, `_MANIFESTS`           | keyless subjects (empty in KMS mode)                                                                                         |
| `SIGNED_IDENTITY_KMS_KEY`, `COSIGN_PUBLIC_KEY`                         | the KMS key name and its base64 PEM public half (empty in keyless mode)                                                      |
| `FLUX_SYNC_CHANNEL`, `FLUX_SYNC_URL`, `PLATFORM_TREE`                  | `flux.sync.ref`, the resolved sync url (default `oci://<registry>/manifests/platform`), `flux.sync.path`                     |
| `PLATFORM_COMPONENTS`                                                  | `platform_components` + `dex` under `sso`, sorted and comma-joined; an empty election publishes `none`                       |
| `DNS_ZONE_NAME`, `DNS_DOMAIN`, `PLATFORM_DOMAIN`, `ACME_EMAIL`         | `dns` (`PLATFORM_DOMAIN` = `dns.host` or the zone apex; `dex.` and `flux.` hang off it)                                      |
| `GATEWAY_IP`                                                           | the Gateway's static address                                                                                                 |
| `SECRET_PREFIX`                                                        | `secret_prefix`: every Secret Manager container the platform and its applications sync is `<prefix><name>`                   |
| `DEX_CONNECTORS`                                                       | the non-secret half of `sso.connector`, JSON (`[]` without sso)                                                              |
| `DEX_CLIENTS`                                                          | the platform's static dex clients `[{id, name, public, redirectURIs}]`: flux-web and the workforce client (`[]` without sso) |
| `RBAC_GROUP_VIEWERS`, `_DEVELOPERS`, `_DEVOPS`, `_ADMINS`              | `rbac.groups`, verbatim (a Google Group email or a workforce `principalSet`)                                                 |

**Google-specific keys:**

| key                                         | source / meaning                                                                          |
| ------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `GCP_PROJECT`, `GCP_PROJECT_NUMBER`         | `project` and its number                                                                  |
| `GCP_REGION`                                | the region of `location` (a zone's enclosing region for a zonal cluster)                  |
| `GATEWAY_ADDRESS_NAME`                      | the reserved (or referenced) global address the gateway component attaches by name        |
| `OTEL_PROJECT`                              | `observability.project`, defaulting to the cluster's own                                  |
| `DEX_DIRECTORY_SA`                          | `sso.directory_sa`, the Workspace directory-reader SA dex's google connector impersonates |

`OCI_PROVIDER` and `ARTIFACT_TAG_PROVIDER` are not published: the google tree defaults them to `gcp` and
`GARArtifactTag`. `SIGNED_IDENTITY_MANIFESTS`, `FLUX_SYNC_CHANNEL`, `FLUX_SYNC_URL` and `PLATFORM_TREE` feed the
platform's flux component (flux managing flux): it re-renders the FluxInstance this module bootstraps, so a changed
var re-points a running cluster without a kubectl patch.

When `sso` is enabled the module also binds `roles/iam.workloadIdentityUser` on the directory-reader SA for the
cluster's dex KSA (`sso.tf`) — the applying identity writes that one SA's policy through the get/setIamPolicy
delegation cloud-accounts grants the app's terraform-apply container, so a new cluster enables dex without a
cloud-accounts change.

**Generated client secrets.** The module generates the platform's dex clients (`sso.tf`): ephemeral random secrets
written through write-only Secret Manager versions (`${SECRET_PREFIX}dex-client-<id>`, never in state or plan), the
composed `flux-web-auth-config` Web Config document, and — with `sso.kubectl` — the workforce provider's client secret,
written write-only from the same value. They follow `platform_components` and `sso.kubectl`, and rotate via
`sso.clients[<id>].version` (bump it; every consumer of the pair rewrites in one apply — then restart dex, which reads
client secrets from env at startup). Deletion is immediate (no delayed-destroy cooldown), so cluster destroy/recreate
mints fresh pairs without manual cleanup.

**Out-of-band credentials** — the upstream connector's OAuth client — are the opposite case: their `dex-<id>-<field>`
containers and accessor grants come from [`modules/sso-secrets`](modules/sso-secrets/), instantiated in a **durable**
root with the same `sso` value; the versions are added with `gcloud secrets versions add` and survive cluster
destroy/recreate. An application's own containers belong to the application's module.

Workload identity namespace/service-account pairs (overridable via `workload_identity`): `external-dns/external-dns` and
`cert-manager/cert-manager` (→ `roles/dns.admin`), `otel-collector/otel-collector` (→ monitoring/logging/trace writers),
`kyverno/kyverno-{admission,reports}-controller` (→ `roles/artifactregistry.reader`, plus `cloudkms` verifier/viewer on
the signing key in KMS mode), `flux-system/{source-controller,flux-operator}` (→ `roles/artifactregistry.reader`), and
`dex/dex` (→
`workloadIdentityUser` on the directory-reader SA — the classic annotation-based flow, since dex must impersonate the
SA rather than hold a grant). Every grant's principal is exported as `workload_members`.

## Applications

An application is a signed OCI image of manifests, published by its own repo to `oci://<registry>/manifests/<app>`.
The cluster module seeds it; after that the image owns itself.

**The seed contract.** For `applications["<key>"]` terraform creates, once, in `flux-system`:

| object                     | name              | notes                                                                                                                  |
| -------------------------- | ----------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `ResourceSetInputProvider` | `<key>-manifests` | `GARArtifactTag` under the platform registry, `OCIArtifactTag` elsewhere; `filter.semver`, `limit: 1`                  |
| `ResourceSet`              | `<key>-manifests` | waits for `FluxInstance/flux`; emits the two objects below from the resolved `{tag, digest}`                           |
| `OCIRepository` (emitted)  | `<key>-manifests` | `provider: gcp` / `generic`, optional `secretRef` (`pull_secret`), cosign verify keyless or keyed                      |
| `Kustomization` (emitted)  | `<key>`           | `path` (default `./deploy/<PLATFORM_TREE>`), `dependsOn`, `substituteFrom` `cluster-vars` + `<key>-vars` (optional)    |

The image's `flux/` directory ships the **same** `ResourceSetInputProvider` and `ResourceSet` under the same names,
and `deploy/<tree>/kustomization.yaml` includes `../../flux`. On its first reconcile `Kustomization <key>` server-side
applies both objects and takes ownership; the seed release is `ignore_changes = all`, so terraform never fights back.
Both objects carry `kustomize.toolkit.fluxcd.io/prune: disabled` in the seed **and** in the image: should a release drop
`flux/`, the application's own Kustomization can never prune its parent and cascade itself away.

After hand-over the image may change anything: its semver range, its `dependsOn`, its path, its verification. To
**remove** an application, delete the key: the seed release uninstalls, the `ResourceSet` finalizer garbage-collects
the `Kustomization`, whose finalizer prunes the application. To **re-point** or **reset** a seed, remove and re-add the
key. A semver range matching no tag prunes the application too — keep ranges bounded (`<1.0.0 >=0.1.0`).

**Composition.** Everything the application needs outside the cluster is emitted by a module in the application's
repo and wired by the root; the application module consumes static root inputs only, never cluster outputs (that
would be a cycle):

```hcl
module "patchy" {
  source = "git::https://github.com/bitwise-media-group/patchy-app-manifests.git//modules/google?ref=v0.1.0"

  project           = var.project
  platform_registry = var.platform_registry
  secret_prefix     = var.secret_prefix
  domain            = var.patchy_domain
  harnesses         = ["claude"]
  claude            = { provider = "vertex" }
  sso_enabled       = var.sso.enabled
}

module "cluster" {
  source = "github.com/bitwise-media-group/terraform-google-gke-flux"

  platform_components = ["flux-web"]
  workload_grants     = module.patchy.workload_grants          # roles per key, as direct federated principals
  flux                = { namespaces = module.patchy.namespaces, sync = { ref = "staging" } }
  applications        = { patchy = module.patchy.application } # url, semver, verify, depends_on
  application_vars    = { patchy = module.patchy.vars }        # the patchy-vars ConfigMap
  # ...
}
```

| input                     | what the application module emits                                                                                       |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `workload_grants`         | `{ <key> = { namespace, service_account, roles, project? } }` — one `google_project_iam_member` per (key, role)         |
| `flux.namespaces`         | namespaces pre-created so out-of-band secrets can land before the application deploys                                   |
| `applications[<key>]`     | `url`, `semver`, `path`, `depends_on`, `verify` (`subject` or `keyed`), `pull_secret`                                   |
| `application_vars[<key>]` | `SCREAMING_SNAKE_CASE` map, rendered as the `<key>-vars` ConfigMap (terraform-reconciled)                               |

There is no `secret_readers` input on GKE: Secret Manager access is granted on the secret itself, so the application
module that creates a container also grants its sync KSA `roles/secretmanager.secretAccessor` on it.

**Registry and verification.** An Artifact Registry url must live under `platform_registry` — the flux controllers
hold read rights on that repository alone, and its tags are listed with the same Workload Identity through the Artifact
Registry API. Any other registry (ghcr.io, an ECR mirror) is listed and pulled generically; `pull_secret` names a
`kubernetes.io/dockerconfigjson` Secret in `flux-system` when it needs credentials. Keyless verification pins the
application repo's publish workflow (the issuer defaults to the platform's); keyed verification (`verify.keyed`) reads
the same `cosign-pub` Secret the platform uses and needs KMS mode. Application keys share one flat namespace with the
platform's Kustomizations and components; the reserved list is identical to terraform-aws-eks-flux's, so an application
name is portable across clouds.

## From another root

[`modules/application`](modules/application/) publishes one application to an existing cluster from a root of its own
(another state, another repository) with nothing changed in the cluster root. The cluster root exports everything it
needs as `application_target`; the application root reads it (through `terraform_remote_state` or any other channel)
and configures a `google` provider and a `helm` provider for the cluster (`examples/application`):

```hcl
module "patchy" {
  source = "git::https://github.com/bitwise-media-group/terraform-google-gke-flux.git//modules/application?ref=vX.Y.Z"

  name    = "patchy"
  cluster = data.terraform_remote_state.cluster.outputs.application_target

  image = {
    url    = "oci://<registry>/manifests/patchy"
    semver = "<1.0.0 >=0.1.0"
    verify = { subject = "^https://github\\.com/bitwise-media-group/patchy-app-manifests/.+$" }
  }

  vars            = { PATCHY_DOMAIN = "patchy.example.com" } # the patchy-vars ConfigMap
  namespaces      = ["patchy", "patchy-agents"]
  workload_grants = module.patchy_app.workload_grants       # project defaults to cluster.project
}
```

It creates exactly what the cluster root would: the bootstrap-only seed (`application-<name>`, the same local chart), a
terraform-reconciled `application-<name>-inputs` release carrying the `<name>-vars` ConfigMap and the namespaces, and
the workload grants' IAM members. An application lives in the cluster root **or** in its own root, never both. The
helm release names collide loudly; the IAM members don't — an IAM member binding is shared, so if two roots declare the
same (member, role) pair, destroying either removes it for both.

## Dex clients

An application registers its OIDC clients itself, by shipping `DexClient` objects in its own image; the platform's
dex-client-controller registers each with dex and writes the credentials to a Secret beside it (`<name>-dex-client`,
keys `clientID`, `clientSecret` and `issuer`). No Secret Manager container, no grant and no cluster apply are involved;
the platform's own clients (flux-web, the workforce client) stay static in `DEX_CLIENTS`. The recipe is in the platform
docs' [Applications](https://oss.bitwisemedia.uk/flux-manifests/applications/#an-identity).

## kubectl through dex

Identity Service for GKE is deprecated (unsupported from GKE 1.37), so kubectl reaches dex through **Workforce
Identity Federation** instead (`sso.kubectl`, `kubectl.tf`): an organization-level workforce pool (`pool_id`, default
`<name>-dex`) whose OIDC provider (`provider_id`, default `dex-oidc`) trusts `https://dex.<PLATFORM_DOMAIN>` through a
confidential dex client (`client_id`, default `gcp-workforce`, published in `DEX_CLIENTS` with Google's workforce
sign-in callback as its redirect URI). The subject is the dex email and `google.groups` the dex groups claim. Every
principal of the pool gets `roles/container.clusterViewer` on the project so `get-credentials` works; RBAC does the
authorization.

```hcl
sso = {
  enabled   = true
  connector = { type = "google" }
  kubectl   = { enabled = true, organization_id = "123456789012" }
}

rbac = {
  groups = {
    admins = "principalSet://iam.googleapis.com/locations/global/workforcePools/patchy-x-dex/group/platform-admins"
  }
}
```

A `principalSet` subject needs no Google Groups RBAC (`rbac.enabled` stays off unless email groups are bound too); the
`kubectl_oidc` output carries the `group_principal_prefix` to build them from. To sign in:

```sh
gcloud iam workforce-pools create-login-config \
  locations/global/workforcePools/<pool>/providers/<provider> --output-file=login.json
gcloud auth login --login-config=login.json
gcloud container clusters get-credentials <name> --location <location> --project <project>
```

The exact commands for a cluster are in `kubectl_oidc.login`. The workforce client's secret rotates with
`sso.clients["<client_id>"].version` like any platform client; changing `pool_id` or `provider_id` replaces the provider
alone, so bump the version in the same apply to keep both halves of the pair in step.

## Development

`make help` lists tasks (`fmt`, `lint`, `test`, `docs`, `pr`). The toolchain submodule (`.mise/`) pins every tool;
`mise trust --all` once per clone.

[flux-operator]: https://github.com/controlplaneio-fluxcd/flux-operator
[patchy]: https://github.com/bitwise-media-group/patchy
[patchy-app-manifests]: https://github.com/bitwise-media-group/patchy-app-manifests
[terraform-aws-eks-flux]: https://github.com/bitwise-media-group/terraform-aws-eks-flux
[flux-containers]: https://github.com/bitwise-media-group/flux-containers
[flux-manifests]: https://github.com/bitwise-media-group/flux-manifests

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| google | >= 7.46, < 8.6 |
| google-beta | >= 7.33, < 8.8 |
| helm | ~> 3.0 |
| random | >= 3.7, < 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.46, < 8.6 |
| google-beta | >= 7.33, < 8.8 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| flux\_operator | ./modules/flux-operator | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [google-beta_google_container_cluster.main](https://registry.terraform.io/providers/hashicorp/google-beta/latest/docs/resources/google_container_cluster) | resource |
| [google_compute_global_address.gateway](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_global_address) | resource |
| [google_container_node_pool.system](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_node_pool) | resource |
| [google_iam_workforce_pool.dex](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/iam_workforce_pool) | resource |
| [google_iam_workforce_pool_provider.dex](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/iam_workforce_pool_provider) | resource |
| [google_kms_crypto_key_iam_member.kyverno_verifiers](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_project_iam_member.kubectl_cluster_viewer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.registry_readers](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.workload](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_secret_manager_secret.dex_client](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret.flux_web_auth_config](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret_iam_member.dex_client_reader](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_secret_manager_secret_iam_member.flux_web_auth_config_reader](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_secret_manager_secret_version.dex_client](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_version) | resource |
| [google_secret_manager_secret_version.flux_web_auth_config](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_version) | resource |
| [google_service_account.nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.dex_directory](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_compute_global_address.gateway](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_global_address) | data source |
| [google_dns_managed_zone.cluster](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/dns_managed_zone) | data source |
| [google_kms_crypto_key_latest_version.signing](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/kms_crypto_key_latest_version) | data source |
| [google_project.cluster](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| location | Region for a regional cluster (e.g. us-central1) or zone for a zonal one (e.g. us-central1-a). The GKE free tier<br/>covers the management fee of one zonal (or Autopilot) cluster per billing account -- a fee regional clusters<br/>always pay. Location is immutable: moving between regional and zonal replaces the cluster. | `string` | n/a | yes |
| name | Cluster name. Also prefixes the node service account and the default gateway address name. | `string` | n/a | yes |
| network | Shared-VPC wiring: network/subnetwork self-links into the HOST project and the names of the GKE secondary ranges on<br/>that subnet (all created by cloud-accounts). | <pre>object({<br/>    network             = string<br/>    subnetwork          = string<br/>    pods_range_name     = string<br/>    services_range_name = string<br/>  })</pre> | n/a | yes |
| platform\_registry | The platform Artifact Registry prefix everything is consumed from (artifact-store module's platform\_registry<br/>output), e.g. us-central1-docker.pkg.dev/o-foundation-7e43/platform (the central store) or a co-located one. | `string` | n/a | yes |
| project | Project ID the cluster lives in (a shared-VPC service project, e.g. x-patchy-app-<rand4>). If not specified, the<br/>provider profile will be used. | `string` | n/a | yes |
| signed\_identity | Cosign verification identity for every platform artifact — exactly one of two modes.<br/><br/>KEYLESS (subjects set, kms\_key\_name null): Go regexps matched against the Fulcio certificate of GitHub Actions OIDC<br/>signatures. The artifact-store module's signed\_identity\_subjects output provides the subjects; the issuer default<br/>matches GitHub Actions. Cloud agnostic — the signing identities are GitHub's, not Google's, so the same values<br/>serve clusters on any cloud.<br/><br/>KMS (kms\_key\_name set, subjects null): the publish workflows sign with an asymmetric SIGN Cloud KMS key<br/>(cosign sign --key gcpkms://<name>; the artifact-store module's signing\_kms\_key\_name grants the publishers<br/>signerVerifier). The key's public half is distributed to the cluster as the flux-system cosign-pub Secret for the<br/>bootstrap verify patch, the key name is published as the SIGNED\_IDENTITY\_KMS\_KEY cluster var, and kyverno's<br/>controllers get cloudkms verifier/viewer on the key to resolve it at admission time. | <pre>object({<br/>    issuer             = optional(string, "^https://token\\.actions\\.githubusercontent\\.com$")<br/>    manifests_subject  = optional(string)<br/>    containers_subject = optional(string)<br/>    kms_key_name       = optional(string)<br/>  })</pre> | n/a | yes |
| application\_vars | Per-application substitution values, keyed by application short name: each entry is rendered as the <key>-vars<br/>ConfigMap in flux-system (terraform-reconciled through cluster-inputs, so changes flow through applies), which the<br/>application's Kustomization substitutes from beside cluster-vars. Keys are top-level rather than nested in<br/>applications so a composite image's inner applications can each have their own ConfigMap. Keys must be<br/>SCREAMING\_SNAKE\_CASE, matching the substitution syntax; an application's own module typically emits this map. | `map(map(string))` | `{}` | no |
| applications | Application manifest images this cluster seeds, keyed by the application's short name. Each entry creates a<br/>bootstrap-only seed in flux-system (a ResourceSetInputProvider and ResourceSet named <key>-manifests) that<br/>resolves the newest tag matching semver, verifies the image's cosign signature and applies path from it as<br/>Kustomization <key>; the image ships the same two seed objects under flux/ and owns them from its first<br/>reconcile, so a new application release never needs a terraform apply. Removing a key uninstalls the seed and<br/>prunes the application. The entry is applied once and then ignored (ignore\_changes), exactly like the<br/>flux-operator and flux-instance releases.<br/>  - url: the image without a tag or digest. An Artifact Registry url must live under platform\_registry (the flux<br/>    controllers pull it with their Workload Identity and list its tags through the Artifact Registry API); any<br/>    other registry is listed and pulled generically, optionally with pull\_secret (a<br/>    kubernetes.io/dockerconfigjson Secret in flux-system that both the tag listing and the pull read).<br/>  - semver: the tag range the seed follows (default >=0.0.0); a range matching no tag prunes the application.<br/>  - path: the Kustomization path inside the image (default ./deploy/<flux.sync.path>, the same per-cloud tree<br/>    selector the platform uses, published as PLATFORM\_TREE).<br/>  - depends\_on: platform Kustomizations the application waits for (default kyverno-policies).<br/>  - verify: keyless (subject, a Fulcio certificate-subject regexp; issuer defaults to signed\_identity.issuer)<br/>    XOR keyed (the cosign-pub public-key Secret, KMS mode only).<br/>Application vars ride separately in application\_vars, so a composite image's inner applications can each have<br/>their own ConfigMap. An application registers its dex clients itself, as DexClient objects in its own image<br/>(the platform's dex-client-controller reconciles them). An application can instead be published from a root of<br/>its own with modules/application and this module's application\_target output - never from both. | <pre>map(object({<br/>    url        = string<br/>    semver     = optional(string, ">=0.0.0")<br/>    path       = optional(string)<br/>    interval   = optional(string, "30m")<br/>    depends_on = optional(set(string), ["kyverno-policies"])<br/>    verify = object({<br/>      issuer  = optional(string)<br/>      subject = optional(string)<br/>      keyed   = optional(bool, false)<br/>    })<br/>    pull_secret = optional(string)<br/>    prune       = optional(bool, true)<br/>    wait        = optional(bool, true)<br/>    timeout     = optional(string, "5m")<br/>  }))</pre> | `{}` | no |
| deletion\_protection | Terraform-level destroy protection for the cluster. Off by default: this environment is disposable by design. | `bool` | `false` | no |
| dns | Existing delegated Cloud DNS zone (created by cloud-accounts; never owned here). zone\_name enables the DNS/TLS<br/>surface: external-dns + cert-manager IAM grants and the DNS\_* / PLATFORM\_DOMAIN cluster vars. host optionally<br/>narrows the served host below the zone apex (PLATFORM\_DOMAIN, the parent of the dex. and flux. hosts). | <pre>object({<br/>    zone_name  = optional(string)<br/>    host       = optional(string)<br/>    acme_email = optional(string)<br/>  })</pre> | `{}` | no |
| flux | Flux bootstrap knobs. Chart repositories, the distribution registry and the sync url default onto platform\_registry;<br/>sync.ref picks the release channel (stable, staging, or edge for dev clusters tracking trunk -- pair edge with the<br/>manifests\_edge signing subject); sync.url defaults to the platform entrypoint image<br/>oci://<platform\_registry>/manifests/platform (flux-manifests >= 4.0.0), published as FLUX\_SYNC\_URL so the<br/>platform's flux component can re-point a running cluster; sync.path selects the per-cloud tree inside it<br/>("google"), published as PLATFORM\_TREE and the default ./deploy/<path> of every application image. namespaces are<br/>pre-created by the cluster-inputs chart ahead of the platform. | <pre>object({<br/>    operator_chart = optional(object({<br/>      repository = optional(string)<br/>      version    = optional(string)<br/>    }), {})<br/>    instance_chart = optional(object({<br/>      repository = optional(string)<br/>      version    = optional(string)<br/>    }), {})<br/>    distribution = optional(object({<br/>      version  = optional(string, "2.x")<br/>      registry = optional(string)<br/>      artifact = optional(string)<br/>    }), {})<br/>    sync = optional(object({<br/>      url      = optional(string)<br/>      ref      = optional(string, "stable")<br/>      path     = optional(string, "google")<br/>      interval = optional(string, "5m")<br/>    }), {})<br/>    kustomize_patches = optional(list(any), [])<br/>    cluster_vars      = optional(map(string), {})<br/>    namespaces        = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| gateway | The platform Gateway's global static IP, stable across cluster recreation. Reserve one here (default; address\_name<br/>defaults to <name>-gateway) or reference an existing address by name with reserve\_static\_ip = false (e.g.<br/>cloud-accounts' `ingress` address in x-patchy-app). | <pre>object({<br/>    reserve_static_ip = optional(bool, true)<br/>    address_name      = optional(string)<br/>  })</pre> | `{}` | no |
| kubernetes\_version | Optional minimum master version pin; null lets the release channel govern. | `string` | `null` | no |
| labels | Resource labels applied to the cluster. | `map(string)` | `{}` | no |
| managed\_opentelemetry | Enable Managed OpenTelemetry for GKE (Preview): Google's in-cluster OTLP pipeline (HTTP endpoint<br/>opentelemetry-collector.gke-managed-otel:4318) shipping traces/logs/metrics to the CLUSTER project's Cloud<br/>Trace/Logging/Monitoring -- it cannot target observability.project. Per-cluster pilot toggle for retiring the<br/>self-hosted otel-collector component; requires GKE >= 1.34.1-gke.2178000. | `bool` | `false` | no |
| master\_authorized\_networks | CIDRs allowed to reach the public control-plane endpoint. Empty leaves the endpoint open (PoC posture) — constrain<br/>it as soon as a stable egress CIDR exists. | <pre>list(object({<br/>    cidr_block   = string<br/>    display_name = optional(string)<br/>  }))</pre> | `[]` | no |
| node\_auto\_provisioning | Node auto-provisioning (NAP) limits for workload capacity — the cluster-wide ceilings across all auto-provisioned<br/>pools. | <pre>object({<br/>    min_cpu        = optional(number, 0)<br/>    max_cpu        = optional(number, 64)<br/>    min_memory_gib = optional(number, 0)<br/>    max_memory_gib = optional(number, 256)<br/>    disk_size_gib  = optional(number, 100)<br/>  })</pre> | `{}` | no |
| observability | Optional central observability project the otel-collector writes telemetry to; null targets the cluster's own<br/>project. | <pre>object({<br/>    project = optional(string)<br/>  })</pre> | `{}` | no |
| platform\_components | The platform manifests' electable-tier components (short names: flux-web, arc) this cluster elects, published as<br/>the PLATFORM\_COMPONENTS cluster var. The platform entrypoint's ResourceSet ranges over the election: an elected<br/>component gets its own OCIRepository (oci://<registry>/manifests/<name>) and Kustomization. Electing none is<br/>explicit - set []. dex is not elected here: it deploys exactly when sso is enabled, and without it the elected<br/>components still run, just with no SSO auth and no human-facing HTTPRoute (kubectl port-forward to reach). The core<br/>tier (flux, kyverno, kyverno-policies, cert-manager, cert-manager-issuers, external-dns, gateway, rbac, secret-sync,<br/>otel-collector) is never electable. Applications are not components: they arrive through var.applications as<br/>their own images. | `set(string)` | <pre>[<br/>  "flux-web"<br/>]</pre> | no |
| private\_endpoint | Serve the control-plane endpoint privately only. Off by default so terraform/helm bootstrap works without a VPN path<br/>into the shared VPC. | `bool` | `false` | no |
| rbac | Google Groups for RBAC, off by default. When enabled, the cluster authenticator trusts gke-security-groups@<domain><br/>— the exact name is a GKE requirement. The group itself and the member groups usable as Role/ClusterRoleBinding<br/>subjects are managed out-of-band in Workspace, never here. groups names the per-role subject groups published to<br/>the platform manifests as RBAC\_GROUP\_<ROLE> cluster vars, verbatim. Each is either a Google Group email -- nested<br/>under the fleet group (out-of-band) for the authenticator to honour it, so it requires enabled -- or a workforce<br/>identity group principal set (principalSet://iam.googleapis.com/locations/global/workforcePools/<pool>/group/<group>,<br/>the kubectl\_oidc output's group\_principal\_prefix plus a dex group), which GKE resolves through workforce identity<br/>federation (sso.kubectl) with no Google Groups RBAC involved. | <pre>object({<br/>    enabled = optional(bool, false)<br/>    domain  = optional(string)<br/>    groups = optional(object({<br/>      viewers    = optional(string)<br/>      developers = optional(string)<br/>      devops     = optional(string)<br/>      admins     = optional(string)<br/>    }), {})<br/>  })</pre> | `{}` | no |
| release\_channel | GKE release channel (RAPID, REGULAR, STABLE). | `string` | `"REGULAR"` | no |
| secret\_prefix | Prefix for every Secret Manager container name the platform and its applications sync, published as the<br/>SECRET\_PREFIX cluster var (resourceNames become <prefix><container>). Lets multiple clusters share one project with<br/>distinct secrets; the modules/sso-secrets instantiation (a durable root, holding the out-of-band dex connector<br/>credentials) and every application module creating containers must use the same prefix (the secret\_prefix<br/>output). Include the trailing separator (e.g. 'platform-x-'); empty keeps the unprefixed names. | `string` | `null` | no |
| secret\_sync | Enable the Secret Manager CSI add-on plus GKE Integrated Secret Synchronization -- the SecretProviderClass and<br/>SecretSync CRDs the platform manifests (dex, flux-web) and applications use to materialise Secret Manager secrets<br/>as Kubernetes Secrets. Requires GKE >= 1.33 and Workload Identity (always on here). The generated dex client<br/>secrets live in this module (sso.tf); the out-of-band dex connector containers come from modules/sso-secrets,<br/>instantiated in a durable root; an application's containers and their accessor grants come from its own module<br/>-- whoever creates a container grants its sync KSA, resource-side. | `bool` | `true` | no |
| sso | Platform SSO: deploys dex as the OIDC identity provider and wires the platform's relying parties to it --<br/>generated client pairs (sso.tf), the DEX\_CONNECTORS/DEX\_CLIENTS/DEX\_DIRECTORY\_SA cluster vars, and the<br/>human-facing HTTPRoutes. Upstream identity is arbitrary: connector declares the deployment's single upstream IdP<br/>-- which connector type a deployment federates isn't known ahead of time, but it only ever federates one --<br/>  - type: the dex connector type (oidc, saml, google, microsoft, github, ...), passed through verbatim, not<br/>    validated against dex's own supported list.<br/>  - id: the dex connector id, also the naming stem for the credential containers (dex-<id>-<field>) and env vars;<br/>    defaults to type -- set it when the type alone reads poorly (e.g. id = "okta" for an oidc connector).<br/>  - name: the display name shown on dex's login screen; defaults to the connector id when unset.<br/>  - config: the connector's own config: block, passed through near-verbatim (issuer, clientID, scopes,<br/>    claimMapping, adminEmail, ...) -- a redirectURI is injected by default (sso.tf) unless the caller sets one.<br/>    Values keep their native types (bools, lists, numbers) all the way into dex's rendered YAML, e.g.<br/>    fetchTransitiveGroupMembership = true stays a bool.<br/>  - secrets: the out-of-band credential fields this connector needs (default ["client-id", "client-secret"]).<br/>    Each field becomes a dex-<id>-<field> Secret Manager container (modules/sso-secrets, instantiated in a durable<br/>    root -- an OAuth client cannot be terraformed) and a <ID>\_<FIELD> env var (uppercased, dashes -> underscores)<br/>    dex expands from its own process env at startup ($<ID>\_<FIELD>) -- reference it yourself, e.g.<br/>    config.clientID = "$GOOGLE\_CLIENT\_ID".<br/>directory\_sa is the keyless Workspace directory-reader service account dex's google connector impersonates for<br/>group claims (domain-wide delegation) -- independently optional, only relevant to a google-typed connector. When<br/>set, this module binds workloadIdentityUser on it for the cluster's dex KSA (sso.tf): the applying identity needs<br/>the get/setIamPolicy delegation cloud-accounts grants the app's terraform-apply container on that SA. Requires the<br/>DNS surface: the issuer and redirect URLs need the served domain.<br/>kubectl turns on kubectl through dex via Workforce Identity Federation (kubectl.tf): a workforce pool (pool\_id,<br/>default <name>-dex) under organization\_id whose OIDC provider (provider\_id) trusts dex as its issuer through a<br/>confidential dex client (client\_id, published in DEX\_CLIENTS). Users sign in with gcloud's workforce login config<br/>and reach the cluster with get-credentials; RBAC binds their dex groups as principalSet subjects (rbac.groups).<br/>clients holds the per-client knobs for the generated confidential pairs (keys: flux-web and, when kubectl is on,<br/>its client\_id) -- today just version, the client secret's rotation counter (absent clients sit at 1): bump it to<br/>mint a new client secret; the raw dex-client-<id> container and every consumer written from the same value (the<br/>flux-web config document, the workforce provider) rewrite in one apply, so the pair cannot drift (then restart<br/>dex: it reads client secrets from env at startup).<br/>Application clients are not here: an application ships DexClient objects in its own image, and the platform's<br/>dex-client-controller registers them. | <pre>object({<br/>    enabled = optional(bool, false)<br/>    connector = optional(object({<br/>      id      = optional(string)<br/>      type    = string<br/>      name    = optional(string)<br/>      config  = optional(any, {})<br/>      secrets = optional(set(string), ["client-id", "client-secret"])<br/>    }))<br/>    directory_sa = optional(string)<br/>    kubectl = optional(object({<br/>      enabled         = optional(bool, false)<br/>      organization_id = optional(string)<br/>      pool_id         = optional(string)<br/>      provider_id     = optional(string, "dex-oidc")<br/>      client_id       = optional(string, "gcp-workforce")<br/>    }), {})<br/>    clients = optional(map(object({<br/>      version = number<br/>    })), {})<br/>  })</pre> | `{}` | no |
| system\_node\_pool | The always-on system node pool platform controllers pin to (label role=system). Autoscaling counts are per zone in<br/>a regional pool. | <pre>object({<br/>    machine_type  = optional(string, "e2-standard-2")<br/>    min_size      = optional(number, 1)<br/>    max_size      = optional(number, 2)<br/>    initial_size  = optional(number, 1)<br/>    disk_size_gib = optional(number, 50)<br/>  })</pre> | `{}` | no |
| workload\_grants | Application workload IAM grants, keyed by a short name: each (entry, role) pair becomes one project-level IAM<br/>member binding of the role to the namespace/service-account pair as a direct Workload Identity Federation<br/>principal (principal://.../subject/ns/<namespace>/sa/<service\_account>), in project (default: the cluster's own).<br/>This is how an application module hands its cloud permissions to the cluster (e.g. aiplatform.user for an egress<br/>broker): the module emits the map, the root wires it here, and nothing application-specific lives in this module.<br/>The platform's own pairs (external-dns, cert-manager, kyverno, otel-collector) are fixed by workload\_identity and<br/>are not declared here. Secret Manager reads are not a grant shape: whoever creates a secret container grants its<br/>sync KSA accessor on it, resource-side. | <pre>map(object({<br/>    namespace       = string<br/>    service_account = string<br/>    roles           = list(string)<br/>    project         = optional(string)<br/>  }))</pre> | `{}` | no |
| workload\_identity | Namespace/service-account pairs the direct Workload Identity grants bind to — the terraform <-> platform manifests<br/>contract. Override only to track a manifests change. | <pre>object({<br/>    external_dns = optional(object({<br/>      namespace       = optional(string, "external-dns")<br/>      service_account = optional(string, "external-dns")<br/>    }), {})<br/>    cert_manager = optional(object({<br/>      namespace       = optional(string, "cert-manager")<br/>      service_account = optional(string, "cert-manager")<br/>    }), {})<br/>    otel_collector = optional(object({<br/>      namespace       = optional(string, "otel-collector")<br/>      service_account = optional(string, "otel-collector")<br/>    }), {})<br/>    kyverno = optional(object({<br/>      namespace = optional(string, "kyverno")<br/>      # the controllers that fetch image signatures from the registry at<br/>      # admission/report time<br/>      service_accounts = optional(list(string), ["kyverno-admission-controller", "kyverno-reports-controller"])<br/>    }), {})<br/>    # dex impersonates the directory-reader SA via the classic<br/>    # annotation-based flow, so its pair binds workloadIdentityUser on that<br/>    # SA (sso.tf) instead of receiving a direct principal:// grant<br/>    dex = optional(object({<br/>      namespace       = optional(string, "dex")<br/>      service_account = optional(string, "dex")<br/>    }), {})<br/>  })</pre> | `{}` | no |
| zones | Optional zone narrowing for node locations (cost control); null runs nodes in every zone of the region (regional<br/>clusters) or in the control-plane zone alone (zonal clusters). | `set(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| application\_target | Everything modules/application needs to publish an application to this cluster from a root of its own: the<br/>cluster name, the flux namespace, the platform registry, the per-cloud tree (flux.sync.path), the keyless<br/>signing issuer (null in KMS mode), whether the cluster is KMS-keyed, the project, project number and Workload<br/>Identity pool its workload grants bind principals in, and the SECRET\_PREFIX. Pass it to the module's cluster<br/>input verbatim. |
| ca\_certificate | Base64-encoded cluster CA certificate. |
| dns | Delegated zone wiring (null when dns.zone\_name is unset): zone name, apex domain, served host (PLATFORM\_DOMAIN) and the zone's name servers. |
| endpoint | Control-plane endpoint IP (host for the helm/kubernetes providers). |
| flux | Flux bootstrap facts: the namespace, the platform entrypoint the FluxInstance syncs, the electable components in<br/>force, the application seeds (per key: the seed release, its tag-listing and pull providers and the resolved<br/>path) and the exact cluster-vars contract this cluster publishes to the platform. |
| gateway | The Gateway address in use — reserved here or referenced from an existing reservation (null when neither). |
| kubectl\_oidc | kubectl-via-dex wiring (null unless sso.kubectl.enabled): the workforce pool and provider resource names, the<br/>group principal-set prefix an rbac.groups entry reached this way carries (append the dex group, e.g.<br/>"<prefix>platform-admins"), and the login steps:<br/><br/>  gcloud iam workforce-pools create-login-config <provider> --output-file=login.json<br/>  gcloud auth login --login-config=login.json<br/>  gcloud container clusters get-credentials <name> --location <location> --project <project> |
| kubernetes\_version | Current master version. |
| name | Cluster name. |
| node\_service\_account | The dedicated node service account (system pool + auto-provisioned pools). |
| platform\_registry | The platform registry prefix (pass-through of var.platform\_registry). |
| rbac | RBAC subjects (null unless rbac.enabled or a group is set): the fleet group the Google Groups authenticator trusts (empty when Google Groups RBAC is off) and the per-role subject groups published as RBAC\_GROUP\_* cluster vars. A Google Group email must be nested under the fleet group (out-of-band, in Workspace) to be usable as a Role/ClusterRoleBinding subject; a workforce principalSet (sso.kubectl) needs no nesting. |
| registry\_reader\_members | Every identity that reads the platform registry (node SA, flux controllers, kyverno controllers). Granted automatically either way: in-project when the registry is co-located, or on the registry's project (registry\_readers, via the org's reader-constrained delegation) when it is central. Exported for visibility and for feeding artifact-store reader\_members where the delegation is not in place. |
| secret\_prefix | The normalized Secret Manager container-name prefix (var.secret\_prefix, or the empty string), published as<br/>SECRET\_PREFIX. Application modules and roots compose container names as <prefix><name> from this rather than<br/>re-deriving the rule. |
| sso | SSO facts this cluster owns (null unless sso.enabled): the dex issuer, the platform's static clients (as<br/>published in DEX\_CLIENTS; application clients are DexClient objects and never appear here), the generated<br/>dex-client-<id> container ids for the confidential ones and the composed config documents. The out-of-band<br/>dex-<id>-<field> connector containers live in modules/sso-secrets (a durable root), fed the same sso value. |
| workload\_identity\_pool | The cluster's workload identity pool (<project>.svc.id.goog). |
| workload\_members | The direct Workload Identity Federation principal of every workload grant this module binds, keyed as in<br/>iam.tf: the platform grants and each workload\_grants entry (by its key). For granting these identities further<br/>access resource-side (a secret container's accessor, a bucket's reader). |
<!-- END_TF_DOCS -->
