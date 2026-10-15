# The app is applied from the same YAML that `kubectl apply -k k8s/app`
# uses, so the manifests in k8s/app stay the single source of truth.

locals {
  app_dir = "${path.module}/../k8s/app"

  namespace = provider::kubernetes::manifest_decode(file("${local.app_dir}/namespace.yaml"))

  app_docs = flatten([
    for f in ["deployment.yaml", "service.yaml", "networkpolicy.yaml"] :
    provider::kubernetes::manifest_decode_multi(file("${local.app_dir}/${f}"))
  ])
  app = { for d in local.app_docs : "${d.kind}/${d.metadata.name}" => d }
}

resource "kubernetes_manifest" "namespace" {
  manifest = local.namespace
}

resource "kubernetes_manifest" "app" {
  for_each = local.app
  manifest = each.value

  # Block until the Deployment has rolled out, so a failed image pull or a
  # policy-controller rejection fails the apply.
  dynamic "wait" {
    for_each = each.value.kind == "Deployment" ? [1] : []
    content {
      rollout = true
    }
  }

  timeouts {
    create = "5m"
    update = "5m"
  }

  depends_on = [kubernetes_manifest.namespace]
}
