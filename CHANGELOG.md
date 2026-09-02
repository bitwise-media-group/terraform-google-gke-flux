# Changelog

## 0.1.0 (2026-09-02)


### ⚠ BREAKING CHANGES

* the region variable is replaced by location; pass a region for a regional cluster or a zone for a zonal one.
* requires flux-manifests >= 3.0.0, whose artifact ships the aws/google/common trees; the old single ./stack entrypoint no longer exists there. Clusters applying this version sync sync.path "google" -- pin flux.sync.path explicitly only to override the tree.
* **sso:** sso.connectors (map) is replaced by sso.connector (a single object; id optional, defaulting to type) in the root module, examples/complete, and modules/secrets, and sso.client_rotation (map(number)) is replaced by sso.clients (map(object({ version = number }))).
* **secrets:** take the cluster module's sso value verbatim

### Features

* accept a zone as the cluster location ([d217b17](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/d217b173ff05f55ae72942d6ba8aefb5e2922ab8))
* add a managed OpenTelemetry (Preview) pilot toggle ([4bcc7f3](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/4bcc7f3c380917596460165437c93b531da624de))
* add a secret_sync toggle for Secret Manager CSI and Integrated Secret Sync ([7e10f18](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/7e10f189b496214f14363459fcaf6654b1386399))
* add claude model-provider surface as CLAUDE_* cluster vars ([31ff37f](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/31ff37f9d8d171c2c57a110d636118d37fdb3f0f))
* add edge release channel for dev clusters tracking trunk ([0bf3f99](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/0bf3f993ea11a290597c9186a462bcffb85569ab))
* add Google Groups for RBAC toggle ([be09d5b](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/be09d5b28f4917e95277e53fd3238246697fa44e))
* add KMS signing mode alongside keyless cosign verification ([3073f50](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/3073f501a2404a26e3b2eec0a6544dd915eb685b))
* add secrets submodule owning the secret-sync contract ([e80f4a9](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/e80f4a988826dbff791d1e20096721d29c64d817))
* **flux-operator:** add a web config secret knob for the status UI ([324017a](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/324017a40ea331ef6134aec3fbb171201d9000e1))
* **flux-operator:** demote the flux releases to bootstrap-only ([0aa74f7](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/0aa74f723477f0ff4ad4ac8eaa1b407c8ebf2403))
* **flux:** publish COSIGN_PUBLIC_KEY for the manifests' keyed verifies ([b68c5d2](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/b68c5d25729f91eb25fd99ee31f56ace6aef8a91))
* generate per-cluster SSO client pairs and export the stack contract ([0018d45](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/0018d4554956a7561a70100b62a27e3547a14025))
* GKE cluster, artifact store and flux-operator bootstrap ([fc216c3](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/fc216c3945f8b3a6836e210e824aa77f3ab5fb37))
* **kms-signing-key:** add cosign signing key module ([b46c086](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/b46c086e8c4467d44f1c40915c5887fc6859665d))
* **patchy:** add the evaluation-controller toggle ([b75f0e2](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/b75f0e221600260855885181ba11728b89bf7386))
* **rbac:** add an admins subject group published as RBAC_GROUP_ADMINS ([790a620](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/790a620da7a7358d2585ffef43beafb085682ade))
* **scc-notifications:** forward SCC findings to patchy ([701ce4a](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/701ce4a17c2fb4c18cbc173d1e5d2c31071c1db4))
* **secrets:** enable rotation on the Secret Manager sync add-on ([30b7918](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/30b7918f79f9fef790e61f10ed7eb52a6fe8c4e1))
* **sso:** declare a single connector object with native config types ([e9a53b3](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/e9a53b3d56d9e6520af69a0ef8170ca6fd07f1e8))
* **sso:** support arbitrary dex connectors via sso.connectors ([5144f59](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/5144f59837cd10d6d58e67df53d9de19015e0c43))
* sync the per-cloud google manifests tree ([a367152](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/a3671528e6fe100e2d21f812c40ab475b1131155))


### Bug Fixes

* **deps:** update bitwise-media-group/github-workflows action to v6.2.0 ([#19](https://github.com/bitwise-media-group/terraform-google-gke-flux/issues/19)) ([28e33f6](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/28e33f6c1301c5f551f086e96b1e16d4dd754ecf))
* **flux-operator:** gate off chart digest tracking at bootstrap ([92b90b2](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/92b90b2e739631895d6ccad07cf2da3aa8ab3932))
* leave node_locations unset when zones is empty ([354c968](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/354c968730292bb4e39bd11c2d65201a16722e22))
* **scc-notifications:** generate SCC notification agent before granting it ([331937d](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/331937deba09ef12967760328a05677d668040c7))
* survive first-cluster bootstrap in locked-down projects ([96aaf4b](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/96aaf4b5b263ad80e71254deac49a5ffd9d7d3cf))


### Code Refactoring

* **secrets:** take the cluster module's sso value verbatim ([13d00fb](https://github.com/bitwise-media-group/terraform-google-gke-flux/commit/13d00fbb812ef40e2a4a8c0902a009ba45c3a7d6))
