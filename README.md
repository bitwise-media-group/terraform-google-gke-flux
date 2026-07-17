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
   the stack and brings up the platform.

## The terraform ↔ flux contract

The `cluster-vars` ConfigMap (flux-system) publishes these to the stack; the authoritative consumer table lives in the
flux-manifests README:

`CLUSTER_NAME`, `GCP_PROJECT`, `GCP_PROJECT_NUMBER`, `GCP_REGION`, `PLATFORM_REGISTRY`, `CONTAINER_REGISTRY`,
`SIGNED_IDENTITY_ISSUER`, `SIGNED_IDENTITY_CHARTS`, `SIGNED_IDENTITY_IMAGES`, `DNS_ZONE_NAME`, `DNS_DOMAIN`,
`PATCHY_DOMAIN`, `ACME_EMAIL`, `GATEWAY_ADDRESS_NAME`, `GATEWAY_IP`, `OTEL_PROJECT` — optional surfaces use the
empty-string convention. Callers may add extras (e.g. `*_SEMVER` range pins) via `flux.cluster_vars`; reserved keys
always win.

Workload identity namespace/service-account pairs (overridable via `workload_identity`): `external-dns/external-dns` and
`cert-manager/cert-manager` (→ `roles/dns.admin`), `otel-collector/otel-collector` (→ monitoring/logging/trace writers),
`kyverno/kyverno-{admission,reports}-controller` and `flux-system/{source-controller,flux-operator}` (→
`roles/artifactregistry.reader`).

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
| [google_project_iam_member.nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.registry_readers](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.workload](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_service_account.nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_compute_global_address.gateway](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_global_address) | data source |
| [google_dns_managed_zone.cluster](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/dns_managed_zone) | data source |
| [google_project.cluster](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| name | Cluster name. Also prefixes the node service account and the default gateway address name. | `string` | n/a | yes |
| network | Shared-VPC wiring: network/subnetwork self-links into the HOST project and the names of the GKE secondary ranges on that subnet (all created by cloud-accounts). | <pre>object({<br/>    network             = string<br/>    subnetwork          = string<br/>    pods_range_name     = string<br/>    services_range_name = string<br/>  })</pre> | n/a | yes |
| platform\_registry | The platform Artifact Registry prefix everything is consumed from (artifact-store module's platform\_registry output), e.g. us-central1-docker.pkg.dev/o-foundation-7e43/platform (the central store) or a co-located one. | `string` | n/a | yes |
| project | Project ID the cluster lives in (a shared-VPC service project, e.g. x-patchy-app-<rand4>). | `string` | n/a | yes |
| region | Region for the (regional) cluster, e.g. us-central1. | `string` | n/a | yes |
| signed\_identity | Cosign keyless verification identities (Go regexps matched against the Fulcio certificate). The artifact-store module's signed\_identity\_subjects output provides the subjects; the issuer default matches GitHub Actions. | <pre>object({<br/>    issuer             = optional(string, "^https://token\\.actions\\.githubusercontent\\.com$")<br/>    manifests_subject  = string<br/>    containers_subject = string<br/>  })</pre> | n/a | yes |
| deletion\_protection | Terraform-level destroy protection for the cluster. Off by default: this environment is disposable by design. | `bool` | `false` | no |
| dns | Existing delegated Cloud DNS zone (created by cloud-accounts; never owned here). zone\_name enables the DNS/TLS surface: external-dns + cert-manager IAM grants and the DNS\_* / PATCHY\_DOMAIN cluster vars. host optionally narrows the served host below the zone apex. | <pre>object({<br/>    zone_name  = optional(string)<br/>    host       = optional(string)<br/>    acme_email = optional(string)<br/>  })</pre> | `{}` | no |
| flux | Flux bootstrap knobs. Chart repositories, the distribution registry and the sync url default onto platform\_registry; sync.ref picks the release channel (stable, staging, or edge for dev clusters tracking trunk -- pair edge with the manifests\_edge signing subject). | <pre>object({<br/>    operator_chart = optional(object({<br/>      repository = optional(string)<br/>      version    = optional(string)<br/>    }), {})<br/>    instance_chart = optional(object({<br/>      repository = optional(string)<br/>      version    = optional(string)<br/>    }), {})<br/>    distribution = optional(object({<br/>      version  = optional(string, "2.x")<br/>      registry = optional(string)<br/>      artifact = optional(string)<br/>    }), {})<br/>    sync = optional(object({<br/>      url      = optional(string)<br/>      ref      = optional(string, "stable")<br/>      path     = optional(string, "stack")<br/>      interval = optional(string, "5m")<br/>    }), {})<br/>    kustomize_patches = optional(list(any), [])<br/>    cluster_vars      = optional(map(string), {})<br/>    namespaces        = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| gateway | The platform Gateway's global static IP, stable across cluster recreation. Reserve one here (default; address\_name defaults to <name>-gateway) or reference an existing address by name with reserve\_static\_ip = false (e.g. cloud-accounts' `ingress` address in x-patchy-app). | <pre>object({<br/>    reserve_static_ip = optional(bool, true)<br/>    address_name      = optional(string)<br/>  })</pre> | `{}` | no |
| kubernetes\_version | Optional minimum master version pin; null lets the release channel govern. | `string` | `null` | no |
| labels | Resource labels applied to the cluster. | `map(string)` | `{}` | no |
| managed\_opentelemetry | Enable Managed OpenTelemetry for GKE (Preview): Google's in-cluster OTLP pipeline (HTTP endpoint opentelemetry-collector.gke-managed-otel:4318) shipping traces/logs/metrics to the CLUSTER project's Cloud Trace/Logging/Monitoring -- it cannot target observability.project. Per-cluster pilot toggle for retiring the self-hosted otel-collector component; requires GKE >= 1.34.1-gke.2178000. | `bool` | `false` | no |
| master\_authorized\_networks | CIDRs allowed to reach the public control-plane endpoint. Empty leaves the endpoint open (PoC posture) — constrain it as soon as a stable egress CIDR exists. | <pre>list(object({<br/>    cidr_block   = string<br/>    display_name = optional(string)<br/>  }))</pre> | `[]` | no |
| node\_auto\_provisioning | Node auto-provisioning (NAP) limits for workload capacity — the cluster-wide ceilings across all auto-provisioned pools. | <pre>object({<br/>    min_cpu        = optional(number, 0)<br/>    max_cpu        = optional(number, 64)<br/>    min_memory_gib = optional(number, 0)<br/>    max_memory_gib = optional(number, 256)<br/>    disk_size_gib  = optional(number, 100)<br/>  })</pre> | `{}` | no |
| observability | Optional central observability project the otel-collector writes telemetry to; null targets the cluster's own project. | <pre>object({<br/>    project = optional(string)<br/>  })</pre> | `{}` | no |
| private\_endpoint | Serve the control-plane endpoint privately only. Off by default so terraform/helm bootstrap works without a VPN path into the shared VPC. | `bool` | `false` | no |
| release\_channel | GKE release channel (RAPID, REGULAR, STABLE). | `string` | `"REGULAR"` | no |
| secret\_sync | Enable the Secret Manager CSI add-on plus GKE Integrated Secret Synchronization -- the SecretProviderClass and SecretSync CRDs flux-manifests' patchy component uses to materialise Secret Manager secrets as Kubernetes Secrets. Requires GKE >= 1.33 and Workload Identity (always on here). The secretmanager.secretAccessor grants live beside the secrets in cloud-accounts, not in this module. | `bool` | `false` | no |
| system\_node\_pool | The always-on system node pool platform controllers pin to (label role=system). Autoscaling counts are per zone in a regional pool. | <pre>object({<br/>    machine_type  = optional(string, "e2-standard-2")<br/>    min_size      = optional(number, 1)<br/>    max_size      = optional(number, 2)<br/>    initial_size  = optional(number, 1)<br/>    disk_size_gib = optional(number, 50)<br/>  })</pre> | `{}` | no |
| workload\_identity | Namespace/service-account pairs the direct Workload Identity grants bind to — the terraform <-> flux-manifests contract. Override only to track a manifests change. | <pre>object({<br/>    external_dns = optional(object({<br/>      namespace       = optional(string, "external-dns")<br/>      service_account = optional(string, "external-dns")<br/>    }), {})<br/>    cert_manager = optional(object({<br/>      namespace       = optional(string, "cert-manager")<br/>      service_account = optional(string, "cert-manager")<br/>    }), {})<br/>    otel_collector = optional(object({<br/>      namespace       = optional(string, "otel-collector")<br/>      service_account = optional(string, "otel-collector")<br/>    }), {})<br/>    kyverno = optional(object({<br/>      namespace = optional(string, "kyverno")<br/>      # the controllers that fetch image signatures from the registry at<br/>      # admission/report time<br/>      service_accounts = optional(list(string), ["kyverno-admission-controller", "kyverno-reports-controller"])<br/>    }), {})<br/>  })</pre> | `{}` | no |
| zones | Optional zone narrowing for node locations (cost control); null runs nodes in every zone of the region. | `set(string)` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| ca\_certificate | Base64-encoded cluster CA certificate. |
| dns | Delegated zone wiring (null when dns.zone\_name is unset): zone name, apex domain, served host and the zone's name servers. |
| endpoint | Control-plane endpoint IP (host for the helm/kubernetes providers). |
| flux | Flux bootstrap facts. |
| gateway | The Gateway address in use — reserved here or referenced from an existing reservation (null when neither). |
| kubernetes\_version | Current master version. |
| name | Cluster name. |
| node\_service\_account | The dedicated node service account (system pool + auto-provisioned pools). |
| platform\_registry | The platform registry prefix (pass-through of var.platform\_registry). |
| registry\_reader\_members | Every identity that reads the platform registry (node SA, flux controllers, kyverno controllers). Granted automatically either way: in-project when the registry is co-located, or on the registry's project (registry\_readers, via the org's reader-constrained delegation) when it is central. Exported for visibility and for feeding artifact-store reader\_members where the delegation is not in place. |
| workload\_identity\_pool | The cluster's workload identity pool (<project>.svc.id.goog). |
<!-- END_TF_DOCS -->
