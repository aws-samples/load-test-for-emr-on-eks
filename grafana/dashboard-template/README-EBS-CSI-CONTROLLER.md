# EBS CSI Driver - Controller Performance Dashboard

## Overview

This Grafana dashboard provides comprehensive monitoring of the AWS EBS CSI Driver controller's provisioning and attachment performance. It visualizes key metrics to help identify bottlenecks, track performance trends, and troubleshoot issues in large-scale EKS environments.

## Dashboard Sections

### 1. Volume Provisioning Performance

Monitors the performance of volume creation and deletion operations:

- **Volume Creation Latency**: Tracks the time taken to create EBS volumes (CreateVolume CSI operation)
  - 99th, 95th, and 50th percentile latencies
  - Helps identify slow volume provisioning issues

- **Volume Deletion Latency**: Tracks the time taken to delete EBS volumes (DeleteVolume CSI operation)
  - 99th, 95th, and 50th percentile latencies
  - Useful for detecting resource cleanup bottlenecks

- **Volume Provisioning Operations Rate**: Shows the rate of create/delete operations per second
  - Monitor workload intensity
  - Identify usage patterns and peak periods

- **Volume Provisioning Errors**: Displays error rates for create/delete operations
  - Quickly spot failing operations
  - Correlate errors with latency spikes

### 2. Volume Attach/Detach Performance

Tracks the performance of attaching and detaching volumes to EC2 instances:

- **Volume Attach/Detach Latency**: Duration of attach (ControllerPublishVolume) and detach (ControllerUnpublishVolume) operations
  - Critical for pod startup time optimization
  - 99th, 95th, and 50th percentiles for both operations
  - Thresholds: Yellow warning at 10s, red alert at 20s

- **Volume Attach/Detach Operations Rate**: Rate of attach/detach operations per second
  - Correlate with pod churn rate
  - Identify scaling event impacts

- **Pending Detach Duration by Volume**: Time CSI driver has been waiting for volume detachment
  - Shows individual volumes stuck in detaching state
  - Labels include: instance_id, volume_id, attachment_state
  - Thresholds: Yellow warning at 60s, red alert at 120s

- **Volume Attach/Detach Errors**: Error rates for attach/detach operations
  - Identify attachment failures
  - Useful for troubleshooting pod startup issues

### 3. AWS API Performance

Monitors the underlying AWS EC2 API calls made by the EBS CSI driver:

- **AWS API Request Duration**: Latency of AWS SDK API calls
  - Broken down by request type (CreateVolume, AttachVolume, DetachVolume, etc.)
  - p99 and p50 percentiles
  - Helps distinguish between AWS API issues and driver issues

- **AWS API Throttles**: Rate of throttled AWS API requests
  - Critical for high-volume workloads
  - Indicates when AWS API rate limits are hit
  - Consider requesting limit increases if consistently high

- **AWS API Errors**: Errors from AWS API calls by request type and error code
  - Shows detailed error breakdown
  - Examples: VolumeNotFound, InvalidParameter, InsufficientCapacity
  - Essential for diagnosing infrastructure issues

### 4. Controller Health

Monitors the health and resource usage of the EBS CSI controller pods:

- **Controller Pods Running**: Number of healthy controller pods
  - Threshold: Green ≥ 2, Yellow = 1, Red = 0
  - Alerts on controller unavailability

- **Controller CPU Usage**: CPU consumption by controller pods
  - Identifies resource constraints
  - Useful for right-sizing controller resources

- **Controller Memory Usage**: Memory consumption by controller pods
  - Detects memory leaks
  - Helps with capacity planning

## Prerequisites

### 1. Enable Controller Metrics

Ensure metrics are enabled in your EBS CSI Driver Helm chart:

```bash
helm upgrade aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --set controller.enableMetrics=true \
  --set controller.serviceMonitor.enabled=true
```

### 2. Deploy ServiceMonitor

Apply the ServiceMonitor to enable Prometheus scraping:

```bash
kubectl apply -f resources/monitor/ebs-csi-servicemonitor.yaml
```

Verify the ServiceMonitor is created:

```bash
kubectl get servicemonitor -n prometheus ebs-csi-controller
```

### 3. Verify Metrics are Being Scraped

Check that Prometheus is successfully scraping EBS CSI controller metrics:

```bash
# Port-forward to Prometheus
kubectl port-forward -n prometheus svc/prometheus-kube-prometheus-prometheus 9090:9090

# Navigate to http://localhost:9090 and query:
up{job="ebs-csi-controller"}
```

Expected result: `up{job="ebs-csi-controller"} 1`

## Dashboard Import

### Import to Amazon Managed Grafana

1. Navigate to your Amazon Managed Grafana workspace URL
2. Go to **Dashboards** → **New** → **Import**
3. Choose **Upload JSON file** and select `ebs-csi-controller-performance.json`
4. Or copy the JSON content and paste it into the **Import via panel json** field
5. Select your Prometheus datasource (Amazon Managed Prometheus)
6. Click **Import**

### Import to Self-Hosted Grafana

