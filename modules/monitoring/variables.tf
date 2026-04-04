variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  type        = string
}

variable "cluster_ca_data" {
  description = "EKS cluster CA certificate data"
  type        = string
}

variable "eks_version" {
  description = "EKS version for BinPacking scheduler compatibility"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC provider URL for IRSA"
  type        = string
}

variable "lb_controller_role_arn" {
  description = "AWS LB Controller IRSA role ARN"
  type        = string
}
