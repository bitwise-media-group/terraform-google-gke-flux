# terraform-google-gke-flux

A GKE Standard cluster that bootstraps [flux-operator] and syncs a cosign-signed OCI manifests artifact from Artifact
Registry — the platform substrate for deploying [patchy] to Google Cloud. The GKE analogue of the arc reference
architecture, with keyless signing in place of KMS.

Three repos make the platform:

| repo                                 | role                                                                                                |
| ------------------------------------ | --------------------------------------------------------------------------------------------------- |
| **terraform-google-gke-flux** (this) | the cluster, the artifact store and the flux bootstrap                                              |
| [flux-containers]                    | vendors, scans, mirrors and keyless-signs charts + images into the artifact store                   |
| [flux-manifests]                     | the GitOps stack every cluster syncs (kyverno, cert-manager, external-dns, gateway, otel-collector) |

## Design

- **GKE Standard, regional, VPC-native** on a shared-VPC subnet (created by cloud-accounts), Dataplane V2 (built-in
  Cilium), Workload Identity, private nodes behind Cloud NAT. A small always-on **system node pool** (`role=system`)
  carries the platform controllers; **node auto-provisioning** scales everything else.
- **One Artifact Registry docker repository** (`platform`) holds mirrored charts (`charts/<name>`), digest-pinned
  mirrored images (`images/<original-path>`) and the `flux-manifests` sync artifact.
- **Cosign keyless everywhere**: artifacts are signed by GitHub Actions OIDC identities (Fulcio/Rekor, public
  transparency log — these repos are public). The generated `flux-system` OCIRepository verifies the manifests artifact
  via `matchOIDCIdentity`; the stack's OCIRepositories and Kyverno policy verify charts and images the same way. No KMS,
  no key distribution.
- **Direct Workload Identity Federation grants** for in-cluster workloads (`principal://…/ns/<ns>/sa/<ksa>`): no GSAs,
  no `iam.gke.io/gcp-service-account` annotations. Real service accounts exist only for the GitHub Actions publishers
  and the nodes.
- **Google Groups for RBAC (off by default)**: `rbac.enabled` + `rbac.domain` point the cluster authenticator at
  `gke-security-groups@<domain>` — the exact name is a GKE requirement. The group itself and the member groups nested
  under it (transitively usable as `Role`/`ClusterRoleBinding` subjects) are managed out-of-band in Workspace, never
  here. `rbac.groups` names the per-role subject groups (viewers, developers, devops, admins) and publishes each as an
  `RBAC_GROUP_<ROLE>` cluster var, so flux-manifests can template the bindings without hard-coding group emails.
- **DNS/TLS survives cluster recreation**: the delegated Cloud DNS zone lives in cloud-accounts and the Gateway's global
  static IP lives beside it (referenced here by name) — destroy/recreate serves the same domain again with no manual
  action.

## Bootstrap order

There is no blueprints repo; this is the canonical ordering:

1. **cloud-accounts**: the `x-patchy-app` project with shared-VPC subnet + GKE secondary ranges, **Cloud NAT** on the
   shared VPC (private nodes need egress for Sigstore/ACME/GitHub), the APIs (`dns`, `artifactregistry`, `cloudtrace`),
   the delegated Cloud DNS zone (`patchy.bitwisemedia.co.uk`, NS records at the parent added once), the `ingress`
   global static IP, and the org WIF trust anchor (`github_wif` output — the artifact-store module's required `wif`
   input; the pool/provider are never created outside cloud-accounts).
2. **artifact store** (`examples/artifact-store`): apply as the project's `terraform-apply` SA. Feed its outputs to the
   publishing repos as the `GCP_WIF_PROVIDER` / `GCP_CHART_PUBLISHER_SA` / `GCP_MANIFEST_PUBLISHER_SA` /
   `PLATFORM_REGISTRY` org-level Actions variables.
3. **flux-containers**: publish every chart + image
   (`charts/{flux-operator,flux-instance,kyverno,cert-manager,external-dns,opentelemetry-collector}` and their images).
