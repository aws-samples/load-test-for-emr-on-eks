variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "repository_names" {
  description = "List of ECR repository names to create"
  type        = list(string)
}
