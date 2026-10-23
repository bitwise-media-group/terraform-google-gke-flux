# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with mocked providers: no credentials, no API
# calls. These assert the cluster shape (shared-VPC wiring, Dataplane V2,
# Workload Identity, Gateway API, NAP) and the terraform -> flux contract
# (workload identity grants, cluster vars, application seeds, kubectl via
# workforce identity).

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }

  mock_data "google_dns_managed_zone" {
    defaults = {
      dns_name     = "patchy.bitwisemedia.co.uk."
      name_servers = ["ns-cloud-a1.googledomains.com."]
    }
  }

  mock_data "google_compute_global_address" {
    defaults = {
      address = "203.0.113.10"
    }
  }

  mock_data "google_kms_crypto_key_latest_version" {
    defaults = {
      public_key = [{
        algorithm = "EC_SIGN_P256_SHA256"
        pem       = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----\n"
      }]
    }
  }
}

mock_provider "google-beta" {}

mock_provider "helm" {}

variables {
  name     = "patchy-x"
  project  = "x-patchy-app-ab12"
  location = "us-central1"

  network = {
    network             = "projects/x-vpc-host-cd34/global/networks/x-vpc-shared"
    subnetwork          = "projects/x-vpc-host-cd34/regions/us-central1/subnetworks/x-patchy-primary-iowa"
    pods_range_name     = "x-patchy-gke-pods-iowa"
    services_range_name = "x-patchy-gke-svc-iowa"
  }

  platform_registry = "us-central1-docker.pkg.dev/x-patchy-app-ab12/platform"

  signed_identity = {
    manifests_subject  = "^https://github\\.com/bitwise-media-group/flux-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    containers_subject = "^https://github\\.com/bitwise-media-group/flux-containers/\\.github/workflows/publish\\.yaml@refs/heads/main$"
  }
}

run "cluster_shape" {
  command = plan

  assert {
    condition     = google_container_cluster.main.datapath_provider == "ADVANCED_DATAPATH"
    error_message = "the cluster must run Dataplane V2 (built-in Cilium)"
  }

  assert {
    condition     = google_container_cluster.main.workload_identity_config[0].workload_pool == "x-patchy-app-ab12.svc.id.goog"
    error_message = "workload identity must be enabled with the project pool"
  }

  assert {
    condition     = google_container_cluster.main.gateway_api_config[0].channel == "CHANNEL_STANDARD"
    error_message = "the GKE Gateway controller must be enabled (patchy webhook HTTPS rides on it)"
  }

  assert {
    condition     = google_container_cluster.main.private_cluster_config[0].enable_private_nodes == true
    error_message = "nodes must be private (egress via Cloud NAT on the shared VPC)"
  }

  assert {
    condition     = google_container_cluster.main.ip_allocation_policy[0].cluster_secondary_range_name == "x-patchy-gke-pods-iowa"
    error_message = "the pods secondary range must be referenced by its cloud-accounts name"
  }

  assert {
    condition     = google_container_cluster.main.ip_allocation_policy[0].services_secondary_range_name == "x-patchy-gke-svc-iowa"
    error_message = "the services secondary range must be referenced by its cloud-accounts name"
  }

  assert {
    condition     = google_container_cluster.main.cluster_autoscaling[0].enabled == true
    error_message = "node auto-provisioning must be enabled (the platform's workload scaling)"
  }

  assert {
    condition     = google_container_node_pool.system.node_config[0].labels["role"] == "system"
    error_message = "the system pool must carry the role=system label platform controllers pin to"
  }

  assert {
    condition     = google_container_cluster.main.deletion_protection == false
    error_message = "the cluster must be disposable by default (destroy/recreate is a design requirement)"
  }

  assert {
    condition     = google_container_cluster.main.managed_opentelemetry_config[0].scope == "NONE"
    error_message = "managed OpenTelemetry must be explicitly NONE by default (the self-hosted otel-collector is the platform OTLP endpoint)"
  }

  assert {
    condition     = google_container_cluster.main.secret_manager_config[0].enabled == true && google_container_cluster.main.secret_sync_config[0].enabled == true
    error_message = "secret sync is on by default (the platform's Secret Manager bridge); both blocks stay declared so disabling actually turns the feature down"
  }

  assert {
    condition     = google_container_cluster.main.secret_manager_config[0].rotation_config[0].enabled == true && google_container_cluster.main.secret_sync_config[0].rotation_config[0].enabled == true
    error_message = "rotation must be on wherever sync is on: without it versions/latest is resolved once and new Secret Manager versions never reach the cluster"
  }

  assert {
    condition     = google_container_cluster.main.secret_manager_config[0].rotation_config[0].rotation_interval == "120s" && google_container_cluster.main.secret_sync_config[0].rotation_config[0].rotation_interval == "120s"
    error_message = "the rotation interval is pinned at 120s so the refresh cadence survives provider default drift"
  }
}

# location accepts a zone as well as a region: a zone builds a zonal cluster
# (management fee covered by the GKE free tier for one per billing account)
# while the consumers that need a true region still see the enclosing one.
run "zonal_location" {
  command = plan

  variables {
    location = "us-central1-a"
  }

  assert {
    condition     = google_container_cluster.main.location == "us-central1-a"
    error_message = "a zone-shaped location must build a zonal cluster"
  }

  assert {
    condition     = google_container_node_pool.system.location == "us-central1-a"
    error_message = "the system pool must follow the cluster's location"
  }

  assert {
    condition     = output.flux.cluster_vars.GCP_REGION == "us-central1"
    error_message = "GCP_REGION must be the zone's enclosing region, never the zone itself"
  }
}

