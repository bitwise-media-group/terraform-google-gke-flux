# sso-secrets

The out-of-band dex connector credential containers the platform's dex component syncs into the cluster, plus the
`secretmanager.secretAccessor` grants for its sync KSA (`dex/dex-secrets`). This is the terraform half of the dex
secret-sync contract — the manifests' `SecretProviderClass`/`SecretSync` objects are the other half — so the container
names and the consuming KSA subject live here, versioned with the module release that tracks those manifests, instead of
being hand-mirrored (and drifting) in every caller.

Only the upstream connector's credentials live here. The generated dex client secrets (`dex-client-<id>`) belong to the
cluster module, and an application's containers belong to the application's own module, which grants its own sync KSA
accessor on each — resource-side, wherever the container is created.

Instantiate it from a **durable** root, not beside the cluster: an upstream OAuth client outlives any one cluster, and the
secret *versions* are added out of band (`gcloud secrets versions add` — never terraform state) and must survive cluster
destroy/recreate with no manual re-entry. The grants can land before the cluster exists — a Workload Identity principal
string depends only on the project number and pool name, so IAM stores the binding and it stays inert until the cluster
and its KSAs arrive.

Pass the same `sso` and `secret_prefix` values as the cluster module call; the module then creates exactly the containers
that cluster's dex syncs:

| Container | Created when | Holds |
| --- | --- | --- |
| `dex-<id>-<field>` | `sso.enabled`, one per `sso.connector.secrets` field | The connector's out-of-band credential fields (e.g. the console-created OAuth client dex signs users in with) |

After the first apply, add a version to every container:

```sh
gcloud secrets versions add <secret_id> --project <project> --data-file=-
```

## Usage

```hcl
module "sso_secrets" {
  source = "github.com/bitwise-media-group/terraform-google-gke-flux//modules/sso-secrets"

  project = "x-patchy-app-ab12"

  # Mirror the cluster module call in the (separate, disposable) cluster
  # root -- the cluster module's sso value can be passed verbatim.
  sso = {
    enabled   = true
    connector = { type = "google" } # default secrets: client-id, client-secret
  }
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| google | >= 7.0, < 8.9 |

## Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.0, < 8.9 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_secret_manager_secret.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret_iam_member.sync](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_project.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| project | Project ID the secret containers live in -- necessarily the cluster's own project: the platform's dex component<br/>reads containers from the GCP\_PROJECT cluster var, and its sync KSA authenticates through that project's<br/><project>.svc.id.goog Workload Identity pool. | `string` | n/a | yes |
| labels | Labels applied to every secret container. | `map(string)` | `{}` | no |
| secret\_prefix | Prefix for every container name, matching the cluster module's secret\_prefix input (its secret\_prefix output;<br/>the platform syncs <prefix><container>, so the two must move together). Lets multiple clusters share one project<br/>with distinct secrets -- each cluster then needs its own prefixed set of containers and fresh out-of-band<br/>versions. Include the trailing separator (e.g. 'platform-x-'); null keeps the unprefixed names. | `string` | `null` | no |
| sso | Platform SSO election -- pass the cluster module's sso value verbatim (its attributes beyond enabled and the<br/>connector's id/type/secrets, e.g. kubectl and clients, are dropped by type conversion). enabled mirrors the cluster's dex toggle and gates<br/>the connector containers; the connector's secrets names its out-of-band credential fields, creating one<br/>dex-<id>-<field> Secret Manager container per field (id defaulting to type, matching the cluster module) --<br/>populate versions out of band (an OAuth client cannot be terraformed). On its own enabled creates nothing: no<br/>connector is declared by default. | <pre>object({<br/>    enabled = optional(bool, false)<br/>    connector = optional(object({<br/>      id      = optional(string)<br/>      type    = string<br/>      secrets = optional(set(string), ["client-id", "client-secret"])<br/>    }))<br/>  })</pre> | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| secrets | The created containers, keyed by unprefixed container name: the full resource id, the (prefixed) secret\_id for<br/>wiring further IAM in the caller (e.g. a maintainer's secretVersionAdder rotation grant), and the sync principal<br/>granted accessor. Every container's versions are added out of band: gcloud secrets versions add <secret\_id><br/>--data-file=-. |
<!-- END_TF_DOCS -->
