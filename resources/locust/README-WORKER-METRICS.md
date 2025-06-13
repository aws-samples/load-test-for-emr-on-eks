# Worker-Based Metrics Implementation

## Overview
This implementation provides distributed metrics collection for large-scale Spark job load testing using Locust in EKS pods.

## Architecture

### Master Node (Port 8000)
- **EKS Status Monitoring**: Real-time SparkApplication state tracking
- **Background Thread**: Queries EKS every 30 seconds
- **Metrics Exported**:
  - `locust_running_spark_application_gauge`
  - `locust_submitted_spark_application_gauge`
  - `locust_succeeding_spark_application_gauge`
  - `locust_new_spark_application_gauge`
  - `locust_completed_spark_application_gauge`
  - `locust_failed_spark_application_gauge`

### Worker Node(s) (Port 8001)
- **Direct Submission Tracking**: Real-time counter increments
- **Zero EKS API Pressure**: No additional API calls
- **Metrics Exported**:
  - `locust_spark_application_submit_success_total`
  - `locust_spark_application_submit_fail_total`
  - `locust_spark_application_submit_gauge`

## File Structure

### Core Files
- `locust-submit-script.py`: Main Locust script with worker-based metrics
- `locust-spark-pi.yaml`: Spark job template
- `locust-deployment.yaml`: Complete deployment with merged worker metrics
- `locust-exporter-deployment.yaml`: Prometheus exporter (if needed)

### Deployment Components
The `locust-deployment.yaml` includes:
1. **Locust Master Deployment**
2. **Locust Worker Deployment** (with port 8001 for metrics)
3. **Master Service** (ports 8089, 5557, 5558, 8000)
4. **Worker Metrics Service** (port 8001, headless)
5. **Master ServiceMonitor** (Prometheus scraping)
6. **Worker ServiceMonitor** (Prometheus scraping)

## Benefits for Large-Scale Testing

### Performance
- ✅ **Zero EKS API pressure** from submission tracking
- ✅ **No master bottleneck** for submission metrics
- ✅ **Real-time accuracy** - every submission counted immediately

### Scalability
- ✅ **Linear scaling**: More workers = more metrics capacity
- ✅ **Distributed load**: Each worker handles its own metrics
- ✅ **No single point of failure**

### Accuracy
- ✅ **100% accuracy**: Direct counter increments on job submission
- ✅ **No timing windows**: Immediate tracking
- ✅ **No missing counts**: Every API call tracked

## Prometheus Configuration

```yaml
scrape_configs:
  # Master metrics (EKS status)
  - job_name: 'locust-master'
    static_configs:
      - targets: ['locust-master:8000']

  # Worker metrics (submissions) - auto-discovery
  - job_name: 'locust-workers'
    kubernetes_sd_configs:
      - role: endpoints
        namespaces: [locust]
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: locust-worker-metrics
```

## Usage

### Deploy
```bash
kubectl apply -f resources/locust/locust-deployment.yaml
```

### Scale Workers
```bash
kubectl scale deployment locust-worker -n locust --replicas=10
```

### Access Metrics
```bash
# Master metrics
kubectl port-forward -n locust svc/locust-master 8000:8000

# Worker metrics
kubectl port-forward -n locust svc/locust-worker-metrics 8001:8001
```

### Aggregate Metrics in Prometheus
```promql
# Total successful submissions across all workers
sum(locust_spark_application_submit_success_total)

# Average execution time across workers
avg(locust_spark_application_submit_gauge)

# Submission rate per second
rate(locust_spark_application_submit_success_total[1m])
```

## Migration Notes

- **Consolidated**: Worker metrics patch merged into main deployment
- **Backward Compatible**: Preserves existing infrastructure
- **Future-Proof**: Ready for infrastructure restarts
- **Clean Structure**: No separate patch files needed
