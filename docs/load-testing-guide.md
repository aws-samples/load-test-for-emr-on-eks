# Load Testing Guide

## How It Works

The Locust Operator runs distributed load tests from within the EKS cluster:

1. You apply a `LocustTest` CRD manifest
2. The operator creates a master pod and worker pods
3. Each worker creates EMR virtual clusters and namespaces
4. Workers submit Spark jobs to EMR on EKS at configurable intervals
5. Karpenter provisions nodes for Spark driver and executor pods
6. Prometheus collects metrics from Locust workers and all cluster components

## Running a Load Test

### Using the Terraform-generated manifest

```bash
kubectl apply -f templates/1-32-locust-test.yaml
```

This uses the parameters from your `terraform.tfvars` locust config:
- `workers`: 2 Locust worker pods
- `users`: 4 concurrent Locust users (2 per worker)
- `run_time`: 10m test duration
- `job_ns_count`: 2 EMR namespaces/virtual clusters per worker
- `emr_image_version`: 7.9.0

### Custom test with different parameters

Create a custom manifest by copying and editing the template:

```bash
cp templates/1-32-locust-test.yaml templates/custom-test.yaml
```

Key parameters to adjust in the YAML:

| Parameter | Location | Effect |
|-----------|----------|--------|
| `workers` | `spec.workers` | Number of Locust worker pods (each creates its own virtual clusters) |
| `--users=N` | `spec.args` | Total concurrent Locust users across all workers |
| `--spawn-rate=N` | `spec.args` | Users spawned per second |
| `--run-time=Nm` | `spec.args` | Test duration (e.g., 10m, 30m, 1h) |
| `SPARK_JOB_NS_NUM` | `spec.env` | Number of EMR namespaces per worker |
| `EMR_IMAGE_VERSION` | `spec.env` | EMR release version (e.g., 7.3.0, 7.9.0) |
| `--job-azs` | `spec.args` | AZs for job scheduling (JSON array) |

### Scaling examples

**Small test** (validation):
```yaml
workers: 1
args: "... --users=2 --spawn-rate=1 --run-time=5m ..."
env:
  - name: SPARK_JOB_NS_NUM
    value: "1"
```

**Medium test** (baseline):
```yaml
workers: 2
args: "... --users=4 --spawn-rate=2 --run-time=10m ..."
env:
  - name: SPARK_JOB_NS_NUM
    value: "2"
```

**Large test** (stress):
```yaml
workers: 4
args: "... --users=8 --spawn-rate=2 --run-time=30m ..."
env:
  - name: SPARK_JOB_NS_NUM
    value: "4"
```

**Note**: Each Locust user submits a job every 20-30 seconds (configured in `locustfile.py` as `wait_time = between(20, 30)`). So 4 users × 2 workers = ~16-24 jobs per minute.

## Monitoring a Running Test

### Watch worker logs

```bash
kubectl logs -f -n locust -l locust.cloud/component=worker
```

Expected output:
```
[2026-04-03 10:56:22] Virtual cluster jsp9hkdvdbmg1lnaagaq8k7h8 mapped to namespace emr-xxx-ns1
[2026-04-03 10:56:23] Created 2 virtual clusters successfully
[2026-04-03 10:56:45] EMR job d3327610 is submitted successfully to VC: jsp9hkdvdbmg1lnaagaq8k7h8
[2026-04-03 10:56:45] Submitted 1 jobs. Elapsed time: 0:02:38
[2026-04-03 10:57:31] EMR Jobs in test session emr-xxx - job_states: {'RUNNING': 2, 'COMPLETED': 0, ...}
```

### Watch master logs

```bash
kubectl logs -f -n locust -l locust.cloud/component=master
```

The master aggregates job counts across all virtual clusters on the EKS cluster.

### Watch Karpenter node provisioning

```bash
kubectl get nodeclaims -w
```

### Watch Spark pods

```bash
kubectl get pods -A -l spark-role=driver -w
kubectl get pods -A -l spark-role=executor -w
```

### Check EMR job status via AWS CLI

```bash
# List virtual clusters
aws emr-containers list-virtual-clusters --region ap-southeast-2 \
  --container-provider-id emr-eks-load-test-1-32 \
  --states RUNNING --query 'virtualClusters[].{id:id,name:name}'

# List job runs for a virtual cluster
aws emr-containers list-job-runs --region ap-southeast-2 \
  --virtual-cluster-id <VC_ID> \
  --query 'jobRuns[].{id:id,name:name,state:state}'
```

## Stopping a Test

### Stop the LocustTest (stops new job submissions)

```bash
kubectl delete locusttest -n locust --all
```

**Note**: This stops Locust from submitting new jobs, but already-running Spark jobs continue until they complete.

### Full cleanup (stop everything)

```bash
./scripts/cleanup-emr-vc.sh
```

This cancels running EMR jobs, deletes virtual clusters, and removes EMR namespaces.

## Test Architecture

```
LocustTest CRD
  └── Locust Master Pod (stats aggregation, no job submission)
      └── Locust Worker Pods (N workers)
          ├── Creates EMR namespaces + virtual clusters (on_start)
          ├── Submits Spark jobs every 20-30s per user
          ├── Exports Prometheus metrics on port 8000
          └── Monitors EMR job states every 60s

Spark Jobs (submitted by Locust workers)
  ├── Driver Pod → scheduled on driver-nodepool (on-demand)
  └── Executor Pods (30 per job) → scheduled on executor-memorynodepool (spot)
      └── Karpenter provisions nodes as needed
```

## Configurable Parameters Reference

### Terraform variables (in `terraform.tfvars`)

```hcl
locust = {
  workers           = 2      # Locust worker pod count
  users             = 4      # Total concurrent Locust users
  run_time          = "10m"  # Test duration
  emr_image_version = "7.9.0" # EMR release version
  job_ns_count      = 2      # EMR namespaces per worker
}
```

### Environment variables (in LocustTest CRD)

| Variable | Description |
|----------|-------------|
| `CLUSTER_NAME` | Full EKS cluster name |
| `AWS_REGION` | AWS region |
| `EMR_IMAGE_VERSION` | EMR release (e.g., 7.9.0) |
| `SPARK_JOB_NS_NUM` | Namespaces per worker |
| `JOB_SCRIPT_NAME` | Job submission script (default: `emr-job-run.sh`) |
| `METRICS_PORT` | Prometheus metrics port (default: 8000) |

### Locust CLI args (in LocustTest CRD `spec.args`)

| Arg | Description |
|-----|-------------|
| `--users=N` | Total concurrent users |
| `--spawn-rate=N` | Users spawned per second |
| `--run-time=Nm` | Test duration |
| `--job-azs='["az1","az2"]'` | AZs for job scheduling |
| `--headless` | Run without web UI |
| `--skip-log-setup` | Use custom logging |

### Spark job parameters (in `emr-job-run.sh`)

| Parameter | Current Value | Description |
|-----------|---------------|-------------|
| `spark.executor.instances` | 30 | Executors per job |
| `spark.executor.cores` | 2 | CPU per executor |
| `spark.executor.memory` | 5g | Memory per executor |
| `spark.driver.cores` | 1 | CPU for driver |
| `spark.driver.memory` | 2g | Memory for driver |
| Benchmark | TPC-DS (30GB) | `q4-v2.4, q24a-v2.4, q24b-v2.4, q67-v2.4` queries |
