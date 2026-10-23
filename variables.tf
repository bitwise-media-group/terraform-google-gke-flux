# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "name" {
  description = "Cluster name. Also prefixes the node service account and the default gateway address name."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,22})$", var.name))
    error_message = "name must be a short lowercase RFC-1035 label (it prefixes service-account ids with tight length limits)."
  }
}

variable "project" {
  description = <<-EOT
    Project ID the cluster lives in (a shared-VPC service project, e.g. x-patchy-app-<rand4>). If not specified, the
    provider profile will be used.
  EOT
  type        = string
  nullable    = true
}

variable "location" {
  description = <<-EOT
    Region for a regional cluster (e.g. us-central1) or zone for a zonal one (e.g. us-central1-a). The GKE free tier
    covers the management fee of one zonal (or Autopilot) cluster per billing account -- a fee regional clusters
    always pay. Location is immutable: moving between regional and zonal replaces the cluster.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9](-[a-z])?$", var.location))
    error_message = "location must be a region (e.g. us-central1) or a zone (e.g. us-central1-a)."
  }
}

variable "zones" {
  description = <<-EOT
    Optional zone narrowing for node locations (cost control); null runs nodes in every zone of the region (regional
    clusters) or in the control-plane zone alone (zonal clusters).
  EOT
  type        = set(string)
  nullable    = false
  default     = []
}

variable "network" {
  description = <<-EOT
    Shared-VPC wiring: network/subnetwork self-links into the HOST project and the names of the GKE secondary ranges on
    that subnet (all created by cloud-accounts).
  EOT
  type = object({
    network             = string
    subnetwork          = string
    pods_range_name     = string
    services_range_name = string
  })
  nullable = false
}

variable "kubernetes_version" {
  description = "Optional minimum master version pin; null lets the release channel govern."
  type        = string
  nullable    = true
  default     = null
}

