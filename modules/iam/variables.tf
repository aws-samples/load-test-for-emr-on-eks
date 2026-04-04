variable "cluster_name" {
  description = "Name of the cluster for role naming"
  type        = string
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA trust policies"
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC provider URL for IRSA trust policies"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for encryption permissions"
  type        = string
}

variable "s3_bucket_arn" {
  description = "S3 bucket ARN for EMR execution role permissions"
  type        = string
}
