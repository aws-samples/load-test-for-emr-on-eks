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

#### 1.2 To modify the EKS cluster yaml file for Cluster / NodeGroups:
- For eks cluster & NodeGroups, please update `./resources/eks-cluster-values.yaml`
- For Karpenter NodePools, please update `./resources/karpenter-nodepool.yaml`
- If you wants to modify the default of the templates, please update `./resources/template-backups/` accordingly, these templates/yaml files will be restoring during `./clean-up.sh` execution.


#### 1.3 To build the infrastructure, please execute the below cmd:
```bash
bash ./infra-provision.sh
```

#### 1.4 Infrastructure Inclusions:

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
# --kube-labels, kubernetes labls, matching node groups.
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
# --kube-labels, in Karpenter test case, the labels should match with NodePool labels.
# --binpacking true, enable binpacking pod scheduler.
# --karpenter_driver_not_evict, enable driver pod not be evicting in Karpenter test case.

locust -f ./locustfile.py -u 2 -t 10m --headless --skip-log-setup \
--job-azs '["us-west-2a", "us-west-2b"]' \
--kube-labels '[{"cluster-worker": "true"}]' \
--job-name karpenter-job \
--job-ns-count 2 \
--karpenter \
--binpacking true \
--karpenter_driver_not_evict true
```

## Best Practice Guide

### 1. Spark Operator

#### 1.1 Spark Operator Numbers
For the single spark operator, the max performance for submission rate would be around 30 jobs per min (`SparkOperator version: emr-6.11.0 (v1beta2-1.3.8-3.1.1)`), and the performance tune on a single operator is very limited in the current version. 
- To handle the large volume of workload, to horizontally scale up by using multiple Spark Operator would be the recommended solution. 
- The operators will be not impacted from each other on eks cluster side, but higher number of operators will increase the overhead on apiserver/etcd side.

#### 1.2 Isolation of Spark Operators
For Spark Operator(s), to minimise the performance impacts caused by other services, eg.: spark job pods, prometheus pods, etc, it is recommended to allocate the Spark Operator(s), Prometheus operators in the dedicated operational node groups accordingly.
<details>
<summary> Spark Operator Best Practice </summary>

- To use `podAntiAffinity` to ensure ***One-Node-One-Operator*** pattern
```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchExpressions:
        - key: app.kubernetes.io/name
          operator: Exists
      topologyKey: "kubernetes.io/hostname"
```
- Increase `controllerThreads`
The default number of spark operator workers(controllerThreads) is `10`, to increase it to get a better performance for job submission. 
    - However, as the qps and bucket size is hardcoded in SparkOperator V1, thus, increase this to very large number, eg: 100, may `NOT` benefit from it as expected.
    - In addition, it would be vary in the different spark job submission object size. As large object size of each job will take more space in the bucket of operator internally.

</details>

### 2. Spark Job Configuration
#### 2.1 Allocate the Spark Job Pods (Driver & Executors) into the Node
To minimise the cross node overhead for a single spark job, it is recommended trying to allocate the spark job pods into the same node as much as possible.

- Similar as operational pods, when using CAS as node scaler solution:
    - utilizing `nodeSelector` with `kubernetes label` feature on the spark job yaml file, to ensure the spark job pods will be allocated to the same worker NodeGroup:
    - As an alternative, to utilize the `topology.kubernetes.io/zone` tag, to ensure all pods of a single job will be allocated into the same AZ, it depends on your NodeGroup Settings.
```yaml
# nodeSelector sample as below:
    driver:
      nodeSelector:
      cluster-worker: "true" 
# This label needs to match with EKS nodegroup kubernetes label or kapenter nodepool

    executor:
      nodeSelector:
      cluster-worker: "true" 
