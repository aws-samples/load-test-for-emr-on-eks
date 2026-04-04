variable "cluster_name" {
  description = "Name of the cluster this VPC belongs to"
  type        = string
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "vpc_cidr" {
  description = "Primary CIDR block for the VPC"
  type        = string
}

variable "availability_zones" {
  description = "List of availability zones for subnet placement"
  type        = list(string)
}
