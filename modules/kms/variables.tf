variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "region" {
  description = "AWS region for KMS ViaService condition"
  type        = string
}

variable "key_alias" {
  description = "KMS key alias name"
  type        = string
}
