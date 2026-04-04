## EMR on EKS Load Test Benchmark Utility

This repository provides a comprehensive tool to benchmark EMR scalability performance on EKS clusters, supporting the **JobRun API** submission type. This out-of-the-box solution uses Terraform to provision complete infrastructure — including EKS clusters, VPC networking, IAM roles, Karpenter autoscaling, and monitoring — along with a load testing job generator powered by the Locust Kubernetes Operator. It features pre-built Grafana dashboard templates for observing test results and throttling events.

With a single `terraform apply`, you can provision multiple EKS clusters simultaneously with different EKS versions and Karpenter configurations, enabling side-by-side benchmarking in one deployment. All files needed to deploy and run are self-contained in this repo.

# Table of Contents
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
  - [Step 1: Configure](#step-1-configure)
  - [Step 2: Deploy Infrastructure](#step-2-deploy-infrastructure)
  - [Step 3: Build and Push Container Images](#step-3-build-and-push-container-images)
  - [Step 4: Run Load Test](#step-4-run-load-test)
  - [Step 5: Cleanup](#step-5-cleanup)
- [Architecture](#architecture)
  - [Module Structure](#module-structure)
  - [Naming Conventions](#naming-conventions)
  - [Design Decisions](#design-decisions)
- [Best Practices](#best-practices)
  - [Pod Allocation](#1-how-to-allocate-spark-driver--executor-pods)
  - [Binpacking](#2-binpacking-application-pods)
  - [Cluster Scalability](#3-cluster-scalability-with-karpenter)
  - [Networking](#4-networking-best-practices)
- [Monitoring](#monitoring)
- [Detailed Guides](#detailed-guides)
- [Cleanup](#cleanup)

## Prerequisites

- Terraform >= 1.10.0
- AWS CLI v2 (>= 2.17.45)
- kubectl (>= 1.31)
- Helm (>= 3.13)
- Docker with buildx (for container image builds)

[^ back to top](#table-of-contents)

## Quick Start

All commands assume you are in the solution directory (`generated/build/solution`).

### Step 1: Configure

```bash
cp examples/single-cluster.tfvars terraform.tfvars
# Edit terraform.tfvars — set region, availability_zones
```

<details>
<summary>Default Configuration (single cluster)</summary>

```hcl
region       = "ap-southeast-2"
project_name = "emr-eks-load-test"

clusters = {
  "1-32" = {
    eks_version        = "1.32"
    karpenter_version  = "1.8.5"
    vpc_cidr           = "10.0.0.0/16"
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    ops_node_group     = { instance_type = "m5.4xlarge", desired_capacity = 3 }
    driver_nodepool    = { cpu_limit = "128", instance_categories = ["m","c"], instance_sizes = ["2xlarge","4xlarge","8xlarge"], capacity_types = ["on-demand"] }
    executor_nodepool  = { cpu_limit = "3440", instance_categories = ["m","r"], instance_sizes = ["4xlarge","8xlarge","12xlarge","16xlarge"], capacity_types = ["spot","on-demand"], consolidate_after = "2m" }
    vpc_cni            = { minimum_ip_target = 32, warm_ip_target = 0, warm_prefix_target = 1 }
    locust             = { workers = 2, users = 4, run_time = "10m", emr_image_version = "7.9.0", job_ns_count = 2 }
  }
}
```
</details>

For multi-cluster comparison (e.g., EKS v1.30 vs v1.32), see `examples/multi-cluster.tfvars`.

### Step 2: Deploy Infrastructure

```bash
terraform init
terraform plan
terraform apply
```

This provisions: VPC, EKS cluster, IAM roles, Karpenter with NodePools, Prometheus + Grafana, Locust Operator, S3 bucket, ECR repos, KMS key, SQS interruption queue, and all access entries.

### Step 3: Build and Push Container Images

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(grep 'region' terraform.tfvars | head -1 | awk -F'"' '{print $2}')
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Login to ECR
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URL

# Build and push Locust image (multi-arch)
docker buildx create --name multiarch --driver docker-container --use 2>/dev/null || docker buildx use multiarch
docker buildx build --platform linux/amd64,linux/arm64 \
  -t $ECR_URL/locust:latest -f docker/locust/Dockerfile docker/ --push

# Copy Spark benchmark image from public ECR
docker buildx imagetools create \
  --tag $ECR_URL/eks-spark-benchmark:emr7.9.0 \
  public.ecr.aws/myang-poc/eks-spark-benchmark:emr7.9.0
```

### Step 4: Run Load Test

```bash
# Update kubeconfig
aws eks update-kubeconfig --region $REGION --name emr-eks-load-test-1-32

# Apply LocustTest CRD
kubectl apply -f templates/1-32-locust-test.yaml

# Watch worker logs
kubectl logs -f -n locust -l locust.cloud/component=worker

# Access Grafana (admin/admin)
kubectl port-forward -n prometheus svc/kube-prometheus-stack-grafana 3000:80
# Open http://localhost:3000
```

> **Tip:** Adjust job submission frequency by modifying `wait_time` in `modules/locust/locustfiles/locustfile.py`. Default is 20-30 seconds per user (~16-24 jobs/min with 4 users × 2 workers).

> **Warning:** Locust creates new namespaces/virtual clusters at each test run. Clean up previous test sessions before starting a new one to avoid stale metrics.

### Step 5: Cleanup

```bash
# Stop test and clean EMR virtual clusters
./scripts/cleanup-emr-vc.sh

# Destroy all infrastructure
terraform destroy
```

[^ back to top](#table-of-contents)

## Architecture

### Module Structure

```
.
├── main.tf              # Root orchestrator with for_each over cluster map
├── variables.tf         # Cluster config map (region set in tfvars only)
├── providers.tf         # AWS, Kubernetes (v3), Helm (v3), kubectl providers
├── docker/              # Dockerfile and dependencies for Locust image
├── examples/            # Single-cluster and multi-cluster tfvars
├── scripts/             # cleanup-emr-vc.sh
├── templates/           # Generated LocustTest CRD manifests
├── docs/                # Detailed guides
└── modules/
    ├── vpc/             # Per-cluster VPC with prefix delegation
    ├── eks/             # EKS cluster, managed node groups, addons
    ├── iam/             # IRSA roles: EMR, Locust, Karpenter, EBS CSI, LB Controller
    ├── karpenter/       # Version-specific Karpenter with driver/executor NodePools
    ├── monitoring/      # Prometheus, Grafana, LB Controller, BinPacking scheduler
    ├── locust/          # Locust Operator, ConfigMap, LocustTest CRD template
    ├── storage/         # Per-cluster S3 bucket with KMS encryption
    ├── ecr/             # Shared ECR repositories
    ├── kms/             # Shared KMS key with rotation
    └── ide/             # Optional managed IDE via SSM
```

### Naming Conventions

| Resource | Pattern | Example |
|----------|---------|---------|
| EKS Cluster | `<project>-<cluster>` | `emr-eks-load-test-1-32` |
| S3 Bucket | `emr-on-<project>-<cluster>-<account>` | `emr-on-emr-eks-load-test-1-32-010117700078` |
| EMR Execution Role | `emr-on-<project>-<cluster>-execution-role` | `emr-on-emr-eks-load-test-1-32-execution-role` |
| ECR Repos | `<name>` (flat) | `locust`, `eks-spark-benchmark` |
| KMS Alias | `alias/<kms_key_alias>` | `alias/emr-eks-load-test` |


[^ back to top](#table-of-contents)

## Best Practices

### 1. How to Allocate Spark Driver & Executor Pods

To minimize cross-node data I/O penalties, allocate Spark executor pods onto the same node as much as possible. This project uses separate Karpenter NodePools for drivers (stable, on-demand) and executors (cost-optimized, spot + on-demand with consolidation).

The load test framework dynamically populates the AZ value for `spark.kubernetes.node.selector.topology.kubernetes.io/zone` during job submission, binding all pods within a job to a single AZ to avoid cross-AZ data transfer fees.

```yaml
"spark.kubernetes.executor.node.selector.karpenter.sh/nodepool": "executor-memorynodepool"
"spark.kubernetes.driver.node.selector.karpenter.sh/nodepool": "driver-nodepool"
"spark.kubernetes.node.selector.topology.kubernetes.io/zone": "${randomly_selected_az}"
```

### 2. Binpacking Application Pods

Two types of binpacking work together:

- **Custom Kubernetes scheduler** (`custom-scheduler-eks`) — binpacks at pod creation time, packing pods tightly onto existing nodes before requesting new ones. Configured via `spark.kubernetes.scheduler.name`.
- **Karpenter consolidation** — binpacks at runtime by replacing underutilized nodes. Only enabled on executor NodePools with disruption budgets (100% for empty nodes, 25% for underutilized).

### 3. Cluster Scalability with Karpenter

This project uses Karpenter exclusively for load test pod scaling. The ops node group (3× m5.4xlarge) is fixed-size for operational pods (Prometheus, Karpenter, LB Controller).

Karpenter NodePool configuration highlights:
- **Driver NodePool:** on-demand, WhenEmpty consolidation, Nitro instances, generation > 4
- **Executor NodePool:** spot + on-demand, WhenEmptyOrUnderutilized consolidation, disruption budgets
- **EC2NodeClass:** 50Gi gp3 EBS with KMS encryption, IMDSv2 enforced, amd64 + arm64 support

### 4. Networking Best Practices

VPC CNI is configured with prefix delegation for large-scale pod scheduling:

```
ENABLE_PREFIX_DELEGATION=true
MINIMUM_IP_TARGET=32
WARM_IP_TARGET=0
WARM_PREFIX_TARGET=1
```

Each cluster gets its own VPC with configurable CIDR to avoid IP conflicts. Subnets are tagged with `karpenter.sh/discovery` for automatic node provisioning.

[^ back to top](#table-of-contents)

## Monitoring

Pre-built Grafana dashboards are included for observing test results:

| Dashboard | What It Shows | Data Available |
|-----------|---------------|----------------|
| AWS CNI Metrics | VPC CNI IP allocation, ENI usage | Always |
| EKS Control Plane | API server latency, etcd, scheduler | Always |
| Karpenter | NodePool utilization, provisioning latency | Always |
| emr-on-eks-load-test | Locust job submissions, EMR job states | During active tests |
| emr-eks-grafana-dashboard | Combined EMR on EKS overview | During active tests |

Access Grafana:
```bash
kubectl port-forward -n prometheus svc/kube-prometheus-stack-grafana 3000:80
# Open http://localhost:3000 (admin/admin)
```

Prometheus scrapes metrics from Karpenter (ServiceMonitor), AWS CNI (PodMonitor), Locust workers (PodMonitor on `locust.cloud/component=worker`), and Spark drivers (PodMonitor on `emr-containers.amazonaws.com/resource.type=job.run`).

[^ back to top](#table-of-contents)

## Detailed Guides

- [Load Testing Guide](docs/load-testing-guide.md) — scaling parameters, custom tests, test architecture, all configurable parameters
- [Monitoring Guide](docs/monitoring-guide.md) — dashboard details, Prometheus targets, Locust metrics reference, troubleshooting

## Cleanup

```bash
# Stop load test and clean EMR resources
./scripts/cleanup-emr-vc.sh

# Destroy all infrastructure
terraform destroy
```

[^ back to top](#table-of-contents)

## Optional: Remote State

```bash
cd bootstrap && terraform init && terraform apply -var="region=ap-southeast-2" && cd ..
# Update backend.hcl with bucket name, uncomment backend block in versions.tf
terraform init -backend-config="backend.hcl" -migrate-state
```

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
