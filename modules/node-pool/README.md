# node-pool

One GKE node pool on an existing cluster. The cluster root builds its always-on `system` pool (and any `node_pools`
entries) through this module, and an **application that needs dedicated capacity calls it directly**, beside its
`modules/application` call, fed from the cluster root's `application_target` output. Application modules never own node
capacity themselves: a pool is sized and tainted where the workload is declared, and lives and dies with that root.

Everything that is policy rather than sizing is fixed, identically for every pool:

- nodes run as the given service account (the cluster's dedicated node SA, `application_target.node_service_account`)
  with the `cloud-platform` scope, behind the GKE metadata server (Workload Identity);
- Shielded VM with secure boot and integrity monitoring;
- auto-repair and auto-upgrade, with surge upgrades (`max_surge = 1`, `max_unavailable = 0`);
- `initial_size` is set once at creation and then ignored: the count is the autoscaler's to move.

Sizing is a **cluster-wide total** by default (`total_min_node_count` / `total_max_node_count`), so `min_size = 0`
gives a scale-to-zero pool whatever its zone count; `size_per_zone = true` switches to per-zone bounds (the cluster's
system pool uses this). `initial_size` is per zone either way — it is GKE's `initial_node_count`.

The pool name is fixed (not a generated prefix) because GKE caps pool names at 40 characters; changing it replaces the
pool. There is deliberately no `create_before_destroy`: it would propagate onto the cluster (whose name is fixed) and
break a cluster replacement, and a fixed pool name could never be created before its predecessor is gone anyway. A
replacement is destroy-then-create.

Taints use the same shape and effect enum as the AWS node-group module (`NO_SCHEDULE`, `PREFER_NO_SCHEDULE`,
`NO_EXECUTE`), which is also GKE's own. GKE adds `kubernetes.io/arch=arm64:NoSchedule` to every Arm node by itself, so
arm64 workloads must tolerate it whether or not the pool lists further taints. Workloads that must land on this pool —
and nowhere else — should select `cloud.google.com/gke-nodepool: <name>` as well as tolerating its taints: pinning the
pool name stops node auto-provisioning from minting a look-alike pool when this one is at `max_size`.

## Usage

```hcl
module "arc_amd64" {
  source = "github.com/bitwise-media-group/terraform-google-gke-flux//modules/node-pool"

  project         = local.cluster.project
  cluster         = local.cluster.name
  location        = local.cluster.location
  node_locations  = local.cluster.node_locations
  service_account = local.cluster.node_service_account
  name            = "arc-amd64"

  machine_type = "e2-standard-4"
  min_size     = 0
  max_size     = 4
  initial_size = 0

  labels = { workload = "arc" }
  taints = [{ key = "workload", value = "arc", effect = "NO_SCHEDULE" }]
}
```

`local.cluster` is the cluster root's `application_target` output (e.g. read through `terraform_remote_state`).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| google | >= 7.0, < 8.10 |

## Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.0, < 8.10 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_container_node_pool.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_node_pool) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster | Name of the GKE cluster the pool joins. | `string` | n/a | yes |
| location | The cluster's location (a region for a regional cluster, a zone for a zonal one). | `string` | n/a | yes |
| name | Node pool name, unique within the cluster. A fixed name rather than a prefix: GKE caps pool names at 40<br/>characters and a generated suffix would eat most of them. Changing it replaces the pool. | `string` | n/a | yes |
| project | Project ID the cluster lives in. | `string` | n/a | yes |
| service\_account | Email of the service account the nodes run as - the cluster's dedicated node service account, never the default<br/>compute one. | `string` | n/a | yes |
| disk\_size\_gib | Boot disk size in GiB. | `number` | `50` | no |
| disk\_type | Boot disk type (pd-standard, pd-balanced, pd-ssd, hyperdisk-balanced, ...). Null takes the GKE default. | `string` | `null` | no |
| image\_type | Node image type (e.g. COS\_CONTAINERD, UBUNTU\_CONTAINERD). Null takes the GKE default (COS\_CONTAINERD). | `string` | `null` | no |
| initial\_size | Node count per zone at creation. Set once and never argued about again (ignore\_changes) - the count is the<br/>autoscaler's to move on a live cluster. | `number` | `1` | no |
| labels | Kubernetes labels applied to every node in the pool - the selectors workloads pin with. | `map(string)` | `{}` | no |
| location\_policy | Autoscaler location policy: BALANCED spreads nodes evenly across zones, ANY prefers zones with spare capacity<br/>(recommended for spot). Null takes the GKE default (BALANCED, or ANY for spot pools). | `string` | `null` | no |
| machine\_type | Compute Engine machine type of every node (e.g. e2-standard-4, or t2a-standard-4 for arm64). | `string` | `"e2-standard-2"` | no |
| max\_size | Maximum node count. A cluster-wide total across node\_locations unless size\_per\_zone is set. | `number` | `3` | no |
| min\_size | Minimum node count. A cluster-wide total across node\_locations unless size\_per\_zone is set. 0 lets the pool<br/>scale to zero when nothing schedules on it. | `number` | `1` | no |
| node\_locations | Zones the pool's nodes run in. Empty inherits the cluster's node locations (every zone of a regional cluster, or<br/>the control-plane zone of a zonal one). | `set(string)` | `[]` | no |
| resource\_labels | GCP resource labels applied to the pool's Compute Engine instances (billing attribution). | `map(string)` | `{}` | no |
| size\_per\_zone | Interpret min\_size and max\_size as per-zone counts (autoscaling min/max\_node\_count) instead of cluster-wide<br/>totals (total\_min/max\_node\_count). GKE holds one or the other, and moving between them is an in-place update. | `bool` | `false` | no |
| spot | Run the pool on Spot VMs (preemptible, deeply discounted). Pair with location\_policy = "ANY" so the autoscaler<br/>chases spare capacity across zones. | `bool` | `false` | no |
| taints | Kubernetes taints applied to every node in the pool. Effects use GKE's (and the AWS node-group module's) enum:<br/>NO\_SCHEDULE, PREFER\_NO\_SCHEDULE or NO\_EXECUTE. GKE adds kubernetes.io/arch=arm64:NoSchedule to Arm nodes on its<br/>own; it need not be listed here. | <pre>list(object({<br/>    key    = string<br/>    value  = optional(string)<br/>    effect = string<br/>  }))</pre> | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| id | Node pool id (projects/<project>/locations/<location>/clusters/<cluster>/nodePools/<name>). |
| labels | Kubernetes labels every node in the pool carries - the selectors workloads pin with. |
| name | The node pool's name - the value workloads pin with the cloud.google.com/gke-nodepool label. |
| taints | Kubernetes taints every node in the pool carries (as configured; GKE's own Arm taint is not listed). |
<!-- END_TF_DOCS -->
