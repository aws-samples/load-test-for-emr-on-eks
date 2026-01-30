# General
export AWS_REGION=us-west-2
export EKS_VERSION=1.34
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export LOAD_TEST_PREFIX=eks-test
export CLUSTER_NAME=${LOAD_TEST_PREFIX}-${EKS_VERSION//./-}
export BUCKET_NAME=emr-on-${CLUSTER_NAME}-$ACCOUNT_ID-${AWS_REGION}
# Locust
export EMR_IMAGE_VERSION=7.9.0
export SPARK_JOB_NS_NUM=2 # number of namespaces/VC to create
export LOCUST_EKS_ROLE="${CLUSTER_NAME}-locust-role"
export JOB_SCRIPT_NAME="emr-job-run.sh"

# ================================================
# Required variables for infra-provision.sh. 
# If skip the infra setup step, remove this unnecessary section
# ================================================
# EKS
export EKS_VPC_CIDR=192.168.0.0/16
export CMK_ALIAS=cmk_locust_pvc_reuse
# EMR on EKS
export EXECUTION_ROLE=emr-on-${CLUSTER_NAME}-execution-role
export EXECUTION_ROLE_POLICY=${CLUSTER_NAME}-SparkJobS3AccessPolicy
# Karpenter
export KARPENTER_VERSION="1.8.5"
export KARPENTER_CONTROLLER_ROLE="KarpenterControllerRole-${CLUSTER_NAME}"
export KARPENTER_CONTROLLER_POLICY="KarpenterControllerPolicy-${CLUSTER_NAME}"
export KARPENTER_NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"
# Create Amazon Managed Grafana workspace or not
export USE_AMG="true"
# =======================================================================