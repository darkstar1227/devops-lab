resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    # The app's NetworkPolicy admits scrapes from this namespace by name.
    name = "monitoring"
  }
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kps"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version
  timeout    = 600
  wait       = true

  values = [file("${path.module}/values/kube-prometheus-stack.yaml")]

  set_sensitive = [{
    name  = "grafana.adminPassword"
    value = random_password.grafana_admin.result
  }]
}

# Probes /healthz from outside the app: availability and latency even if
# /metrics breaks. Its ServiceMonitor needs the CRDs installed by the
# release above.
resource "helm_release" "blackbox_exporter" {
  name       = "blackbox"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-blackbox-exporter"
  version    = var.blackbox_exporter_version
  wait       = true

  values = [file("${path.module}/values/blackbox-exporter.yaml")]

  depends_on = [helm_release.kube_prometheus_stack]
}

# Grafana's dashboard sidecar loads ConfigMaps labelled grafana_dashboard=1.
resource "kubernetes_config_map_v1" "dashboard" {
  metadata {
    name      = "fastapi-hello-dashboard"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "fastapi-hello.json" = file("${path.module}/dashboards/fastapi-hello.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
