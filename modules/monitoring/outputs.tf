output "grafana_url" {
  description = "Grafana access URL (use kubectl port-forward)"
  value       = "kubectl port-forward -n prometheus svc/kube-prometheus-stack-grafana 3000:80"
}

output "prometheus_namespace" {
  description = "Namespace where Prometheus is deployed"
  value       = "prometheus"
}
