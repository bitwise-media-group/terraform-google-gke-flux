# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "name" {
  description = "Cluster name."
  value       = google_container_cluster.main.name
}

output "endpoint" {
  description = "Control-plane endpoint IP (host for the helm/kubernetes providers)."
  value       = google_container_cluster.main.endpoint
}

output "ca_certificate" {
  description = "Base64-encoded cluster CA certificate."
  # try(): master_auth is only populated by the real API, so mocked plans (the
  # test suite) see an empty list here.
  value = try(google_container_cluster.main.master_auth[0].cluster_ca_certificate, null)
}

output "kubernetes_version" {
  description = "Current master version."
  value       = google_container_cluster.main.master_version
}

output "workload_identity_pool" {
  description = "The cluster's workload identity pool (<project>.svc.id.goog)."
  value       = local.workload_identity_pool
}

output "node_service_account" {
  description = "The dedicated node service account (system pool + auto-provisioned pools)."
  value = {
    email  = google_service_account.nodes.email
    member = google_service_account.nodes.member
  }
}

output "platform_registry" {
  description = "The platform registry prefix (pass-through of var.platform_registry)."
  value       = var.platform_registry
}

output "dns" {
  description = "Delegated zone wiring (null when dns.zone_name is unset): zone name, apex domain, served host (PLATFORM_DOMAIN) and the zone's name servers."
  value = var.dns.zone_name == null ? null : {
    zone_name    = var.dns.zone_name
    domain       = local.dns_domain
    host         = local.platform_domain
    name_servers = data.google_dns_managed_zone.cluster["true"].name_servers
  }
}

output "gateway" {
  description = "The Gateway address in use — reserved here or referenced from an existing reservation (null when neither)."
  value = local.gateway_address_name != "" ? {
    address_name = local.gateway_address_name
    address      = local.gateway_address
  } : null
}

output "rbac" {
  description = "RBAC subjects (null unless rbac.enabled or a group is set): the fleet group the Google Groups authenticator trusts (empty when Google Groups RBAC is off) and the per-role subject groups published as RBAC_GROUP_* cluster vars. A Google Group email must be nested under the fleet group (out-of-band, in Workspace) to be usable as a Role/ClusterRoleBinding subject; a workforce principalSet (sso.kubectl) needs no nesting."
  value = var.rbac.enabled || anytrue([for group in values(var.rbac.groups) : group != null]) ? {
    security_group = local.gke_security_group
    groups         = var.rbac.groups
  } : null
}

output "flux" {
  description = <<-EOT
    Flux bootstrap facts: the namespace, the platform entrypoint the FluxInstance syncs, the electable components in
    force, the application seeds (per key: the seed release, its tag-listing and pull providers and the resolved
    path) and the exact cluster-vars contract this cluster publishes to the platform.
  EOT
  value = {
    namespace           = module.flux_operator.namespace
    sync_url            = local.sync_url
    platform_components = local.platform_components
    applications = {
      for key, app in module.flux_operator.applications : key => merge(app, {
        url  = local.applications[key].url
        path = local.applications[key].path
      })
    }
    cluster_vars = merge(var.flux.cluster_vars, local.reserved_cluster_vars)
  }
}

output "application_target" {
  description = <<-EOT
    Everything modules/application needs to publish an application to this cluster from a root of its own: the
    cluster name, the flux namespace, the platform registry, the per-cloud tree (flux.sync.path), the keyless
    signing issuer (null in KMS mode), whether the cluster is KMS-keyed, the project, project number and Workload
    Identity pool its workload grants bind principals in, and the SECRET_PREFIX. Pass it to the module's cluster
    input verbatim.
  EOT
  value = {
    name              = google_container_cluster.main.name
    namespace         = module.flux_operator.namespace
    platform_registry = var.platform_registry
    tree              = var.flux.sync.path
    issuer            = local.signing_kms ? null : var.signed_identity.issuer
    keyed             = local.signing_kms
    project           = var.project
    project_number    = data.google_project.cluster.number
    workload_pool     = local.workload_identity_pool
    secret_prefix     = local.secret_prefix
  }
}

output "secret_prefix" {
  description = <<-EOT
    The normalized Secret Manager container-name prefix (var.secret_prefix, or the empty string), published as
    SECRET_PREFIX. Application modules and roots compose container names as <prefix><name> from this rather than
    re-deriving the rule.
  EOT
  value       = local.secret_prefix
}

output "workload_members" {
  description = <<-EOT
    The direct Workload Identity Federation principal of every workload grant this module binds, keyed as in
    iam.tf: the platform grants and each workload_grants entry (by its key). For granting these identities further
    access resource-side (a secret container's accessor, a bucket's reader).
  EOT
  value = {
    for key, grant in local.workload_grants :
    key => "${local.wi_principal_prefix}/ns/${grant.namespace}/sa/${grant.service_account}"
  }
}

output "sso" {
  description = <<-EOT
    SSO facts this cluster owns (null unless sso.enabled): the dex issuer, the platform's static clients (as
    published in DEX_CLIENTS; application clients are DexClient objects and never appear here), the generated
    dex-client-<id> container ids for the confidential ones and the composed config documents. The out-of-band
    dex-<id>-<field> connector containers live in modules/sso-secrets (a durable root), fed the same sso value.
  EOT
  value = var.sso.enabled ? {
    issuer_url       = "https://dex.${local.platform_domain}"
    clients          = { for id, client in local.dex_clients : id => { name = client.name, public = client.public, redirect_uris = client.redirect_uris } }
    client_secrets   = { for client, secret in google_secret_manager_secret.dex_client : client => secret.secret_id }
    config_documents = [for secret in google_secret_manager_secret.flux_web_auth_config : secret.secret_id]
  } : null
}

output "kubectl_oidc" {
  description = <<-EOT
    kubectl-via-dex wiring (null unless sso.kubectl.enabled): the workforce pool and provider resource names, the
    group principal-set prefix an rbac.groups entry reached this way carries (append the dex group, e.g.
    "<prefix>platform-admins"), and the login steps:

      gcloud iam workforce-pools create-login-config <provider> --output-file=login.json
      gcloud auth login --login-config=login.json
      gcloud container clusters get-credentials <name> --location <location> --project <project>
  EOT
  value = local.kubectl_enabled ? {
    pool                   = "locations/global/workforcePools/${local.kubectl_pool_id}"
    provider               = "locations/global/workforcePools/${local.kubectl_pool_id}/providers/${var.sso.kubectl.provider_id}"
    issuer_url             = "https://dex.${local.platform_domain}"
    client_id              = var.sso.kubectl.client_id
    group_principal_prefix = "${local.kubectl_pool_principal}/group/"
    login = [
      "gcloud iam workforce-pools create-login-config locations/global/workforcePools/${local.kubectl_pool_id}/providers/${var.sso.kubectl.provider_id} --output-file=login.json",
      "gcloud auth login --login-config=login.json",
      "gcloud container clusters get-credentials ${var.name} --location ${var.location} --project ${var.project}",
    ]
  } : null
}

output "registry_reader_members" {
  description = "Every identity that reads the platform registry (node SA, flux controllers, kyverno controllers). Granted automatically either way: in-project when the registry is co-located, or on the registry's project (registry_readers, via the org's reader-constrained delegation) when it is central. Exported for visibility and for feeding artifact-store reader_members where the delegation is not in place."
  value       = local.registry_reader_members
}
