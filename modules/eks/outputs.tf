output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_data" {
  description = "EKS cluster CA certificate data (base64)"
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL (without https://)"
  value       = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
}

output "cluster_security_group_id" {
  description = "Cluster primary security group ID"
  value       = module.eks.cluster_primary_security_group_id
}

output "node_security_group_id" {
  description = "Node security group ID"
  value       = module.eks.node_security_group_id
}
