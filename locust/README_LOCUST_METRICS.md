# Locust Metrics

This document describes the custom Prometheus metrics exposed by the Locust load testing framework for EMR on EKS.

## Overview

The enhanced `locustfile_with_prometheus.py` exposes comprehensive `locust_*` metrics via a Prometheus HTTP endpoint on port 8000 (configurable via `METRICS_PORT` environment variable).

## New Metrics

### Job Submission Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `locust_spark_submit_total` | Counter | `status`, `namespace` | Total Spark job submissions by status (success/failed/timeout/exception) |
| `locust_spark_submit_success_total` | Counter | - | Total successful Spark job submissions |
| `locust_spark_submit_failed_total` | Counter | `error_type` | Total failed Spark job submissions by error type |
| `locust_spark_submit_duration_seconds` | Histogram | `namespace` | Job submission duration in seconds (buckets: 0.5s to 300s) |
| `locust_spark_submit_duration_summary_seconds` | Summary | - | Summary statistics for job submission duration |

### Job State Metrics (Gauges)

| Metric | Type | Description |
|--------|------|-------------|
| `locust_spark_jobs_running` | Gauge | Currently running Spark jobs |
| `locust_spark_jobs_submitted` | Gauge | Submitted Spark jobs |
| `locust_spark_jobs_pending` | Gauge | Pending Spark jobs |
| `locust_spark_jobs_new` | Gauge | New Spark jobs |
| `locust_spark_jobs_completed` | Gauge | Completed Spark jobs |
| `locust_spark_jobs_failed` | Gauge | Failed Spark jobs |

### Locust User Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `locust_users_active` | Gauge | Number of active Locust users (concurrent load) |
| `locust_users_spawned_total` | Counter | Total number of Locust users spawned |

### Virtual Cluster Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `locust_virtual_clusters_total` | Gauge | Total EMR virtual clusters created for test |
| `locust_virtual_clusters_active` | Gauge | Active EMR virtual clusters |

### Test Session Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `locust_test_info` | Info | `test_id`, `cluster_name`, `region`, `namespace_prefix` | Test session metadata |
| `locust_test_uptime_seconds` | Gauge | - | Test session uptime in seconds |
| `locust_test_start_timestamp` | Gauge | - | Unix timestamp when test started |
| `locust_jobs_per_namespace` | Gauge | `namespace` | Jobs submitted per namespace |

## Deployment

### Step 1: Update Locust Deployment

Ensure your Locust pods have the following:

1. **Port Configuration**: Add metrics port to your pod spec
2. **Labels**: Add `app: locust` label
3. **Environment Variable** (optional): Set `METRICS_PORT=8000`

Example pod template snippet:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: locust-master
  labels:
    app: locust
    component: master
spec:
  containers:
  - name: locust
    image: your-locust-image
    ports:
    - name: web
      containerPort: 8089
      protocol: TCP
    - name: metrics  # Prometheus metrics port
      containerPort: 8000
      protocol: TCP
    env:
    - name: METRICS_PORT
      value: "8000"
    - name: CLUSTER_NAME
      value: "your-cluster"
    - name: AWS_REGION
      value: "us-west-2"
```

### Step 2: Deploy PodMonitor

Apply the PodMonitor to enable Prometheus scraping:

```bash
kubectl apply -f resources/monitor/locust-podmonitor.yaml
```

Verify the PodMonitor is created:

```bash
kubectl get podmonitor -n prometheus locust-load-test-monitor
```

### Step 3: Verify Metrics Collection

Check that Prometheus is scraping Locust metrics:

```bash
# Port-forward to Prometheus
kubectl port-forward -n prometheus svc/prometheus-kube-prometheus-prometheus 9090:9090

# Open browser to http://localhost:9090 and query:
locust_spark_submit_success_total
locust_users_active
locust_spark_jobs_running
```

Expected result: You should see metrics with current values.

## Query Examples

### Job Submission Rate

```promql
# Successful submissions per second
rate(locust_spark_submit_success_total[5m])

# Failed submissions per second by error type
rate(locust_spark_submit_failed_total[5m])
```

### Job Submission Latency

```promql
# P99 submission latency across all namespaces
histogram_quantile(0.99, sum(rate(locust_spark_submit_duration_seconds_bucket[5m])) by (le))

# P95 submission latency by namespace
histogram_quantile(0.95, sum(rate(locust_spark_submit_duration_seconds_bucket[5m])) by (namespace, le))

# Average submission duration
rate(locust_spark_submit_duration_summary_seconds_sum[5m]) / rate(locust_spark_submit_duration_summary_seconds_count[5m])
```

### Job State Tracking

```promql
# Total jobs in any active state
locust_spark_jobs_running + locust_spark_jobs_submitted + locust_spark_jobs_pending

