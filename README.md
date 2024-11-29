## EMR Spark Operator on EKS Benchmark Utility

This repository provides a general tool to benchmark EMR Spark Operator & EKS performance. This is an out-of-the-box tool, with both EKS cluster and load testing job generator (Locust). You will have zero or minimal setup overhead for the EKS cluster.

Enjoy! ^.^
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


## Set up Test Environment
### 1. Create the EKS Cluster with Necessary Services 
This script creates a new EKS cluster with [Auto Scaler](https://aws.github.io/aws-emr-containers-best-practices/troubleshooting/docs/eks-cluster-auto-scaler/), [Karpenter](https://aws.github.io/aws-emr-containers-best-practices/troubleshooting/docs/karpenter/), and [BinPacking](https://awslabs.github.io/data-on-eks/docs/resources/binpacking-custom-scheduler-eks) enabled. The monitoring tool by default uses [Amazon Managed Prometheus](https://aws.amazon.com/prometheus/) and [Amazon Managed Grafana](https://aws.amazon.com/grafana/).

#### 1.1 Update the Environment Variables
Please update the values in `./env.sh` or use the default configurations as shown below:



<details>
<summary>Default Environment Variables</summary>

```bash
# General Configuration
export LOAD_TEST_PREFIX=eks-operator-test
export AWS_REGION=us-west-2
export ECR_REGISTRY_ACCOUNT=895885662937
export EKS_VPC_CIDR=172.16.0.0/16

# Note: For ECR_REGISTRY_ACCOUNT in different regions, please refer to:
# https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/docker-custom-images-tag.html

# AWS Resource Identifiers
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER_NAME=${LOAD_TEST_PREFIX}-eks-cluster
export BUCKET_NAME=${LOAD_TEST_PREFIX}-bucket-01  

# Spark Operator Configuration
# Test Mode Options:
# - "multiple": Creates multiple operators (one per job namespace)
# - "single": Creates one operator monitoring all job namespaces
#
# Examples:
# 1. multiple mode (for example, OPERATOR_TEST_MODE="multiple" && SPARK_JOB_NS_NUM=2):
#    - Creates 2 job namespaces and 2 operators
#    - spark-operator0 monitors spark-job0
#    - spark-operator1 monitors spark-job1
#
# 2. single mode (for example, OPERATOR_TEST_MODE="single" && SPARK_JOB_NS_NUM=2):
#    - Creates 2 job namespaces but only 1 operator
#    - spark-operator0 monitors both spark-job0 and spark-job1

export OPERATOR_TEST_MODE="multiple"
export SPARK_JOB_NS_NUM=2
export SPARK_OPERATOR_VERSION=6.11.0
export EMR_IMAGE_VERSION=6.11.0
export EMR_IMAGE_URL="${ECR_REGISTRY_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/spark/emr-${EMR_IMAGE_VERSION}:latest"

# IAM Roles and Policies
export SPARK_OPERATOR_ROLE=${LOAD_TEST_PREFIX}-SparkJobS3AccessRole
export SPARK_OPERATOR_POLICY=${LOAD_TEST_PREFIX}-SparkJobS3AccessPolicy

# Prometheus Configuration
export AMP_SERVICE_ACCOUNT_INGEST_NAME=amp-iamproxy-ingest-service-account
export AMP_SERVICE_ACCOUNT_IAM_INGEST_ROLE=${LOAD_TEST_PREFIX}-prometheus-ingest
export AMP_SERVICE_ACCOUNT_IAM_INGEST_POLICY=${LOAD_TEST_PREFIX}-AMPIngestPolicy

# Karpenter Configuration
export KARPENTER_CONTROLLER_ROLE="KarpenterControllerRole-${LOAD_TEST_PREFIX}"
export KARPENTER_CONTROLLER_POLICY="KarpenterControllerPolicy-${LOAD_TEST_PREFIX}"
export KARPENTER_NODE_ROLE="KarpenterNodeRole-${LOAD_TEST_PREFIX}"

# Monitoring Configuration
export USE_AMG="true"  # Enable Amazon Managed Grafana
```

</details>




#### 1.2 To build the infrastructure, please execute the below cmd:
```bash
bash ./infra-provision.sh
```

#### 1.3 Infrastructure Inclusions:

<details>
<summary>Here are the inclusions of the <b>infra-provision.sh</b> script </summary>

- S3 Bucket for storing assets, eg: job script.
- EKS cluster (v 1.30) with following set ups
    - VPC CNI Addon
    - EBS CSI Addon
    - Binpacking Pod Scheduler
    - EKS Cluster Autoscaler
        - Node Group for Operational & Monitoring Purposes
            - labels: 
            - `operational=true`, `monitor=true`
        - Node Group for Spark Operators.
            - labels: 
            - `operational=true`, `monitor=false`
        - Node Groups for Spark Jobs Execution in 2 AZs accordingly:
            - labels: 
            - `operational=false`, `monitor=false`
            - eg: `us-west-2a`, `us-west-2b`
    - Karpenter Scaler
        - NodePool for Spark Driver Pods:
            - labels:
                - `cluster-worker: "true"`
                - `provisioner: "spark-driver-provisioner"`
        - NodePool for Spark Executor Pods:
            - labels:
                - `cluster-worker: "true"`
                - `provisioner: "spark-executor-provisioner"`
        - EC2 Node Class: `spark-worker-nc`
            - Across 2 AZs/Subnets by default.
        - Please modify `./resources/karpenter-nodepool.yaml` to change instance family and sizes, NP and NC Configs.
    - Prometheus on EKS
        - @XI TO DO.
    - Spark Operators & Job Namespaces
        - Number of Spark Operators will be created in `-n spark-operator` by default, eg: `spark-operatpr0`, `spark-operatpr1`, etc.
        - Number of Job Namespaces will be created, eg: `-n spark-job0`, `-n sparkjob1`, etc.
        - Please update the `./env.sh` to configure Spark Operator & job namespace numbers.
- Amazon Managed Prometheus Workspace



</details>


### 2. To use [Locust](https://github.com/locustio/locust) as the testing job producer (Optional)
Locust is a Open source load testing tool based on the Python.

This script creates an EC2 as the load testing client which is using Locust to submit spark testing jobs to EKS cluster. 

#### 2.1 To build the Locust on EC2, please execute the below cmd:


```bash
bash ./locust-provision.sh

## You have to ensure there is EKS cluster created by script above `./infra-provision.sh`and ready to use or modify the script with your own EKS cluster.
```

With this script implementation, you don't need to have extra settings to play around the load testing, but just choose the volume of workload to mimick your real production.

#### 2.2 Locust EC2 Inclusions:

<details>
<summary>Here are the inclusions of the <b>locust-provision.sh</b> script </summary>

- EC2 Instance with Instance Profile
    - A ssh key will be available to use to access the EC2 instance.
    - You should be able to see the below once the script is executed successfully.
    ```
    To connect to the instance use: ssh -i eks-operator-test-locust-key.pem ec2-user@xxx.xxx.xxx.xxx
    ```
    - The security group is attached for "My IP" to access the Instance
    - The security group on EKS cluster is attached to allow 443 access for the instance.
    - Some necessary IAM policies have been attached to the Instance Profile.
- Locust service have been installed
    - The assets under `./locust` will be uploaded to S3 bucket, and then cp to the instance.
        - The `./env.sh` will be copied before uploading to S3, the path in EC2 will be: `./load-test/locust/env.sh`
        - Please see below how to start the Load testing with Locust.

</details>



## Run Load Testing with Locust
### 1. Submit Jobs to Cluster Autoscaler (CAS)

```bash
# SSH to Locust EC2
ssh -i eks-operator-test-locust-key.pem ec2-user@xxx.xxx.xxx.xxx
cd load-test/locust

# -u, how many users are going to submit the testing jobs to eks cluster via spark operator.
#     The default wait interval for each user to submit jobs is between 20 - 30s in this testing tool.
# -t, the time of submitting jobs.
# --job-azs, customized api, let jobs to be submitted into 2 AZs randomly.
# --kube-labels, kubernates labls, matching node groups.
# --job-name, spark job prefix. 
# --job-ns-count, the testing jobs will be submitting to 2 Namespaces, `spark-job0`, `spark-job1`.

locust -f ./locustfile.py -u 2 -t 10m --headless --skip-log-setup \
--job-azs '["us-west-2a", "us-west-2b"]' \
--kube-labels '[{"operational":"false"},{"monitor":"false"}]' \
--job-name cas-job \
--job-ns-count 2

```

### 2. Submit Jobs to Karpenter

```bash
# --karpenter, to enable karpenter, instead of CAS.
# --kube-labels, in Karpenter test case, the labels should match with Noodpool labels.
# --binpacking true, enable binpacking pod scheduler.
# --karpenter_driver_not_evict, enable driver pod not be evicting in Karpenter test case.

locust -f ./locustfile.py -u 2 -t 10m --headless --skip-log-setup \
--job-azs '["us-west-2a", "us-west-2b"]' \
--kube-labels '[{"cluster-worker": "true"}]' \
--job-name karpnter-job \
--job-ns-count 2 \
--karpenter \
--binpacking true \
--karpenter_driver_not_evict true
```


## Clean up
```bash
# To remove the Locust EC2 from infrastructure. You can ignore if you did not execute bash ./locust-provision.sh before.
bash ./locust-provision.sh -action delete

# To remove the resources that created by ./infra-provision.sh.
bash ./clean-up.sh 
```

## Monitoring:

Please aware if the below charts are not working, which is expected, due to the kubelet will generate the large volume of metrics and it will boot prometheus memory usage.
- Prometheus Kublet Metrics Series Count
- Spark Operator Pod CPU Core Usage





## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

