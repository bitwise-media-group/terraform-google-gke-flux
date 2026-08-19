# secrets

The out-of-band credential containers the flux-manifests stack syncs into the cluster, plus the
`secretmanager.secretAccessor` grants for the sync KSAs. This is the terraform half of the secret-sync contract — the
manifests' `SecretProviderClass`/`SecretSync` objects are the other half — so the container names, consuming KSA
subjects and election gating live here, versioned with the module release that tracks those manifests, instead of being
hand-mirrored (and drifting) in every caller.

Instantiate it from a **durable** root, not beside the cluster: the secret *versions* are added out of band
(`gcloud secrets versions add` — never terraform state) and must survive cluster destroy/recreate with no manual
re-entry. The grants can land before the cluster exists — a Workload Identity principal string depends only on the
project number and pool name, so IAM stores the binding and it stays inert until the cluster and its KSAs arrive.

Pass the same election values as the cluster module call (`stack_components`, `sso`, `patchy.harnesses`,
`patchy.claude.provider.name`, `secret_prefix`); the module then creates exactly the containers that cluster shape
syncs:

| Container | Created when | Holds |
| --- | --- | --- |
| `patchy-github-app-id` | `patchy` elected | The patchy GitHub App's numeric id |
| `patchy-github-app-private-key` | `patchy` elected | The App's private key (PEM) |
| `patchy-webhook-secret` | `patchy` elected | The App's webhook secret |
| `patchy-anthropic-token` | + `claude` harness on `anthropic` | `claude setup-token` OAuth token (or an API key, per the chart's `anthropicAuth`) |
| `patchy-openai-token` | + `codex` harness | OpenAI platform API key |
| `patchy-copilot-token` | + `copilot` harness | Fine-grained GitHub token with **no** repository permissions |
| `dex-<id>-<field>` | `sso.enabled`, per `connectors[*].secrets` | The connector's out-of-band credential fields (e.g. the console-created OAuth client dex signs users in with) |

After the first apply, add a version to every container:

```sh
gcloud secrets versions add <secret_id> --project <project> --data-file=-
```

## Usage

```hcl
module "secrets" {
  source = "github.com/bitwise-media-group/terraform-google-gke-flux//modules/secrets"

  project = "x-patchy-app-ab12"

  # Mirror the cluster module call in the (separate, disposable) cluster
  # root -- the cluster module's sso value can be passed verbatim.
  sso = {
    enabled    = true
    connectors = { google = {} } # default secrets: client-id, client-secret
  }
}
```

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
| [google_secret_manager_secret.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret_iam_member.sync](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_project.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| project | Project ID the secret containers live in -- necessarily the cluster's own project: the manifests read containers<br/>from the GCP\_PROJECT cluster var, and the sync KSAs authenticate through that project's <project>.svc.id.goog<br/>Workload Identity pool. | `string` | n/a | yes |
| agent\_harnesses | The agent harnesses the cluster elects -- pass the cluster module's patchy.harnesses value (published to the<br/>manifests as AGENT\_HARNESSES). Each harness brings its credential container: claude's rides claude\_provider<br/>(anthropic only), codex adds patchy-openai-token, copilot adds patchy-copilot-token. | `set(string)` | <pre>[<br/>  "claude"<br/>]</pre> | no |
| claude\_provider | The claude runner's model provider -- pass the cluster module's patchy.claude.provider.name value. Only anthropic<br/>needs a credential container (patchy-anthropic-token); a vertex cluster's egress broker authenticates with its<br/>cloud identity and gets none. | `string` | `"anthropic"` | no |
| labels | Labels applied to every secret container. | `map(string)` | `{}` | no |
| secret\_prefix | Prefix for every container name, matching the cluster module's secret\_prefix input (the manifests sync<br/><prefix><container>, so the two must move together). Lets multiple clusters share one project with distinct<br/>secrets -- each cluster then needs its own prefixed set of containers and fresh out-of-band versions. Include the<br/>trailing separator (e.g. 'patchy-x-'); null keeps the unprefixed names. | `string` | `null` | no |
| sso | Platform SSO election -- pass the cluster module's sso value verbatim (its attributes beyond enabled and the<br/>connector's id/type/secrets are dropped by type conversion). enabled mirrors the cluster's dex toggle and gates<br/>the connector containers; the connector's secrets names its out-of-band credential fields, creating one<br/>dex-<id>-<field> Secret Manager container per field (id defaulting to type, matching the cluster module) --<br/>populate versions out of band (an OAuth client cannot be terraformed). On its own enabled creates nothing: no<br/>connector is declared by default. | <pre>object({<br/>    enabled = optional(bool, false)<br/>    connector = optional(object({<br/>      id      = optional(string)<br/>      type    = string<br/>      secrets = optional(set(string), ["client-id", "client-secret"])<br/>    }))<br/>  })</pre> | `{}` | no |
| stack\_components | The flux-manifests optional-tier components the cluster elects -- pass the cluster module's stack\_components<br/>value. Only patchy carries out-of-band credentials today: electing it creates the GitHub App containers plus the<br/>elected harnesses' model credentials; flux-web is accepted for symmetric passing and creates nothing (dex rides<br/>sso.enabled, mirroring the cluster module's sso toggle). | `set(string)` | <pre>[<br/>  "flux-web",<br/>  "patchy"<br/>]</pre> | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| secrets | The created containers, keyed by unprefixed container name: the full resource id, the (prefixed) secret\_id for<br/>wiring further IAM in the caller (e.g. a maintainer's secretVersionAdder rotation grant), and the sync principal<br/>granted accessor. Every container's versions are added out of band: gcloud secrets versions add <secret\_id><br/>--data-file=-. |
<!-- END_TF_DOCS -->
