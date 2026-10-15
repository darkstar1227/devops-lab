variable "kubeconfig" {
  description = "Path to the kubeconfig file."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubeconfig context to deploy to (orbstack locally, kind-* in CI)."
  type        = string
  default     = "orbstack"
}

variable "kube_prometheus_stack_version" {
  description = "prometheus-community/kube-prometheus-stack chart version."
  type        = string
  default     = "92.8.0"
}

variable "blackbox_exporter_version" {
  description = "prometheus-community/prometheus-blackbox-exporter chart version."
  type        = string
  default     = "11.20.0"
}
