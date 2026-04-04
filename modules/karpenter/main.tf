# Karpenter module: Version-parameterized Helm release with NodePools
# Implements FR-005, ADR-003

locals {
  cluster_full_name = "${var.project_name}-${var.cluster_name}"

  # CRD API version conditional: v1 for Karpenter >= 1.0.0, v1beta1 for < 1.0.0
  karpenter_major = tonumber(split(".", var.karpenter_version)[0])
  use_v1_api      = local.karpenter_major >= 1
  crd_api_version = local.use_v1_api ? "karpenter.sh/v1" : "karpenter.sh/v1beta1"
  nodeclass_api   = local.use_v1_api ? "karpenter.k8s.aws/v1" : "karpenter.k8s.aws/v1beta1"
}

# --- Karpenter Helm Release ---

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  values = [yamlencode({
    settings = {
      clusterName      = local.cluster_full_name
      clusterEndpoint  = var.cluster_endpoint
      interruptionQueue = local.cluster_full_name
    }
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = var.karpenter_controller_role_arn
      }
    }
    controller = {
      resources = {
        requests = { cpu = "2", memory = "2Gi" }
        limits   = { cpu = "10", memory = "20Gi" }
      }
    }
  })]

  wait = true
}

# --- Driver NodePool (on-demand, stable) ---

resource "kubectl_manifest" "driver_nodepool" {
  yaml_body = yamlencode({
    apiVersion = local.crd_api_version
    kind       = "NodePool"
    metadata = {
      name = "driver-nodepool"
    }
    spec = {
      template = {
        spec = {
          expireAfter = "Never"
          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64", "arm64"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = var.driver_nodepool.capacity_types
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = var.driver_nodepool.instance_categories
            },
            {
              key      = "karpenter.k8s.aws/instance-size"
              operator = "In"
              values   = var.driver_nodepool.instance_sizes
            },
            {
              key      = "karpenter.k8s.aws/instance-hypervisor"
              operator = "In"
              values   = ["nitro"]
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["4"]
            }
          ]
          nodeClassRef = local.use_v1_api ? {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "memoryec2"
          } : {
            apiVersion = local.nodeclass_api
            kind       = "EC2NodeClass"
            name       = "memoryec2"
          }
        }
      }
      limits = {
        cpu = var.driver_nodepool.cpu_limit
      }
      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [helm_release.karpenter]
}

# --- Executor NodePool (spot + on-demand, aggressive consolidation) ---

resource "kubectl_manifest" "executor_nodepool" {
  yaml_body = yamlencode({
    apiVersion = local.crd_api_version
    kind       = "NodePool"
    metadata = {
      name = "executor-memorynodepool"
    }
    spec = {
      template = {
        spec = {
          expireAfter = "Never"
          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64", "arm64"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = var.executor_nodepool.capacity_types
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = var.executor_nodepool.instance_categories
            },
            {
              key      = "karpenter.k8s.aws/instance-size"
              operator = "In"
              values   = var.executor_nodepool.instance_sizes
            },
            {
              key      = "karpenter.k8s.aws/instance-hypervisor"
              operator = "In"
              values   = ["nitro"]
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["4"]
            }
          ]
          nodeClassRef = local.use_v1_api ? {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "memoryec2"
          } : {
            apiVersion = local.nodeclass_api
            kind       = "EC2NodeClass"
            name       = "memoryec2"
          }
        }
      }
      limits = {
        cpu = var.executor_nodepool.cpu_limit
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = var.executor_nodepool.consolidate_after
        budgets = [
          {
            nodes   = "100%"
            reasons = ["Empty"]
          },
          {
            nodes   = "25%"
            reasons = ["Underutilized"]
          }
        ]
      }
    }
  })

  depends_on = [helm_release.karpenter]
}

# --- EC2NodeClass (shared across NodePools) ---

resource "kubectl_manifest" "nodeclass" {
  yaml_body = yamlencode({
    apiVersion = local.nodeclass_api
    kind       = "EC2NodeClass"
    metadata = {
      name = "memoryec2"
    }
    spec = {
      role = var.karpenter_node_role_name
      amiSelectorTerms = [
        {
          alias = var.ami_selector_alias
        }
      ]
      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.cluster_full_name
          }
        }
      ]
      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.cluster_full_name
          }
        }
      ]
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "50Gi"
            volumeType          = "gp3"
            encrypted           = true
            kmsKeyID            = var.kms_key_arn
            deleteOnTermination = true
          }
        }
      ]
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 2
        httpTokens              = "required"
      }
      tags = {
        Name                     = "${local.cluster_full_name}-karpenter-node"
        "karpenter.sh/discovery" = local.cluster_full_name
      }
    }
  })

  depends_on = [helm_release.karpenter]
}