run "managed_opentelemetry_pilot" {
  command = plan

  variables {
    managed_opentelemetry = true
  }

  assert {
    condition     = google_container_cluster.main.managed_opentelemetry_config[0].scope == "COLLECTION_AND_INSTRUMENTATION_COMPONENTS"
    error_message = "the pilot toggle must enable collection and instrumentation components"
  }
}

run "secret_sync_disabled" {
  command = plan

  variables {
    secret_sync = false
  }

  assert {
    condition     = google_container_cluster.main.secret_manager_config[0].enabled == false
    error_message = "the toggle must turn the Secret Manager CSI add-on down, not orphan it"
  }

  assert {
    condition     = google_container_cluster.main.secret_sync_config[0].enabled == false
    error_message = "the toggle must turn Integrated Secret Synchronization down with the add-on it rides on"
  }

  assert {
    condition     = google_container_cluster.main.secret_manager_config[0].rotation_config[0].enabled == false && google_container_cluster.main.secret_sync_config[0].rotation_config[0].enabled == false
    error_message = "the toggle must turn rotation down with the sync it belongs to, not orphan it"
  }
}

run "rbac_disabled_by_default" {
  command = plan

  assert {
    condition     = google_container_cluster.main.authenticator_groups_config[0].security_group == ""
    error_message = "Google Groups for RBAC must be explicitly disabled by default (always-declared so flipping the toggle off turns the authenticator down)"
  }
}

run "rbac_enabled" {
  command = plan

  variables {
    rbac = {
      enabled = true
      domain  = "bitwisemedia.co.uk"
      groups = {
        viewers    = "gcp-x-patchy-viewers@bitwisemedia.co.uk"
        developers = "gcp-x-patchy-developers@bitwisemedia.co.uk"
        devops     = "gcp-x-patchy-devops@bitwisemedia.co.uk"
        admins     = "gcp-x-patchy-admins@bitwisemedia.co.uk"
      }
    }
  }

  assert {
    condition     = google_container_cluster.main.authenticator_groups_config[0].security_group == "gke-security-groups@bitwisemedia.co.uk"
    error_message = "the authenticator must trust the fleet group under the caller's domain (the exact gke-security-groups name is a GKE requirement)"
  }

  assert {
    condition     = output.rbac.security_group == "gke-security-groups@bitwisemedia.co.uk"
    error_message = "the trusted fleet group must be exported for the out-of-band membership management"
  }

  assert {
    condition     = output.rbac.groups.developers == "gcp-x-patchy-developers@bitwisemedia.co.uk"
    error_message = "the per-role subject groups must be exported alongside the fleet group"
  }

  assert {
    condition     = output.rbac.groups.admins == "gcp-x-patchy-admins@bitwisemedia.co.uk"
    error_message = "the admins subject group must be exported alongside the fleet group"
  }
}

run "workload_identity_grants" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy-bitwisemedia-co-uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
  }

  assert {
    condition     = google_project_iam_member.workload["external-dns:roles/dns.admin"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/external-dns/sa/external-dns"
    error_message = "external-dns must get dns.admin as a direct federated principal"
  }

  assert {
    condition     = contains(keys(google_project_iam_member.workload), "cert-manager:roles/dns.admin")
    error_message = "cert-manager must get dns.admin for DNS-01 solving"
  }

  assert {
    condition     = contains(keys(google_project_iam_member.workload), "otel-collector:roles/monitoring.metricWriter")
    error_message = "the otel-collector must be able to write metrics"
  }

  assert {
    condition     = contains(keys(google_project_iam_member.workload), "kyverno-kyverno-admission-controller:roles/artifactregistry.reader")
    error_message = "kyverno's admission controller must read the registry to fetch signatures"
  }
}

run "no_dns_no_grants" {
  command = plan

  assert {
    condition     = !contains(keys(google_project_iam_member.workload), "external-dns:roles/dns.admin")
    error_message = "without a zone there must be no dns.admin grants"
  }

  assert {
    condition     = length(data.google_dns_managed_zone.cluster) == 0
    error_message = "without a zone there must be no zone lookup"
  }
}

run "observability_project_override" {
  command = plan

  variables {
    observability = {
      project = "o-o11y-ef56"
    }
  }

  assert {
    condition     = google_project_iam_member.workload["otel-collector:roles/monitoring.metricWriter"].project == "o-o11y-ef56"
    error_message = "otel grants must follow the observability project override"
  }
}

run "gateway_reservation" {
  command = plan

  assert {
    condition     = google_compute_global_address.gateway["true"].name == "patchy-x-gateway"
    error_message = "the gateway address must default to <name>-gateway"
  }
}

run "central_registry" {
  command = plan

  variables {
    platform_registry = "us-central1-docker.pkg.dev/o-foundation-7e43/platform"
  }

  assert {
    condition     = !contains(keys(google_project_iam_member.nodes), "roles/artifactregistry.reader")
    error_message = "a central registry cannot be covered by an in-project node grant (feed reader_members instead)"
  }

  assert {
    condition     = length([for k in keys(google_project_iam_member.workload) : k if startswith(k, "kyverno-")]) == 0
    error_message = "kyverno registry reads on a central registry come from artifact-store reader_members, not in-project grants"
  }

  assert {
    condition     = output.registry_reader_members[1] == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/flux-system/sa/source-controller"
    error_message = "the reader members must be exported"
  }

  assert {
    condition     = google_project_iam_member.registry_readers["principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/flux-system/sa/source-controller"].project == "o-foundation-7e43"
    error_message = "central-registry reader bindings must target the registry's project"
  }

  assert {
    condition     = contains(keys(google_project_iam_member.registry_readers), "serviceAccount:patchy-x-nodes@x-patchy-app-ab12.iam.gserviceaccount.com")
    error_message = "the node service account must be bound on the central registry too"
  }
}

