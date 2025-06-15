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

# AI Agents Configuration
export AI_AGENTS_ENABLED="true"
export AGENT_NAMESPACE="spark-agents"
export AGENT_ECR_REPO="spark-agents"
export AGENT_IMAGE_TAG="v1.0.0"

# LLM Configuration
export BEDROCK_MODEL_ID="anthropic.claude-3-5-sonnet-20241022-v2:0"

# SQS Configuration for Job Queues
export SQS_HIGH_PRIORITY_QUEUE="${LOAD_TEST_PREFIX}-spark-jobs-high.fifo"
export SQS_MEDIUM_PRIORITY_QUEUE="${LOAD_TEST_PREFIX}-spark-jobs-medium.fifo"
export SQS_LOW_PRIORITY_QUEUE="${LOAD_TEST_PREFIX}-spark-jobs-low.fifo"
export SQS_DLQ="${LOAD_TEST_PREFIX}-spark-jobs-dlq.fifo"

# Agent IAM Configuration
export AGENT_ROLE="${LOAD_TEST_PREFIX}-AgentRole"
export AGENT_POLICY="${LOAD_TEST_PREFIX}-AgentPolicy"
export SQS_AGENT_POLICY="${LOAD_TEST_PREFIX}-SQSAgentPolicy"
export BEDROCK_AGENT_POLICY="${LOAD_TEST_PREFIX}-BedrockAgentPolicy"

# Agent Resource Configuration
export AGENT_CPU_REQUEST="100m"
export AGENT_CPU_LIMIT="500m"
export AGENT_MEMORY_REQUEST="256Mi"
export AGENT_MEMORY_LIMIT="512Mi"


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