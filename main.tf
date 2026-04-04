# Root module: Orchestrates shared resources and per-cluster module composition
# Full implementation in Task 3

locals {
  cluster_names            = keys(var.clusters)
  first_cluster_full_name  = "${var.project_name}-${local.cluster_names[0]}"
  cluster_endpoint         = try(module.eks[local.cluster_names[0]].cluster_endpoint, "https://localhost")
  cluster_ca_cert          = try(base64decode(module.eks[local.cluster_names[0]].cluster_ca_data), "")
}

# --- Shared Resources (outside per-cluster loop) ---

module "kms" {
  source = "./modules/kms"

  project_name = var.project_name
  region       = var.region
  key_alias    = var.kms_key_alias
}

module "ecr" {
  source = "./modules/ecr"

  project_name     = var.project_name
  repository_names = var.ecr_repository_names
}

# --- Per-Cluster Resources (for_each over cluster map) ---

module "vpc" {
  source   = "./modules/vpc"
  for_each = var.clusters

  cluster_name       = each.key
  project_name       = var.project_name
  vpc_cidr           = each.value.vpc_cidr
  availability_zones = each.value.availability_zones
}

module "eks" {
  source   = "./modules/eks"
  for_each = var.clusters

  cluster_name   = each.key
  project_name   = var.project_name
  eks_version    = each.value.eks_version
  vpc_id         = module.vpc[each.key].vpc_id
  private_subnets = module.vpc[each.key].private_subnet_ids
  ops_node_group = each.value.ops_node_group
  kms_key_arn    = module.kms.key_arn
  vpc_cni_config = each.value.vpc_cni
}

module "iam" {
  source   = "./modules/iam"
  for_each = var.clusters

  cluster_name          = each.key
  project_name          = var.project_name
  oidc_provider_arn     = module.eks[each.key].oidc_provider_arn
  oidc_provider_url     = module.eks[each.key].oidc_provider_url
  kms_key_arn           = module.kms.key_arn
  s3_bucket_arn         = module.storage[each.key].bucket_arn
}

module "karpenter" {
  source   = "./modules/karpenter"
  for_each = var.clusters

  cluster_name      = each.key
  project_name      = var.project_name
  region            = var.region
  karpenter_version = each.value.karpenter_version
  cluster_endpoint  = module.eks[each.key].cluster_endpoint
  cluster_ca_data   = module.eks[each.key].cluster_ca_data

  karpenter_controller_role_arn = module.iam[each.key].karpenter_controller_role_arn
  karpenter_node_role_name     = module.iam[each.key].karpenter_node_role_name
  karpenter_instance_profile   = module.iam[each.key].karpenter_instance_profile_name
  kms_key_arn                  = module.kms.key_arn

  driver_nodepool   = each.value.driver_nodepool
  executor_nodepool = each.value.executor_nodepool

  private_subnet_ids    = module.vpc[each.key].private_subnet_ids
  cluster_security_group_id = module.eks[each.key].cluster_security_group_id

  # Wait for LB Controller webhook to be ready (deployed in monitoring module)
  depends_on = [module.monitoring]
}

module "monitoring" {
  source   = "./modules/monitoring"
  for_each = var.clusters

  cluster_name     = each.key
  project_name     = var.project_name
  region           = var.region
  cluster_endpoint = module.eks[each.key].cluster_endpoint
  cluster_ca_data  = module.eks[each.key].cluster_ca_data
  eks_version      = each.value.eks_version

  oidc_provider_arn = module.eks[each.key].oidc_provider_arn
  oidc_provider_url = module.eks[each.key].oidc_provider_url

  lb_controller_role_arn = module.iam[each.key].lb_controller_role_arn
}

module "locust" {
  source   = "./modules/locust"
  for_each = var.clusters

  cluster_name     = each.key
  project_name     = var.project_name
  region           = var.region
  cluster_endpoint = module.eks[each.key].cluster_endpoint
  cluster_ca_data  = module.eks[each.key].cluster_ca_data

  locust_role_arn = module.iam[each.key].locust_role_arn
  locust_config   = each.value.locust

  ecr_repository_url = module.ecr.repository_urls["locust"]
  s3_bucket_name     = module.storage[each.key].bucket_name

  depends_on = [module.monitoring]
}

module "storage" {
  source   = "./modules/storage"
  for_each = var.clusters

  cluster_name = each.key
  project_name = var.project_name
  region       = var.region
  kms_key_arn  = module.kms.key_arn
}

# --- SQS queue for Karpenter spot interruption handling ---

resource "aws_sqs_queue" "karpenter_interruption" {
  for_each = var.clusters

  name                      = "${var.project_name}-${each.key}"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = {
    Cluster = each.key
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  for_each = var.clusters

  queue_url = aws_sqs_queue.karpenter_interruption[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.karpenter_interruption[each.key].arn
      }
    ]
  })
}

# EC2 event rules for spot interruption, rebalance, state change, and health
resource "aws_cloudwatch_event_rule" "karpenter_interruption" {
  for_each = var.clusters

  name = "${var.project_name}-${each.key}-karpenter"
  event_pattern = jsonencode({
    source = ["aws.health", "aws.ec2"]
    "detail-type" = [
      "AWS Health Event",
      "EC2 Spot Instance Interruption Warning",
      "EC2 Instance Rebalance Recommendation"
    ]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_interruption" {
  for_each = var.clusters

  rule      = aws_cloudwatch_event_rule.karpenter_interruption[each.key].name
  target_id = "karpenter-interruption"
  arn       = aws_sqs_queue.karpenter_interruption[each.key].arn
}

# --- Karpenter node role access entry (allows Karpenter-launched nodes to join the cluster) ---

resource "aws_eks_access_entry" "karpenter_node" {
  for_each = var.clusters

  cluster_name  = module.eks[each.key].cluster_name
  principal_arn = module.iam[each.key].karpenter_node_role_arn
  type          = "EC2_LINUX"

  depends_on = [module.eks, module.iam]
}

# --- Locust role access entry (allows Locust to manage namespaces and virtual clusters) ---

resource "aws_eks_access_entry" "locust" {
  for_each = var.clusters

  cluster_name  = module.eks[each.key].cluster_name
  principal_arn = module.iam[each.key].locust_role_arn
  type          = "STANDARD"

  depends_on = [module.eks, module.iam]
}

resource "aws_eks_access_policy_association" "locust_admin" {
  for_each = var.clusters

  cluster_name  = module.eks[each.key].cluster_name
  principal_arn = module.iam[each.key].locust_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.locust]
}

# --- EBS CSI addon with IRSA (managed here to break EKS↔IAM circular dependency) ---

resource "aws_eks_addon" "ebs_csi" {
  for_each = var.clusters

  cluster_name                = module.eks[each.key].cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.ebs_csi[each.key].version
  service_account_role_arn    = module.iam[each.key].ebs_csi_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks, module.iam]
}

data "aws_eks_addon_version" "ebs_csi" {
  for_each = var.clusters

  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = each.value.eks_version
  most_recent        = true
}

# --- Optional IDE Module ---

module "ide" {
  source = "./modules/ide"
  count  = var.enable_ide ? var.ide_users : 0

  project_name   = var.project_name
  instance_type  = var.ide_instance_type
  vpc_id         = module.vpc[local.cluster_names[0]].vpc_id
  subnet_id      = module.vpc[local.cluster_names[0]].private_subnet_ids[0]
  cluster_names  = local.cluster_names
  region         = var.region
}