variable "release_channel" {
  description = "GKE release channel (RAPID, REGULAR, STABLE)."
  type        = string
  nullable    = false
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "deletion_protection" {
  description = <<-EOT
    Terraform-level destroy protection for the cluster. Off by default: this environment is disposable by design.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "private_endpoint" {
  description = <<-EOT
    Serve the control-plane endpoint privately only. Off by default so terraform/helm bootstrap works without a VPN path
    into the shared VPC.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "master_authorized_networks" {
  description = <<-EOT
    CIDRs allowed to reach the public control-plane endpoint. Empty leaves the endpoint open (PoC posture) — constrain
    it as soon as a stable egress CIDR exists.
  EOT
  type = list(object({
    cidr_block   = string
    display_name = optional(string)
  }))
  nullable = false
  default  = []
}

variable "rbac" {
  description = <<-EOT
    Google Groups for RBAC, off by default. When enabled, the cluster authenticator trusts gke-security-groups@<domain>
    — the exact name is a GKE requirement. The group itself and the member groups usable as Role/ClusterRoleBinding
    subjects are managed out-of-band in Workspace, never here. groups names the per-role subject groups published to
    the platform manifests as RBAC_GROUP_<ROLE> cluster vars, verbatim. Each is either a Google Group email -- nested
    under the fleet group (out-of-band) for the authenticator to honour it, so it requires enabled -- or a workforce
    identity group principal set (principalSet://iam.googleapis.com/locations/global/workforcePools/<pool>/group/<group>,
    the kubectl_oidc output's group_principal_prefix plus a dex group), which GKE resolves through workforce identity
    federation (sso.kubectl) with no Google Groups RBAC involved.
  EOT
  type = object({
    enabled = optional(bool, false)
    domain  = optional(string)
    groups = optional(object({
      viewers    = optional(string)
      developers = optional(string)
      devops     = optional(string)
      admins     = optional(string)
    }), {})
  })
  nullable = false
  default  = {}

  validation {
    condition     = !var.rbac.enabled || var.rbac.domain != null
    error_message = "rbac.domain is required when rbac.enabled is set (the Workspace domain hosting gke-security-groups)."
  }

  validation {
    condition = var.rbac.enabled || alltrue([
      for group in values(var.rbac.groups) : group == null || startswith(group, "principalSet://")
    ])
    error_message = "A Google Group email in rbac.groups requires rbac.enabled — without Google Groups RBAC the cluster ignores group subjects (a workforce principalSet needs no toggle)."
  }

  validation {
    condition = alltrue([
      for group in values(var.rbac.groups) : group == null || can(regex(
        "^([^@\\s/]+@[^@\\s]+|principalSet://iam\\.googleapis\\.com/locations/global/workforcePools/[a-z][a-z0-9-]{4,61}[a-z0-9]/group/[^\\s/]+)$",
        group,
      ))
    ])
    error_message = "Each rbac.groups entry must be a group email address (e.g. gcp-x-app-developers@example.com) or a workforce group principal set (principalSet://iam.googleapis.com/locations/global/workforcePools/<pool>/group/<group>)."
  }
}

variable "system_node_pool" {
  description = <<-EOT
    The always-on system node pool platform controllers pin to (label role=system). Autoscaling counts are per zone in
    a regional pool.
  EOT
  type = object({
    machine_type  = optional(string, "e2-standard-2")
    min_size      = optional(number, 1)
    max_size      = optional(number, 2)
    initial_size  = optional(number, 1)
    disk_size_gib = optional(number, 50)
  })
  nullable = false
  default  = {}
}

variable "node_auto_provisioning" {
  description = <<-EOT
    Node auto-provisioning (NAP) limits for workload capacity — the cluster-wide ceilings across all auto-provisioned
    pools.
  EOT
  type = object({
    min_cpu        = optional(number, 0)
    max_cpu        = optional(number, 64)
    min_memory_gib = optional(number, 0)
    max_memory_gib = optional(number, 256)
    disk_size_gib  = optional(number, 100)
  })
  nullable = false
  default  = {}
}

variable "platform_registry" {
  description = <<-EOT
    The platform Artifact Registry prefix everything is consumed from (artifact-store module's platform_registry
    output), e.g. us-central1-docker.pkg.dev/o-foundation-7e43/platform (the central store) or a co-located one.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9-]+-docker\\.pkg\\.dev/[^/]+/[^/]+$", var.platform_registry))
    error_message = "platform_registry must be an Artifact Registry docker repository prefix: <location>-docker.pkg.dev/<project>/<repository>."
  }
}

variable "signed_identity" {
  description = <<-EOT
    Cosign verification identity for every platform artifact — exactly one of two modes.

    KEYLESS (subjects set, kms_key_name null): Go regexps matched against the Fulcio certificate of GitHub Actions OIDC
    signatures. The artifact-store module's signed_identity_subjects output provides the subjects; the issuer default
    matches GitHub Actions. Cloud agnostic — the signing identities are GitHub's, not Google's, so the same values
    serve clusters on any cloud.

    KMS (kms_key_name set, subjects null): the publish workflows sign with an asymmetric SIGN Cloud KMS key
    (cosign sign --key gcpkms://<name>; the artifact-store module's signing_kms_key_name grants the publishers
    signerVerifier). The key's public half is distributed to the cluster as the flux-system cosign-pub Secret for the
    bootstrap verify patch, the key name is published as the SIGNED_IDENTITY_KMS_KEY cluster var, and kyverno's
    controllers get cloudkms verifier/viewer on the key to resolve it at admission time.
  EOT
  type = object({
    issuer             = optional(string, "^https://token\\.actions\\.githubusercontent\\.com$")
    manifests_subject  = optional(string)
    containers_subject = optional(string)
    kms_key_name       = optional(string)
  })
  nullable = false

  validation {
    condition = var.signed_identity.kms_key_name != null || (
      var.signed_identity.manifests_subject != null && var.signed_identity.containers_subject != null
    )
    error_message = "Keyless verification needs both manifests_subject and containers_subject (or set kms_key_name for KMS mode)."
  }

  validation {
    condition = var.signed_identity.kms_key_name == null || (
      var.signed_identity.manifests_subject == null && var.signed_identity.containers_subject == null
    )
    error_message = "kms_key_name and the keyless subjects are mutually exclusive — verification is keyless or KMS, never both."
  }

  validation {
    condition = var.signed_identity.kms_key_name == null || can(
      regex("^projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+$", var.signed_identity.kms_key_name)
    )
    error_message = "signed_identity.kms_key_name must be a Cloud KMS crypto key resource name: projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>."
  }
}

variable "dns" {
  description = <<-EOT
    Existing delegated Cloud DNS zone (created by cloud-accounts; never owned here). zone_name enables the DNS/TLS
    surface: external-dns + cert-manager IAM grants and the DNS_* / PLATFORM_DOMAIN cluster vars. host optionally
    narrows the served host below the zone apex (PLATFORM_DOMAIN, the parent of the dex. and flux. hosts).
  EOT
  type = object({
    zone_name  = optional(string)
    host       = optional(string)
    acme_email = optional(string)
  })
  nullable = false
  default  = {}

  validation {
    condition     = var.dns.zone_name == null || var.dns.acme_email != null
    error_message = "dns.acme_email is required when dns.zone_name is set (Let's Encrypt registration for the cert-manager issuers)."
  }
}

variable "gateway" {
  description = <<-EOT
    The platform Gateway's global static IP, stable across cluster recreation. Reserve one here (default; address_name
    defaults to <name>-gateway) or reference an existing address by name with reserve_static_ip = false (e.g.
    cloud-accounts' `ingress` address in x-patchy-app).
  EOT
  type = object({
    reserve_static_ip = optional(bool, true)
    address_name      = optional(string)
  })
  nullable = false
  default  = {}
}

variable "workload_identity" {
  description = <<-EOT
    Namespace/service-account pairs the direct Workload Identity grants bind to — the terraform <-> platform manifests
    contract. Override only to track a manifests change.
  EOT
  type = object({
    external_dns = optional(object({
      namespace       = optional(string, "external-dns")
      service_account = optional(string, "external-dns")
    }), {})
    cert_manager = optional(object({
      namespace       = optional(string, "cert-manager")
      service_account = optional(string, "cert-manager")
    }), {})
    otel_collector = optional(object({
      namespace       = optional(string, "otel-collector")
      service_account = optional(string, "otel-collector")
    }), {})
    kyverno = optional(object({
      namespace = optional(string, "kyverno")
      # the controllers that fetch image signatures from the registry at
      # admission/report time
      service_accounts = optional(list(string), ["kyverno-admission-controller", "kyverno-reports-controller"])
    }), {})
    # dex impersonates the directory-reader SA via the classic
    # annotation-based flow, so its pair binds workloadIdentityUser on that
    # SA (sso.tf) instead of receiving a direct principal:// grant
    dex = optional(object({
      namespace       = optional(string, "dex")
      service_account = optional(string, "dex")
    }), {})
  })
  nullable = false
  default  = {}
}

variable "observability" {
  description = <<-EOT
    Optional central observability project the otel-collector writes telemetry to; null targets the cluster's own
    project.
  EOT
  type = object({
    project = optional(string)
  })
  nullable = false
  default  = {}
}

variable "managed_opentelemetry" {
  description = <<-EOT
    Enable Managed OpenTelemetry for GKE (Preview): Google's in-cluster OTLP pipeline (HTTP endpoint
    opentelemetry-collector.gke-managed-otel:4318) shipping traces/logs/metrics to the CLUSTER project's Cloud
    Trace/Logging/Monitoring -- it cannot target observability.project. Per-cluster pilot toggle for retiring the
    self-hosted otel-collector component; requires GKE >= 1.34.1-gke.2178000.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "secret_sync" {
  description = <<-EOT
    Enable the Secret Manager CSI add-on plus GKE Integrated Secret Synchronization -- the SecretProviderClass and
    SecretSync CRDs the platform manifests (dex, flux-web) and applications use to materialise Secret Manager secrets
    as Kubernetes Secrets. Requires GKE >= 1.33 and Workload Identity (always on here). The generated dex client
    secrets live in this module (sso.tf); the out-of-band dex connector containers come from modules/sso-secrets,
    instantiated in a durable root; an application's containers and their accessor grants come from its own module
    -- whoever creates a container grants its sync KSA, resource-side.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "secret_prefix" {
  description = <<-EOT
    Prefix for every Secret Manager container name the platform and its applications sync, published as the
    SECRET_PREFIX cluster var (resourceNames become <prefix><container>). Lets multiple clusters share one project with
    distinct secrets; the modules/sso-secrets instantiation (a durable root, holding the out-of-band dex connector
    credentials) and every application module creating containers must use the same prefix (the secret_prefix
    output). Include the trailing separator (e.g. 'platform-x-'); empty keeps the unprefixed names.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.secret_prefix == null || try(can(regex("^[A-Za-z0-9_-]*$", var.secret_prefix)), false)
    error_message = "secret_prefix must use Secret Manager id characters only ([A-Za-z0-9_-])."
  }
}

variable "platform_components" {
  description = <<-EOT
    The platform manifests' electable-tier components (short names: flux-web, arc) this cluster elects, published as
    the PLATFORM_COMPONENTS cluster var. The platform entrypoint's ResourceSet ranges over the election: an elected
    component gets its own OCIRepository (oci://<registry>/manifests/<name>) and Kustomization. Electing none is
    explicit - set []. dex is not elected here: it deploys exactly when sso is enabled, and without it the elected
    components still run, just with no SSO auth and no human-facing HTTPRoute (kubectl port-forward to reach). The core
    tier (flux, kyverno, kyverno-policies, cert-manager, cert-manager-issuers, external-dns, gateway, rbac, secret-sync,
    otel-collector) is never electable. Applications are not components: they arrive through var.applications as
    their own images.
  EOT
  type        = set(string)
  nullable    = false
  default     = ["flux-web"]

  validation {
    condition = alltrue([
      for component in var.platform_components : contains(["flux-web", "arc"], component)
    ])
    error_message = "platform_components entries must be electable-tier short names: flux-web, arc (dex rides the sso toggle; the core tier is never electable)."
  }
}

variable "workload_grants" {
  description = <<-EOT
    Application workload IAM grants, keyed by a short name: each (entry, role) pair becomes one project-level IAM
    member binding of the role to the namespace/service-account pair as a direct Workload Identity Federation
    principal (principal://.../subject/ns/<namespace>/sa/<service_account>), in project (default: the cluster's own).
    This is how an application module hands its cloud permissions to the cluster (e.g. aiplatform.user for an egress
    broker): the module emits the map, the root wires it here, and nothing application-specific lives in this module.
    The platform's own pairs (external-dns, cert-manager, kyverno, otel-collector) are fixed by workload_identity and
    are not declared here. Secret Manager reads are not a grant shape: whoever creates a secret container grants its
    sync KSA accessor on it, resource-side.
  EOT
  type = map(object({
    namespace       = string
    service_account = string
    roles           = list(string)
    project         = optional(string)
  }))
  nullable = false
  default  = {}

  validation {
    condition     = alltrue([for key in keys(var.workload_grants) : can(regex("^[a-z]([a-z0-9-]{0,38})$", key))])
    error_message = "workload_grants keys must be short lowercase RFC-1035 labels."
  }

  validation {
    condition = alltrue([
      for key in keys(var.workload_grants) :
      !contains(["external-dns", "cert-manager", "otel-collector"], key) && !startswith(key, "kyverno-")
    ])
    error_message = "workload_grants keys must not collide with the platform grants (external-dns, cert-manager, otel-collector, kyverno-*)."
  }

  validation {
    condition = alltrue(flatten([
      for grant in values(var.workload_grants) : [
        for role in grant.roles : can(regex("^(roles/|projects/[^/]+/roles/|organizations/[0-9]+/roles/)", role))
      ]
    ]))
    error_message = "Each workload_grants role must be an IAM role name: roles/<role>, projects/<project>/roles/<role> or organizations/<id>/roles/<role>."
  }
}

variable "applications" {
  description = <<-EOT
    Application manifest images this cluster seeds, keyed by the application's short name. Each entry creates a
    bootstrap-only seed in flux-system (a ResourceSetInputProvider and ResourceSet named <key>-manifests) that
    resolves the newest tag matching semver, verifies the image's cosign signature and applies path from it as
    Kustomization <key>; the image ships the same two seed objects under flux/ and owns them from its first
    reconcile, so a new application release never needs a terraform apply. Removing a key uninstalls the seed and
    prunes the application. The entry is applied once and then ignored (ignore_changes), exactly like the
    flux-operator and flux-instance releases.
      - url: the image without a tag or digest. An Artifact Registry url must live under platform_registry (the flux
        controllers pull it with their Workload Identity and list its tags through the Artifact Registry API); any
        other registry is listed and pulled generically, optionally with pull_secret (a
        kubernetes.io/dockerconfigjson Secret in flux-system that both the tag listing and the pull read).
      - semver: the tag range the seed follows (default >=0.0.0); a range matching no tag prunes the application.
      - path: the Kustomization path inside the image (default ./deploy/<flux.sync.path>, the same per-cloud tree
        selector the platform uses, published as PLATFORM_TREE).
      - depends_on: platform Kustomizations the application waits for (default kyverno-policies).
      - verify: keyless (subject, a Fulcio certificate-subject regexp; issuer defaults to signed_identity.issuer)
        XOR keyed (the cosign-pub public-key Secret, KMS mode only).
    Application vars ride separately in application_vars, so a composite image's inner applications can each have
    their own ConfigMap. An application registers its dex clients itself, as DexClient objects in its own image
    (the platform's dex-client-controller reconciles them). An application can instead be published from a root of
    its own with modules/application and this module's application_target output - never from both.
  EOT
  type = map(object({
    url        = string
    semver     = optional(string, ">=0.0.0")
    path       = optional(string)
    interval   = optional(string, "30m")
    depends_on = optional(set(string), ["kyverno-policies"])
    verify = object({
      issuer  = optional(string)
      subject = optional(string)
      keyed   = optional(bool, false)
    })
    pull_secret = optional(string)
    prune       = optional(bool, true)
    wait        = optional(bool, true)
    timeout     = optional(string, "5m")
  }))
  nullable = false
  default  = {}

  validation {
    condition     = alltrue([for key in keys(var.applications) : can(regex("^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$", key))])
    error_message = "applications keys must be short lowercase RFC-1035 labels of at most 32 characters (they name the seed objects <key>-manifests and Kustomization <key>)."
  }

  # The same list as the AWS module, so an application name is portable
  # across clouds.
  validation {
    condition = alltrue([
      for key in keys(var.applications) : !contains([
        "flux-system", "flux", "cilium", "kyverno", "kyverno-policies", "cert-manager", "cert-manager-issuers",
        "external-dns", "gateway", "gateway-api-crds", "aws-load-balancer-controller", "rbac", "secret-sync", "dex",
        "flux-web", "arc", "platform", "cluster-inputs",
      ], key)
    ])
    error_message = "applications keys must not reuse a platform Kustomization or component name (flux-system, flux, cilium, kyverno, kyverno-policies, cert-manager, cert-manager-issuers, external-dns, gateway, gateway-api-crds, aws-load-balancer-controller, rbac, secret-sync, dex, flux-web, arc, platform, cluster-inputs) - the registry and the flux-system namespace are one flat namespace."
  }

  validation {
    condition = alltrue([
      for app in values(var.applications) : can(regex("^oci://[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$", app.url))
    ])
    error_message = "Each applications entry's url must be oci://<host>/<repository> with no tag or digest (the seed resolves the tag from semver)."
  }

  validation {
    condition = alltrue([
      for app in values(var.applications) :
      !can(regex("^oci://[a-z0-9-]+-docker\\.pkg\\.dev/", app.url)) || startswith(app.url, "oci://${var.platform_registry}/")
    ])
    error_message = "An Artifact Registry-hosted applications url must live under platform_registry - the flux controllers hold read rights on that repository alone, and its tags are listed through the Artifact Registry API with the same identity."
  }

  validation {
    condition = alltrue([
      for app in values(var.applications) : (app.verify.subject != null) != app.verify.keyed
    ])
    error_message = "Each applications entry's verify must be keyless (subject) or keyed, never both or neither - an unverified application image is never applied."
  }

  validation {
    condition = alltrue([
      for app in values(var.applications) : !app.verify.keyed || var.signed_identity.kms_key_name != null
    ])
    error_message = "applications[*].verify.keyed requires signed_identity.kms_key_name: the cosign-pub Secret only exists in KMS mode."
  }

  validation {
    condition = alltrue([
      for app in values(var.applications) : app.verify.subject == null || app.verify.issuer != null || var.signed_identity.kms_key_name == null
    ])
    error_message = "A keyless applications entry on a KMS-mode cluster must set verify.issuer explicitly - there is no keyless issuer to default onto."
  }

  validation {
    condition = alltrue([
      for app in values(var.applications) : app.pull_secret == null || !startswith(app.url, "oci://${var.platform_registry}/")
    ])
    error_message = "applications[*].pull_secret only applies to images outside the platform registry - the platform registry is pulled with the flux controllers' Workload Identity."
  }
}

variable "application_vars" {
  description = <<-EOT
    Per-application substitution values, keyed by application short name: each entry is rendered as the <key>-vars
    ConfigMap in flux-system (terraform-reconciled through cluster-inputs, so changes flow through applies), which the
    application's Kustomization substitutes from beside cluster-vars. Keys are top-level rather than nested in
    applications so a composite image's inner applications can each have their own ConfigMap. Keys must be
    SCREAMING_SNAKE_CASE, matching the substitution syntax; an application's own module typically emits this map.
  EOT
  type        = map(map(string))
  nullable    = false
  default     = {}

  validation {
    condition     = alltrue([for key in keys(var.application_vars) : can(regex("^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$", key))])
    error_message = "application_vars keys must be short lowercase RFC-1035 labels (they name the <key>-vars ConfigMap)."
  }

  validation {
    condition = alltrue(flatten([
      for vars in values(var.application_vars) : [for name in keys(vars) : can(regex("^[A-Z][A-Z0-9_]*$", name))]
    ]))
    error_message = "application_vars entries must use SCREAMING_SNAKE_CASE keys (^[A-Z][A-Z0-9_]*$), the shape flux substitution reads."
  }
}

variable "sso" {
  description = <<-EOT
    Platform SSO: deploys dex as the OIDC identity provider and wires the platform's relying parties to it --
    generated client pairs (sso.tf), the DEX_CONNECTORS/DEX_CLIENTS/DEX_DIRECTORY_SA cluster vars, and the
    human-facing HTTPRoutes. Upstream identity is arbitrary: connector declares the deployment's single upstream IdP
    -- which connector type a deployment federates isn't known ahead of time, but it only ever federates one --
      - type: the dex connector type (oidc, saml, google, microsoft, github, ...), passed through verbatim, not
        validated against dex's own supported list.
      - id: the dex connector id, also the naming stem for the credential containers (dex-<id>-<field>) and env vars;
        defaults to type -- set it when the type alone reads poorly (e.g. id = "okta" for an oidc connector).
      - name: the display name shown on dex's login screen; defaults to the connector id when unset.
      - config: the connector's own config: block, passed through near-verbatim (issuer, clientID, scopes,
        claimMapping, adminEmail, ...) -- a redirectURI is injected by default (sso.tf) unless the caller sets one.
        Values keep their native types (bools, lists, numbers) all the way into dex's rendered YAML, e.g.
        fetchTransitiveGroupMembership = true stays a bool.
      - secrets: the out-of-band credential fields this connector needs (default ["client-id", "client-secret"]).
        Each field becomes a dex-<id>-<field> Secret Manager container (modules/sso-secrets, instantiated in a durable
        root -- an OAuth client cannot be terraformed) and a <ID>_<FIELD> env var (uppercased, dashes -> underscores)
        dex expands from its own process env at startup ($<ID>_<FIELD>) -- reference it yourself, e.g.
        config.clientID = "$GOOGLE_CLIENT_ID".
    directory_sa is the keyless Workspace directory-reader service account dex's google connector impersonates for
    group claims (domain-wide delegation) -- independently optional, only relevant to a google-typed connector. When
    set, this module binds workloadIdentityUser on it for the cluster's dex KSA (sso.tf): the applying identity needs
    the get/setIamPolicy delegation cloud-accounts grants the app's terraform-apply container on that SA. Requires the
    DNS surface: the issuer and redirect URLs need the served domain.
    kubectl turns on kubectl through dex via Workforce Identity Federation (kubectl.tf): a workforce pool (pool_id,
    default <name>-dex) under organization_id whose OIDC provider (provider_id) trusts dex as its issuer through a
    confidential dex client (client_id, published in DEX_CLIENTS). Users sign in with gcloud's workforce login config
    and reach the cluster with get-credentials; RBAC binds their dex groups as principalSet subjects (rbac.groups).
    clients holds the per-client knobs for the generated confidential pairs (keys: flux-web and, when kubectl is on,
    its client_id) -- today just version, the client secret's rotation counter (absent clients sit at 1): bump it to
    mint a new client secret; the raw dex-client-<id> container and every consumer written from the same value (the
    flux-web config document, the workforce provider) rewrite in one apply, so the pair cannot drift (then restart
    dex: it reads client secrets from env at startup).
    Application clients are not here: an application ships DexClient objects in its own image, and the platform's
    dex-client-controller registers them.
  EOT
  # config is bare any, NOT map(any): map(any) unifies the map's value
  # types, so a mixed-type config ({clientID = "$...",
  # fetchTransitiveGroupMembership = true}) silently collapses to
  # map(string) and dex rejects the stringified bool at startup. Bare any
  # inside a plain object faces no such unification, so each value keeps
  # its native type all the way into the DEX_CONNECTORS JSON. That safety
  # is also why connector is a single object rather than a map of them:
  # map elements must share one concrete type, which would collapse
  # heterogeneous configs to map(string) just as silently.
  type = object({
    enabled = optional(bool, false)
    connector = optional(object({
      id      = optional(string)
      type    = string
      name    = optional(string)
      config  = optional(any, {})
      secrets = optional(set(string), ["client-id", "client-secret"])
    }))
    directory_sa = optional(string)
    kubectl = optional(object({
      enabled         = optional(bool, false)
      organization_id = optional(string)
      pool_id         = optional(string)
      provider_id     = optional(string, "dex-oidc")
      client_id       = optional(string, "gcp-workforce")
    }), {})
    clients = optional(map(object({
      version = number
    })), {})
  })
  nullable = false
  default  = {}

  validation {
    condition     = var.sso.directory_sa == null || can(regex("^[a-z0-9-]+@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.sso.directory_sa))
    error_message = "sso.directory_sa must be a service-account email (<name>@<project>.iam.gserviceaccount.com) -- the workloadIdentityUser binding derives the SA's project from it."
  }

  validation {
    condition     = !var.sso.enabled || var.dns.zone_name != null
    error_message = "sso requires dns.zone_name -- dex's issuer and the relying parties' redirect URLs need the served domain."
  }

  validation {
    condition = alltrue([
      for client in keys(var.sso.clients) :
      client == "flux-web" || (var.sso.kubectl.enabled && client == var.sso.kubectl.client_id)
    ])
    error_message = "sso.clients keys must be generated client ids: flux-web, or sso.kubectl.client_id when sso.kubectl is enabled."
  }

  validation {
    condition     = !var.sso.enabled || var.sso.connector != null
    error_message = "sso.enabled requires sso.connector -- a dex deployment with no upstream connector is a footgun (nobody can authenticate)."
  }

  validation {
    condition = var.sso.connector == null || (
      can(regex("^[a-z0-9-]+$", coalesce(var.sso.connector.id, var.sso.connector.type))) &&
      coalesce(var.sso.connector.id, var.sso.connector.type) != "client"
    )
    error_message = "sso.connector.id (defaulting to type) must match ^[a-z0-9-]+$ and must not be \"client\" (reserved -- relying-party containers are already named dex-client-<id>)."
  }

  validation {
    condition = var.sso.connector == null || alltrue([
      for field in var.sso.connector.secrets : can(regex("^[a-z0-9-]+$", field))
    ])
    error_message = "sso.connector.secrets entries must match ^[a-z0-9-]+$."
  }

  validation {
    condition     = !var.sso.kubectl.enabled || var.sso.enabled
    error_message = "sso.kubectl requires sso.enabled -- the workforce pool's OIDC provider trusts dex as its issuer."
  }

  validation {
    condition     = !var.sso.kubectl.enabled || can(regex("^[0-9]+$", var.sso.kubectl.organization_id))
    error_message = "sso.kubectl.enabled requires sso.kubectl.organization_id, the numeric organization id the workforce pool lives under."
  }

  validation {
    condition = (
      can(regex("^[a-z][a-z0-9-]{4,61}[a-z0-9]$", coalesce(var.sso.kubectl.pool_id, "${var.name}-dex")))
      && !startswith(coalesce(var.sso.kubectl.pool_id, "${var.name}-dex"), "gcp-")
    )
    error_message = "sso.kubectl.pool_id (default <name>-dex) must be a workforce pool id: 6-63 lowercase letters, digits or hyphens, starting with a letter, not ending with a hyphen, and not starting with the reserved gcp- prefix."
  }

  validation {
    condition     = can(regex("^[a-z0-9-]{4,32}$", var.sso.kubectl.provider_id)) && !startswith(var.sso.kubectl.provider_id, "gcp-")
    error_message = "sso.kubectl.provider_id (default dex-oidc) must be a workforce pool provider id: 4-32 lowercase letters, digits or hyphens, not starting with the reserved gcp- prefix."
  }

  validation {
    condition     = var.sso.kubectl.client_id != "flux-web" && can(regex("^[a-z0-9-]+$", var.sso.kubectl.client_id))
    error_message = "sso.kubectl.client_id must match ^[a-z0-9-]+$ and must not be flux-web (another platform client)."
  }
}

variable "flux" {
  description = <<-EOT
    Flux bootstrap knobs. Chart repositories, the distribution registry and the sync url default onto platform_registry;
    sync.ref picks the release channel (stable, staging, or edge for dev clusters tracking trunk -- pair edge with the
    manifests_edge signing subject); sync.url defaults to the platform entrypoint image
    oci://<platform_registry>/manifests/platform (flux-manifests >= 4.0.0), published as FLUX_SYNC_URL so the
    platform's flux component can re-point a running cluster; sync.path selects the per-cloud tree inside it
    ("google"), published as PLATFORM_TREE and the default ./deploy/<path> of every application image. namespaces are
    pre-created by the cluster-inputs chart ahead of the platform.
  EOT
  type = object({
    operator_chart = optional(object({
      repository = optional(string)
      version    = optional(string)
    }), {})
    instance_chart = optional(object({
      repository = optional(string)
      version    = optional(string)
    }), {})
    distribution = optional(object({
      version  = optional(string, "2.x")
      registry = optional(string)
      artifact = optional(string)
    }), {})
    sync = optional(object({
      url      = optional(string)
      ref      = optional(string, "stable")
      path     = optional(string, "google")
      interval = optional(string, "5m")
    }), {})
    kustomize_patches = optional(list(any), [])
    cluster_vars      = optional(map(string), {})
    namespaces        = optional(list(string), [])
  })
  nullable = false
  default  = {}

  validation {
    condition     = contains(["stable", "staging", "edge"], var.flux.sync.ref) || can(regex("^v", var.flux.sync.ref))
    error_message = "flux.sync.ref must be a channel tag (stable, staging, edge) or a pinned version tag (vX.Y.Z)."
  }
}

variable "labels" {
  description = "Resource labels applied to the cluster."
  type        = map(string)
  nullable    = false
  default     = {}
}
