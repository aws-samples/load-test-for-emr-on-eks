variable "cluster_name" {
  description = "Name of the cluster this bucket belongs to"
  type        = string
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "region" {
  description = "AWS region for bucket naming convention"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for bucket encryption"
  type        = string
}
