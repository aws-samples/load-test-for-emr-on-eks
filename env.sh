# General
# AWS identity is derived from the active AWS profile -- no hardcoded account/region.
# Set the profile via the MCP tool `set_aws_profile`, or export AWS_PROFILE yourself.
export AWS_PROFILE=${AWS_PROFILE:-default}
export AWS_REGION=${AWS_REGION:-$(aws configure get region --profile "$AWS_PROFILE" 2>/dev/null)}
export EKS_VERSION=${EKS_VERSION:-1.35}
export ACCOUNT_ID=${ACCOUNT_ID:-$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text 2>/dev/null)}
export CLUSTER_NAME=${CLUSTER_NAME:-loadtest-mcp-demo}
# LOAD_TEST_PREFIX mirrors CLUSTER_NAME (used by clean-up.sh discovery).
export LOAD_TEST_PREFIX=${CLUSTER_NAME}
export BUCKET_NAME=emr-on-${CLUSTER_NAME}-$ACCOUNT_ID-${AWS_REGION}
# Locust
export EMR_IMAGE_VERSION=${EMR_IMAGE_VERSION:-7.13.0}
export SPARK_JOB_NS_NUM="2" # number of namespaces/VC to create
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
export EXECUTION_ROLE=emr-on-${CLUSTER_NAME}-mcp-execution-role
export EXECUTION_ROLE_POLICY=${CLUSTER_NAME}-SparkJobS3AccessPolicy
# Karpenter
export KARPENTER_VERSION=${KARPENTER_VERSION:-"1.8.5"}
export KARPENTER_CONTROLLER_ROLE="KarpenterControllerRole-${CLUSTER_NAME}"
export KARPENTER_CONTROLLER_POLICY="KarpenterControllerPolicy-${CLUSTER_NAME}"
export KARPENTER_NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"
# =======================================================================