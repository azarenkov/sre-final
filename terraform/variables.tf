variable "kubeconfig_path" {
  type        = string
  default     = "~/.kube/config"
  description = "Path to kubeconfig (Minikube writes here)."
}

variable "kube_context" {
  type        = string
  default     = "minikube"
  description = "kubectl context to apply against."
}

variable "app_image" {
  type        = string
  default     = "shop-api:v1"
  description = "Image tag the shop-api deployment will use."
}

variable "manifests_dir" {
  type        = string
  default     = "../k8s"
  description = "Static K8s manifests directory."
}

variable "observability_dir" {
  type        = string
  default     = "../observability"
  description = "Source of Prometheus/Grafana/Alertmanager configs that get baked into ConfigMaps."
}