run "local_registry_no_central_grants" {
  command = plan

  assert {
    condition     = length(google_project_iam_member.registry_readers) == 0
    error_message = "a co-located registry is covered by in-project grants; no central bindings"
  }
}

run "gateway_existing_address" {
  command = plan

  variables {
    gateway = {
      reserve_static_ip = false
      address_name      = "ingress"
    }
  }

  assert {
    condition     = length(google_compute_global_address.gateway) == 0
    error_message = "no address may be reserved when referencing an existing one"
  }

  assert {
    condition     = output.gateway.address_name == "ingress"
    error_message = "the existing address name (cloud-accounts' ingress) must flow through to the cluster vars"
  }
}

run "cluster_vars_contract" {
  command = plan

  assert {
    condition     = output.flux.cluster_vars.SECRET_PREFIX == ""
    error_message = "the default must publish an empty SECRET_PREFIX (unprefixed container names)"
  }

  assert {
    condition     = output.flux.cluster_vars.DEX_DIRECTORY_SA == ""
    error_message = "without sso there is no directory SA to publish (empty-string convention)"
  }

  assert {
    condition     = output.flux.cluster_vars.DEX_CONNECTORS == "[]"
    error_message = "without sso, DEX_CONNECTORS must publish the empty JSON array (not the empty string -- the manifests unconditionally mustFromJson-parse it)"
  }

  assert {
    condition     = output.flux.cluster_vars.FLUX_SYNC_CHANNEL == "stable"
    error_message = "the default sync channel (stable) must reach the stack's flux component"
  }

  assert {
    condition     = output.flux.cluster_vars.SIGNED_IDENTITY_MANIFESTS == "^https://github\\.com/bitwise-media-group/flux-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    error_message = "the manifests signing subject must be published for the stack's sync verify patch"
  }

  assert {
    condition     = output.flux.cluster_vars.SIGNED_IDENTITY_KMS_KEY == ""
    error_message = "keyless mode must blank the KMS key var (empty-string convention)"
  }

  assert {
    condition     = output.flux.cluster_vars.COSIGN_PUBLIC_KEY == ""
    error_message = "keyless mode distributes no key material (empty-string convention)"
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.kyverno_verifiers) == 0
    error_message = "keyless mode must grant kyverno no KMS access"
  }

  assert {
    condition     = output.flux.cluster_vars.DEX_CLIENTS == "[]"
    error_message = "without sso, DEX_CLIENTS must publish the empty JSON array (the manifests unconditionally mustFromJson-parse it)"
  }

  assert {
    condition     = output.flux.cluster_vars.PLATFORM_COMPONENTS == "flux-web"
    error_message = "the default election is flux-web alone, comma-joined and sorted (arc is opt-in, dex rides sso)"
  }

  assert {
    condition     = output.flux.cluster_vars.PLATFORM_TREE == "google"
    error_message = "PLATFORM_TREE must publish flux.sync.path, so applications select the same per-cloud tree the platform syncs"
  }

  assert {
    condition     = output.flux.cluster_vars.FLUX_SYNC_URL == "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/platform" && output.flux.sync_url == output.flux.cluster_vars.FLUX_SYNC_URL
    error_message = "the sync must default to the platform entrypoint image under the platform registry, and publish it so the flux component can re-point a running cluster"
  }

  assert {
    condition = alltrue([
      for key in ["DNS_ZONE_NAME", "DNS_DOMAIN", "PLATFORM_DOMAIN", "ACME_EMAIL"] :
      output.flux.cluster_vars[key] == ""
    ])
    error_message = "unset optional surfaces must publish empty strings, not null"
  }

  # Every google-specific key the google tree reads.
  assert {
    condition = (
      output.flux.cluster_vars.GCP_PROJECT == "x-patchy-app-ab12"
      && output.flux.cluster_vars.GCP_PROJECT_NUMBER == "123456789012"
      && output.flux.cluster_vars.GCP_REGION == "us-central1"
      && output.flux.cluster_vars.OTEL_PROJECT == "x-patchy-app-ab12"
      && output.flux.cluster_vars.GATEWAY_ADDRESS_NAME == "patchy-x-gateway"
    )
    error_message = "the google-specific keys (GCP_*, OTEL_PROJECT, GATEWAY_*) must keep publishing"
  }

  # The manifests default these on google (gcp / GARArtifactTag); publishing
  # them would only add a second source of truth.
  assert {
    condition     = !contains(keys(output.flux.cluster_vars), "OCI_PROVIDER") && !contains(keys(output.flux.cluster_vars), "ARTIFACT_TAG_PROVIDER") && !contains(keys(output.flux.cluster_vars), "CLOUD")
    error_message = "OCI_PROVIDER / ARTIFACT_TAG_PROVIDER are left to the google tree's defaults, and nothing may publish a CLOUD var"
  }

  # The generic-module guard: nothing application-specific may be published.
  assert {
    condition = length([
      for key in keys(local.reserved_cluster_vars) : key
      if key == "STACK_COMPONENTS" || startswith(key, "PATCHY_") || startswith(key, "CLAUDE_") || startswith(key, "AGENT_")
    ]) == 0
    error_message = "the cluster module knows no application: no STACK_COMPONENTS, PATCHY_*, CLAUDE_* or AGENT_* key may be published (application vars ride in <key>-vars)"
  }

  assert {
    condition     = length(module.flux_operator.applications) == 0 && length(output.flux.applications) == 0
    error_message = "a cluster with no applications seeds nothing - the platform alone is a complete deployment"
  }
}

