# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with mocked providers: the seed values a
# standalone application hands the shared chart, the inputs release, the IAM
# members the workloads authenticate as, and every validation.

mock_provider "google" {}

mock_provider "helm" {}

variables {
  name = "demo"

  cluster = {
    name              = "patchy-x"
    namespace         = "flux-system"
    platform_registry = "us-central1-docker.pkg.dev/x-patchy-app-ab12/platform"
    tree              = "google"
    issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
    keyed             = false
    project           = "x-patchy-app-ab12"
    project_number    = "123456789012"
    workload_pool     = "x-patchy-app-ab12.svc.id.goog"
    secret_prefix     = "patchy-x-"
  }

  image = {
    url    = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/demo"
    semver = "<1.0.0 >=0.1.0"
    verify = {
      subject = "^https://github\\.com/org/demo/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    }
  }
}

run "platform_image_seed" {
  command = plan

  assert {
    condition     = helm_release.seed.name == "application-demo" && helm_release.seed.namespace == "flux-system"
    error_message = "the seed is release application-<name> in the cluster's flux namespace, exactly as the cluster root names its own"
  }

  assert {
    condition     = helm_release.seed.chart == "${path.module}/charts/application"
    error_message = "the seed is the module's local application chart (shared with the cluster root)"
  }

  # The registry, never the cloud, picks the listing and pull dialect.
  assert {
    condition     = output.tag_provider == "GARArtifactTag" && output.oci_provider == "gcp"
    error_message = "an image under the platform registry is listed with GARArtifactTag and pulled as provider gcp"
  }

  assert {
    condition     = yamldecode(helm_release.seed.values[0]).tagProvider == "GARArtifactTag" && yamldecode(helm_release.seed.values[0]).ociProvider == "gcp"
    error_message = "the providers must reach the chart"
  }

  assert {
    condition     = output.path == "./deploy/google" && yamldecode(helm_release.seed.values[0]).path == "./deploy/google"
    error_message = "the path defaults to ./deploy/<cluster.tree>, the platform's own tree selector"
  }

  # Keyless images default onto the cluster's own issuer.
  assert {
    condition     = yamldecode(helm_release.seed.values[0]).verify.issuer == var.cluster.issuer
    error_message = "a keyless image without an issuer verifies against cluster.issuer"
  }

  assert {
    condition     = yamldecode(helm_release.seed.values[0]).verify.subject == var.image.verify.subject && yamldecode(helm_release.seed.values[0]).verify.keyed == false
    error_message = "the keyless subject must reach the chart verbatim (a Go regexp full of backslashes)"
  }

  assert {
    condition     = join(",", yamldecode(helm_release.seed.values[0]).dependsOn) == "kyverno-policies" && yamldecode(helm_release.seed.values[0]).pullSecret == ""
    error_message = "the seed waits for kyverno-policies by default and needs no pull secret on the platform registry"
  }

  # Nothing to render: no vars, no namespaces, no inputs release.
  assert {
    condition     = length(helm_release.inputs) == 0
    error_message = "the inputs release exists only when there are vars or namespaces"
  }

  assert {
    condition     = length(google_project_iam_member.workload) == 0 && length(output.workload_members) == 0
    error_message = "no grants, no IAM members"
  }
}

run "external_image_seed" {
  command = plan

  variables {
    image = {
      url         = "oci://ghcr.io/org/demo-manifests"
      path        = "./deploy/custom"
      depends_on  = ["kyverno-policies", "gateway"]
      pull_secret = "ghcr-pull"
      verify = {
        issuer  = "^https://example\\.com$"
        subject = "^https://github\\.com/org/demo/.+$"
      }
    }
  }

  assert {
    condition     = output.tag_provider == "OCIArtifactTag" && output.oci_provider == "generic"
    error_message = "an image outside the platform registry is listed with OCIArtifactTag and pulled as provider generic"
  }

  assert {
    condition     = yamldecode(helm_release.seed.values[0]).pullSecret == "ghcr-pull" && output.path == "./deploy/custom"
    error_message = "the pull secret and an explicit path must reach the chart"
  }

  assert {
    condition     = yamldecode(helm_release.seed.values[0]).verify.issuer == "^https://example\\.com$"
    error_message = "an explicit issuer wins over cluster.issuer"
  }

  assert {
    condition     = join(",", yamldecode(helm_release.seed.values[0]).dependsOn) == "gateway,kyverno-policies"
    error_message = "dependsOn must reach the chart as a sorted list"
  }
}

run "keyed_seed" {
  command = plan

  variables {
    cluster = {
      name              = "patchy-x"
      namespace         = "flux-system"
      platform_registry = "us-central1-docker.pkg.dev/x-patchy-app-ab12/platform"
      tree              = "google"
      keyed             = true
      project           = "x-patchy-app-ab12"
      project_number    = "123456789012"
      workload_pool     = "x-patchy-app-ab12.svc.id.goog"
      secret_prefix     = ""
    }
    image = {
      url    = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/demo"
      verify = { keyed = true }
    }
  }

  assert {
    condition     = yamldecode(helm_release.seed.values[0]).verify.keyed == true && yamldecode(helm_release.seed.values[0]).verify.subject == "" && yamldecode(helm_release.seed.values[0]).verify.issuer == ""
    error_message = "keyed mode hands the chart the keyed flag and no keyless identity - the chart then verifies against the cosign-pub Secret"
  }
}

run "inputs_release" {
  command = plan

  variables {
    vars       = { DEMO_DOMAIN = "demo.example.com" }
    namespaces = ["demo-b", "demo"]
  }

  assert {
    condition     = helm_release.inputs["true"].name == "application-demo-inputs" && helm_release.inputs["true"].namespace == "flux-system"
    error_message = "vars and namespaces ride one terraform-reconciled release, application-<name>-inputs, in the flux namespace"
  }

  assert {
    condition     = helm_release.inputs["true"].chart == "${path.module}/charts/inputs"
    error_message = "the inputs are the module's local inputs chart"
  }

  assert {
    condition     = yamldecode(helm_release.inputs["true"].values[0]).name == "demo" && yamldecode(helm_release.inputs["true"].values[0]).vars.DEMO_DOMAIN == "demo.example.com"
    error_message = "the vars reach the chart under the application's name, which renders them as the <name>-vars ConfigMap"
  }

  assert {
    condition     = join(",", yamldecode(helm_release.inputs["true"].values[0]).namespaces) == "demo,demo-b"
    error_message = "namespaces reach the chart as a sorted list"
  }
}

run "namespaces_alone_need_inputs" {
  command = plan

  variables {
    namespaces = ["demo"]
  }

  assert {
    condition     = length(helm_release.inputs) == 1
    error_message = "namespaces without vars still need the inputs release"
  }
}

run "workload_grants" {
  command = plan

  variables {
    workload_grants = {
      egress-broker = {
        namespace       = "demo"
        service_account = "egress-broker"
        roles           = ["roles/aiplatform.user", "roles/logging.logWriter"]
      }
      exporter = {
        namespace       = "demo"
        service_account = "exporter"
        roles           = ["projects/o-data-ef56/roles/exportWriter"]
        project         = "o-data-ef56"
      }
    }
  }

  assert {
    condition     = google_project_iam_member.workload["egress-broker:roles/aiplatform.user"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/demo/sa/egress-broker"
    error_message = "a grant binds its pair as a direct Workload Identity Federation principal of the cluster's pool"
  }

  assert {
    condition     = google_project_iam_member.workload["egress-broker:roles/aiplatform.user"].project == "x-patchy-app-ab12" && google_project_iam_member.workload["egress-broker:roles/logging.logWriter"].role == "roles/logging.logWriter"
    error_message = "each (grant, role) pair is one member binding, in cluster.project by default"
  }

  assert {
    condition     = google_project_iam_member.workload["exporter:projects/o-data-ef56/roles/exportWriter"].project == "o-data-ef56"
    error_message = "an explicit project wins over cluster.project"
  }

  assert {
    condition     = length(google_project_iam_member.workload) == 3
    error_message = "two grants with three roles between them are three member bindings"
  }

  assert {
    condition     = output.workload_members["exporter"] == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/x-patchy-app-ab12.svc.id.goog/subject/ns/demo/sa/exporter"
    error_message = "workload_members must name each grant's principal, for resource-side grants (secret accessors) in the caller"
  }
}

run "invalid_name" {
  command = plan

  variables {
    name = "Demo_App"
  }

  expect_failures = [var.name]
}

run "reserved_name" {
  command = plan

  variables {
    name = "dex"
  }

  expect_failures = [var.name]
}

run "keyless_cluster_needs_issuer" {
  command = plan

  variables {
    cluster = {
      name              = "patchy-x"
      namespace         = "flux-system"
      platform_registry = "us-central1-docker.pkg.dev/x-patchy-app-ab12/platform"
      tree              = "google"
      keyed             = false
      project           = "x-patchy-app-ab12"
      project_number    = "123456789012"
      workload_pool     = "x-patchy-app-ab12.svc.id.goog"
      secret_prefix     = ""
    }
  }

  expect_failures = [var.cluster]
}

run "url_with_tag" {
  command = plan

  variables {
    image = {
      url    = "oci://ghcr.io/org/demo:1.0.0"
      verify = { subject = "^https://github\\.com/org/demo/.+$" }
    }
  }

  expect_failures = [var.image]
}

run "foreign_artifact_registry_url" {
  command = plan

  variables {
    image = {
      url    = "oci://europe-west2-docker.pkg.dev/other-project/other/demo"
      verify = { subject = "^https://github\\.com/org/demo/.+$" }
    }
  }

  expect_failures = [var.image]
}

run "unverified_image" {
  command = plan

  variables {
    image = {
      url    = "oci://ghcr.io/org/demo"
      verify = {}
    }
  }

  expect_failures = [var.image]
}

run "keyed_image_needs_keyed_cluster" {
  command = plan

  variables {
    image = {
      url    = "oci://ghcr.io/org/demo"
      verify = { keyed = true }
    }
  }

  expect_failures = [var.image]
}

run "keyless_image_on_keyed_cluster_needs_issuer" {
  command = plan

  variables {
    cluster = {
      name              = "patchy-x"
      namespace         = "flux-system"
      platform_registry = "us-central1-docker.pkg.dev/x-patchy-app-ab12/platform"
      tree              = "google"
      keyed             = true
      project           = "x-patchy-app-ab12"
      project_number    = "123456789012"
      workload_pool     = "x-patchy-app-ab12.svc.id.goog"
      secret_prefix     = ""
    }
  }

  expect_failures = [var.image]
}

run "pull_secret_on_platform_registry" {
  command = plan

  variables {
    image = {
      url         = "oci://us-central1-docker.pkg.dev/x-patchy-app-ab12/platform/manifests/demo"
      pull_secret = "gar-pull"
      verify      = { subject = "^https://github\\.com/org/demo/.+$" }
    }
  }

  expect_failures = [var.image]
}

run "lowercase_vars" {
  command = plan

  variables {
    vars = { demo_domain = "demo.example.com" }
  }

  expect_failures = [var.vars]
}

run "invalid_namespace" {
  command = plan

  variables {
    namespaces = ["Demo"]
  }

  expect_failures = [var.namespaces]
}

run "grant_key_collides_with_platform" {
  command = plan

  variables {
    workload_grants = {
      kyverno-demo = {
        namespace       = "demo"
        service_account = "demo"
        roles           = ["roles/viewer"]
      }
    }
  }

  expect_failures = [var.workload_grants]
}

run "grant_key_shape" {
  command = plan

  variables {
    workload_grants = {
      Broker = {
        namespace       = "demo"
        service_account = "demo"
        roles           = ["roles/viewer"]
      }
    }
  }

  expect_failures = [var.workload_grants]
}

run "grant_role_shape" {
  command = plan

  variables {
    workload_grants = {
      broker = {
        namespace       = "demo"
        service_account = "demo"
        roles           = ["aiplatform.user"]
      }
    }
  }

  expect_failures = [var.workload_grants]
}
