output "locust_namespace" {
  description = "Namespace where Locust Operator is deployed"
  value       = "locust"
}

output "locust_test_crd_path" {
  description = "Path to the generated LocustTest CRD manifest"
  value       = local_file.locust_test_crd.filename
}