# This label needs to match with EKS nodegroup kubernetes label or kapenter nodepool
```


- To utilize `Binpacking` while submitting a Spark Job, please see details at below - `3. Binpacking`

- Try to NOT use `initContainers`.
we have found, with `initContainers` enabled, the events of a single spark job increased significantly. As a result, the eks api server and etcd DB size will be filling up faster than disabling the `initContainers`. Thus, try to avoid to use with large scale workload in a single EKS cluster, or split the jobs into multiple eks cluster.

### 3. Binpacking

Binpacking could efficiently allocate pods to available nodes within a Kubernetes cluster. Its primary goal is to optimize resource utilization by packing pods as tightly as possible onto nodes, while still meeting resource requirements and constraints. 
- This approach aims to maximize cluster efficiency, reduce costs, and improve overall performance by minimizing the number of active nodes required to run the workload. 
- With Binpacking enabled, the overall workload can minimise the resources used on network traffic between physical nodes, as most of pods will be allocated in a single node at its launch time. 
- However, we use Karpenter's consolidation feature to maximize pods density when node's utilization starts to drop.
- Please learn more about Binpacking via link: https://awslabs.github.io/data-on-eks/docs/resources/binpacking-custom-scheduler-eks



### 4. Cluster Scalability
#### 4.1 EKS Cluster Autoscaler (CAS)
- To utilize the Kubernetes Labels for operational services with CAS:
    -  With `podAntiAffinity` enabled followed by `2.1 Allocate the Spark Job Pods (Driver & Executors) into the Node` above, and enable CAS for Operational service, eg: Spark Operators, to scale up and down the Spark Operator Node by CAS automatically.
- To schedule the large volume of pods, need to increase the qps and burst for `NodeScaler`, to avoid CAS self throttling issue:
```yaml
nodeSelector:
 ## Kubernetes label for pod allocation.
podAnnotations:
  cluster-autoscaler.kubernetes.io/safe-to-evict: 'false'
...
extraArgs:
...
  kube-client-qps: 300
  kube-client-burst: 400
```

#### 4.2 Karpenter Scaler:

- To allocate the operational pods, e.g.: Spark Operator, Prometheus, Karpenter, Binpacking, etc in the Operational EKS NodeGroup, which are NOT controlled by Karpenter via setting up nodeSelector on the operational pods, please see details explained in `4.1 EKS Cluster Autoscaler (CAS)`
- Karpenter Nodepool configs:
    - Utilize the provisioner label to separate the spark driver pods and spark executor pods. As the driver pods will be creating earlier than executor pods, and then each driver pod will create 10 executors, which can improve the pending pods in short period of time.
    - To align with NodeGroup on CAS, and also minimise the networking level noise, to utilize the `topology.kubernetes.io/zone` when submitting karpenter spark jobs, to ensure all pods of a single job will be allocated into the same AZ.
```yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: spark-driver-provisioner
spec:
  template:
    metadata:
      labels:
        cluster-worker: "true"
        provisioner: "spark-driver-provisioner"
    spec:
      requirements:
...
        - key: "topology.kubernetes.io/zone"
          operator: In
          values: ["${AWS_REGION}a", "${AWS_REGION}b"]
```

### 5 Best Practices for Networking
With large volume of workload, if the IP addresses of the eks cluster resided subnets may be exhausted. To solve this here are tips to address this issue:
- To use AWS VPC CNI, to set up the 2nd or more CIDRs for your eks cluster, instead of utilizing the primary subnet. Please learn more about this via: https://aws.github.io/aws-eks-best-practices/networking/custom-networking/
- To minimise IP wastage on the existing subnets, you may try to fine tune the below set up: 
    - `WARM_ENI_TARGET`, `MAX_ENI`
    - `WARM_IP_TARGET`, `MINIMUM_IP_TARGET`
    - Please learn more details from here: https://aws.github.io/aws-eks-best-practices/networking/vpc-cni/
https://docs.aws.amazon.com/eks/latest/best-practices/networking.html


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

### 1. To use Amazon Managed Prometheus and Amazon Managed Grafana, please follow the below links:
Please aware, `./infra-provision.sh` has involved prometheus on eks and also Amazon Managed Prometheus by default. Thus, please just follow the below guidence to set up Amazon Managed Grafana:
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
    - You can either use `Upload` or `Copy & Paste` the value of `./grafana/grafana-dashboard-template.json` and then click "Load";
    - Select the data source, which align with the AMP connection that sets up above, eg: `Prometheus ws-xxxx.....`

Please aware if the below charts are not working, which is expected, due to the kubelet will generate the large volume of metrics and it will boot prometheus memory usage.
- Prometheus Kubelet Metrics Series Count
- Spark Operator Pod CPU Core Usage

If you want to enable them, then please update `./resources/prometheus-values.yaml` as below:
```yaml
kubelet:
  enabled: true
