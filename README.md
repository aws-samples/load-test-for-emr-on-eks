## EMR Spark Operator on EKS Benchmark Utility

This repository provides a general tool to benchmark EMR Spark Operator & EKS performance. This is an out-of-the-box tool, with both EKS cluster and load testing job generator (Locust). You will have zero or minimal setup overhead for the EKS cluster.

Enjoy! ^.^

# Table of Contents
- [Prerequisite](#prerequisite)
- [Set up Test Environment](#set-up-test-environment)
  - [Prerequisite](#prerequisite---set-environment-variables)
  - [Create the EKS Cluster with Necessary Components(Optional)](#create-an-eks-cluster-with-components-needed-optional)
  - [Install Locust Operator on EKS](#install-locust-operator-on-eks)
- [Get Started](#get-started-with-load-test)
  - [Prerequisite](#prerequisite---update-job-script)
  - [Run test from local](#1-fire-up-load-test-locally)
  - [Run test on EKS](#1-load-test-via-locust-operator-on-eks)
- [Best Practice Guide](#best-practices-learned-from-load-test)
  - [How to Allocate Pods](#1-how-to-allocate-spark-driver--executor-pods)
  - [DONOT Use Sidecars Whenever Possible](#2-try-not-to-use-initcontainersor-custom-sidecar)
  - [Binpacking pods](#3-binpacking-application-pods)
  - [Cluster Scalability](#4-cluster-scalability)
  - [Networking in EKS](#5-best-practices-for-networking)
- [Monitoring](#monitoring)
- [Clean up](#clean-up)

## Prerequisite
- eksctl is installed in latest version ( >= 0.194.)
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
- Install kubectl on macOS, check out the [link](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) for Linux or Windows.( >= 1.31.2 )
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --short --client
```
- Helm CLI ( >= 3.13.2 )
```bash
curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
helm version --short
```

[^ back to top](#table-of-contents)

## Set up Test Environment

### Prerequisite - Set Environment Variables
Please update the values in `./env.sh` based on your environment settings.
Alternatively, use the default configurations shown as below:

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
# If skip the infra setup step, remove this unnecessary section
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

### Create an EKS Cluster with components needed (OPTIONAL)
A `infra-provision.sh` script is provided by the project, which creates a brand new EKS cluster with the following components. 

Skip this step if you use an existing EKS cluster. If required, install missing components individually, such as EBS CSI Driver, based on the infra provision script. 

- [Auto Scaler](https://aws.github.io/aws-emr-containers-best-practices/troubleshooting/docs/eks-cluster-auto-scaler/)
- [Load Balancer Controler](https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html)
- [EBS CSI Driver Addon](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
- [Karpenter](https://aws.github.io/aws-emr-containers-best-practices/troubleshooting/docs/karpenter/)
- [BinPacking](https://awslabs.github.io/data-on-eks/docs/resources/binpacking-custom-scheduler-eks) 

Monitoring by default uses managed services:
- [Amazon Managed Prometheus](https://aws.amazon.com/prometheus/)
- [Amazon Managed Grafana](https://aws.amazon.com/grafana/)

[^ back to top](#table-of-contents)


#### 1. Modify EKS cluster and components' configurations before provisioning the environemnt
- For eks cluster, update [./resources/eks-cluster-values.yaml](./resources/eks-cluster-values.yaml)
- For autoscaler, modify [./resources/autoscaler-values.yaml](./resources/autoscaler-values.yaml)
- For custom k8s scheduler, update [./resources/binpacking-values.yaml](./resources/binpacking-values.yaml)
- For Karpenter, update yaml files under the [./resources/karpenter/](./resources/karpenter/)
- For Prometheus, update [./resources/prometheus-values.yaml](./resources/prometheus-values.yaml)
- For Prometheus's podmonitor and servicemonitor settings, update files under the [./resources/monitor](./resources/monitor)

#### 2. Run the script after all the customizations are done.
NOTE: at the end of script, 2 ECR container images will be built and pushed : Spark benchmark and Locust.
```bash
bash ./infra-provision.sh
```

### Install Locust Operator on EKS
[Locust](https://docs.locust.io/en/stable/locust-cloud/locust-cloud.html#kubernetes-operator) is an open source load testing tool based on Python. 

This project offers a provison scirpt `locust-provision.sh` to setup a Locust k8s Operator via a helm chart. Before run the scirpt, modify the [operator's RBAC permission](./locust/locust-operator/patch-role-binding.yaml) and [IRSA role policy](./locust/locust-operator/eks-role-policy.json) based on your requirement.
```bash
# create IRSA role and install locust operator
bash ./locust-provision.sh
```
[^ back to top](#table-of-contents)

## Get Started with Load Test

 To get an optimal load test outcome, you can configure your compute resource allocation via Spark settings. See the best practice section: [How to Allocate Pods](#1-how-to-allocate-spark-driver--executor-pods).

### Prerequisite - Update job script
This project supports most of EMR on EKS load test cases with a defualt monitoring configuration, ie. AWS Managed Promethues + Managed Grafana. Before getting started, replace the sample job run file [./locust/locustfiles/emr-job-run.sh](./locust/locustfiles/emr-job-run.sh) by your actual EMR on EKS job submission script. It then will be mapped into each Locust containers's home directory `/home/locust` via a configmap called `emr-loadtest-locustfile`. More detials can be found in the [locust-provision.sh](https://github.com/aws-samples/load-test-for-emr-on-eks/blob/b389458ff4ebb1b829f6fd9c8aa49405c482bfc9/locust-provision.sh#L124) script. The setup looks like this:
```bash
kubectl create configmap emr-loadtest-locustfile --namespace locust --from-file=locust/locustfiles
```

### 1. Fire up Load Test locally
Let's run a small test from a local terminal window. The following parameters are avaiable to adjust before run the locust CLI:
```bash
# -u or --users, How many users are going to submit the jobs concurrently.
#     Used a default wait interval (between 20s-30s per user) before submit the next job. 
# -t or --run-time, The total load test period.
# --emr-script-path, Set by env.sh. Load test job's shell script name. 
# --job-azs, Default: None. a list of AZs available in the EKS's VPC. It means pods in a single job will be scheduled to multiple AZs which could cause data transfer fee and performance downgrade. If it's set (see below), all pods of a job will be scheduled to a single AZ. NOTE: The AZ selection is random not round robin.
# --job-ns-count, Default: 2 namespaces. Total number of namespaces/VCs that jobs will be submitting to.

cd load-test-for-emr-on-eks/locust
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
source ../env.sh

locust -f ./locustfiles/locustfile.py --run-time=10m --users=20 \
--job-azs '["us-west-2a", "us-west-2b"]' \
--job-ns-count 1
```

After each load test session is finished or in progress, you can forcefuly cancel jobs and delete EMR-on-EKS virtual clusters, excluding namespaces:
```bash
# clean up script for EMR-EKS's Virtual Clsuters and jobs created by Locust:
# --id, remove a test by its session/instance ID
# --cluster, remove all tests by the eks cluster name
python3 stop_test.py --cluster $CLUSTER_NAME  
```
**WARNING:** `Locust creates a new namespace/VC at each initalization time. To re-used a namespace from a previous test session, the old VC created by the previously tests must be terminated first. Either manually or via the above python script.`


[^ back to top](#table-of-contents)

### 2. Load Test on EKS
Locust Operator supports a distributed way of load test. By default, it fires up load testing from a cluster of 1 master+ 2workers pods. Each of which initlizes a test session with a unique session ID.

Update the locust test CRD manifest file by actual environment attributes, then start the load test from an EKS cluster:
```bash
 kubectl apply -f examples/load-test-pvc-reuse.yaml
```

```bash
# check load test status
kubectl logs -f -n locust -l locust.cloud/component=master
# access to Locust WebUI: http://localhost:8089/
kubectl port-forward svc/pvc-reuse-load-test-cluster-10-webui -n locust 8089:8089
```

[^ back to top](#table-of-contents)

## Best Practices Learned from Load Test

### 1. How to Allocate Spark Driver & Executor Pods
To minimise the cross-node DataIO and networkIO penalty in a single Spark job, it is recommended trying to allocate the Spark executor pods into the same node as much as possible.

However, to reduce the compute cost, executor's node pool has aggressive node consolidation rule. To remove the eviction impact on Driver pod, we run it in a seperate node pool in Karpenter.

Additionally, to avoid the cross-AZ data transfer fee, utilize the `spark.kubernetes.node.selector.topology.kubernetes.io/zone` config to tight all pods within a Spark job to a specified single AZ. If your managed node group or Karpenter nodepool is configured as a single-AZ node provisoners, you can simply use a nodegroup/nodepool name as the nodeSelector to ensure your job's pods are in a single AZ.

```yaml
# nodeSelector sample as below:
"spark.kubernetes.node.selector.topology.kubernetes.io/zone": "us-west-2a"

# Or match by a kapenter nodepool name
"spark.kubernetes.node.selector.karpenter.sh/nodepool": "single-az-nodepool"

# Or match by a nodegroup name managed by cluster autoscaler
"spark.kubernetes.driver.node.selector.eks.amazonaws.com/nodegroup": "m5-ng-uw2a",
```
[^ back to top](#table-of-contents)

### 2. TRY NOT to Use `initContainers`or Custom Sidecar.
k8s events in EKS emitted by a Spark job increased significantly, as soon as we enable the `initContainers`. As a result, EKS API Server and ETCD DB size will be filled up quicker than normal. It is recommended to avoid the `initContainers` or any sidecars in a large scale workload on an EKS cluster. Otherwise, try to split your workload to multiple EKS clusters.

### 3. Binpacking Application Pods

There are two types of binpackings:
- Custom k8s scheduler - binpack pods at job launch time
- Karpenter's consolidation feature - binpack pods or replace underutilized nodes at job run time

**Binpack at Launch Time** - a custom k8s scheduler can efficiently assign pods to the least allocated nodes before a new node is requested. The goal is to optimize resource utilization by packing pods as tightly as possible onto a single node, while still meeting resource requirements and constraints. 

This approach aims to maximize cluster efficiency, reduce costs, and improve overall Spark job's shuffle IO performance by minimizing the number of active nodes required to run the workload. Becuase with Binpacking enabled, workloads can minimise the resources used on network traffic between physical nodes, as most of pods will be allocated in a single node at its launch time. The Spark configuration at job submission looks like this:
```bash
  "spark.kubernetes.scheduler.name": "custom-scheduler-eks"
```

**Binpack at Run Time** - the launch-time binpacking doesn't solve the resources wastage or cost spike caused by frequent pod terminations, such as by Spark's Dynamic Resource Allocation (DRA). That's why another binpack feature needs to co-exist in our use case, ie. enable Karpenter's consolidation feature for ( only for) executor's nodepool, in order to maximize pods density at job's run time.

Learn more about Binpacking via link: https://aws.github.io/aws-emr-containers-best-practices/performance/docs/binpack/

[^ back to top](#table-of-contents)


### 4. Cluster Scalability

EKS Cluster autoscaling contains two main types:
  - [EKS Cluster Autoscaler (CAS)](https://docs.aws.amazon.com/eks/latest/best-practices/cas.html)
  - [Karpenter (default)](https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html)

**EKS Cluster Autoscaler (CAS)** - This project's EKS cluster is configured with three managed node groups: 
- 1/ Operational CAS for operational services ( fixed size: 2 nodes). It is used to host Prometheus, Load Balancer, Karpenter etc. operational pods
- 2/ Two Application managed nodegroups ( one per AZ) to scale between 1 and 350 m5.xlarge EC2 nodes for load test jobs.

To schedule a large volume of nodes, the qps and burst rate in the [CAS configuration](./resources/autoscaler-values.yaml) needs to increase, to avoid its throttling:
```yaml
podAnnotations:
  cluster-autoscaler.kubernetes.io/safe-to-evict: 'false'
...
extraArgs:
...
  kube-client-qps: 300
  kube-client-burst: 400
```

**Karpenter** - In this project, we only provision load test jobs by Karpenter, the rest of operational pods, eg: Prometheus, Karpenter, Binpacking etc. are still scheduled in the fix-sized opertional NodeGroup, which is out of controll by Karpenter.

- Karpenter Nodepool configs
    - To align with NodeGroup's configs by CAS, we can utilize the `topology.kubernetes.io/zone` when submitting karpenter spark jobs, to ensure all pods in a single job will be allocated into the same AZ.

```bash
  "spark.kubernetes.executor.node.selector.karpenter.sh/nodepool": "executor-nodepool",
  "spark.kubernetes.driver.node.selector.karpenter.sh/nodepool": "driver-nodepool",
  "spark.kubernetes.node.selector.topology.kubernetes.io/zone": "ua-west-2a",
```

[^ back to top](#table-of-contents)

### 5. Best Practices for Networking
With large volume of workloads, IP addresses often exhaustes. To solve this, we have some tips to address the network problem:
- Use `AWS VPC CNI` - to set up a 2nd or more CIDRs for your EKS cluster, instead of utilizing the primary subnet. Please learn more about this technique here: https://aws.github.io/aws-eks-best-practices/networking/custom-networking/
- To minimise IP wastage per existing subnet, you should try to fine tune the following VPC CNI configs: 
    - `WARM_ENI_TARGET`, `MAX_ENI`
    - `WARM_IP_TARGET`, `MINIMUM_IP_TARGET`
More details can be found: https://aws.github.io/aws-eks-best-practices/networking/vpc-cni/
https://docs.aws.amazon.com/eks/latest/best-practices/networking.html

[^ back to top](#table-of-contents)

## Monitoring:

We have built monitoring solution for this architecture, with [Amazon Managed Prometheus](https://aws.amazon.com/prometheus/) and [Amazon Managed Grafana](https://aws.amazon.com/grafana/) included by default.

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

### 1. Monitor Load Testing with Amazon Managed Prometheus and Amazon Managed Grafana

#### 1.1 Set up AMP & AMG follow based on this git repo
Please aware, `./infra-provision.sh` has included prometheus on eks and also Amazon Managed Prometheus by default. Thus, please just follow the below guidence to set up Amazon Managed Grafana:
<details>
<summary>Here are the steps to use Amazon Managed Grafana </summary>

- From `./env.sh`, keep default value as below, then the script will create AMG workspace automatically:
```bash
export USE_AMG="true"
```
If you do not have the IAM Identity Center / useage account enabled, then please follow: https://docs.aws.amazon.com/databrew/latest/dg/sso-setup.html

- Set up the access for Amazon Grafana:
    - Access to aws console -> search "Amazon Grafana" -> click the three lines icon at top left of the page -> click "All workspaces";
    - click the workspace name, which is the same value of the `LOAD_TEST_PREFIX` value;
    - From Authentication tab -> click "Assign new user or group";
    - Select your account -> click "Assign Users and groups";
    - Select your account again -> click "Action" -> "Make admin";
    - To find the "Grafana workspace URL" from the workspace detail page -> access to the URL.

- Sign in via IAM Identity Center access;
- Set up Amazon Managed Prometheus Datasource via:
    - Click Apps -> AWS Data Source -> Click `Amazon Managed Service for Prometheus`;
    - Select `region` align with your eks cluster, eg: `us-west-2`;
    - Select the Region and Click Add data source.
    - Click `Go to Settings`, scroll down to the bottom and click `Save & test` to verify the connection.

- Set up Grafana Dashboard:
    - Client the "+" icon from top right of the page after signed in -> click "Import dashboard";
    - You can either use `Upload` or `Copy & Paste` the value of `./grafana/dashboard-template/spark-operator-dashbord.json` and then click "Load";
    - Select the data source, which align with the AMP connection that sets up above, eg: `Prometheus ws-xxxx.....`
    - You may repeat above step to import more templates from `./grafana/dashboard-template/`;


Please aware if the below charts are not working, which is expected due to the `kubelet` will generate the large volume of metrics and it will boost prometheus memory usage.
- Prometheus Kubelet Metrics Series Count
- Spark Operator Pod CPU Core Usage

If you want to enable them, then please update `./resources/prometheus-values.yaml` as below:
```yaml
kubelet:
  enabled: true
```

</details>

[^ back to top](#table-of-contents)


### 2. Metrics & Evaluation

Please refer to the [Grafana README](./grafana/README.md) document for detailed explanation, how to monitor and evaluate your performance in Locust, Spark Operator, EKS cluster, IP utilization, etc.

## Clean up
```bash
# To remove the resources that created by ./infra-provision.sh.
bash ./clean-up.sh 
```

[^ back to top](#table-of-contents)


## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