run "stack_contract_kms_signing" {
  command = plan

  variables {
    signed_identity = {
      kms_key_name = "projects/o-foundation-7e43/locations/us-central1/keyRings/platform/cryptoKeys/cosign"
    }
  }

  assert {
    condition     = output.flux.cluster_vars.SIGNED_IDENTITY_KMS_KEY == "projects/o-foundation-7e43/locations/us-central1/keyRings/platform/cryptoKeys/cosign"
    error_message = "KMS mode must publish the signing key's resource name for the manifests' gcpkms:// references"
  }

  assert {
    condition = alltrue([
      for key in ["SIGNED_IDENTITY_ISSUER", "SIGNED_IDENTITY_CHARTS", "SIGNED_IDENTITY_IMAGES", "SIGNED_IDENTITY_MANIFESTS"] :
      output.flux.cluster_vars[key] == ""
    ])
    error_message = "KMS mode must blank every keyless identity var — the manifests select the mode by guarding on empties"
  }

  # The manifests render each verified namespace's cosign-pub Secret from
  # this var, so it must carry the signing key's public half base64-encoded
  # (Secret data format).
  assert {
    condition     = base64decode(output.flux.cluster_vars.COSIGN_PUBLIC_KEY) == "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----\n"
    error_message = "KMS mode must publish the signing key's public half as base64 PEM in COSIGN_PUBLIC_KEY"
  }

  assert {
    condition     = google_kms_crypto_key_iam_member.kyverno_verifiers["kyverno-admission-controller:verifier"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/kyverno/sa/kyverno-admission-controller"
    error_message = "kyverno's admission controller must be able to verify against the signing key as a direct federated principal"
  }

  assert {
    condition     = contains(keys(google_kms_crypto_key_iam_member.kyverno_verifiers), "kyverno-reports-controller:viewer")
    error_message = "kyverno's controllers need viewer too (cosign lists versions behind a versionless gcpkms:// reference)"
  }
}

run "signed_identity_modes_exclusive" {
  command = plan

  variables {
    signed_identity = {
      manifests_subject  = "^https://github\\.com/bitwise-media-group/flux-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
      containers_subject = "^https://github\\.com/bitwise-media-group/flux-containers/\\.github/workflows/publish\\.yaml@refs/heads/main$"
      kms_key_name       = "projects/o-foundation-7e43/locations/us-central1/keyRings/platform/cryptoKeys/cosign"
    }
  }

  expect_failures = [var.signed_identity]
}

run "signed_identity_needs_a_mode" {
  command = plan

  variables {
    signed_identity = {}
  }

  expect_failures = [var.signed_identity]
}

run "empty_election_publishes_none" {
  command = plan

  variables {
    platform_components = []
  }

  assert {
    condition     = output.flux.cluster_vars.PLATFORM_COMPONENTS == "none"
    error_message = "an explicitly-empty election must publish the reserved name 'none' -- an empty string would re-default to elect-everything in the manifests"
  }

  assert {
    condition     = length(google_secret_manager_secret.dex_client) == 0
    error_message = "no elected components, no SSO pairs"
  }
}

run "platform_components_reject_unknown" {
  command = plan

  variables {
    platform_components = ["flux-web", "patchy"]
  }

  expect_failures = [var.platform_components]
}

run "arc_is_electable" {
  command = plan

  variables {
    platform_components = ["arc", "flux-web"]
  }

  assert {
    condition     = output.flux.cluster_vars.PLATFORM_COMPONENTS == "arc,flux-web" && output.flux.platform_components == tolist(["arc", "flux-web"])
    error_message = "arc must be electable beside flux-web, published sorted and comma-joined"
  }
}

run "platform_contract_elected" {
  command = plan

  variables {
    secret_prefix = "patchy-x-"
    dns = {
      zone_name  = "patchy-bitwisemedia-co-uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled      = true
      directory_sa = "dex-directory@x-patchy-app-ab12.iam.gserviceaccount.com"
      connector = {
        type = "google"
        config = {
          clientID                       = "$GOOGLE_CLIENT_ID"
          fetchTransitiveGroupMembership = true
        }
      }
    }
  }

  assert {
    condition     = output.flux.cluster_vars.SECRET_PREFIX == "patchy-x-"
    error_message = "the secret prefix must flow through to the cluster vars"
  }

  assert {
    condition     = output.flux.cluster_vars.PLATFORM_COMPONENTS == "dex,flux-web"
    error_message = "the election must publish as comma-separated short names, dex joining via the sso toggle"
  }

  assert {
    condition     = output.flux.cluster_vars.PLATFORM_DOMAIN == "patchy.bitwisemedia.co.uk"
    error_message = "PLATFORM_DOMAIN must publish the served host (the zone apex when dns.host is unset)"
  }

  assert {
    condition = jsondecode(output.flux.cluster_vars.DEX_CLIENTS) == [{
      id           = "flux-web"
      name         = "Flux Status"
      public       = false
      redirectURIs = ["https://flux.patchy.bitwisemedia.co.uk/oauth2/callback"]
    }]
    error_message = "DEX_CLIENTS must publish the elected flux-web client as a confidential static client on the served domain"
  }

  assert {
    condition     = output.sso.issuer_url == "https://dex.patchy.bitwisemedia.co.uk" && output.sso.client_secrets["flux-web"] == "patchy-x-dex-client-flux-web"
    error_message = "the sso output must carry the issuer and the generated client container names"
  }

  assert {
    condition     = output.flux.cluster_vars.DEX_DIRECTORY_SA == "dex-directory@x-patchy-app-ab12.iam.gserviceaccount.com"
    error_message = "sso must publish the typed directory SA as the DEX_DIRECTORY_SA cluster var"
  }

  assert {
    condition     = google_service_account_iam_member.dex_directory[0].service_account_id == "projects/x-patchy-app-ab12/serviceAccounts/dex-directory@x-patchy-app-ab12.iam.gserviceaccount.com"
    error_message = "sso must bind workloadIdentityUser on the directory SA itself (project derived from the email), not expect cloud-accounts to"
  }

  assert {
    condition     = google_service_account_iam_member.dex_directory[0].member == "serviceAccount:x-patchy-app-ab12.svc.id.goog[dex/dex]"
    error_message = "the binding must pin this cluster's dex KSA in the classic annotation-based member form"
  }

  assert {
    condition     = [for c in jsondecode(output.flux.cluster_vars.DEX_CONNECTORS) : c.id][0] == "google"
    error_message = "an unset connector id must default to the connector type"
  }

  assert {
    condition     = [for c in jsondecode(output.flux.cluster_vars.DEX_CONNECTORS) : c.name][0] == "google"
    error_message = "an unset connector name must default to the connector id"
  }

  assert {
    condition     = [for c in jsondecode(output.flux.cluster_vars.DEX_CONNECTORS) : c.config.redirectURI][0] == "https://dex.patchy.bitwisemedia.co.uk/callback"
    error_message = "a connector with no explicit redirectURI must get the shared callback endpoint injected"
  }

  assert {
    condition     = [for c in jsondecode(output.flux.cluster_vars.DEX_CONNECTORS) : c.config.clientID][0] == "$GOOGLE_CLIENT_ID"
    error_message = "explicit connector config must pass through verbatim alongside the injected redirectURI"
  }

  # Regression guard for the map(any) footgun: config typed as map(any)
  # unifies its value types and stringifies bools ("true"), which dex then
  # rejects at startup (cannot unmarshal string into bool). Bare any on a
  # single connector object faces no unification -- see the sso variable's
  # type comment.
  assert {
    condition     = [for c in jsondecode(output.flux.cluster_vars.DEX_CONNECTORS) : c.config.fetchTransitiveGroupMembership][0] == true
    error_message = "connector config values must keep their native JSON types -- a bool must publish as true, not the string \"true\""
  }

  assert {
    condition     = toset([for c in jsondecode(output.flux.cluster_vars.DEX_CONNECTORS) : c.secrets][0]) == toset(["client-id", "client-secret"])
    error_message = "an unset connector secrets set must default to the client-id/client-secret pair"
  }
}

run "sso_requires_connector" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy-bitwisemedia-co-uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled = true
    }
  }

  expect_failures = [var.sso]
}

