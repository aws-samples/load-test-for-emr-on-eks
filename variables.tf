variable "region" {
  description = "AWS region for all resource provisioning and state storage"
  type        = string
  # No default — must be set in terraform.tfvars (single source of truth)
}

variable "project_name" {
  description = "Project name used as prefix for resource naming"
  type        = string
  default     = "emr-eks-load-test"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "clusters" {
  description = "Map of cluster configurations. Each key is a cluster name, value defines its settings."
  type = map(object({
    eks_version        = string
    karpenter_version  = string
    vpc_cidr           = string
    availability_zones = list(string)

    ops_node_group = object({
      instance_type    = string
      desired_capacity = number
    })

    driver_nodepool = object({
      cpu_limit           = string
      instance_categories = list(string)
      instance_sizes      = list(string)
      capacity_types      = list(string)
    })

    executor_nodepool = object({
      cpu_limit           = string
      instance_categories = list(string)
      instance_sizes      = list(string)
      capacity_types      = list(string)
      consolidate_after   = string
    })

    vpc_cni = object({
      minimum_ip_target  = number
      warm_ip_target     = number
      warm_prefix_target = number
    })

    locust = object({
      workers           = number
      users             = number
      run_time          = string
      emr_image_version = string
      job_ns_count      = number
    })
  }))

  validation {
    condition     = alltrue([for k, v in var.clusters : can(regex("^1\\.(2[89]|3[0-9])$", v.eks_version))])
    error_message = "EKS version must be in format 1.XX where XX >= 28 (e.g., 1.30, 1.32)."
  }

  validation {
    condition     = alltrue([for k, v in var.clusters : can(cidrhost(v.vpc_cidr, 0))])
    error_message = "VPC CIDR must be a valid CIDR block (e.g., 10.0.0.0/16)."
  }

  validation {
    condition     = alltrue([for k, v in var.clusters : can(regex("^\\d+\\.\\d+\\.\\d+$", v.karpenter_version))])
    error_message = "Karpenter version must be in semver format (e.g., 1.8.5)."
  }
}

# --- Shared Resource Variables ---

variable "ecr_repository_names" {
  description = "List of ECR repository names shared across clusters"
  type        = list(string)
  default     = ["locust", "eks-spark-benchmark"]
}

variable "kms_key_alias" {
  description = "Alias for the shared KMS key used for EBS and S3 encryption"
  type        = string
  default     = "emr-eks-load-test"
}

# --- Optional IDE Variables ---

variable "enable_ide" {
  description = "Enable managed VS Code IDE environment for load test interaction"
  type        = bool
  default     = false
}

variable "ide_instance_type" {
  description = "EC2 instance type for the IDE environment"
  type        = string
  default     = "m5.large"
}

variable "ide_users" {
  description = "Number of IDE instances to provision (one per concurrent user)"
  type        = number
  default     = 1
}
