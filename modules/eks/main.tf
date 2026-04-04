# EKS module: Per-cluster EKS with managed node groups and addons
# Implements FR-003, FR-011, FR-012, ADR-001

locals {
  cluster_full_name = "${var.project_name}-${var.cluster_name}"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_full_name
  cluster_version = var.eks_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Enable IRSA
  enable_irsa = true

  # Cluster addons
  cluster_addons = {
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        replicaCount = 3
      })
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          MINIMUM_IP_TARGET        = tostring(var.vpc_cni_config.minimum_ip_target)
          WARM_IP_TARGET           = tostring(var.vpc_cni_config.warm_ip_target)
          WARM_PREFIX_TARGET       = tostring(var.vpc_cni_config.warm_prefix_target)
        }
      })
    }
    # EBS CSI driver managed separately in root main.tf to avoid circular dependency with IAM
    # aws-ebs-csi-driver = { most_recent = true }
    amazon-cloudwatch-observability = {
      most_recent = true
    }
  }

  # Managed node group for operational workloads
  eks_managed_node_groups = {
    ops = {
      name                   = "${var.cluster_name}-ops"
      iam_role_use_name_prefix = false
      instance_types         = [var.ops_node_group.instance_type]
      desired_size   = var.ops_node_group.desired_capacity
      min_size       = 1
      max_size       = var.ops_node_group.desired_capacity + 2

      labels = {
        role        = "ops"
        operational = "true"
        monitor     = "true"
      }

      tags = {
        "karpenter.sh/discovery" = local.cluster_full_name
      }
    }
  }

  # Enable CloudWatch logging
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Node security group additional rules for Karpenter
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  # Access entries for cluster admin
  enable_cluster_creator_admin_permissions = true

  # Use exact names instead of name_prefix to avoid 38-char limit
  iam_role_use_name_prefix = false

  tags = {
    Cluster                          = var.cluster_name
    "karpenter.sh/discovery"         = local.cluster_full_name
  }
}