run "sso_directory_sa_independently_optional" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy-bitwisemedia-co-uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled = true
      connector = {
        id   = "okta"
        type = "oidc"
      }
    }
  }

  assert {
    condition     = length(google_service_account_iam_member.dex_directory) == 0
    error_message = "without directory_sa, no workloadIdentityUser binding may exist even though sso is enabled -- the connector doesn't need Google's directory delegation"
  }

  assert {
    condition     = output.flux.cluster_vars.DEX_DIRECTORY_SA == ""
    error_message = "DEX_DIRECTORY_SA must publish empty when directory_sa is unset, regardless of sso.enabled"
  }

  assert {
    condition     = [for c in jsondecode(output.flux.cluster_vars.DEX_CONNECTORS) : c.id][0] == "okta"
    error_message = "an explicit connector id must win over the type default"
  }

  assert {
    condition     = [for c in jsondecode(output.flux.cluster_vars.DEX_CONNECTORS) : c.name][0] == "okta"
    error_message = "an unset connector name must default to the explicit id, not the type"
  }
}

run "sso_requires_domain" {
  command = plan

  variables {
    sso = {
      enabled      = true
      directory_sa = "dex-directory@x-patchy-app-ab12.iam.gserviceaccount.com"
      connector    = { type = "google" }
    }
  }

  expect_failures = [var.sso]
}

run "sso_clients_reject_unknown_ids" {
  command = plan

  variables {
    sso = {
      clients = {
        dex = { version = 2 }
      }
    }
  }

  expect_failures = [var.sso]
}

run "sso_client_pairs" {
  command = plan

  variables {
    secret_prefix = "patchy-x-"
    dns = {
      zone_name  = "patchy-bitwisemedia-co-uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled      = true
      directory_sa = "dex-directory@x-patchy-app-ab12.iam.gserviceaccount.com"
      connector    = { type = "google" }
      clients = {
        flux-web = { version = 3 }
      }
    }
  }

  assert {
    condition     = google_secret_manager_secret.dex_client["flux-web"].secret_id == "patchy-x-dex-client-flux-web"
    error_message = "the generated client containers must carry the cluster's secret prefix"
  }

  assert {
    condition     = tostring(google_secret_manager_secret_version.dex_client["flux-web"].secret_data_wo_version) == "3" && tostring(google_secret_manager_secret_version.flux_web_auth_config[0].secret_data_wo_version) == "3"
    error_message = "a client's version must drive both the raw container and the composed config document, so a bump rotates the pair together"
  }

  assert {
    condition     = join(",", keys(google_secret_manager_secret_iam_member.dex_client_reader)) == "flux-web/ns/dex/sa/dex-secrets"
    error_message = "dex alone reads the raw client secret; flux-web's consumer reads the composed config document"
  }

  assert {
    condition     = google_secret_manager_secret.flux_web_auth_config[0].secret_id == "patchy-x-flux-web-auth-config"
    error_message = "the composed flux-web config container must carry the prefix too"
  }

}