```

</details>

### 2. To use our pre-defined Grafana Temaplate


We have set up a comprehensive dashboard to monitor how is the load testing running, and here are the major metrics we are using to monitor the load testing.



<details>
<summary> Partial explanation for `grafana-dashboard-template.json` </summary>

- CNI(1 panel)

    To monitor the IP address usage.
    - If the `Not assigned IP` is large, which mean the eks has large number of wasted IP addresses.
 
- Prometheus Stats(6 panels)

    To monitor promtheus itself, ensuring promtheus on eks is running well. 
 
- Spark Job Status on EKS(6 panels)
    
    The overall spark job running statistics on the eks cluster. 
    - `Total Running Spark Pods & Driver Exec Ratio`: For a spark job eg, with 1 driver & 10 executors, to ensure overall jobs are running in a healthy status, can monitor this ratio. Due to spark has default `0.8` of `spark.scheduler.minRegisteredResourcesRatio`, so the graph should over `8`.
 
- Spark Operator Workqueue(7 panels)

    - `spark_application_controller_adds enqueue`, which counts one minute rate (per second) of number items added to workqueuec (each spark operator is in a dedicated namespace).
    - `spark_application_controller_work_duration_count dequeue`, which calculates one minute rate (per second) of number items removed from workqueue grouped by namespace.
    - `Spark Application Controller Latency`, which calculates average time from an item is added to the workqueue to the time when the item is fetched from workqueue by spark operator worker, which means it measures how much time an item has to stay on the queue before it is fetched.
    - `Spark Application Controller Task Process Time`, when a worker fetch an item from the workqueue, it will spend sometime processing the item then import workqueue the process is finished. This metrics measures the average time taken from the item is feched from the queue to the time when the item finished processing.  
    - `Spark Application Controller Queue Depth`, which is monitoring the spark operator workqueue depth.

- Spark Application apiserver(2 panels)

    - `apiserver_request_total`, which measures rate of apiserver request on resource sparkapplication. Since spark operator responsible for updating sparkapplication CRD status. This metrics can also tell us how fast or how senstive spark operator reacts to workqueue input. 
 
- Spark Application Status at Locust Client(5 panels)

    Spark Application Status at Locust Client, the load test uses a locust client running on an ec2 instance to create sparkapplication to EKS. From the same locust client, a seperated thread runs every 30 seconds to get a list of all sparkapplication and count their status at the given point of time.
    - `New(not yet submitted)`, which metrics counts number of sparkapplications that are created by not yet submitted at the given point of time.
    - `SUBMITTED`, which counts number of submitted sparkapplication but not running yet at the given point of time.
    - `Running`, which counts the number of sparkappication in RUNNING state at the given point of time.
    - `SUCCEEDING`, which counts the number of sparkapplication in SUCCEEDING state.
    - `COMPLETED`, which counts number of spark application in COMPLETED state at the given point of time.
 
- Locust metrics - Client(6 panels)
    These metrics generated from locust client. It counts number of successful submitted jobs, failed submitted job, average job submit time, measured from client side. This tells job submission stats from user perspective.
    ```python
    try:
            submit_job()
            success_counter.inc()
            execution_time_gauge.set(time.time() - start_time)
        except client.exceptions.ApiException as e:
            failed_counter.inc()
    ```
    - `Locust Submit (success) rate 1m`, which counts number of success job submits for 1 minute.
    - `Locust Submit Job Total`, which counts total successfull submitted job.
    - `Locust Submit (fail) Rate`, which counts number of failed job submits for 1 minute.
    - `Locust Submit Job Fail Total`, which counts number of failed job submits in total.
    - `Locust Submit Job Time`, which measures time used to submit a sparkapplication job.
    - `Locust User Count`, which counts number of locust users.

 
- Spark Operator Metrics - Server(15 panels)
    This group of metrics shows spark operator internal metrics provided from https://github.com/kubeflow/spark-operator/blob/v1beta2-1.3.8-3.1.1/pkg/controller/sparkapplication/sparkapp_metrics.go.
    - `Failed Spark Job Per minutes`: This metric meassures number of failed spark application increased per minutes.
    - `Failed Spark Job Total`: This metric measture total number of failed spark job deteced by spark operator.
    - `Average Job Failure Runtime`: This metric measures how long a failed sparkappliction runs.
    - `Success Spark Application Per Minute`: This metrics meastures average number of success spark application per minute, grouped by namespace, and sum.
    - `Success Spark Application Total`: This metric meastures total number of success spark application.
    - `Average Sucess Job Run Time`: This metric measures average run time of success spark application
    - `Spark Application Count Incrase Per minute`: This metric number of newly created spark application detected by spark operator, grouped by namespace and sum
    - `Spark Application Count Total`: This metrics total created spark application detected by spark operator, grouped by namespace and sum.
    - `Submitted Spark Application Per Minutes`: This metric counts number of submitted spark application per minutes, grouped by namespace and sum. This is a counter and increased when spark application enters Submitted state https://github.com/kubeflow/spark-operator/blob/c261df66a00635509f7d8cb2a7fba4c602c9228e/pkg/controller/sparkapplication/sparkapp_metrics.go#L204
    - `Submitted Spark Application Total`: This metric counts total number of submitted spark application, grouped by namespace and sum.
    - `Running Spark Application Count`: Metrics is based on spark_app_running_count. spark_app_running_count is a counter, this counter is increased by 1 when a spark job enters Running state https://github.com/kubeflow/spark-operator/blob/c261df66a00635509f7d8cb2a7fba4c602c9228e/pkg/controller/sparkapplication/sparkapp_metrics.go#L210, and decrease when a spark application enters Succeeding state https://github.com/kubeflow/spark-operator/blob/c261df66a00635509f7d8cb2a7fba4c602c9228e/pkg/controller/sparkapplication/sparkapp_metrics.go#L222. So it means (TotalNumberOfSparkApplicationEnteredRunningState - TotalNumberOfSparkApplicationEnteredSucceedingState)
    - `Start Application Start Latency`: This metric measures the duration from the application is created (New State) to the time when the application entered Running state. In other words, it includes two time cost on two phase. 
    Phase1, from the time user creates spark application to the time spark operator run spark-submit. Phase2, from spark operator runs spark-submit to the time when application starts running. https://github.com/kubeflow/spark-operator/blob/c261df66a00635509f7d8cb2a7fba4c602c9228e/pkg/controller/sparkapplication/sparkapp_metrics.go#L300 https://github.com/kubeflow/spark-operator/blob/c261df66a00635509f7d8cb2a7fba4c602c9228e/pkg/controller/sparkapplication/sparkapp_metrics.go#L212



</details>

## Clean up
```bash
# To remove the Locust EC2 from infrastructure. You can ignore if you did not execute bash ./locust-provision.sh before.
bash ./locust-provision.sh -action delete

# To remove the resources that created by ./infra-provision.sh.
bash ./clean-up.sh 
```

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

