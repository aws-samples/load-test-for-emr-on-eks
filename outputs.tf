# Root outputs: Per-cluster access information and shared resource details

output "cluster_kubeconfig_commands" {
  description = "AWS CLI commands to update kubeconfig for each cluster"
  value = {
    for name, _ in var.clusters :
    name => "aws eks update-kubeconfig --region ${var.region} --name ${module.eks[name].cluster_name}"
  }
}

output "cluster_endpoints" {
  description = "EKS cluster API endpoints"
  value = {
    for name, _ in var.clusters :
    name => module.eks[name].cluster_endpoint
  }
}

output "grafana_access_commands" {
  description = "Commands to access Grafana dashboards per cluster"
  value = {
    for name, _ in var.clusters :
    name => "kubectl --context arn:aws:eks:${var.region}:*:cluster/${module.eks[name].cluster_name} port-forward -n prometheus svc/kube-prometheus-stack-grafana 3000:80"
  }
}

output "locust_test_apply_commands" {
  description = "Commands to apply LocustTest CRD per cluster"
  value = {
    for name, _ in var.clusters :
    name => "kubectl apply -f templates/${name}-locust-test.yaml"
  }
}

output "s3_bucket_names" {
  description = "S3 bucket names per cluster"
  value = {
    for name, _ in var.clusters :
    name => module.storage[name].bucket_name
  }
}

output "ecr_repository_urls" {
  description = "ECR repository URLs (shared across clusters)"
  value       = module.ecr.repository_urls
}

output "kms_key_arn" {
  description = "KMS key ARN for EBS and S3 encryption"
  value       = module.kms.key_arn
}

output "ide_access_commands" {
  description = "Commands to access IDE instances via Session Manager"
  value = var.enable_ide ? [
    for ide in module.ide :
    ide.ide_url
  ] : []
}
