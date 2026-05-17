provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

provider "kubectl" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
  load_config_file = true
  apply_retry_count = 5
}

resource "kubernetes_namespace_v1" "shop" {
  metadata {
    name = "shop"
    labels = {
      "app.kubernetes.io/part-of" = "sre-capstone"
    }
  }
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "app.kubernetes.io/part-of" = "sre-capstone"
    }
  }
}

resource "kubernetes_config_map_v1" "prometheus_config" {
  metadata {
    name      = "prometheus-config"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  data = {
    "prometheus.yml" = file("${var.observability_dir}/prometheus/prometheus.yml")
  }
}

resource "kubernetes_config_map_v1" "prometheus_rules" {
  metadata {
    name      = "prometheus-rules"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  data = {
    "rules.yml" = file("${var.observability_dir}/prometheus/rules.yml")
  }
}

resource "kubernetes_config_map_v1" "grafana_datasources" {
  metadata {
    name      = "grafana-datasources"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  data = {
    "datasource.yml" = file("${var.observability_dir}/grafana/datasource.yml")
  }
}

resource "kubernetes_config_map_v1" "grafana_dashboards_provisioning" {
  metadata {
    name      = "grafana-dashboards-provisioning"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  data = {
    "dashboards.yml" = file("${var.observability_dir}/grafana/dashboards.yml")
  }
}

resource "kubernetes_config_map_v1" "grafana_dashboards" {
  metadata {
    name      = "grafana-dashboards"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  data = {
    "shop-api.json" = file("${var.observability_dir}/grafana/shop-api-dashboard.json")
  }
}

resource "kubernetes_config_map_v1" "alertmanager_config" {
  metadata {
    name      = "alertmanager-config"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  data = {
    "alertmanager.yml" = file("${var.observability_dir}/alertmanager/alertmanager.yml")
  }
}

data "kubectl_path_documents" "app" {
  pattern = "${var.manifests_dir}/10-app-deployment.yaml"
}

data "kubectl_path_documents" "prometheus" {
  pattern = "${var.manifests_dir}/20-prometheus.yaml"
}

data "kubectl_path_documents" "grafana" {
  pattern = "${var.manifests_dir}/30-grafana.yaml"
}

data "kubectl_path_documents" "alertmanager" {
  pattern = "${var.manifests_dir}/40-alertmanager.yaml"
}

resource "kubectl_manifest" "app" {
  for_each   = toset(data.kubectl_path_documents.app.documents)
  yaml_body  = each.value
  depends_on = [kubernetes_namespace_v1.shop]
}

resource "kubectl_manifest" "prometheus" {
  for_each   = toset(data.kubectl_path_documents.prometheus.documents)
  yaml_body  = each.value
  depends_on = [
    kubernetes_namespace_v1.monitoring,
    kubernetes_config_map_v1.prometheus_config,
    kubernetes_config_map_v1.prometheus_rules,
  ]
}

resource "kubectl_manifest" "grafana" {
  for_each   = toset(data.kubectl_path_documents.grafana.documents)
  yaml_body  = each.value
  depends_on = [
    kubernetes_namespace_v1.monitoring,
    kubernetes_config_map_v1.grafana_datasources,
    kubernetes_config_map_v1.grafana_dashboards_provisioning,
    kubernetes_config_map_v1.grafana_dashboards,
  ]
}

resource "kubectl_manifest" "alertmanager" {
  for_each   = toset(data.kubectl_path_documents.alertmanager.documents)
  yaml_body  = each.value
  depends_on = [
    kubernetes_namespace_v1.monitoring,
    kubernetes_config_map_v1.alertmanager_config,
  ]
}

output "next_steps" {
  value = <<EOT
Apply complete. Endpoints (NodePort via minikube ip):
  shop-api     : http://$(minikube ip):30080
  Prometheus   : http://$(minikube ip):30090
  Grafana      : http://$(minikube ip):30030    (admin/admin)
  Alertmanager : http://$(minikube ip):30093
EOT
}
