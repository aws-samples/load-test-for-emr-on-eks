# Monitoring module: Prometheus, Grafana, LB Controller, BinPacking Scheduler
# Implements FR-006, FR-011, FR-012

locals {
  cluster_full_name = "${var.project_name}-${var.cluster_name}"
}

# --- kube-prometheus-stack (Prometheus + Grafana) ---

resource "helm_release" "prometheus" {
  name             = "kube-prometheus-stack"
  namespace        = "prometheus"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"

  values = [yamlencode({
    prometheus = {
      prometheusSpec = {
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
      }
    }
    grafana = {
      adminPassword = "admin"
      sidecar = {
        dashboards = {
          enabled         = true
          searchNamespace = "ALL"
        }
      }
    }
  })]

  wait    = true
  timeout = 600

  depends_on = [helm_release.lb_controller]
}

# --- Grafana Dashboard ConfigMaps ---

resource "kubernetes_config_map_v1" "grafana_dashboards" {
  for_each = fileset("${path.module}/dashboards", "*.json")

  metadata {
    name      = "grafana-dashboard-${trimsuffix(each.value, ".json")}"
    namespace = "prometheus"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "${each.value}" = file("${path.module}/dashboards/${each.value}")
  }

  depends_on = [helm_release.prometheus]
}

# --- PodMonitors ---

resource "kubectl_manifest" "podmonitor_locust" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "locust-metrics"
      namespace = "prometheus"
    }
    spec = {
      namespaceSelector = {
        matchNames = ["locust"]
      }
      selector = {
        matchExpressions = [
          {
            key      = "locust.cloud/component"
            operator = "In"
            values   = ["worker"]
          }
        ]
      }
      podMetricsEndpoints = [
        {
          port     = "8000"
          interval = "30s"
          path     = "/metrics"
          metricRelabelings = [
            {
              action       = "keep"
              regex        = "locust_.*"
              sourceLabels = ["__name__"]
            }
          ]
        }
      ]
    }
  })

  depends_on = [helm_release.prometheus]
}

resource "kubectl_manifest" "podmonitor_spark" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "spark-driver-monitoring"
      namespace = "prometheus"
      labels = {
        prometheus = "true"
      }
    }
    spec = {
      jobLabel = "spark-driver-monitoring"
      namespaceSelector = { any = true }
      selector = {
        matchLabels = {
          "spark-role"                                    = "driver"
          "emr-containers.amazonaws.com/resource.type"    = "job.run"
        }
      }
      podMetricsEndpoints = [
        {
          port = "web-ui"
          path = "/metrics/executors/prometheus/"
        }
      ]
    }
  })

  depends_on = [helm_release.prometheus]
}

resource "kubectl_manifest" "servicemonitor_spark" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "spark-service-monitoring"
      namespace = "prometheus"
      labels = {
        prometheus = "true"
      }
    }
    spec = {
      namespaceSelector = { any = true }
      endpoints = [
        {
          port = "web-ui"
          path = "/metrics/driver/prometheus/"
        }
      ]
      selector = {
        matchLabels = {
          "spark_role"                                    = "driver"
          "emr-containers.amazonaws.com/resource.type"    = "job.run"
        }
      }
    }
  })

  depends_on = [helm_release.prometheus]
}

resource "kubectl_manifest" "podmonitor_aws_cni" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "aws-cni"
      namespace = "prometheus"
    }
    spec = {
      namespaceSelector = {
        matchNames = ["kube-system"]
      }
      selector = {
        matchLabels = { k8s-app = "aws-node" }
      }
      podMetricsEndpoints = [
        { port = "metrics", interval = "30s" }
      ]
    }
  })

  depends_on = [helm_release.prometheus]
}

# --- ServiceMonitor for Karpenter ---

resource "kubectl_manifest" "servicemonitor_karpenter" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "karpenter"
      namespace = "prometheus"
    }
    spec = {
      namespaceSelector = {
        matchNames = ["kube-system"]
      }
      selector = {
        matchLabels = { "app.kubernetes.io/name" = "karpenter" }
      }
      endpoints = [
        { port = "http-metrics", interval = "15s" }
      ]
    }
  })

  depends_on = [helm_release.prometheus]
}

# --- Metrics Server ---

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"

  wait = true
}

# --- AWS Load Balancer Controller (FR-012) ---

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"

  values = [yamlencode({
    clusterName = local.cluster_full_name
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = var.lb_controller_role_arn
      }
    }
  })]

  wait = true
}

# --- BinPacking Scheduler (FR-011) ---
# The custom-scheduler-eks chart is not in a public Helm repo.
# It must be cloned from https://github.com/aws-samples/custom-scheduler-eks
# and referenced locally. This resource assumes the chart is available locally.

resource "helm_release" "binpacking_scheduler" {
  name      = "custom-scheduler-eks"
  namespace = "kube-system"
  chart     = "${path.module}/charts/custom-scheduler-eks"

  values = [yamlencode({
    eksVersion    = var.eks_version
    schedulerName = "custom-scheduler-eks"
    logLevel      = 0
    resources = {
      requests = { cpu = "1", memory = "2Gi" }
      limits   = { cpu = "8", memory = "16Gi" }
    }
    nodeSelector = {
      operational = "true"
    }
    clientConnection = {
      burst = 200
      qps   = 100
    }
  })]

  wait = true
}
