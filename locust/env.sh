export LOAD_TEST_PREFIX=eks-operator-test
export AWS_REGION=us-west-2
export ECR_REGISTRY_ACCOUNT=895885662937
export EKS_VPC_CIDR=172.16.0.0/16
export EKS_VERSION=1.30

# Please check below for the ECR_REGISTRY_ACCOUNT if you are using other regions
# https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/docker-custom-images-tag.html


# Utility
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER_NAME=${LOAD_TEST_PREFIX}-eks-cluster
export BUCKET_NAME=${LOAD_TEST_PREFIX}-bucket-01


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
export SPARK_OPERATOR_VERSION=6.11.0
export EMR_IMAGE_VERSION=6.11.0
export EMR_IMAGE_URL="${ECR_REGISTRY_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/spark/emr-${EMR_IMAGE_VERSION}:latest"

export SPARK_OPERATOR_ROLE=${LOAD_TEST_PREFIX}-SparkJobS3AccessRole
export SPARK_OPERATOR_POLICY=${LOAD_TEST_PREFIX}-SparkJobS3AccessPolicy


# Prometheus
export AMP_SERVICE_ACCOUNT_INGEST_NAME=amp-iamproxy-ingest-service-account
export AMP_SERVICE_ACCOUNT_IAM_INGEST_ROLE=${LOAD_TEST_PREFIX}-prometheus-ingest
export AMP_SERVICE_ACCOUNT_IAM_INGEST_POLICY=${LOAD_TEST_PREFIX}-AMPIngestPolicy

# Karpenter
export KARPENTER_CONTROLLER_ROLE="KarpenterControllerRole-${LOAD_TEST_PREFIX}"
export KARPENTER_CONTROLLER_POLICY="KarpenterControllerPolicy-${LOAD_TEST_PREFIX}"
export KARPENTER_NODE_ROLE="KarpenterNodeRole-${LOAD_TEST_PREFIX}"

# To use Amazon Managed Grafana
export USE_AMG="true"
