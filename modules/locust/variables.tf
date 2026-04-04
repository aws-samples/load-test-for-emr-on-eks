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

variable "locust_role_arn" {
  description = "Locust IRSA role ARN"
  type        = string
}

variable "locust_config" {
  description = "Locust test configuration"
  type = object({
    workers           = number
    users             = number
    run_time          = string
    emr_image_version = string
    job_ns_count      = number
  })
}

variable "ecr_repository_url" {
  description = "ECR repository URL for Locust images"
  type        = string
}

variable "s3_bucket_name" {
  description = "S3 bucket name for test artifacts"
  type        = string
}
