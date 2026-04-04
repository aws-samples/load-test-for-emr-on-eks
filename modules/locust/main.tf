# Locust module: Locust Operator, ConfigMap, and test CRD template
# Implements FR-007, FR-014

locals {
  cluster_full_name = "${var.project_name}-${var.cluster_name}"
}

# --- Locust Operator Helm Release ---

resource "helm_release" "locust_operator" {
  name             = "locust-operator"
  namespace        = "locust"
  create_namespace = true
  repository       = "http://locustcloud.github.io/k8s-operator"
  chart            = "locust-operator"

  wait = true
}

# --- Patch RBAC for cross-namespace operations ---

resource "kubectl_manifest" "locust_rbac_patch" {
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name = "locust-operator-cluster-admin"
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "cluster-admin"
    }
    subjects = [
      {
        kind      = "ServiceAccount"
        name      = "default"
        namespace = "locust"
      }
    ]
  })

  depends_on = [helm_release.locust_operator]
}

# --- Annotate Locust SA with IRSA ---

resource "kubectl_manifest" "locust_sa_annotation" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = "default"
      namespace = "locust"
      annotations = {
        "eks.amazonaws.com/role-arn" = var.locust_role_arn
      }
    }
  })

  depends_on = [helm_release.locust_operator]
}

# --- Locust ConfigMap from locustfiles ---

resource "kubernetes_config_map_v1" "locustfiles" {
  metadata {
    name      = "emr-loadtest-locustfile"
    namespace = "locust"
  }

  data = merge(
    {
      for f in fileset("${path.module}/locustfiles", "*.py") :
      f => file("${path.module}/locustfiles/${f}")
    },
    {
      for f in fileset("${path.module}/locustfiles", "*.sh") :
      f => file("${path.module}/locustfiles/${f}")
    }
  )

  depends_on = [helm_release.locust_operator]
}

# --- LocustTest CRD Template (generated per cluster) ---

resource "local_file" "locust_test_crd" {
  filename = "${path.module}/../../templates/${var.cluster_name}-locust-test.yaml"

  content = yamlencode({
    apiVersion = "locust.cloud/v1"
    kind       = "LocustTest"
    metadata = {
      name      = "tpcds-job-${local.cluster_full_name}"
      namespace = "locust"
    }
    spec = {
      image           = "${var.ecr_repository_url}:latest"
      imagePullPolicy = "IfNotPresent"
      workers         = var.locust_config.workers
      env = [
        { name = "AWS_REGION", value = var.region },
        { name = "CLUSTER_NAME", value = local.cluster_full_name },
        { name = "EMR_IMAGE_VERSION", value = var.locust_config.emr_image_version },
        { name = "METRICS_PORT", value = "8000" },
        { name = "JOB_SCRIPT_NAME", value = "emr-job-run.sh" },
        { name = "SPARK_JOB_NS_NUM", value = tostring(var.locust_config.job_ns_count) }
      ]
      args = "-f /home/locust/locustfile.py --job-azs '[\"${var.region}a\",\"${var.region}b\"]' --run-time=${var.locust_config.run_time} --users=${var.locust_config.users} --spawn-rate=2 --skip-log-setup --headless"
      locustfile = {
        configMap = {
          name = "emr-loadtest-locustfile"
        }
      }
      master = {
        resources = {
          requests = { cpu = "10m", memory = "250Mi" }
          limits   = { cpu = "50m", memory = "250Mi" }
        }
      }
      worker = {
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8000"
          "prometheus.io/path"   = "/metrics"
        }
        resources = {
          requests = { cpu = "4", memory = "4Gi" }
          limits   = { cpu = "15", memory = "25Gi" }
        }
      }
    }
  })
}
