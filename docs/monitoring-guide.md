# Monitoring Guide

## Accessing Grafana

```bash
kubectl port-forward -n prometheus svc/kube-prometheus-stack-grafana 3000:80
```

Open http://localhost:3000 — login with `admin` / `admin`.

If the password was changed or forgotten, reset it:

```bash
kubectl exec -n prometheus $(kubectl get pods -n prometheus -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}') \
  -c grafana -- grafana cli admin reset-admin-password admin
```

## Dashboards

### Custom Dashboards (from reference repo)

| Dashboard | What It Shows | When It Has Data |
|-----------|---------------|------------------|
| AWS CNI Metrics | VPC CNI IP allocation, ENI usage, prefix delegation stats | Always (as long as nodes are running) |
| EKS Control Plane | API server latency, etcd performance, scheduler metrics | Always |
| Karpenter | NodePool utilization, node provisioning latency, capacity | Always (after Karpenter is installed) |
| emr-on-eks-load-test | Locust job submission rates, EMR job states (running/pending/completed/failed) | Only during active load tests |
| emr-eks-grafana-dashboard | Combined EMR on EKS overview | Only during active load tests |

### Built-in Dashboards (from kube-prometheus-stack)

These are always available with data:
- Kubernetes / Compute Resources / Cluster
- Kubernetes / Compute Resources / Namespace
- Kubernetes / Networking / Cluster
- CoreDNS
- etcd
- Kubelet
- Node Exporter

## Prometheus Targets

Verify Prometheus is scraping all expected targets:

```bash
kubectl port-forward -n prometheus svc/kube-prometheus-stack-prometheus 9090:9090
```

Open http://localhost:9090 → Status → Targets. Expected targets:

| Target | Source | Metrics |
|--------|--------|---------|
| `karpenter` | ServiceMonitor | Node provisioning, NodePool capacity, scheduling latency |
| `prometheus/aws-cni` | PodMonitor | IP addresses allocated, ENI attachments, prefix delegation |
| `locust-metrics` | PodMonitor (`locust.cloud/component=worker`) | Locust job submission, EMR job states |
| `spark-driver-monitoring` | PodMonitor (`spark-role=driver`) | Spark executor metrics |
| `spark-service-monitoring` | ServiceMonitor (`spark_role=driver`) | Spark driver metrics |
| `apiserver` | Built-in | API request latency, error rates |
| `kubelet` | Built-in | Pod lifecycle, container metrics |
| `node-exporter` | Built-in | CPU, memory, disk, network per node |
| `kube-state-metrics` | Built-in | Pod/deployment/node state |
| `coredns` | Built-in | DNS query rates, cache hits |

### Locust Metrics (only during active tests)

Locust worker pods expose Prometheus metrics on port 8000. The `locust` PodMonitor scrapes these:

| Metric | Type | Description |
|--------|------|-------------|
| `locust_spark_application_submit_success_total` | Counter | Successful EMR job submissions |
| `locust_spark_application_submit_fail_total` | Counter | Failed EMR job submissions |
| `locust_spark_application_submit_time_gauge` | Gauge | Time to submit a Spark application |
| `locust_running_spark_application_gauge` | Gauge | Currently running Spark jobs |
| `locust_submitted_spark_application_gauge` | Gauge | Submitted EMR jobs |
| `locust_succeeding_spark_application_gauge` | Gauge | Pending jobs waiting for compute |
| `locust_completed_spark_application_gauge` | Gauge | Successfully completed jobs |
| `locust_failed_spark_application_gauge` | Gauge | Failed EMR jobs |
| `locust_concurrent_user` | Gauge | Active Locust users |

## Troubleshooting

### Dashboard shows "No data"

1. Check the time range (top right) — set to "Last 15 minutes" or "Last 1 hour"
2. Verify the data source: Settings → Data Sources → Prometheus should point to `http://kube-prometheus-stack-prometheus.prometheus:9090/`
3. For EMR/Locust dashboards: data only appears during active load tests
4. Check Prometheus targets: http://localhost:9090/targets — all targets should be "UP"

### Locust metrics not appearing

```bash
# Verify worker pods have the correct label (locust.cloud/component=worker)
kubectl get pods -n locust -l locust.cloud/component=worker --show-labels

# Check if PodMonitor exists with correct selector
kubectl get podmonitor -n prometheus locust-metrics -o yaml | grep -A10 "selector:"

# Test metrics endpoint directly (while workers are running)
kubectl port-forward -n locust $(kubectl get pods -n locust -l locust.cloud/component=worker -o jsonpath='{.items[0].metadata.name}') 8000:8000
curl http://localhost:8000/metrics
```
