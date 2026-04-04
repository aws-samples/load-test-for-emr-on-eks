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

variable "karpenter_version" {
  description = "Karpenter Helm chart version"
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

variable "karpenter_controller_role_arn" {
  description = "Karpenter controller IRSA role ARN"
  type        = string
}

variable "karpenter_node_role_name" {
  description = "Karpenter node IAM role name"
  type        = string
}

variable "karpenter_instance_profile" {
  description = "Karpenter instance profile name"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for EBS encryption"
  type        = string
}

variable "driver_nodepool" {
  description = "Driver NodePool configuration"
  type = object({
    cpu_limit           = string
    instance_categories = list(string)
    instance_sizes      = list(string)
    capacity_types      = list(string)
  })
}

variable "executor_nodepool" {
  description = "Executor NodePool configuration"
  type = object({
    cpu_limit           = string
    instance_categories = list(string)
    instance_sizes      = list(string)
    capacity_types      = list(string)
    consolidate_after   = string
  })
}

variable "ami_selector_alias" {
  description = "AMI selector alias for Karpenter EC2NodeClass (e.g., al2023@latest or al2023@v20251217)"
  type        = string
  default     = "al2023@latest"
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for Karpenter node provisioning"
  type        = list(string)
}

variable "cluster_security_group_id" {
  description = "Cluster security group ID for Karpenter nodes"
  type        = string
}
