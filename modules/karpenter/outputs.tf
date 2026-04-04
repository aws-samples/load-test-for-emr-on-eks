output "karpenter_namespace" {
  description = "Namespace where Karpenter is installed"
  value       = "kube-system" # Karpenter typically runs in kube-system
}
