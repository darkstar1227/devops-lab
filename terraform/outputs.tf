output "grafana_admin_password" {
  description = "Grafana admin password (user: admin)."
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "port_forward" {
  description = "Commands to reach the UIs from the laptop."
  value = {
    grafana    = "kubectl -n monitoring port-forward svc/kps-grafana 3000:80"
    prometheus = "kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090"
  }
}