4. **flux-manifests**: cut the first release; its publish workflow pushes the signed artifact and moves the `staging`
   channel tag (promote moves `stable`).
5. **cluster** (`examples/complete` is the shape): `terraform apply` — one apply bootstraps flux-operator, which syncs
   the stack and brings up the platform. The operator/instance releases are bootstrap-only (`ignore_changes`): the
   stack's flux component adopts them and follows the newest mirrored charts, so flux upgrades ship by publishing to
   the registry, never by terraform.

## The terraform ↔ flux contract

The `cluster-vars` ConfigMap (flux-system) publishes these to the stack; the authoritative consumer table lives in the
flux-manifests README:

`CLUSTER_NAME`, `GCP_PROJECT`, `GCP_PROJECT_NUMBER`, `GCP_REGION`, `PLATFORM_REGISTRY`, `CONTAINER_REGISTRY`,
`SIGNED_IDENTITY_ISSUER`, `SIGNED_IDENTITY_CHARTS`, `SIGNED_IDENTITY_IMAGES`, `SIGNED_IDENTITY_MANIFESTS`,
`FLUX_SYNC_CHANNEL`, `DNS_ZONE_NAME`, `DNS_DOMAIN`, `PATCHY_DOMAIN`, `ACME_EMAIL`, `GATEWAY_ADDRESS_NAME`,
`GATEWAY_IP`, `OTEL_PROJECT`, `RBAC_GROUP_VIEWERS`, `RBAC_GROUP_DEVELOPERS`, `RBAC_GROUP_DEVOPS`,
`RBAC_GROUP_ADMINS`, `SECRET_PREFIX`, `STACK_COMPONENTS` — optional surfaces use the empty-string convention.
`SIGNED_IDENTITY_MANIFESTS` and `FLUX_SYNC_CHANNEL` feed the manifests' flux component (flux managing flux): it
re-renders the FluxInstance this module bootstraps, so the sync verify subject and release channel must reach the
stack. `SECRET_PREFIX` (`secret_prefix`) prefixes every Secret Manager container the stack syncs, so
clusters sharing a project keep distinct secrets. `STACK_COMPONENTS` (`stack_components`) elects the manifests'
optional tier by short name (`flux-web`, `patchy`); the default elects the whole tier, and an explicit `[]` publishes
the reserved name `none` (an empty string would re-trigger the manifests' elect-everything default). dex is not
elected directly: it deploys exactly when `sso` is enabled (which also publishes the typed `DEX_DIRECTORY_SA`), and
without it the elected components still run -- no SSO auth, no human-facing HTTPRoute, kubectl port-forward to reach.
Callers may add extras (e.g. `*_SEMVER` range pins) via `flux.cluster_vars`; reserved keys always win. The published
contract is exported as `flux.cluster_vars` in the module outputs for inspection.

When `sso` is enabled the module also binds `roles/iam.workloadIdentityUser` on the directory-reader SA for the
cluster's dex KSA (`sso.tf`) — the applying identity writes that one SA's policy through the get/setIamPolicy
delegation cloud-accounts grants the app's terraform-apply container, so a new cluster enables dex without a
cloud-accounts change.

The module also generates the per-cluster SSO client pairs between dex and its in-cluster relying parties (`sso.tf`):
ephemeral random client secrets written through write-only Secret Manager versions (never in state or plan), the
composed `flux-web-auth-config` Web Config document and the secretless `patchy-status-auth-config` document, plus the
accessor grants for the syncing KSAs. They follow the `stack_components` election and `secret_prefix`, and rotate via
`sso.client_rotation` (bump a counter; both sides of a pair rewrite in one apply — then restart dex, which reads client
secrets from env at startup). Deletion is immediate (no delayed-destroy cooldown), so cluster destroy/recreate mints
fresh pairs without manual cleanup.

Workload identity namespace/service-account pairs (overridable via `workload_identity`): `external-dns/external-dns` and
`cert-manager/cert-manager` (→ `roles/dns.admin`), `otel-collector/otel-collector` (→ monitoring/logging/trace writers),
`kyverno/kyverno-{admission,reports}-controller` and `flux-system/{source-controller,flux-operator}` (→
`roles/artifactregistry.reader`), and `dex/dex` (→ `workloadIdentityUser` on the directory-reader SA — the classic
annotation-based flow, since dex must impersonate the SA rather than hold a grant).

## Development

`make help` lists tasks (`fmt`, `lint`, `validate`, `test`, `docs`, `pr`). The toolchain submodule (`.mise/`) pins every
tool; `mise trust --all` once per clone.

[flux-operator]: https://github.com/controlplaneio-fluxcd/flux-operator
[patchy]: https://github.com/bitwise-media-group/patchy
[flux-containers]: https://github.com/bitwise-media-group/flux-containers
[flux-manifests]: https://github.com/bitwise-media-group/flux-manifests

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| google | >= 7.0, < 8.0 |
| google-beta | >= 7.33, < 8.0 |
| helm | ~> 3.0 |
| random | >= 3.7, < 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.0, < 8.0 |
| google-beta | >= 7.33, < 8.0 |

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
| [google_kms_crypto_key_iam_member.kyverno_verifiers](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_project_iam_member.nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.registry_readers](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.workload](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_secret_manager_secret.dex_client](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret.flux_web_auth_config](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret.patchy_status_auth_config](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret_iam_member.dex_client_reader](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_secret_manager_secret_iam_member.flux_web_auth_config_reader](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_secret_manager_secret_iam_member.patchy_status_auth_config_reader](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_secret_manager_secret_version.dex_client](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_version) | resource |
| [google_secret_manager_secret_version.flux_web_auth_config](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_version) | resource |
| [google_secret_manager_secret_version.patchy_status_auth_config](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_version) | resource |
| [google_service_account.nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.dex_directory](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_compute_global_address.gateway](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_global_address) | data source |
| [google_dns_managed_zone.cluster](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/dns_managed_zone) | data source |
| [google_kms_crypto_key_latest_version.signing](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/kms_crypto_key_latest_version) | data source |
| [google_project.cluster](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| name | Cluster name. Also prefixes the node service account and the default gateway address name. | `string` | n/a | yes |
| network | Shared-VPC wiring: network/subnetwork self-links into the HOST project and the names of the GKE secondary ranges on<br/>that subnet (all created by cloud-accounts). | <pre>object({<br/>    network             = string<br/>    subnetwork          = string<br/>    pods_range_name     = string<br/>    services_range_name = string<br/>  })</pre> | n/a | yes |
| platform\_registry | The platform Artifact Registry prefix everything is consumed from (artifact-store module's platform\_registry<br/>output), e.g. us-central1-docker.pkg.dev/o-foundation-7e43/platform (the central store) or a co-located one. | `string` | n/a | yes |
| project | Project ID the cluster lives in (a shared-VPC service project, e.g. x-patchy-app-<rand4>). If not specified, the<br/>provider profile will be used. | `string` | n/a | yes |
| region | Region for the (regional) cluster, e.g. us-central1. | `string` | n/a | yes |
| signed\_identity | Cosign verification identity for every platform artifact — exactly one of two modes.<br/><br/>KEYLESS (subjects set, kms\_key\_name null): Go regexps matched against the Fulcio certificate of GitHub Actions OIDC<br/>signatures. The artifact-store module's signed\_identity\_subjects output provides the subjects; the issuer default<br/>matches GitHub Actions. Cloud agnostic — the signing identities are GitHub's, not Google's, so the same values<br/>serve clusters on any cloud.<br/><br/>KMS (kms\_key\_name set, subjects null): the publish workflows sign with an asymmetric SIGN Cloud KMS key<br/>(cosign sign --key gcpkms://<name>; the artifact-store module's signing\_kms\_key\_name grants the publishers<br/>signerVerifier). The key's public half is distributed to the cluster as the flux-system cosign-pub Secret for the<br/>bootstrap verify patch, the key name is published as the SIGNED\_IDENTITY\_KMS\_KEY cluster var, and kyverno's<br/>controllers get cloudkms verifier/viewer on the key to resolve it at admission time. | <pre>object({<br/>    issuer             = optional(string, "^https://token\\.actions\\.githubusercontent\\.com$")<br/>    manifests_subject  = optional(string)<br/>    containers_subject = optional(string)<br/>    kms_key_name       = optional(string)<br/>  })</pre> | n/a | yes |
| deletion\_protection | Terraform-level destroy protection for the cluster. Off by default: this environment is disposable by design. | `bool` | `false` | no |
| dns | Existing delegated Cloud DNS zone (created by cloud-accounts; never owned here). zone\_name enables the DNS/TLS<br/>surface: external-dns + cert-manager IAM grants and the DNS\_* / PATCHY\_DOMAIN cluster vars. host optionally narrows<br/>the served host below the zone apex. | <pre>object({<br/>    zone_name  = optional(string)<br/>    host       = optional(string)<br/>    acme_email = optional(string)<br/>  })</pre> | `{}` | no |
| flux | Flux bootstrap knobs. Chart repositories, the distribution registry and the sync url default onto platform\_registry;<br/>sync.ref picks the release channel (stable, staging, or edge for dev clusters tracking trunk -- pair edge with the<br/>manifests\_edge signing subject). | <pre>object({<br/>    operator_chart = optional(object({<br/>      repository = optional(string)<br/>      version    = optional(string)<br/>    }), {})<br/>    instance_chart = optional(object({<br/>      repository = optional(string)<br/>      version    = optional(string)<br/>    }), {})<br/>    distribution = optional(object({<br/>      version  = optional(string, "2.x")<br/>      registry = optional(string)<br/>      artifact = optional(string)<br/>    }), {})<br/>    sync = optional(object({<br/>      url      = optional(string)<br/>      ref      = optional(string, "stable")<br/>      path     = optional(string, "stack")<br/>      interval = optional(string, "5m")<br/>    }), {})<br/>    kustomize_patches = optional(list(any), [])<br/>    cluster_vars      = optional(map(string), {})<br/>    namespaces        = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| gateway | The platform Gateway's global static IP, stable across cluster recreation. Reserve one here (default; address\_name<br/>defaults to <name>-gateway) or reference an existing address by name with reserve\_static\_ip = false (e.g.<br/>cloud-accounts' `ingress` address in x-patchy-app). | <pre>object({<br/>    reserve_static_ip = optional(bool, true)<br/>    address_name      = optional(string)<br/>  })</pre> | `{}` | no |
| kubernetes\_version | Optional minimum master version pin; null lets the release channel govern. | `string` | `null` | no |
| labels | Resource labels applied to the cluster. | `map(string)` | `{}` | no |
| managed\_opentelemetry | Enable Managed OpenTelemetry for GKE (Preview): Google's in-cluster OTLP pipeline (HTTP endpoint<br/>opentelemetry-collector.gke-managed-otel:4318) shipping traces/logs/metrics to the CLUSTER project's Cloud<br/>Trace/Logging/Monitoring -- it cannot target observability.project. Per-cluster pilot toggle for retiring the<br/>self-hosted otel-collector component; requires GKE >= 1.34.1-gke.2178000. | `bool` | `false` | no |
| master\_authorized\_networks | CIDRs allowed to reach the public control-plane endpoint. Empty leaves the endpoint open (PoC posture) — constrain<br/>it as soon as a stable egress CIDR exists. | <pre>list(object({<br/>    cidr_block   = string<br/>    display_name = optional(string)<br/>  }))</pre> | `[]` | no |
| node\_auto\_provisioning | Node auto-provisioning (NAP) limits for workload capacity — the cluster-wide ceilings across all auto-provisioned<br/>pools. | <pre>object({<br/>    min_cpu        = optional(number, 0)<br/>    max_cpu        = optional(number, 64)<br/>    min_memory_gib = optional(number, 0)<br/>    max_memory_gib = optional(number, 256)<br/>    disk_size_gib  = optional(number, 100)<br/>  })</pre> | `{}` | no |
| observability | Optional central observability project the otel-collector writes telemetry to; null targets the cluster's own<br/>project. | <pre>object({<br/>    project = optional(string)<br/>  })</pre> | `{}` | no |
| private\_endpoint | Serve the control-plane endpoint privately only. Off by default so terraform/helm bootstrap works without a VPN path<br/>into the shared VPC. | `bool` | `false` | no |
| rbac | Google Groups for RBAC, off by default. When enabled, the cluster authenticator trusts gke-security-groups@<domain><br/>— the exact name is a GKE requirement. The group itself and the member groups usable as Role/ClusterRoleBinding<br/>subjects are managed out-of-band in Workspace, never here. groups names the per-role subject groups published to<br/>flux-manifests as RBAC\_GROUP\_<ROLE> cluster vars — each must be nested under the fleet group (out-of-band) for the<br/>authenticator to honour it. | <pre>object({<br/>    enabled = optional(bool, false)<br/>    domain  = optional(string)<br/>    groups = optional(object({<br/>      viewers    = optional(string)<br/>      developers = optional(string)<br/>      devops     = optional(string)<br/>      admins     = optional(string)<br/>    }), {})<br/>  })</pre> | `{}` | no |
| release\_channel | GKE release channel (RAPID, REGULAR, STABLE). | `string` | `"REGULAR"` | no |
| secret\_prefix | Prefix for every Secret Manager container name the manifests stack syncs, published as the SECRET\_PREFIX cluster var<br/>(resourceNames become <prefix><container>). Lets multiple clusters share one project with distinct secrets; the<br/>containers and accessor grants in cloud-accounts must be created under the same prefix. Include the trailing<br/>separator (e.g. 'patchy-x-'); empty keeps the unprefixed names. | `string` | `null` | no |
| secret\_sync | Enable the Secret Manager CSI add-on plus GKE Integrated Secret Synchronization -- the SecretProviderClass and<br/>SecretSync CRDs flux-manifests' patchy component uses to materialise Secret Manager secrets as Kubernetes Secrets.<br/>Requires GKE >= 1.33 and Workload Identity (always on here). The secretmanager.secretAccessor grants live beside the<br/>secrets in cloud-accounts, not in this module. | `bool` | `true` | no |
| sso | Platform SSO: deploys dex as the OIDC identity provider (Google Workspace upstream) and wires every elected relying<br/>party to it -- generated client pairs (sso.tf), the DEX\_DIRECTORY\_SA cluster var, and the human-facing HTTPRoutes.<br/>directory\_sa is the keyless Workspace directory-reader service account dex impersonates for group claims<br/>(domain-wide delegation) -- required when enabled. This module binds workloadIdentityUser on it for the cluster's<br/>dex KSA (sso.tf): the applying identity needs the get/setIamPolicy delegation cloud-accounts grants the app's<br/>terraform-apply container on that SA. Requires the DNS surface: the issuer and redirect URLs need the served<br/>domain. client\_rotation holds the<br/>per-client rotation counters (keys: flux-web, patchy-status; absent keys default to 1) -- bump one to mint a new<br/>client secret; the raw dex-client-* container and any config document embedding the same value rewrite in one apply,<br/>so the pair cannot drift (then restart dex: it reads client secrets from env at startup)." | <pre>object({<br/>    enabled         = optional(bool, false)<br/>    directory_sa    = optional(string)<br/>    client_rotation = optional(map(number), {})<br/>  })</pre> | `{}` | no |
| stack\_components | The flux-manifests optional-tier components (short names: flux-web, patchy) this cluster elects, published as the<br/>STACK\_COMPONENTS cluster var. The default elects the whole tier; electing none is explicit -- set []. dex is not<br/>elected here: it deploys exactly when sso is enabled, and without it the elected components still run, just with no<br/>SSO auth and no human-facing HTTPRoute (kubectl port-forward to reach). The core tier (kyverno, cert-manager,<br/>external-dns, gateway, rbac) is not electable. | `set(string)` | <pre>[<br/>  "flux-web",<br/>  "patchy"<br/>]</pre> | no |
| system\_node\_pool | The always-on system node pool platform controllers pin to (label role=system). Autoscaling counts are per zone in<br/>a regional pool. | <pre>object({<br/>    machine_type  = optional(string, "e2-standard-2")<br/>    min_size      = optional(number, 1)<br/>    max_size      = optional(number, 2)<br/>    initial_size  = optional(number, 1)<br/>    disk_size_gib = optional(number, 50)<br/>  })</pre> | `{}` | no |
| workload\_identity | Namespace/service-account pairs the direct Workload Identity grants bind to — the terraform <-> flux-manifests<br/>contract. Override only to track a manifests change. | <pre>object({<br/>    external_dns = optional(object({<br/>      namespace       = optional(string, "external-dns")<br/>      service_account = optional(string, "external-dns")<br/>    }), {})<br/>    cert_manager = optional(object({<br/>      namespace       = optional(string, "cert-manager")<br/>      service_account = optional(string, "cert-manager")<br/>    }), {})<br/>    otel_collector = optional(object({<br/>      namespace       = optional(string, "otel-collector")<br/>      service_account = optional(string, "otel-collector")<br/>    }), {})<br/>    kyverno = optional(object({<br/>      namespace = optional(string, "kyverno")<br/>      # the controllers that fetch image signatures from the registry at<br/>      # admission/report time<br/>      service_accounts = optional(list(string), ["kyverno-admission-controller", "kyverno-reports-controller"])<br/>    }), {})<br/>    # dex impersonates the directory-reader SA via the classic<br/>    # annotation-based flow, so its pair binds workloadIdentityUser on that<br/>    # SA (sso.tf) instead of receiving a direct principal:// grant<br/>    dex = optional(object({<br/>      namespace       = optional(string, "dex")<br/>      service_account = optional(string, "dex")<br/>    }), {})<br/>  })</pre> | `{}` | no |
| zones | Optional zone narrowing for node locations (cost control); null runs nodes in every zone of the region. | `set(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| ca\_certificate | Base64-encoded cluster CA certificate. |
| dns | Delegated zone wiring (null when dns.zone\_name is unset): zone name, apex domain, served host and the zone's name servers. |
| endpoint | Control-plane endpoint IP (host for the helm/kubernetes providers). |
| flux | Flux bootstrap facts, including the exact cluster-vars contract this cluster publishes to the stack. |
| gateway | The Gateway address in use — reserved here or referenced from an existing reservation (null when neither). |
| kubernetes\_version | Current master version. |
| name | Cluster name. |
| node\_service\_account | The dedicated node service account (system pool + auto-provisioned pools). |
| platform\_registry | The platform registry prefix (pass-through of var.platform\_registry). |
| rbac | Google Groups for RBAC (null unless rbac.enabled): the fleet group the cluster authenticator trusts, and the per-role subject groups published as RBAC\_GROUP\_* cluster vars. Groups must be nested under the fleet group (out-of-band, in Workspace) to be usable as Role/ClusterRoleBinding subjects. |
| registry\_reader\_members | Every identity that reads the platform registry (node SA, flux controllers, kyverno controllers). Granted automatically either way: in-project when the registry is co-located, or on the registry's project (registry\_readers, via the org's reader-constrained delegation) when it is central. Exported for visibility and for feeding artifact-store reader\_members where the delegation is not in place. |
| workload\_identity\_pool | The cluster's workload identity pool (<project>.svc.id.goog). |
<!-- END_TF_DOCS -->
