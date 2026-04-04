variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "eks_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the cluster"
  type        = string
}

variable "private_subnets" {
  description = "List of private subnet IDs for the cluster"
  type        = list(string)
}

variable "ops_node_group" {
  description = "Configuration for the operational workloads node group"
  type = object({
    instance_type    = string
    desired_capacity = number
  })
}

variable "kms_key_arn" {
  description = "KMS key ARN for EBS encryption"
  type        = string
}

variable "vpc_cni_config" {
  description = "VPC CNI prefix delegation configuration"
  type = object({
    minimum_ip_target  = number
    warm_ip_target     = number
    warm_prefix_target = number
  })
}

variable "ebs_csi_role_arn" {
  description = "IAM role ARN for the EBS CSI driver addon"
  type        = string
  default     = null
}
