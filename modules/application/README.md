# application

One application published to an existing cluster's Flux instance from a root of its own - another state, another
repository, another team - with everything it needs outside the cluster. The cluster root never changes: the module
reads the cluster through the root's `application_target` output and creates the bootstrap-only seed
(`application-<name>`: the `ResourceSetInputProvider` + `ResourceSet` named `<name>-manifests`, the same local chart the
cluster root seeds its own applications with), a terraform-reconciled `application-<name>-inputs` release carrying the
`<name>-vars` ConfigMap and pre-created namespaces, and the workload grants (one `google_project_iam_member` per (grant,
role), bound to the namespace/service-account pair as a direct Workload Identity Federation principal).

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

  vars       = { PATCHY_DOMAIN = "patchy.example.com" }
  namespaces = ["patchy", "patchy-agents"]

  workload_grants = {
    patchy-egress-broker = {
      namespace       = "patchy"
      service_account = "patchy-egress-broker"
      roles           = ["roles/aiplatform.user"] # project defaults to cluster.project
    }
  }
}
```

The root needs a `google` provider for the cluster's project and a `helm` provider pointed at the cluster (both charts
are local, so no registry credentials). Images under `cluster.platform_registry` are listed with `GARArtifactTag` and
pulled as provider `gcp`; anything else generically. There is no `secret_readers` input: Secret Manager access is
granted on the secret itself, so create the application's containers in the same root (named under
`cluster.secret_prefix`) and grant their sync KSA `roles/secretmanager.secretAccessor` on each - the `workload_members`
output and `cluster.project_number` / `cluster.workload_pool` compose the principal. Dex clients aren't here either: the
application ships `DexClient` objects in its own image, and the platform's dex-client-controller registers them.

Every name matches what the cluster root mints for an application it seeds itself. An application lives in the cluster
root **or** in its own root, never both. The helm release names collide loudly - helm refuses a release or object
another release owns - but the IAM members don't: an IAM member binding is shared, so if two roots declare the same
(member, role) pair, destroying either one removes it for both.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| google | >= 7.46, < 8.8 |
| helm | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.46, < 8.8 |
| helm | ~> 3.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_project_iam_member.workload](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [helm_release.inputs](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.seed](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster | The cluster to publish to: pass the cluster root's application\_target output verbatim (through<br/>terraform\_remote\_state or any other channel) rather than composing it by hand.<br/>  - name: the GKE cluster name.<br/>  - namespace: the flux namespace the seed and vars live in.<br/>  - platform\_registry: the platform Artifact Registry prefix (<location>-docker.pkg.dev/<project>/<repository>);<br/>    images beneath it are listed and pulled with the flux controllers' Workload Identity.<br/>  - tree: the per-cloud tree the cluster syncs (flux.sync.path), the default image path ./deploy/<tree>.<br/>  - issuer: the keyless signing issuer, the default for image.verify.issuer; null on a KMS-keyed cluster.<br/>  - keyed: whether the cluster verifies with a KMS signing key (the cosign-pub Secret exists only then).<br/>  - project / project\_number / workload\_pool: the cluster's project and its Workload Identity pool<br/>    (<project>.svc.id.goog), which compose the direct principal:// members workload\_grants bind.<br/>  - secret\_prefix: the SECRET\_PREFIX the application's own Secret Manager containers are named under. | <pre>object({<br/>    name              = string<br/>    namespace         = string<br/>    platform_registry = string<br/>    tree              = string<br/>    issuer            = optional(string)<br/>    keyed             = bool<br/>    project           = string<br/>    project_number    = string<br/>    workload_pool     = string<br/>    secret_prefix     = string<br/>  })</pre> | n/a | yes |
| image | The application's manifest image, exactly as a cluster root applications entry. Becomes one bootstrap-only<br/>seed: a ResourceSetInputProvider and ResourceSet named <name>-manifests that resolve the newest tag matching<br/>semver, verify the image's cosign signature and apply path from it as Kustomization <name>. The image ships the<br/>same two seed objects under flux/ and owns them from its first reconcile, so a new application release never<br/>needs a terraform apply; the seed is applied once and then ignored (ignore\_changes). Destroying the module<br/>uninstalls the seed and prunes the application.<br/>  - url: the image without a tag or digest. An Artifact Registry url must live under cluster.platform\_registry<br/>    (the flux controllers pull it with their Workload Identity and list its tags through the Artifact Registry<br/>    API); any other registry is listed and pulled generically, optionally with pull\_secret (a<br/>    kubernetes.io/dockerconfigjson Secret in the flux namespace that both the tag listing and the pull read).<br/>  - semver: the tag range the seed follows (default >=0.0.0); a range matching no tag prunes the application.<br/>  - path: the Kustomization path inside the image (default ./deploy/<cluster.tree>).<br/>  - depends\_on: platform Kustomizations the application waits for (default kyverno-policies).<br/>  - verify: keyless (subject, a Fulcio certificate-subject regexp; issuer defaults to cluster.issuer) XOR keyed<br/>    (the cosign-pub public-key Secret, KMS-keyed clusters only). | <pre>object({<br/>    url        = string<br/>    semver     = optional(string, ">=0.0.0")<br/>    path       = optional(string)<br/>    interval   = optional(string, "30m")<br/>    depends_on = optional(set(string), ["kyverno-policies"])<br/>    verify = object({<br/>      issuer  = optional(string)<br/>      subject = optional(string)<br/>      keyed   = optional(bool, false)<br/>    })<br/>    pull_secret = optional(string)<br/>    prune       = optional(bool, true)<br/>    wait        = optional(bool, true)<br/>    timeout     = optional(string, "5m")<br/>  })</pre> | n/a | yes |
| name | The application's short name: the seed release is application-<name>, the seed objects <name>-manifests, the<br/>Kustomization <name> and the vars ConfigMap <name>-vars, all in the cluster's flux namespace. Must not be seeded<br/>by the cluster root as well (an applications key there) - an application lives in exactly one root. | `string` | n/a | yes |
| namespaces | Namespaces created ahead of the application (e.g. so out-of-band secrets can land before Flux deploys into<br/>them), labelled app.kubernetes.io/managed-by: application-<name>; the image's kustomizations adopt them via<br/>server-side apply. A namespace the cluster root already pre-creates (flux.namespaces) cannot be listed here too. | `set(string)` | `[]` | no |
| vars | The application's own substitution values, rendered as the <name>-vars ConfigMap in the flux namespace, which<br/>its Kustomization substitutes from beside cluster-vars. Terraform-reconciled (the inputs release), so changes<br/>flow through this root's applies. Keys must be SCREAMING\_SNAKE\_CASE, matching the substitution syntax. | `map(string)` | `{}` | no |
| workload\_grants | Workload IAM grants, keyed by a short name: each (entry, role) pair becomes one project-level IAM member binding<br/>of the role to the namespace/service-account pair as a direct Workload Identity Federation principal, in<br/>project (default: cluster.project) - the same shape as the cluster root's workload\_grants. Secret Manager reads<br/>are not a grant shape: create the application's containers in this root and grant their sync KSA accessor<br/>on each, resource-side. | <pre>map(object({<br/>    namespace       = string<br/>    service_account = string<br/>    roles           = list(string)<br/>    project         = optional(string)<br/>  }))</pre> | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| namespace | The flux namespace the seed objects (<name>-manifests) and the <name>-vars ConfigMap live in. |
| oci\_provider | The OCIRepository provider the registry selected: gcp under the platform prefix, generic elsewhere. |
| path | The resolved Kustomization path inside the image. |
| release | The bootstrap-only seed release (application-<name>) in the flux namespace. |
| tag\_provider | The tag-listing provider the registry selected: GARArtifactTag under the platform prefix, OCIArtifactTag elsewhere. |
| workload\_members | The direct Workload Identity Federation principal of each workload\_grants entry, keyed as workload\_grants - for<br/>granting these identities further access resource-side (a secret container's accessor, a bucket's reader). |
<!-- END_TF_DOCS -->
