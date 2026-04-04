output "emr_execution_role_arn" {
  description = "EMR on EKS execution role ARN"
  value       = aws_iam_role.emr_execution.arn
}

output "locust_role_arn" {
  description = "Locust IRSA role ARN"
  value       = aws_iam_role.locust.arn
}

output "karpenter_controller_role_arn" {
  description = "Karpenter controller IRSA role ARN"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_node_role_name" {
  description = "Karpenter node IAM role name"
  value       = aws_iam_role.karpenter_node.name
}

output "karpenter_node_role_arn" {
  description = "Karpenter node IAM role ARN"
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_instance_profile_name" {
  description = "Karpenter instance profile name"
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "ebs_csi_role_arn" {
  description = "EBS CSI driver IRSA role ARN"
  value       = aws_iam_role.ebs_csi.arn
}

output "lb_controller_role_arn" {
  description = "AWS LB Controller IRSA role ARN"
  value       = aws_iam_role.lb_controller.arn
}
