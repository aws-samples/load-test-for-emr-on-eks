export AWS_PROFILE=${AWS_PROFILE:-default}
export AWS_REGION=${AWS_REGION}
export EKS_VERSION=${EKS_VERSION:-1.35}
export ACCOUNT_ID=${ACCOUNT_ID:-$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text 2>/dev/null)}
export LOAD_TEST_PREFIX=${CLUSTER_NAME}
export CLUSTER_NAME=${CLUSTER_NAME:-loadtest-mcp-demo}
export BUCKET_NAME=emr-on-${CLUSTER_NAME}-$ACCOUNT_ID-${AWS_REGION}
# Locust
export EMR_IMAGE_VERSION=8.100.0
export SPARK_JOB_NS_NUM=1 # number of namespaces/VC to create
export LOCUST_EKS_ROLE="${CLUSTER_NAME}-locust-role"
export JOB_SCRIPT_NAME="emr-job-run.sh"
# EKS
export EKS_VPC_CIDR=192.168.0.0/16
export CMK_ALIAS=cmk_locust_pvc_reuse
# EMR on EKS
export EMR_CONTAINERS_ENDPOINT_URL=${EMR_CONTAINERS_ENDPOINT_URL:-https://emr-containers.${AWS_REGION}.amazonaws.com}
export SRC_ECR_URL=${SRC_ECR_URL:-public.ecr.aws/myang-poc/eks-spark-benchmark:emr}
export EMR_VERSIONS=${EMR_VERSIONS:-7.13.0}
export EXECUTION_ROLE=emr-on-${CLUSTER_NAME}-execution-role
export EXECUTION_ROLE_POLICY=${CLUSTER_NAME}-SparkJobS3AccessPolicy
export EXECUTION_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/${EXECUTION_ROLE}
export SPARK_CONNECT_IMAGE_URL=${SPARK_CONNECT_IMAGE_URL:-${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/eks-spark-benchmark:emr${EMR_IMAGE_VERSION}}
export SPARK_CONNECT_DATA_PATH=${SPARK_CONNECT_DATA_PATH:-}
export SPARK_CONNECT_DATA_FORMAT=${SPARK_CONNECT_DATA_FORMAT:-parquet}
# Karpenter
export KARPENTER_VERSION=${KARPENTER_VERSION:-"1.8.5"}
export KARPENTER_CONTROLLER_ROLE="KarpenterControllerRole-${CLUSTER_NAME}"
export KARPENTER_CONTROLLER_POLICY="KarpenterControllerPolicy-${CLUSTER_NAME}"
export KARPENTER_NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"