# Job completion rate
rate(locust_spark_jobs_completed[5m])

# Job failure rate
rate(locust_spark_jobs_failed[5m])
```

### Load Testing Progress

```promql
# Current concurrent users
locust_users_active

# Test duration in hours
locust_test_uptime_seconds / 3600

# Jobs per namespace
sum(locust_jobs_per_namespace) by (namespace)
```

### Success Rate

```promql
# Overall success rate (%)
100 * rate(locust_spark_submit_success_total[5m]) / rate(locust_spark_submit_total[5m])

# Failure rate by error type
sum(rate(locust_spark_submit_failed_total[5m])) by (error_type)
```

## Grafana Dashboard

Create a Grafana dashboard with these panels:

### 1. Job Submission Rate
```promql
rate(locust_spark_submit_success_total[5m])
```

### 2. Job States Over Time
```promql
locust_spark_jobs_running
locust_spark_jobs_pending
locust_spark_jobs_submitted
```

### 3. Active Users
```promql
locust_users_active
```

### 4. Submission Latency (P99, P95, P50)
```promql
histogram_quantile(0.99, sum(rate(locust_spark_submit_duration_seconds_bucket[5m])) by (le))
histogram_quantile(0.95, sum(rate(locust_spark_submit_duration_seconds_bucket[5m])) by (le))
histogram_quantile(0.50, sum(rate(locust_spark_submit_duration_seconds_bucket[5m])) by (le))
```

### 5. Job Success Rate
```promql
100 * rate(locust_spark_submit_success_total[5m]) / rate(locust_spark_submit_total[5m])
```

### 6. Errors by Type
```promql
sum(rate(locust_spark_submit_failed_total[5m])) by (error_type)
```

## Backward Compatibility

The new version maintains backward compatibility with the original metric names:
- `locust_spark_application_submit_success_total`
- `locust_spark_application_submit_fail_total`
- `locust_running_spark_application_gauge`
- `locust_submitted_spark_application_gauge`
- `locust_concurrent_user`
- `locust_virtual_clusters_count`

Both old and new metric names are exported simultaneously.

## Troubleshooting

### Metrics Not Appearing

1. **Check Pod Labels**:
```bash
kubectl get pods -n locust --show-labels | grep locust
```
Ensure pods have `app=locust` label.

2. **Verify Metrics Port**:
```bash
POD=$(kubectl get pod -l locust.cloud/component=master -n locust -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward $POD -n locust 8000:8000
curl http://localhost:8000/metrics | grep locust
```

3. **Check PodMonitor Status**:
```bash
kubectl get podmonitor -n prometheus locust-metrics -o yaml
```

4. **Check Prometheus Targets**:
- Open Prometheus UI: `http://localhost:9090/targets`
- Search for "locust-load-test-monitor"
- Verify status is "UP"

**Check metric names**:
```promql
{job_name="pvc-reuse-cluster-10-master"}
```
Should show all available metrics.

## Performance Considerations

- **Cardinality**: The `namespace` label on histograms increases cardinality. Monitor Prometheus resource usage.
- **Scrape Interval**: Default 30s is suitable. Reduce if you need higher resolution.
- **Retention**: Histogram buckets consume more storage. Adjust Prometheus retention as needed.

## Configuration Reference

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `METRICS_PORT` | `8000` | Port for Prometheus metrics endpoint |
| `CLUSTER_NAME` | Required | EKS cluster name |
| `AWS_REGION` | Required | AWS region |
| `JOB_SCRIPT_NAME` | Required | EMR on EKS job submission script |
| `SPARK_JOB_NS_NUM` | `1` | Number of job namespaces to be created by each Locust Worker |

### PodMonitor Configuration

The PodMonitor scrapes metrics from pods with `app: locust` label:
- **Namespace**: Any namespace (cross-namespace scraping enabled)
- **Port**: `metrics` (8000)
- **Interval**: 30 seconds
- **Path**: `/metrics`
- **Filtering**: Keeps only `locust_*` metrics

## Next Steps

1. Create Grafana dashboards for visualization
2. Set up Prometheus alerts for critical thresholds:
   - High failure rate: `rate(locust_spark_submit_failed_total[5m]) > 0.1`
   - High latency: `histogram_quantile(0.99, ...) > 60`
   - Low active users: `locust_users_active < 1`
3. Export metrics to CloudWatch for long-term storage
4. Correlate with EBS CSI and Karpenter metrics for comprehensive analysis
