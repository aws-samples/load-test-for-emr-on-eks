# Bootstrap: Provision S3 bucket for Terraform state
# Run this ONCE before configuring the S3 backend in the main project.
# Usage:
#   cd bootstrap
#   terraform init
#   terraform apply -var="region=us-west-2"

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region for the state bucket — should match your main project region"
  type        = string
  # No default — pass explicitly: terraform apply -var="region=ap-southeast-2"
}

variable "bucket_prefix" {
  description = "Prefix for the state bucket name"
  type        = string
  default     = "emr-eks-load-test-tfstate"
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.bucket_prefix}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name      = "Terraform State"
    ManagedBy = "bootstrap"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "bucket_name" {
  description = "S3 bucket name for Terraform state — use this in the backend config"
  value       = aws_s3_bucket.tfstate.id
}

output "region" {
  description = "Region of the state bucket"
  value       = var.region
}

output "backend_config" {
  description = "Copy this into versions.tf backend block"
  value       = <<-EOT
    backend "s3" {
      bucket       = "${aws_s3_bucket.tfstate.id}"
      key          = "emr-eks-load-test/terraform.tfstate"
      region       = "${var.region}"
      encrypt      = true
      use_lockfile = true
    }
  EOT
}
