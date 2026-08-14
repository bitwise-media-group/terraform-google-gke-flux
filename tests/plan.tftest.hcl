# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with mocked providers: no credentials, no API
# calls. These assert the cluster shape (shared-VPC wiring, Dataplane V2,
# Workload Identity, Gateway API, NAP) and the terraform -> flux contract
# (workload identity grants, cluster vars).

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
  name    = "patchy-x"
  project = "x-patchy-app-ab12"
  region  = "us-central1"

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

run "stack_contract_defaults" {
  command = plan

  assert {
    condition     = output.flux.cluster_vars.SECRET_PREFIX == ""
    error_message = "the default must publish an empty SECRET_PREFIX (unprefixed container names)"
  }

  assert {
    condition     = output.flux.cluster_vars.STACK_COMPONENTS == "flux-web,patchy"
    error_message = "the default election must publish the whole optional tier explicitly -- without dex, which rides the sso toggle"
  }

  assert {
    condition     = output.flux.cluster_vars.DEX_DIRECTORY_SA == ""
    error_message = "without sso there is no directory SA to publish (empty-string convention)"
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
    condition     = length(google_kms_crypto_key_iam_member.kyverno_verifiers) == 0
    error_message = "keyless mode must grant kyverno no KMS access"
  }

  assert {
    condition     = output.flux.cluster_vars.CLAUDE_PROVIDER == "anthropic"
    error_message = "the claude provider must default to anthropic (the egress-broker's default upstream)"
  }

  assert {
    condition     = output.flux.cluster_vars.CLAUDE_ANTHROPIC_AUTH == "token"
    error_message = "anthropic auth must default to token"
  }

  assert {
    condition = alltrue([
      for key in ["CLAUDE_BEDROCK_REGION", "CLAUDE_BEDROCK_REGION_PREFIX", "CLAUDE_VERTEX_REGION", "CLAUDE_VERTEX_PROJECT_ID", "CLAUDE_MODEL_MAP"] :
      output.flux.cluster_vars[key] == ""
    ])
    error_message = "every non-anthropic provider var must publish empty by default (empty-string convention; bedrock is always empty on GKE)"
  }

  assert {
    condition     = !contains(keys(google_project_iam_member.workload), "patchy-egress-broker:roles/aiplatform.user")
    error_message = "the anthropic provider must grant the egress-broker no Vertex AI access"
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

  assert {
    condition     = google_kms_crypto_key_iam_member.kyverno_verifiers["kyverno-admission-controller:verifier"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/kyverno/sa/kyverno-admission-controller"
    error_message = "kyverno's admission controller must be able to verify against the signing key as a direct federated principal"
  }

  assert {
    condition     = contains(keys(google_kms_crypto_key_iam_member.kyverno_verifiers), "kyverno-reports-controller:viewer")
    error_message = "kyverno's controllers need viewer too (cosign lists versions behind a versionless gcpkms:// reference)"
  }
}

run "claude_provider_vertex" {
  command = plan

  variables {
    patchy = {
      claude = {
        provider = {
          name = "vertex"
          model_map = {
            "anthropic/claude-opus-5"   = "claude-opus-5"
            "anthropic/claude-sonnet-5" = "claude-sonnet-5"
          }
        }
      }
    }
  }

  assert {
    condition     = output.flux.cluster_vars.CLAUDE_VERTEX_REGION == "us-central1"
    error_message = "the vertex region must default onto the cluster's own region"
  }

  assert {
    condition     = output.flux.cluster_vars.CLAUDE_VERTEX_PROJECT_ID == "x-patchy-app-ab12"
    error_message = "the vertex project must default onto the cluster's own project"
  }

  assert {
    condition     = output.flux.cluster_vars.CLAUDE_MODEL_MAP == "anthropic/claude-opus-5=claude-opus-5,anthropic/claude-sonnet-5=claude-sonnet-5"
    error_message = "the model map must publish as comma-joined sorted canonical=providerID pairs"
  }

  assert {
    condition     = google_project_iam_member.workload["patchy-egress-broker:roles/aiplatform.user"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/patchy/sa/patchy-egress-broker"
    error_message = "the egress-broker must get aiplatform.user as a direct federated principal"
  }

  assert {
    condition     = google_project_iam_member.workload["patchy-egress-broker:roles/aiplatform.user"].project == "x-patchy-app-ab12"
    error_message = "the vertex grant must land in the serving project (the cluster's own by default)"
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

run "stack_contract_nothing_elected" {
  command = plan

  variables {
    stack_components = []
  }

  assert {
    condition     = output.flux.cluster_vars.STACK_COMPONENTS == "none"
    error_message = "an explicitly-empty election must publish the reserved name 'none' -- an empty string would re-default to elect-everything in the manifests"
  }

  assert {
    condition     = length(google_secret_manager_secret.dex_client) == 0
    error_message = "no elected components, no SSO pairs"
  }
}

run "stack_contract_elected" {
  command = plan

  variables {
    secret_prefix    = "patchy-x-"
    stack_components = ["patchy"]
    dns = {
      zone_name  = "patchy-bitwisemedia-co-uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled      = true
      directory_sa = "dex-directory@x-patchy-app-ab12.iam.gserviceaccount.com"
    }
  }

  assert {
    condition     = output.flux.cluster_vars.SECRET_PREFIX == "patchy-x-"
    error_message = "the secret prefix must flow through to the cluster vars"
  }

  assert {
    condition     = output.flux.cluster_vars.STACK_COMPONENTS == "dex,patchy"
    error_message = "the election must publish as comma-separated short names, dex joining via the sso toggle"
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
}

run "sso_requires_directory_sa" {
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

run "sso_requires_domain" {
  command = plan

  variables {
    sso = {
      enabled      = true
      directory_sa = "dex-directory@x-patchy-app-ab12.iam.gserviceaccount.com"
    }
  }

  expect_failures = [var.sso]
}

run "sso_rotation_rejects_unknown_clients" {
  command = plan

  variables {
    sso = {
      client_rotation = {
        dex = 2
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
    }
  }

  assert {
    condition     = google_secret_manager_secret.dex_client["flux-web"].secret_id == "patchy-x-dex-client-flux-web"
    error_message = "the generated client containers must carry the cluster's secret prefix"
  }

  assert {
    condition     = google_secret_manager_secret.flux_web_auth_config[0].secret_id == "patchy-x-flux-web-auth-config"
    error_message = "the composed flux-web config container must carry the prefix too"
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.dex_client_reader["patchy-status/ns/patchy/sa/patchy-secrets"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/patchy/sa/patchy-secrets"
    error_message = "the patchy status server must read its client secret as a direct federated principal"
  }

  assert {
    condition     = strcontains(google_secret_manager_secret_version.patchy_status_auth_config[0].secret_data, "https://dex.patchy.bitwisemedia.co.uk")
    error_message = "the status auth document must point at the platform dex on the served domain"
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
    }
    stack_components = ["patchy"]
  }

  assert {
    condition     = !contains(keys(google_secret_manager_secret.dex_client), "flux-web")
    error_message = "an unelected relying party must get no client secret"
  }

  assert {
    condition     = length(google_secret_manager_secret.flux_web_auth_config) == 0
    error_message = "an unelected relying party must get no config document"
  }

  assert {
    condition     = contains(keys(google_secret_manager_secret.dex_client), "patchy-status")
    error_message = "elected relying parties keep their client pairs"
  }
}

run "sso_disabled_no_pairs" {
  command = plan

  assert {
    condition     = length(google_secret_manager_secret.dex_client) == 0
    error_message = "sso off (the default) must generate no client pairs"
  }
}
