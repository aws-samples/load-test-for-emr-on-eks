export LOAD_TEST_PREFIX=load-test-cluster
export CLUSTER_NAME=${LOAD_TEST_PREFIX}-20
export AWS_REGION=us-west-2
export PUB_ECR_REGISTRY_ACCOUNT=895885662937
export EKS_VPC_CIDR=172.16.0.0/16
export EKS_VERSION=1.34

# Utility
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET_NAME=emr-on-${CLUSTER_NAME}-$ACCOUNT_ID-$AWS_REGION
export EXECUTION_ROLE=emr-on-${CLUSTER_NAME}-execution-role
export EXECUTION_ROLE_POLICY=${CLUSTER_NAME}-SparkJobS3AccessPolicy
export SPARK_JOB_NS_NUM=2
export EMR_IMAGE_VERSION=7.9.0
export ECR_URL="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Karpenter
export KARPENTER_VERSION="1.6.1"
export KARPENTER_CONTROLLER_ROLE="KarpenterControllerRole-${CLUSTER_NAME}"
export KARPENTER_CONTROLLER_POLICY="KarpenterControllerPolicy-${CLUSTER_NAME}"
export KARPENTER_NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"

# To use Amazon Managed Grafana
export USE_AMG="true"
