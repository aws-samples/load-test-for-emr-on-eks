variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the IDE"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for IDE placement"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for IDE placement"
  type        = string
}

variable "cluster_names" {
  description = "List of cluster names for kubeconfig setup"
  type        = list(string)
}

variable "region" {
  description = "AWS region"
  type        = string
}
