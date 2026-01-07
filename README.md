## EMR on EKS Load Test Benchmark Utility

This repository provides a comprehensive tool to benchmark EMR scalability performance on EKS clusters, supporting the job submission types: **JobRun API** (other types are coming soon). This out-of-the-box solution includes complete infrastructure setup for EKS clusters and a load testing job generator powered by the Locust Kubernetes Operator. It also features pre-built Grafana dashboard templates that can be used directly to observe your test results and throttling events. With zero to minimal setup overhead, you can quickly establish a large-scale load testing environment using this utility.

# Table of Contents
- [Prerequisite](#prerequisite)
- [Set up Test Environment](#set-up-test-environment)
  - [Prerequisite](#prerequisite---set-environment-variables)
  - [Create the EKS Cluster with Necessary Components (Optional)](#create-an-eks-cluster-with-components-needed-optional)
  - [Install Locust Operator on EKS](#install-locust-operator-on-eks)
- [Get Started](#get-started)
  - [Prerequisite](#prerequisite---update-job-script)
  - [Run test from local](#1-run-load-test-locally)
  - [Run test on EKS](#2-load-test-on-eks)
- [Best Practice Guide](#best-practices-and-considerations)
  - [How to Allocate Pods](#1-how-to-allocate-spark-driver--executor-pods)
  - [Avoid Sidecars When Possible](#2-avoid-initcontainers-and-custom-sidecars)
  - [Binpacking pods](#3-binpacking-application-pods)
  - [Cluster Scalability](#4-cluster-scalability)
  - [Networking in EKS](#5-best-practices-for-networking)
- [Monitoring](#monitoring)
- [Clean up](#clean-up)

## Prerequisite
- eksctl is installed in latest version (>= 0.194)
```bash
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv -v /tmp/eksctl /usr/local/bin
eksctl version
```
- Update AWS CLI to the latest (requires aws cli version >= 2.17.45) on macOS. Check out the [link](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) for Linux or Windows
```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg ./AWSCLIV2.pkg -target /
aws --version
rm AWSCLIV2.pkg
```
- Install kubectl on macOS, check out the [link](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) for Linux or Windows (>= 1.31.2)
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --short --client
```
- Helm CLI (>= 3.13.2)
```bash
curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
helm version --short
```

[^ back to top](#table-of-contents)

## Set up Test Environment

### Prerequisite - Set Environment Variables
Please update the values in `./env.sh` based on your environment settings.
Alternatively, use the default configurations shown below:

<details>
<summary>Default Environment Variables</summary>

```bash
# General
export AWS_REGION=us-west-2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export LOAD_TEST_PREFIX=load-test-cluster
export CLUSTER_NAME=${LOAD_TEST_PREFIX}-10
export BUCKET_NAME=emr-on-${CLUSTER_NAME}-$ACCOUNT_ID-${AWS_REGION}
# Locust
export EMR_IMAGE_VERSION=7.9.0
export SPARK_JOB_NS_NUM=2 # number of namespaces/VC to create
export LOCUST_EKS_ROLE="${CLUSTER_NAME}-locust-eks-role"
export JOB_SCRIPT_NAME="emr-job-run.sh"

# ================================================
# Required variables for infra-provision.sh. 
# If skipping the infra setup step, remove this section
# ================================================
# EKS
export EKS_VPC_CIDR=192.164.0.0/16
export EKS_VERSION=1.34
# EMR on EKS
export PUB_ECR_REGISTRY_ACCOUNT=895885662937
export EXECUTION_ROLE=emr-on-${CLUSTER_NAME}-execution-role
export EXECUTION_ROLE_POLICY=${CLUSTER_NAME}-SparkJobS3AccessPolicy
# Karpenter
export KARPENTER_VERSION="1.8.1"
export KARPENTER_CONTROLLER_ROLE="KarpenterControllerRole-${CLUSTER_NAME}"
export KARPENTER_CONTROLLER_POLICY="KarpenterControllerPolicy-${CLUSTER_NAME}"
export KARPENTER_NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"
# Create Amazon Managed Grafana workspace or not
export USE_AMG="true"
# =======================================================================
```
</details>

### Create an EKS Cluster with Components Needed (OPTIONAL)
An `infra-provision.sh` script is provided by the project, which creates a brand new EKS cluster with the following components.

Skip this step if you are using an existing EKS cluster. If required, install missing components individually, such as EBS CSI Driver, based on the infra provision script.

- [Auto Scaler](https://aws.github.io/aws-emr-containers-best-practices/troubleshooting/docs/eks-cluster-auto-scaler/)
- [Load Balancer Controller](https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html)
- [EBS CSI Driver Addon](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
- [Karpenter](https://aws.github.io/aws-emr-containers-best-practices/troubleshooting/docs/karpenter/)
- [BinPacking](https://awslabs.github.io/data-on-eks/docs/resources/binpacking-custom-scheduler-eks) 

Monitoring by default uses managed services:
- [Amazon Managed Prometheus](https://aws.amazon.com/prometheus/)
- [Amazon Managed Grafana](https://aws.amazon.com/grafana/)

#### 1. Modify EKS cluster and component configurations before provisioning the environment
- For EKS cluster, update [./resources/eks-cluster-values.yaml](./resources/eks-cluster-values.yaml)
- For autoscaler, modify [./resources/autoscaler-values.yaml](./resources/autoscaler-values.yaml)
- For custom k8s scheduler, update [./resources/binpacking-values.yaml](./resources/binpacking-values.yaml)
- For Karpenter, update yaml files under [./resources/karpenter/](./resources/karpenter/)
- For Prometheus, update [./resources/monitor/prometheus-values.yaml](./resources/monitor/prometheus-values.yaml)
- For Prometheus PodMonitor and ServiceMonitor settings, update files under [./resources/monitor](./resources/monitor)

#### 2. Run the script after all customizations are done
NOTE: at the end of the script, 2 ECR container images will be built and pushed: Spark benchmark and Locust.
```bash
bash ./infra-provision.sh
```

### Install Locust Operator on EKS
[Locust](https://docs.locust.io/en/stable/locust-cloud/locust-cloud.html#kubernetes-operator) is an open source load testing tool based on Python. 

This project offers a provision script `locust-provision.sh` to set up a Locust k8s Operator via a Helm chart. Before running the script, modify the [operator's RBAC permission](./locust/locust-operator/patch-role-binding.yaml) and [IRSA role policy](./locust/locust-operator/eks-role-policy.json) based on your requirements.
```bash
# create IRSA role and install locust operator
bash ./locust-provision.sh
```
[^ back to top](#table-of-contents)

## Get Started

To get an optimal load test outcome, you can configure your compute resource allocation via Spark settings. See the best practice section: [How to Allocate Pods](#1-how-to-allocate-spark-driver--executor-pods).

### Prerequisite - Update Job Script
This project supports most EMR on EKS load test cases with a default monitoring configuration (AWS Managed Prometheus + Managed Grafana). Before getting started, replace the sample job run file [./locust/locustfiles/emr-job-run.sh](./locust/locustfiles/emr-job-run.sh) with your actual EMR on EKS job submission script. Don't change the directory location, because it will be mapped into each Locust container's home directory `/home/locust` via a ConfigMap called `emr-loadtest-locustfile`. More details can be found in the [locust-provision.sh](https://github.com/aws-samples/load-test-for-emr-on-eks/blob/b389458ff4ebb1b829f6fd9c8aa49405c482bfc9/locust-provision.sh#L124) script. The setup looks like this:
```bash
kubectl create configmap emr-loadtest-locustfile --namespace locust --from-file=locust/locustfiles
```

NOTE: delete then recreate this ConfigMap if your submission script or other Python scripts are changed. Otherwise, Locust operator will only read from the previous version before any changes. You don't need to refresh the ConfigMap if running a test locally via `locust -f ./locustfiles/locustfile.py ...`.
```bash
kubectl delete configmap emr-loadtest-locustfile --namespace locust
```
[^ back to top](#table-of-contents)

### 1. Run Load Test Locally
Let's run a small test from a local terminal window. The following parameters are available to adjust before running the Locust CLI:
```bash
# -u or --users, How many users are going to submit jobs concurrently.
#     Uses a default wait interval (between 20s-30s per user) before submitting the next job.
# -t or --run-time, The total load test period.
# --emr-script-name, Set by env.sh. Load test job's shell script name.
# --job-azs, Default: None. A list of AZs available in the EKS VPC. When not set, pods in a
#            single job may be scheduled across multiple AZs, which could cause data transfer fees
#            and performance degradation. If set (see below), all pods in a job will be scheduled
#            to a single AZ. NOTE: The AZ selection is random, not round-robin.
# --job-ns-count, Default: 2 namespaces. Total number of namespaces/VCs that jobs will be submitted to.

cd load-test-for-emr-on-eks
python -m venv .venv
source .venv/bin/activate
sudo pip install -r locust/requirements.txt
source env.sh

locust -f locust/locustfiles/locustfile.py --run-time=2m --users=2 --spawn-rate=.5 \
--job-azs '["us-west-2a","us-west-2b"]' \
--job-ns-count 1 \
--skip-log-setup \
--headless
```
When the load test session is finished or in progress, you can cancel these jobs and delete EMR-on-EKS virtual clusters:

**WARNING:** Locust creates new namespace(s)/VC(s) at each test run. Any previously created VCs must be terminated before starting a new test session. Otherwise, the aggregated job stats will be affected by data from old test sessions, causing fluctuations in the results. Before deleting any load test namespaces in EKS, use the "stop_test.py" script to ensure all EMR-EKS jobs and VCs are terminated.
```bash
# --id, terminate VCs by a test session id. The unique id is used as namespace prefix "emr-{uniqueID}-{date}"
# --cluster, cancel test jobs across all VCs on the EKS cluster. A default value is set.
python3 locust/locustfiles/stop_test.py --cluster $CLUSTER_NAME  
# or 
python3 locust/locustfiles/stop_test.py
# delete namespaces if needed
kubectl get namespaces -o name | grep "emr" | xargs kubectl delete
```

[^ back to top](#table-of-contents)

### 2. Load Test on EKS
Locust Operator supports distributed load testing. By default, it fires up load testing from a cluster of 1 master + 2 worker pods. Each initializes a test session with a unique session ID.

Update the Locust test CRD manifest file with actual environment attributes, then start the load test from an EKS cluster:
```bash
cd load-test-for-emr-on-eks
kubectl apply -f examples/load-test-pvc-reuse.yaml

# check summarized load test metrics at master node
kubectl logs -f -n locust -l locust.cloud/component=master
# check load test status at job level
kubectl logs -f -n locust -l locust.cloud/component=worker
```

<!-- ```bash
# access to Locust WebUI: http://localhost:8089/
kubectl port-forward svc/pvc-reuse-cluster-10-webui -n locust 8089
``` -->

[^ back to top](#table-of-contents)

## Best Practices and Considerations

### 1. How to Allocate Spark Driver & Executor Pods

To minimize cross-node data I/O and network I/O penalties in a single Spark job, it is recommended to allocate Spark executor pods onto the same node as much as possible.

However, to reduce compute costs, we configure the executor's node pool with an aggressive node consolidation rule. To avoid eviction impact on the driver pod (which stays alive throughout the entire job lifecycle), we created a separate Karpenter node pool for driver pods in this load test.

Additionally, to avoid cross-AZ data transfer fees and degraded job performance, the load test framework (`locust/locustfile.py`) dynamically populates the AZ value for `spark.kubernetes.node.selector.topology.kubernetes.io/zone` during job submission, binding all pods within a job to a specified single AZ.

If your managed node group or Karpenter NodePool is configured as a single-AZ node provisioner, you can simply use a nodegroup/nodepool name as the nodeSelector to ensure your job's pods are in a single AZ. See the example below:

```yaml
# nodeSelector sample:
"spark.kubernetes.node.selector.topology.kubernetes.io/zone": "us-west-2a"

# Or match by a Karpenter NodePool name
"spark.kubernetes.executor.node.selector.karpenter.sh/nodepool": "executor-nodepool",
"spark.kubernetes.driver.node.selector.karpenter.sh/nodepool": "driver-nodepool",

# Or match by a node group name when using cluster autoscaler
"spark.kubernetes.driver.node.selector.eks.amazonaws.com/nodegroup": "m5-ng-uw2a",
```

**Additional Best Practices:**
- **Use instance store for shuffle:** If using instance-store-backed instances (i3, i4i, r6id), configure `spark.local.dir` to use the ephemeral NVMe volumes for better I/O performance and lower costs.
- **Separate driver and executor node pools:** Drivers require stable long-lived nodes, while executors can tolerate more aggressive consolidation and spot interruptions.
- **Right-size executor pods:** Balance between pod density (multiple executors per node) and resource isolation. Generally, 2-4 executors per node provides good shuffle performance while maintaining cost efficiency.

[^ back to top](#table-of-contents)

### 2. Avoid `initContainers` and Custom Sidecars

The number of Kubernetes events in EKS emitted by Spark jobs increases significantly when `initContainers` are enabled. As a result, the EKS API Server and etcd database size will fill up much faster than normal.

**Recommendation:** Avoid using `initContainers` or sidecar containers for large-scale workloads on an EKS cluster. Otherwise, consider splitting your workload across multiple EKS clusters or upgrading to [EKS Provisioned Control Plane](https://docs.aws.amazon.com/eks/latest/userguide/eks-provisioned-control-plane.html) for higher API server capacity.

**Why this matters:**
- Each pod with initContainers generates 2-3x more Kubernetes events
- At scale (1000+ concurrent pods), this can overwhelm the control plane
- etcd has a default 2GB storage limit; excessive events can fill this quickly
- API server throttling impacts job submission and pod scheduling latency

**Alternatives to initContainers:**
- **Bake dependencies into container images:** Pre-install libraries, JARs, and Python packages in your Spark image
- **Use init-only jobs:** Run setup as separate Kubernetes Jobs before main workload
- **Leverage S3 mounting:** Use s3a:// paths directly instead of downloading files locally
- **EmptyDir volumes:** Use ephemeral volumes for scratch space instead of PVCs when possible

[^ back to top](#table-of-contents)

### 3. Binpacking Application Pods

There are two types of binpacking:
- **Custom Kubernetes scheduler** - binpack at pod creation time
- **Karpenter's consolidation feature** - binpack pods or replace underutilized nodes during job runtime

**Binpack at Pod Launch Time** - A custom Kubernetes scheduler can efficiently assign pods to the least allocated nodes before a new node is requested. The goal is to optimize resource utilization by packing pods as tightly as possible onto a single node while still meeting resource requirements and constraints.

This approach aims to maximize cluster efficiency, reduce costs, and improve overall Spark job shuffle I/O performance by minimizing the number of active nodes required to run the workload. With binpacking enabled, workloads can minimize resources used on network traffic between physical nodes, as most pods will be allocated to a single node at launch time. The Spark configuration at job submission looks like this:

```bash
"spark.kubernetes.scheduler.name": "custom-scheduler-eks"
```

**Binpack at Runtime** - Launch-time binpacking doesn't solve resource wastage or cost spikes caused by frequent pod terminations, such as by Spark's Dynamic Resource Allocation (DRA). That's why another binpacking feature needs to coexist in our use case: enable Karpenter's consolidation feature (only for executor NodePools) to maximize pod density during job runtime.

**Important considerations:**
- **Enable consolidation selectively:** Only enable on executor NodePools, not driver NodePools
- **Tune consolidation timing:** Set appropriate `consolidateAfter` values (e.g., 30m) to avoid premature node terminations
- **Budget disruptions:** Use disruption budgets to limit how many nodes can be consolidated simultaneously
- **Monitor churn:** High pod churn can negate binpacking benefits and increase EBS API throttling

Example of Karpenter configuration:
```yaml
spec:
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 30m
    budgets:
    - nodes: "10%"  # Only consolidate 10% of nodes at a time
```

Learn more about binpacking via link: https://aws.github.io/aws-emr-containers-best-practices/performance/docs/binpack/

[^ back to top](#table-of-contents)

### 4. Cluster Scalability

EKS cluster autoscaling contains two main types:
  - [EKS Cluster Autoscaler (CAS)](https://docs.aws.amazon.com/eks/latest/best-practices/cas.html)
  - [Karpenter (default)](https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html)

**EKS Cluster Autoscaler (CAS)** - This project's EKS cluster is configured with three managed node groups: 
- **Operational NodeGroup:** For operational services (fixed size: 2 nodes). Used to host Prometheus, Load Balancer, Karpenter, and other operational pods.
- **Two application managed node groups:** One per AZ, scaling between 1 and 350 m5.xlarge EC2 nodes for load test jobs.

To schedule a large volume of nodes, the QPS and burst rate in the [CAS configuration](./resources/autoscaler-values.yaml) need to increase to avoid throttling:

```yaml
podAnnotations:
  cluster-autoscaler.kubernetes.io/safe-to-evict: 'false'
...
extraArgs:
...
  kube-client-qps: 300
  kube-client-burst: 400
```

**Best practices for CAS:**
- **Over-provision managed node groups:** Create node groups with higher max size than expected to avoid hitting AWS account limits
- **Use multiple instance types:** Configure mixed instance types for better availability
- **Monitor CAS logs:** Watch for throttling errors or scaling failures
- **Set appropriate cooldown:** Balance between rapid scaling and API throttling

**Karpenter** - In this project, we only provision load test jobs with Karpenter; the rest of operational pods (e.g., Prometheus, Karpenter, Binpacking) are scheduled in a fixed-size operational managef NodeGroup, outside of Karpenter's control.

**Karpenter NodePool configuration:**
To apply best practices for cost and performance, we utilize the `topology.kubernetes.io/zone` node selector to ensure all Spark pods in a single job are allocated to the same AZ:

```bash
"spark.kubernetes.executor.node.selector.karpenter.sh/nodepool": "executor-nodepool",
"spark.kubernetes.driver.node.selector.karpenter.sh/nodepool": "driver-nodepool",
"spark.kubernetes.node.selector.topology.kubernetes.io/zone": "${randomly_selected_az}" # eg. us-west-2a
```

**Karpenter best practices:**
- **Diversify instance types:** Use a wide range of instance types in NodePool requirements to improve availability
- **Set appropriate limits:** Configure `limits.cpu` and `limits.memory` on NodePools to prevent runaway scaling
- **Use Spot instances for executors:** Add Spot instance types to executor's NodePools for cost savings.
- **Monitor provisioning latency:** Track time from pod pending to pod running; high latency indicates nodepool capacity issues or API Throttlings.
- **Enable interruption handling:** Use `aws.interruptionQueue` for graceful Spot termination

Example NodePool configuration:
```yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
spec:
  template:
    spec:
      requirements:
      - key: "karpenter.sh/capacity-type"
        operator: In
        values: ["spot", "on-demand"]
      - key: karpenter.k8s.aws/instance-category
        operator: In
        values: ["m", "c"]
      - key: karpenter.k8s.aws/instance-size
        operator: In
        values: ["4xlarge", "8xlarge", "12xlarge", "16xlarge"]
```

[^ back to top](#table-of-contents)

### 5. Best Practices for Networking

With large volumes of workloads, IP addresses often become exhausted. To solve this, here are some tips to address the networking challenges:

- **Use AWS VPC CNI with secondary CIDRs:** Set up a secondary or additional CIDRs for your EKS cluster instead of relying solely on the primary subnet. Learn more about this technique here: https://aws.github.io/aws-eks-best-practices/networking/custom-networking/

- **Fine-tune VPC CNI configurations** to minimize IP wastage per subnet:
    - `WARM_ENI_TARGET`
    - `WARM_PREFIX_TARGET` 
    - `WARM_IP_TARGET`, `MINIMUM_IP_TARGET`

More details can be found in the [EKS networking best practices](https://docs.aws.amazon.com/eks/latest/best-practices/networking.html), [VPC-CNI concepts](https://aws.github.io/aws-eks-best-practices/networking/vpc-cni/), and [Prefix Delegation](https://docs.aws.amazon.com/eks/latest/best-practices/prefix-mode-linux.html).

In our tests, the following configurations provide the fastest EC2 startup speed, with the trade-off of reduced pod density flexibility:

- `MINIMUM_IP_TARGET=29` (Max EBS volumes per node is usually 27)
- `WARM_IP_TARGET=3`
- `ENABLE_IP_COOLDOWN_COUNTING=false`
- `WARM_ENI_TARGET=0`
- `WARM_PREFIX_TARGET=1` (value can't be 0, but can be overridden by WARM_IP_TARGET > 0)

**Why these settings:**
- **MINIMUM_IP_TARGET=29:** Pre-warms IPs to match known pod density ( max 27 executors + driver + system pods)
- **WARM_IP_TARGET=3:**  Pre-allocate 32 IPs in total (16 IPS per prefix) while keeping a small buffer of IPs ready without excessive waste.
- **WARM_ENI_TARGET=0:** Disables ENI pre-warming; relies on prefix delegation instead
- **WARM_PREFIX_TARGET=1:** Maintains one prefix (/28 = 16 IPs) ready for fast pod scheduling

**Additional networking best practices:**
- **Enable prefix delegation:** Use `ENABLE_PREFIX_DELEGATION=true` for better IP efficiency & pod density (16 IPs per prefix)
- **Use security groups for pods:** Enable `ENABLE_POD_ENI=true` for pod-level security groups when needed
- **Monitor CNI metrics:** Watch `awscni_assigned_ip_addresses` and `awscni_total_ip_addresses` to track IP utilization
- **Plan for AZ failure:** Ensure each AZ has sufficient IP capacity to handle failover scenarios
- **Avoid IPv4 exhaustion:** Consider dual-stack (IPv4 + IPv6) for future-proofing large clusters

**Common pitfalls to avoid:**
- Setting `WARM_IP_TARGET` too high wastes IPs
- Setting `MINIMUM_IP_TARGET` too low causes pod startup delays
- Forgetting to increase QPS and burst settings after API limit were lifted.
- Not monitoring CNI logs for IP allocation errors

[^ back to top](#table-of-contents)

## Monitoring

We have built insightful monitoring dashboards for the load test, with [Amazon Managed Prometheus](https://aws.amazon.com/prometheus/) and [Amazon Managed Grafana](https://aws.amazon.com/grafana/) set up in `infra-provision.sh` by default.

<table align="center">
  <tr>
    <td>
      <img src="grafana/images/spark-operator-dashboard.png" width="600"/>
      <p align="center">Spark Operator Dashboard</p>
    </td>
    <td>
      <img src="grafana/images/emr-on-eks-dashboard.png" width="600"/>
      <p align="center">EMR on EKS Dashboard</p>
    </td>
  </tr>
  <tr>
    <td>
      <img src="grafana/images/eks-control-plane.png" width="600"/>
      <p align="center">EKS Control Plane</p>
    </td>
    <td>
      <img src="grafana/images/aws-cni-metrics.png" width="600"/>
      <p align="center">AWS CNI Metrics</p>
    </td>
  </tr>
</table>

### 1. Observe Load Testing with Amazon Managed Prometheus and Amazon Managed Grafana

#### 1.1 Set up AMP & AMG
Please be aware that `./infra-provision.sh` includes Amazon Managed Prometheus setup by default. Please follow the guidance below to set up Amazon Managed Grafana:
<details>
<summary>Steps to install Amazon Managed Grafana</summary>

- In `./env.sh`, keep the default value as shown below, which creates an AMG workspace automatically:
```bash
export USE_AMG="true"
```
If you do not have IAM Identity Center (IDC) enabled in your test region and AWS account, follow the instructions [here](https://docs.aws.amazon.com/databrew/latest/dg/sso-setup.html) to create one.

- Set up access for Amazon Grafana:
    - Access the AWS console → search "Amazon Grafana" → click the three-line icon at the top left of the page → choose "All workspaces"
    - Click on the workspace name, which matches the `CLUSTER_NAME` value
    - From the Authentication tab → click "Assign new user or group"
    - Select your account → click "Assign Users and groups"
    - Select your account again → click "Action" → "Make admin"
    - Finally, find the "Grafana workspace URL" from the workspace detail page → click on the URL

- Sign in to the Grafana UI via IAM Identity Center access
- Set up Amazon Managed Prometheus as a data source:
    - Navigate to Apps → Amazon Data Sources → `Amazon Managed Service for Prometheus`
    - Select the `region` aligned with your load test region, e.g., `us-west-2`
    - Select the region then click "Add data source"
    - Click `Go to Settings`, scroll down to the bottom and click `Save & test` to verify the connection

- Import pre-built Grafana dashboard templates:
    - Navigate to the `Dashboards` side menu, hit the "New" button → choose `Import` from the dropdown list
    - You can either use "file upload" or "Copy & Paste" approaches to import the raw content of `./grafana/dashboard-template/spark-operator-dashboard.json`, then click `Load`
    - Select your data source, which aligns with the AMP connection set up previously, e.g., `Prometheus ws-xxxx.....`
    - Repeat the above steps to import the rest of the templates under the directory: `./grafana/dashboard-template/`

Please be aware that the following charts are not working by default, which is expected because `kubelet` generates a large volume of metrics and will significantly boost Prometheus memory usage:
- Prometheus Kubelet Metrics Series Count
- Spark Operator Pod CPU Core Usage

If you want to enable them, update `./resources/monitor/prometheus-values.yaml` as follows:
```yaml
kubelet:
  enabled: true
```

</details>

[^ back to top](#table-of-contents)

### 2. Metrics & Evaluation

Please refer to the [Grafana README](./grafana/README.md) document for detailed explanations on how to monitor and evaluate your performance in Locust, Spark Operator, EKS cluster, IP utilization, etc.

## Clean up
```bash
# To remove the resources created by ./infra-provision.sh
bash ./clean-up.sh 
```

[^ back to top](#table-of-contents)

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