run "sso_follows_election" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy-bitwisemedia-co-uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled      = true
      directory_sa = "dex-directory@x-patchy-app-ab12.iam.gserviceaccount.com"
      connector    = { type = "google" }
    }
    platform_components = []
  }

  assert {
    condition     = length(google_secret_manager_secret.dex_client) == 0
    error_message = "an unelected relying party must get no client secret"
  }

  assert {
    condition     = length(google_secret_manager_secret.flux_web_auth_config) == 0
    error_message = "an unelected relying party must get no config document"
  }

  assert {
    condition     = output.flux.cluster_vars.PLATFORM_COMPONENTS == "dex" && output.flux.cluster_vars.DEX_CLIENTS == "[]"
    error_message = "dex still deploys on the sso toggle, with no platform clients to serve"
  }
}

run "sso_disabled_no_pairs" {
  command = plan

  assert {
    condition     = length(google_secret_manager_secret.dex_client) == 0
    error_message = "sso off (the default) must generate no client pairs"
  }
}

run "applications_seeded" {
  command = plan

  variables {
    applications = {
      demo = {
        url        = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/demo"
        semver     = "<1.0.0 >=0.1.0"
        depends_on = ["kyverno-policies", "gateway"]
        verify     = { subject = "^https://github\\.com/org/demo-app-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$" }
      }
      external = {
        url         = "oci://ghcr.io/org/external-manifests"
        path        = "./deploy/gke"
        verify      = { issuer = "^https://token\\.actions\\.githubusercontent\\.com$", subject = "^https://github\\.com/org/external/.+$" }
        pull_secret = "ghcr-pull"
      }
    }
  }

  # The registry, never the cloud, picks the listing/pull dialect: under the
  # platform prefix the flux controllers reach Artifact Registry with their
  # Workload Identity; anywhere else is a generic OCI listing and pull.
  assert {
    condition     = output.flux.applications["demo"].tag_provider == "GARArtifactTag" && output.flux.applications["demo"].oci_provider == "gcp"
    error_message = "an image under the platform registry must be listed with GARArtifactTag and pulled as provider gcp"
  }

  assert {
    condition     = output.flux.applications["external"].tag_provider == "OCIArtifactTag" && output.flux.applications["external"].oci_provider == "generic"
    error_message = "an image outside the platform registry must be listed with OCIArtifactTag and pulled as provider generic"
  }

  # Defaults resolve against cluster facts: the per-cloud tree the platform
  # syncs, and the platform's own keyless issuer.
  assert {
    condition     = output.flux.applications["demo"].path == "./deploy/google" && output.flux.applications["external"].path == "./deploy/gke"
    error_message = "path must default to ./deploy/<flux.sync.path> and pass through when set"
  }

  assert {
    condition     = local.applications["demo"].verify.issuer == var.signed_identity.issuer && local.applications["external"].verify.issuer == "^https://token\\.actions\\.githubusercontent\\.com$"
    error_message = "a keyless application's issuer must default to signed_identity.issuer and pass through when set"
  }

  assert {
    condition     = output.flux.applications["demo"].release == "application-demo" && output.flux.applications["demo"].namespace == "flux-system"
    error_message = "each application must seed one bootstrap-only release in flux-system"
  }

  assert {
    condition     = output.flux.applications["demo"].url == "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/demo"
    error_message = "the flux output must carry each application's url"
  }
}

run "applications_reject_unverified" {
  command = plan

  variables {
    applications = {
      demo = {
        url    = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/demo"
        verify = {}
      }
    }
  }

  expect_failures = [var.applications]
}

run "applications_reject_keyed_without_kms" {
  command = plan

  variables {
    applications = {
      demo = {
        url    = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/demo"
        verify = { keyed = true }
      }
    }
  }

  expect_failures = [var.applications]
}

run "applications_reject_foreign_artifact_registry" {
  command = plan

  variables {
    applications = {
      demo = {
        url    = "oci://europe-west2-docker.pkg.dev/other-project/other/manifests/demo"
        verify = { subject = "^https://github\\.com/org/demo/.+$" }
      }
    }
  }

  # The flux controllers hold read rights on the platform repository alone,
  # so an Artifact Registry image anywhere else could never be listed or
  # pulled.
  expect_failures = [var.applications]
}

run "applications_reject_platform_names" {
  command = plan

  variables {
    applications = {
      kyverno = {
        url    = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/kyverno"
        verify = { subject = "^https://github\\.com/org/kyverno/.+$" }
      }
    }
  }

  expect_failures = [var.applications]
}

run "applications_reject_tagged_url" {
  command = plan

  variables {
    applications = {
      demo = {
        url    = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/demo:1.2.3"
        verify = { subject = "^https://github\\.com/org/demo/.+$" }
      }
    }
  }

  expect_failures = [var.applications]
}

