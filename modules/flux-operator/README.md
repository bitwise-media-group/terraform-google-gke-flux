# flux-operator

Bootstraps flux-operator on the cluster and points it at the signed flux-manifests artifact in the platform registry:
three helm releases (flux-operator → cluster-inputs → flux-instance) take an empty cluster to a reconciling GitOps
platform in one `terraform apply`.

The generated `flux-system` OCIRepository is patched with cosign **keyless** verification (`matchOIDCIdentity` pinning
the flux-manifests publish workflow), and the source-controller / flux-operator service accounts get direct Workload
Identity grants for Artifact Registry reads — no key material, no GSAs, no annotations.

The local `charts/cluster-inputs` chart delivers the terraform ↔ flux-manifests contract: the `cluster-vars` ConfigMap
(substituted into every stack Kustomization via `postBuild.substituteFrom`) and any pre-created namespaces.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| google | >= 7.0, < 8.0 |
| helm | >= 3.0, < 4 |

## Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.0, < 8.0 |
| helm | >= 3.0, < 4 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_project_iam_member.registry_read](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [helm_release.cluster_inputs](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.flux_instance](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.flux_operator](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| distribution | Flux distribution: version constraint and the registry hosting the mirrored fluxcd controller images (and optionally the OCI artifact with the operator's manifests). | <pre>object({<br/>    version  = string<br/>    registry = string<br/>    artifact = optional(string)<br/>  })</pre> | n/a | yes |
| instance\_chart | flux-instance helm chart location (renders the FluxInstance CR; avoids the kubernetes\_manifest plan-time CRD problem). A null version installs the latest available at create and pins it in state. | <pre>object({<br/>    repository = string<br/>    version    = optional(string)<br/>  })</pre> | n/a | yes |
| operator\_chart | flux-operator helm chart location: the platform registry's charts/flux-operator, published by flux-containers (the artifact store must be populated before the first cluster bootstraps). A null version installs the latest available at create and pins it in state — later applies don't auto-upgrade. | <pre>object({<br/>    repository = string # e.g. oci://<registry>/charts<br/>    version    = optional(string)<br/>  })</pre> | n/a | yes |
| project | Project ID the cluster (and its workload identity pool) lives in. | `string` | n/a | yes |
| project\_number | Project number, for composing principal:// workload identity members at plan time. | `string` | n/a | yes |
| signed\_identity | Cosign keyless identity (Go regexps over the Fulcio certificate) enforced on the generated flux-system OCIRepository, so an unsigned or tampered manifests artifact is never applied. | <pre>object({<br/>    issuer            = string<br/>    manifests_subject = string<br/>  })</pre> | n/a | yes |
| sync | Cluster sync source: the flux-manifests artifact in the platform registry and the path within it. | <pre>object({<br/>    url      = string # oci://<registry>/flux-manifests<br/>    ref      = string # channel tag (stable, staging) or exact version<br/>    path     = string # stack (the single entrypoint all clusters share)<br/>    interval = optional(string, "5m")<br/>  })</pre> | n/a | yes |
| cluster\_vars | The cluster-vars ConfigMap contents — every value the flux-manifests stack substitutes via postBuild.substituteFrom. | `map(string)` | `{}` | no |
| grant\_registry\_read | Grant the flux principals artifactregistry.reader on the cluster's project. On only when the platform registry is co-located; a central registry grants them via the artifact-store module's reader\_members instead. | `bool` | `true` | no |
| kustomize\_patches | Extra kustomize patches applied to the generated Flux instance objects, on top of the built-in controller nodeSelector and flux-system OCIRepository verify patches. | `list(any)` | `[]` | no |
| namespace | Namespace for the flux-operator and Flux controllers. | `string` | `"flux-system"` | no |
| namespaces | Namespaces pre-created by the cluster-inputs chart (e.g. workload namespaces that must exist before their secrets arrive out-of-band); flux kustomizations adopt them via server-side apply. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| cluster\_vars\_configmap | Name of the cluster-vars ConfigMap the stack substitutes from. |
| namespace | The flux namespace. |
<!-- END_TF_DOCS -->
