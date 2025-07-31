mkdir -p /tmp/load_test/
LOAD_TEST_PREFIX_FILE=/tmp/load_test/eks_load_test_prefix
CLUSTER_NAME_FILE=/tmp/load_test/eks_cluster_name

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

if [ -f "$LOAD_TEST_PREFIX_FILE" ]; then
  export LOAD_TEST_PREFIX=$(cat "$LOAD_TEST_PREFIX_FILE")
  echo "Using existing LOAD_TEST_PREFIX: $LOAD_TEST_PREFIX"
else
  ACCOUNT_HASH=$(echo -n "$ACCOUNT_ID" | md5sum | cut -c1-4)
  export LOAD_TEST_PREFIX=eks-load-test-${ACCOUNT_HASH}
  
  echo "$LOAD_TEST_PREFIX" > "$LOAD_TEST_PREFIX_FILE"
  echo "Created new LOAD_TEST_PREFIX: $LOAD_TEST_PREFIX"
fi

export AWS_REGION=us-west-2
export ECR_REGISTRY_ACCOUNT=895885662937
export EKS_VPC_CIDR=10.0.0.0/16
export EKS_VPC_CIDR_SECONDARY=10.1.0.0/16
export EKS_VERSION=1.32

# Check if the cluster name file already exists
if [ -f "$CLUSTER_NAME_FILE" ]; then
  export CLUSTER_NAME=$(cat "$CLUSTER_NAME_FILE")
  echo "Using existing CLUSTER_NAME: $CLUSTER_NAME"
else
  # Keep asking until we get a valid response
  while true; do
    # Ask the user if they want to use an existing cluster
    echo "Do you want to use an existing cluster? If yes, enter the cluster name, otherwise enter 'n' or just press enter to use default name: "
    read user_input
    
    if [ -z "$user_input" ] || [ "$user_input" = "n" ] || [ "$user_input" = "no" ]; then
      # Use the original naming convention
      export CLUSTER_NAME=${LOAD_TEST_PREFIX}
      echo "Using new CLUSTER_NAME: $CLUSTER_NAME"
      break  # Exit the loop
    else
      # Check if the cluster exists
      if aws eks describe-cluster --name "$user_input" --region "$AWS_REGION" >/dev/null 2>&1; then
        export CLUSTER_NAME=$user_input
        echo "Using existing cluster: $CLUSTER_NAME"
        break  # Exit the loop
      else
        echo "Cluster '$user_input' does not exist. Please try again."
        # Loop continues, asking the question again
      fi
    fi
  done
  
  # Store the cluster name for future use
  echo "$CLUSTER_NAME" > "$CLUSTER_NAME_FILE"
  echo "Stored CLUSTER_NAME for future use"
fi


export BUCKET_NAME=${LOAD_TEST_PREFIX}-bucket

# Spark Operator
# OPERATOR_TEST_MODE, either using "multiple" or "single"
# SPARK_JOB_NS_NUM, int, which means how many spark job namespaces to be created. 

# OPERATOR_TEST_MODE="multiple", which means multiple spark operators will be created.
# The operator number is the same as "SPARK_JOB_NS_NUM"

# eg 1: OPERATOR_TEST_MODE="multiple" && SPARK_JOB_NS_NUM=2.
# It will be 2 job namespaces and 2 spark operators to be created:
# `spark-operator0` is only monitoring `spark-job0` namespace
# `spark-operator1` is only monitoring `spark-job1` namespace

# eg 2: OPERATOR_TEST_MODE="single" && SPARK_JOB_NS_NUM=2. 

# It will be 2 job namespaces, but only one spark operator to be created.
# spark-operator0 will be monitoring both `spark-job0`` and `spark-job1``.

export OPERATOR_TEST_MODE="multiple"
export SPARK_JOB_NS_NUM=2
export SPARK_OPERATOR_VERSION=7.7.0
export EMR_IMAGE_VERSION=7.7.0
export SPARK_VERSION=3.5.3
export EMR_IMAGE_URL="${ECR_REGISTRY_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/spark/emr-${EMR_IMAGE_VERSION}:latest"

export SPARK_OPERATOR_ROLE=${LOAD_TEST_PREFIX}-SparkJobS3AccessRole
export SPARK_OPERATOR_POLICY=${LOAD_TEST_PREFIX}-SparkJobS3AccessPolicy


# Prometheus
export AMP_SERVICE_ACCOUNT_INGEST_NAME=amp-iamproxy-ingest-service-account
export AMP_SERVICE_ACCOUNT_IAM_INGEST_ROLE=${LOAD_TEST_PREFIX}-prometheus-ingest
export AMP_SERVICE_ACCOUNT_IAM_INGEST_POLICY=${LOAD_TEST_PREFIX}-AMPIngestPolicy

# Karpenter

export KARPENTER_NAMESPACE="kube-system"
export KARPENTER_VERSION="1.5.0"

export KARPENTER_CONTROLLER_ROLE="KarpenterControllerRole-${LOAD_TEST_PREFIX}"
export KARPENTER_CONTROLLER_POLICY="KarpenterControllerPolicy-${LOAD_TEST_PREFIX}"
export KARPENTER_NODE_ROLE="KarpenterNodeRole-${LOAD_TEST_PREFIX}"

# To use Amazon Managed Grafana
export USE_AMG="true"



# SQS Configuration
export SQS_QUEUE_NAME="${LOAD_TEST_PREFIX}-spark-jobs-queue"
export SQS_DLQ_NAME="${LOAD_TEST_PREFIX}-spark-jobs-dlq"
export SQS_SCHEDULER_ROLE="${LOAD_TEST_PREFIX}-SQSSchedulerRole"
export SQS_SCHEDULER_POLICY="${LOAD_TEST_PREFIX}-SQSSchedulerPolicy"

# Spark Operator V2 Configuration (OSS)
export SPARK_OPERATOR_OSS_VERSION="v2.2.0"

# Job Scheduler Configuration
export JOB_SCHEDULER_NAMESPACE="job-scheduler"
export JOB_SCHEDULER_SERVICE_ACCOUNT="job-scheduler-sa"
export JOB_SCHEDULER_BATCH_SIZE=10
export JOB_SCHEDULER_POLL_INTERVAL=1