run "application_vars_render" {
  command = plan

  variables {
    application_vars = {
      demo = {
        DEMO_DOMAIN    = "demo.example.com"
        DEMO_HARNESSES = "claude"
      }
    }
  }

  # The rendering itself (one <key>-vars ConfigMap per entry) is asserted in
  # the flux-operator module's own suite; here the contract is separation.
  assert {
    condition     = !contains(keys(local.reserved_cluster_vars), "DEMO_DOMAIN") && !contains(keys(output.flux.cluster_vars), "DEMO_DOMAIN")
    error_message = "application vars must never leak into cluster-vars"
  }
}

run "application_vars_reject_lowercase_keys" {
  command = plan

  variables {
    application_vars = {
      demo = { demoDomain = "x" }
    }
  }

  expect_failures = [var.application_vars]
}

run "workload_grants_become_members" {
  command = plan

  variables {
    workload_grants = {
      egress-broker = {
        namespace       = "demo"
        service_account = "egress-broker"
        roles           = ["roles/aiplatform.user"]
      }
      exporter = {
        namespace       = "demo"
        service_account = "exporter"
        roles           = ["roles/bigquery.dataEditor", "projects/o-data-ef56/roles/exportWriter"]
        project         = "o-data-ef56"
      }
    }
  }

  assert {
    condition     = google_project_iam_member.workload["egress-broker:roles/aiplatform.user"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/demo/sa/egress-broker"
    error_message = "an application grant must bind its pair as a direct federated principal, exactly like the platform grants"
  }

  assert {
    condition     = google_project_iam_member.workload["egress-broker:roles/aiplatform.user"].project == "x-patchy-app-ab12"
    error_message = "a grant without a project lands in the cluster's own"
  }

  assert {
    condition = (
      google_project_iam_member.workload["exporter:roles/bigquery.dataEditor"].project == "o-data-ef56"
      && google_project_iam_member.workload["exporter:projects/o-data-ef56/roles/exportWriter"].role == "projects/o-data-ef56/roles/exportWriter"
    )
    error_message = "each (grant, role) pair is one member binding, in the grant's own project when set"
  }

  assert {
    condition     = output.workload_members["exporter"] == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/demo/sa/exporter"
    error_message = "workload_members must name every grant's principal, for resource-side grants in the caller"
  }

  assert {
    condition     = contains(keys(output.workload_members), "otel-collector")
    error_message = "the platform grants are exported beside the application ones"
  }
}

run "workload_grants_reject_platform_keys" {
  command = plan

  variables {
    workload_grants = {
      external-dns = { namespace = "x", service_account = "y", roles = ["roles/dns.admin"] }
    }
  }

  expect_failures = [var.workload_grants]
}

run "workload_grants_reject_bare_roles" {
  command = plan

  variables {
    workload_grants = {
      broker = { namespace = "x", service_account = "y", roles = ["aiplatform.user"] }
    }
  }

  expect_failures = [var.workload_grants]
}

# The contract modules/application reads to publish an application from a
# root of its own: the same facts the cluster root resolves its own seeds
# and workload grants from.
run "application_target" {
  command = plan

  variables {
    secret_prefix = "patchy-x-"
  }

  assert {
    condition = (
      output.application_target.namespace == "flux-system"
      && output.application_target.platform_registry == var.platform_registry
      && output.application_target.tree == "google"
      && output.application_target.secret_prefix == "patchy-x-"
      && output.secret_prefix == "patchy-x-"
    )
    error_message = "application_target must carry the flux namespace, platform registry, tree and secret prefix"
  }

  assert {
    condition = (
      output.application_target.project == "x-patchy-app-ab12"
      && output.application_target.project_number == "123456789012"
      && output.application_target.workload_pool == "x-patchy-app-ab12.svc.id.goog"
    )
    error_message = "application_target must carry the project, project number and pool its workload grants compose principals from"
  }

  assert {
    condition     = output.application_target.keyed == false && output.application_target.issuer == var.signed_identity.issuer
    error_message = "a keyless cluster hands applications its own issuer as the verify default"
  }
}

run "application_target_keyed" {
  command = plan

  variables {
    signed_identity = {
      kms_key_name = "projects/o-foundation-7e43/locations/us-central1/keyRings/platform/cryptoKeys/cosign"
    }
  }

  assert {
    condition     = output.application_target.keyed == true && output.application_target.issuer == null
    error_message = "a KMS-keyed cluster has no keyless issuer to hand on, only the keyed flag"
  }
}

run "sso_kubectl_workforce" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy-bitwisemedia-co-uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled   = true
      connector = { type = "google" }
      kubectl = {
        enabled         = true
        organization_id = "282673588123"
      }
      clients = {
        gcp-workforce = { version = 2 }
      }
    }
  }

  assert {
    condition = (
      google_iam_workforce_pool.dex["true"].parent == "organizations/282673588123"
      && google_iam_workforce_pool.dex["true"].workforce_pool_id == "patchy-x-dex"
      && google_iam_workforce_pool.dex["true"].location == "global"
    )
    error_message = "the workforce pool must default to <name>-dex under the given organization"
  }

  assert {
    condition     = google_iam_workforce_pool_provider.dex["true"].oidc[0].issuer_uri == "https://dex.patchy.bitwisemedia.co.uk" && google_iam_workforce_pool_provider.dex["true"].oidc[0].client_id == "gcp-workforce"
    error_message = "the workforce provider must trust dex on the served domain through the workforce client"
  }

  assert {
    condition = (
      google_iam_workforce_pool_provider.dex["true"].oidc[0].web_sso_config[0].response_type == "CODE"
      && google_iam_workforce_pool_provider.dex["true"].oidc[0].web_sso_config[0].assertion_claims_behavior == "MERGE_USER_INFO_OVER_ID_TOKEN_CLAIMS"
      && contains(google_iam_workforce_pool_provider.dex["true"].oidc[0].web_sso_config[0].additional_scopes, "groups")
    )
    error_message = "web sign-in must run the authorization-code flow, merge userinfo and ask dex for the groups scope"
  }

  assert {
    condition     = google_iam_workforce_pool_provider.dex["true"].attribute_mapping["google.subject"] == "assertion.email" && google_iam_workforce_pool_provider.dex["true"].attribute_mapping["google.groups"] == "assertion.groups"
    error_message = "the federated subject is the dex email and the groups its groups claim (what rbac.groups binds)"
  }

  # One rotation counter drives both halves of the pair.
  assert {
    condition     = google_iam_workforce_pool_provider.dex["true"].oidc[0].client_secret[0].value[0].plain_text_wo_version == "2" && tostring(google_secret_manager_secret_version.dex_client["gcp-workforce"].secret_data_wo_version) == "2"
    error_message = "the workforce client's version must drive both the dex-client container and the provider's write-only secret"
  }

  assert {
    condition = contains(jsondecode(output.flux.cluster_vars.DEX_CLIENTS), {
      id           = "gcp-workforce"
      name         = "Google Cloud"
      public       = false
      redirectURIs = ["https://auth.cloud.google/signin-callback/locations/global/workforcePools/patchy-x-dex/providers/dex-oidc"]
    })
    error_message = "DEX_CLIENTS must publish the workforce client as confidential, redirecting to Google's workforce sign-in callback"
  }

  assert {
    condition     = google_secret_manager_secret.dex_client["gcp-workforce"].secret_id == "dex-client-gcp-workforce" && contains(keys(google_secret_manager_secret_iam_member.dex_client_reader), "gcp-workforce/ns/dex/sa/dex-secrets")
    error_message = "the workforce client's secret must be minted like flux-web's and read by dex/dex-secrets"
  }

  assert {
    condition     = google_project_iam_member.kubectl_cluster_viewer["true"].role == "roles/container.clusterViewer" && google_project_iam_member.kubectl_cluster_viewer["true"].member == "principalSet://iam.googleapis.com/locations/global/workforcePools/patchy-x-dex/*" && google_project_iam_member.kubectl_cluster_viewer["true"].project == "x-patchy-app-ab12"
    error_message = "every pool principal must be able to get-credentials (clusterViewer); RBAC does the authorization"
  }

  assert {
    condition     = output.kubectl_oidc.group_principal_prefix == "principalSet://iam.googleapis.com/locations/global/workforcePools/patchy-x-dex/group/" && length(output.kubectl_oidc.login) == 3
    error_message = "kubectl_oidc must export the group principal prefix and the three login steps"
  }
}

