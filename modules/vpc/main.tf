# VPC module: Per-cluster VPC with prefix delegation support
# Implements FR-002, ADR-002

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-${var.cluster_name}"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = [for i, az in var.availability_zones : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in var.availability_zones : cidrsubnet(var.vpc_cidr, 4, i + length(var.availability_zones))]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags required for Karpenter subnet discovery
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                          = "1"
    "karpenter.sh/discovery"                                   = "${var.project_name}-${var.cluster_name}"
    "kubernetes.io/cluster/${var.project_name}-${var.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb"                                   = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.cluster_name}" = "shared"
  }

  tags = {
    Cluster = var.cluster_name
  }
}
