# scc-notifications

Forwards Google Cloud Security Command Center findings to
[patchy](https://github.com/bitwise-media-group/patchy) for triage and remediation.

Security Command Center has no webhook. Its only egress is a `NotificationConfig` publishing to a Pub/Sub topic, so
reaching an HTTP consumer takes a push subscription in between. This module owns that whole path — topic, notification
config, push subscription, dead-letter queue, and the three IAM identities involved — because the pieces are one unit
and pointless apart.

**Authentication is an OIDC token, not a shared secret.** A push subscription cannot compute an HMAC over the body:
Pub/Sub composes the message, so the sender never sees the bytes patchy receives. Instead Pub/Sub signs a short-lived
token bound to a service account and an audience, and patchy checks both. Nothing secret is stored by this module,
which is why it needs no Secret Manager entry — and why the `push_service_account` output matters so much. It is the
only identity patchy will accept; a token from any other Google principal, and anyone with a Google Cloud account can
mint one, is rejected.

**The filter is the cheapest place to control volume.** An organization's SCC emits far more than patchy should
triage, and a finding dropped by the notification config never becomes a Pub/Sub message, a webhook delivery, or a
`Finding` resource. The default takes active, unmuted findings at `HIGH` or above; widen it deliberately.

Creating an organization-scoped notification config requires `roles/securitycenter.admin` at the organization — often
held by a different team than the one running the cluster. That is the module's real prerequisite, and the reason it is
**standalone and opt-in**: nothing in the root cluster module references it, and it is applied on its own.

`project` is optional and defaults to the provider's — these resources belong beside the cluster that consumes them.
One resource, `google_project_service_identity`, rides the `google-beta` provider; it is what returns the Pub/Sub
service agent's identity directly, rather than composing `service-<project number>@gcp-sa-pubsub…` by hand. A composed
address is wrong silently when it is wrong at all, and it forced callers to supply a project number for no other
reason. Fold it back into `google` when it reaches GA.

## Resolving a repository

An SCC finding is about a cloud resource, not repository code, so patchy cannot remediate one until it knows which
repository provisions the thing that is wrong. It answers that by reading ownership labels off the resource through
Cloud Asset Inventory:

```text
scm-repository-org:      acme
scm-repository-name:     infra-prod
scm-repository-provider: github        # optional, defaults to github
```

Labelling resources is the resource owner's job, not this module's — the labels belong beside the thing they describe.
Pass patchy's context-controller workload identity in `asset_viewer_members` to grant the read access that lookup
needs. A finding whose resource carries no such labels still flows through triage; it simply cannot be remediated
automatically, and is handed to a human instead.

## Wiring it to patchy

The `integration` output carries exactly what the cluster-side `Integration` must agree with:

```yaml
apiVersion: patchy.bitwisemedia.uk/v1alpha1
kind: Integration
metadata:
  name: google-cloud
spec:
  provider: google-cloud
  googleCloud:
    securityCommandCenter:
      enabled: true
      audience: <integration.audience>
      serviceAccount: <integration.service_account>
      organization: <integration.organization>
      minSeverity: high
```

A mismatch on either the audience or the service account fails closed: patchy rejects the push rather than accepting an
unexpected identity.

## Watching it

Two signals are worth alerting on. Anything in the **dead-letter topic** is a finding patchy never accepted, and the
push subscription's **oldest unacknowledged message age** rising means patchy is failing or saturated — it answers 503
when its delivery queue is full, which Pub/Sub correctly treats as backpressure.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| google | >= 7.0, < 8.2 |
| google-beta | >= 7.0, < 8.0 |

## Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.0, < 8.2 |
| google-beta | >= 7.0, < 8.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google-beta_google_organization_service_identity.scc](https://registry.terraform.io/providers/hashicorp/google-beta/latest/docs/resources/google_organization_service_identity) | resource |
| [google-beta_google_project_service_identity.pubsub](https://registry.terraform.io/providers/hashicorp/google-beta/latest/docs/resources/google_project_service_identity) | resource |
| [google_project_iam_member.asset_viewers](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_pubsub_subscription.push](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription) | resource |
| [google_pubsub_subscription_iam_member.dead_letter](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription_iam_member) | resource |
| [google_pubsub_topic.dead_letter](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic) | resource |
| [google_pubsub_topic.findings](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic) | resource |
| [google_pubsub_topic_iam_member.dead_letter](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_member) | resource |
| [google_pubsub_topic_iam_member.scc_publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_member) | resource |
| [google_scc_v2_organization_notification_config.patchy](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/scc_v2_organization_notification_config) | resource |
| [google_service_account.push](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.push_token_creator](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| organization\_id | Numeric organization id the notification config is created under. Creating it requires<br/>roles/securitycenter.admin at the organization -- an org-scoped config is what makes one patchy deployment see<br/>every project's findings. | `string` | n/a | yes |
| push | Where and how findings are delivered. endpoint is patchy's receiver, whose path is fixed by the provider name<br/>(/google-cloud/webhooks). audience defaults to the endpoint, which is the convention patchy's own default<br/>assumes -- set it explicitly only when the Integration says something else. | <pre>object({<br/>    endpoint             = string<br/>    audience             = optional(string)<br/>    ack_deadline_seconds = optional(number, 30)<br/>    minimum_backoff      = optional(string, "10s")<br/>    maximum_backoff      = optional(string, "600s")<br/>  })</pre> | n/a | yes |
| asset\_viewer\_members | IAM members granted roles/cloudasset.viewer on the project, for resolving a finding's repository from its<br/>resource's ownership labels. Pass patchy's context-controller workload identity principal; leave empty when the<br/>grant is owned centrally or repository resolution is not in use. | `list(string)` | `[]` | no |
| config\_id | Notification config id, unique within the organization. | `string` | `"patchy"` | no |
| dead\_letter | Where findings patchy never accepted end up. Without this a repeatedly failing delivery is retried until it<br/>expires and then disappears, leaving no record that a finding was lost. | <pre>object({<br/>    enabled               = optional(bool, true)<br/>    max_delivery_attempts = optional(number, 10)<br/>    retention             = optional(string, "604800s")<br/>  })</pre> | `{}` | no |
| description | Human-facing description recorded on the notification config. | `string` | `"Findings forwarded to patchy for triage and remediation."` | no |
| filter | Which findings to publish, in Security Command Center's findings.list filter syntax. This is the cheapest place<br/>to control volume: a finding dropped here never becomes a Pub/Sub message, a webhook delivery, or a Finding<br/>resource. The default takes active, unmuted findings at HIGH or above.<br/><br/>Two syntax traps the default works around: negation is a leading `-`, not `NOT` (there is no `!=` operator), and<br/>OR binds *tighter* than AND -- so the severity alternation is parenthesised to say what it looks like it says. | `string` | `"state=\"ACTIVE\" AND -mute=\"MUTED\" AND (severity=\"HIGH\" OR severity=\"CRITICAL\")"` | no |
| labels | Labels applied to the topics and subscription. | `map(string)` | `{}` | no |
| location | Security Command Center location for the notification config. Only global is generally available. | `string` | `"global"` | no |
| project | Project ID the topic, subscription and push identity live in. Null uses the provider's project, which is the<br/>common case: these resources belong beside the cluster that consumes them. | `string` | `null` | no |
| push\_service\_account\_id | account\_id of the service account whose identity Pub/Sub presents to patchy. Its email is what patchy is<br/>configured to trust, so changing it means reconfiguring the Integration. | `string` | `"patchy-scc-push"` | no |
| subscription\_name | Pub/Sub push subscription name. | `string` | `"patchy-scc-push"` | no |
| topic\_name | Pub/Sub topic name findings are published to. | `string` | `"patchy-scc-findings"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| dead\_letter\_topic | Full resource name of the dead-letter topic, or null when disabled. Watch its message count: anything here is a finding patchy never accepted. |
| integration | The two values patchy's google-cloud Integration must carry, ready to paste into<br/>spec.googleCloud.securityCommandCenter. A mismatch on either fails closed: patchy rejects the push rather than<br/>accepting an unexpected identity. |
| notification\_config | Full resource name of the Security Command Center notification config. |
| push\_service\_account | Email of the identity Pub/Sub presents to patchy. Feed it to the Integration's serviceAccount field; patchy accepts no other. |
| subscription | Full resource name of the push subscription, for alerting on its oldest unacknowledged message age. |
| topic | Full resource name of the findings topic, for granting other publishers or attaching more subscriptions. |
<!-- END_TF_DOCS -->