run "sso_kubectl_off_by_default" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy-bitwisemedia-co-uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled   = true
      connector = { type = "google" }
    }
  }

  assert {
    condition     = length(google_iam_workforce_pool.dex) == 0 && length(google_project_iam_member.kubectl_cluster_viewer) == 0 && output.kubectl_oidc == null
    error_message = "kubectl through dex is opt-in: no pool, no grant, no output"
  }

  assert {
    condition     = join(",", keys(google_secret_manager_secret.dex_client)) == "flux-web"
    error_message = "without sso.kubectl the only platform client is flux-web"
  }
}

run "sso_kubectl_requires_org" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy-bitwisemedia-co-uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled   = true
      connector = { type = "google" }
      kubectl   = { enabled = true }
    }
  }

  expect_failures = [var.sso]
}

run "sso_kubectl_requires_sso" {
  command = plan

  variables {
    sso = {
      kubectl = { enabled = true, organization_id = "282673588123" }
    }
  }

  expect_failures = [var.sso]
}

run "sso_kubectl_rejects_bad_pool_id" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy-bitwisemedia-co-uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled   = true
      connector = { type = "google" }
      kubectl   = { enabled = true, organization_id = "282673588123", pool_id = "Dex" }
    }
  }

  expect_failures = [var.sso]
}

run "rbac_groups_accept_principal_set" {
  command = plan

  variables {
    rbac = {
      groups = {
        admins  = "principalSet://iam.googleapis.com/locations/global/workforcePools/patchy-x-dex/group/platform-admins"
        viewers = "principalSet://iam.googleapis.com/locations/global/workforcePools/patchy-x-dex/group/platform-viewers"
      }
    }
  }

  assert {
    condition     = output.flux.cluster_vars.RBAC_GROUP_ADMINS == "principalSet://iam.googleapis.com/locations/global/workforcePools/patchy-x-dex/group/platform-admins"
    error_message = "a workforce principalSet must publish verbatim as its RBAC_GROUP_* var"
  }

  assert {
    condition     = google_container_cluster.main.authenticator_groups_config[0].security_group == ""
    error_message = "a principalSet subject needs no Google Groups RBAC - the authenticator stays off"
  }
}

run "rbac_groups_reject_email_without_toggle" {
  command = plan

  variables {
    rbac = {
      groups = { admins = "gcp-x-patchy-admins@bitwisemedia.co.uk" }
    }
  }

  expect_failures = [var.rbac]
}

run "rbac_groups_reject_garbage" {
  command = plan

  variables {
    rbac = {
      enabled = true
      domain  = "bitwisemedia.co.uk"
      groups  = { admins = "principalSet://iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/group/x" }
    }
  }

  expect_failures = [var.rbac]
}