1. Open Grafana UI
2. Navigate to **+** → **Import**
3. Upload `ebs-csi-controller-performance.json` or paste the JSON content
4. Select your Prometheus datasource
5. Click **Import**

## Key Metrics Reference

### CSI Operation Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `csi_operations_seconds_bucket` | Histogram | Duration of CSI operations (CreateVolume, DeleteVolume, ControllerPublishVolume, ControllerUnpublishVolume) |
| `csi_operations_seconds_count` | Counter | Total count of CSI operations, includes `grpc_status_code` label for error tracking |

### AWS API Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `aws_ebs_csi_api_request_duration_seconds_bucket` | Histogram | Duration of AWS SDK API calls by request type |
| `aws_ebs_csi_api_request_errors_total` | Counter | Total errors by request type and error code |
| `aws_ebs_csi_api_request_throttles_total` | Counter | Total throttled requests per request type |
| `aws_ebs_csi_ec2_detach_pending_seconds` | Gauge | Time waiting for volume detachment, includes volume_id, instance_id, attachment_state labels |

### Controller Health Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `up{job="ebs-csi-controller"}` | Gauge | Controller pod health status (1 = up, 0 = down) |
| `container_cpu_usage_seconds_total` | Counter | CPU usage of controller containers |
| `container_memory_working_set_bytes` | Gauge | Memory usage of controller containers |

## Troubleshooting

### High Attach/Detach Latency

**Symptoms**: Attach/Detach latency p99 > 20 seconds

**Common Causes**:
1. **AWS API throttling**: Check "AWS API Throttles" panel
   - Solution: Request EC2 API rate limit increase
   - Temporary: Scale down workload or increase throttle backoff

2. **Pending detachments**: Check "Pending Detach Duration by Volume" panel
   - Volumes stuck in "detaching" state
   - Solution: Investigate underlying instance issues or stale attachments

3. **Controller resource constraints**: Check "Controller CPU/Memory Usage" panels
   - Solution: Increase controller pod resources or scale replicas

### High Provisioning Errors

**Symptoms**: Non-zero values in "Volume Provisioning Errors" panel

**Common Causes**:
1. **InsufficientCapacity**: AWS unable to provision requested volume type/size in AZ
   - Solution: Use different volume type or distribute across AZs

2. **VolumeInUse**: Attempting to delete volume still attached
   - Check application pod termination
   - Verify persistent volume reclaim policy

3. **InvalidParameter**: Incorrect volume specifications
   - Review StorageClass parameters
   - Check volume size/type compatibility

### Controller Pods Not Running

**Symptoms**: "Controller Pods Running" shows < 2 (or 0)

**Common Causes**:
1. Resource constraints on operational nodes
2. Image pull failures
3. IRSA role misconfiguration

**Troubleshooting**:
```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
kubectl describe pod -n kube-system <controller-pod-name>
kubectl logs -n kube-system <controller-pod-name> -c ebs-plugin
```

## Performance Tuning Recommendations

### 1. Scale Controller Replicas

For high-volume workloads (>1000 volume operations/hour):

```bash
# In infra-provision.sh, modify the CSI controller patch
kubectl scale deployment ebs-csi-controller --replicas=5 -n kube-system
```

### 2. Optimize Controller Resources

Based on dashboard metrics, adjust controller resource requests/limits:

```yaml
# In Helm values
controller:
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi
```

### 3. Monitor AWS API Limits

Set up alerts for throttling:
- Alert when `aws_ebs_csi_api_request_throttles_total` > 0 for sustained period
- Request limit increases proactively based on growth trends

### 4. Enable Faster Volume Attach

Use Nitro instance types with NVMe for significantly faster attach/detach times.

## Integration with Load Testing

This dashboard is designed to work seamlessly with the EMR on EKS load testing framework:

1. **Baseline Measurement**: Run dashboard before load test to establish baseline performance
2. **Load Test Monitoring**: Observe real-time metrics during Locust-based load tests
3. **Bottleneck Identification**: Correlate Spark job failures with EBS CSI performance issues
4. **Capacity Planning**: Use historical data to size EBS CSI controller for production workloads

### Correlation with Spark Metrics

Compare this dashboard with:
- **Spark Operator Dashboard**: Pod scheduling times correlate with volume attach latency
- **Karpenter Dashboard**: Node provisioning rate affects volume creation rate
- **EKS Control Plane Dashboard**: API server performance impacts CSI operation responsiveness

## Dashboard Refresh and Time Range

- **Refresh Interval**: 30 seconds (configurable in dashboard settings)
- **Default Time Range**: Last 1 hour
- **Recommended for Load Tests**: Extend to last 3-6 hours to capture full test duration

## Additional Resources

- [AWS EBS CSI Driver Metrics Documentation](https://github.com/kubernetes-sigs/aws-ebs-csi-driver/blob/master/docs/metrics.md)
- [EBS CSI Driver GitHub Repository](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
- [AWS EBS Volume Performance](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html)
- [Prometheus Operator ServiceMonitor](https://prometheus-operator.dev/docs/operator/design/#servicemonitor)
