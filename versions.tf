terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.27.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
  }

  # S3 backend with native state locking (Terraform >= 1.10)
  # Step 1: Run bootstrap/ first to create the bucket
  # Step 2: Uncomment this block and run: terraform init -migrate-state
  #         Use: terraform init -backend-config="backend.hcl" -migrate-state
  # backend "s3" {
  #   key          = "emr-eks-load-test/terraform.tfstate"
  #   encrypt      = true
  #   use_lockfile = true
  #   # bucket and region are set via backend.hcl (single source of truth)
  # }
}
