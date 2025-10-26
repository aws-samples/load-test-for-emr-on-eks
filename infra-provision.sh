#!/bin/bash


# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

source env.sh

echo "==============================================="
echo "  Setup Bucket ......"
echo "==============================================="

# Create S3 bucket for testing
echo "Creating S3 bucket: $BUCKET_NAME"
aws s3api create-bucket \
    --bucket $BUCKET_NAME \
    --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_REGION || {
    echo "Error: Failed to create S3 bucket $BUCKET_NAME"
    exit 1
}

# Upload the testing pyspark code
aws s3 sync ./locust/resources/ "s3://${BUCKET_NAME}/app-code/"

echo "==============================================="
echo "  Create EKS Cluster ......"
echo "==============================================="

if ! aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} >/dev/null 2>&1; then

    sed -i='' 's|${AWS_REGION}|'$AWS_REGION'|g' ./resources/eks-cluster-values.yaml
    sed -i='' 's|${CLUSTER_NAME}|'$CLUSTER_NAME'|g' ./resources/eks-cluster-values.yaml
    sed -i='' 's|${EKS_VERSION}|'$EKS_VERSION'|g' ./resources/eks-cluster-values.yaml
    sed -i='' 's|${EKS_VPC_CIDR}|'$EKS_VPC_CIDR'|g' ./resources/eks-cluster-values.yaml
    
    eksctl create cluster -f ./resources/eks-cluster-values.yaml

fi


echo "==============================================="
echo "  Get OIDC ......"
echo "==============================================="

OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
echo $OIDC_PROVIDER

echo "==============================================="
echo "  Create a default gp3 storageclass ......"
echo "==============================================="

kubectl apply -f resources/storageclass.yaml

echo "==============================================="
echo "  Setup Cluster Autoscaler ......"
echo "==============================================="

sed -i='' 's/${CLUSTER_NAME}/'$CLUSTER_NAME'/g' ./resources/autoscaler-values.yaml
sed -i='' 's/${AWS_REGION}/'$AWS_REGION'/g' ./resources/autoscaler-values.yaml

helm repo update
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade --install nodescaler autoscaler/cluster-autoscaler -n kube-system --values ./resources/autoscaler-values.yaml


echo "==============================================="
echo "  Setup BinPacking ......"
echo "==============================================="

git clone https://github.com/aws-samples/custom-scheduler-eks
cd custom-scheduler-eks/deploy
helm install custom-scheduler-eks charts/custom-scheduler-eks -n kube-system -f ./resources/binpacking-values.yaml

echo "==============================================="
echo "  Create EMR on EKS Execution Role ......"
echo "==============================================="
# Create S3 access policy if it doesn't exist
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${EXECUTION_ROLE_POLICY}" 2>/dev/null; then
    echo "IAM policy ${EXECUTION_ROLE_POLICY} already exists"
else
    cat <<EOF > /tmp/spark-job-s3-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:GetObject",
                "s3:ListBucket"
              ],
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}",
                "arn:aws:s3:::${BUCKET_NAME}/*"
            ]
        }
    ]
}
EOF
    aws iam create-policy --policy-name ${EXECUTION_ROLE_POLICY} --policy-document file:///tmp/spark-job-s3-policy.json
fi

if aws iam get-role --role-name "$EXECUTION_ROLE" 2>/dev/null; then
    echo "IAM role ${EXECUTION_ROLE} already exists"
else
    echo "Creating IAM role ${EXECUTION_ROLE}..."
    cat <<EOF > /tmp/trust-relationship.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
    aws iam create-role --role-name ${EXECUTION_ROLE} --assume-role-policy-document file:///tmp/trust-relationship.json
    aws iam attach-role-policy --role-name ${EXECUTION_ROLE} --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/${EXECUTION_ROLE_POLICY}
fi

echo "================================================================="
echo "  Create multi-platform Image for Spark benchmark Utility ......"
echo "================================================================="   

echo "Logging into ECR..."
export SRC_ECR_URL=${PUB_ECR_REGISTRY_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin $SRC_ECR_URL
docker pull $SRC_ECR_URL/spark/emr-${EMR_IMAGE_VERSION}:latest

# Custom an image on top of the EMR Spark
wget -O Dockerfile https://raw.githubusercontent.com/aws-samples/emr-on-eks-benchmark/refs/heads/main/docker/benchmark-util/Dockerfile

docker buildx build --platform linux/amd64,linux/arm64 \
-t $ECR_URL/eks-spark-benchmark:emr${EMR_IMAGE_VERSION} \
-f ./Dockerfile \
--build-arg SPARK_BASE_IMAGE=$SRC_ECR_URL/spark/emr-${EMR_IMAGE_VERSION}:latest \
--push .


echo "==============================================="
echo "  Setup Prometheus ......"
echo "==============================================="

kubectl create namespace prometheus --dry-run=client -o yaml | kubectl apply -f -
# SA name and IRSA role were created at EKS cluster creation time
amp=$(aws amp list-workspaces --query "workspaces[?alias=='$EKSCLUSTER_NAME'].workspaceId" --output text)
if [ -z "$amp" ]; then
    echo "Creating a new prometheus workspace..."
    export WORKSPACE_ID=$(aws amp create-workspace --alias $EKSCLUSTER_NAME --query workspaceId --output text)
else
    echo "A prometheus workspace already exists"
    export WORKSPACE_ID=$amp
fi
# export INGEST_ROLE_ARN="arn:aws:iam::${ACCOUNTID}:role/${EKSCLUSTER_NAME}-prometheus-ingest"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add kube-state-metrics https://kubernetes.github.io/kube-state-metrics
helm repo update
sed -i -- 's/{AWS_REGION}/'$AWS_REGION'/g'  ./resources/prometheus-values.yaml
sed -i -- 's/{ACCOUNTID}/'$ACCOUNT_ID'/g'  ./resources/prometheus-values.yaml
sed -i -- 's/{WORKSPACE_ID}/'$WORKSPACE_ID'/g'  ./resources/prometheus-values.yaml
sed -i -- 's/{CLUSTER_NAME}/'$CLUSTER_NAME'/g'  ./resources/prometheus-values.yaml
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack -n prometheus -f  ./resources/prometheus-values.yaml --debug
# validate in a web browser - localhost:9090, go to menu of status->targets
# kubectl --namespace prometheus port-forward service/prometheus-kube-prometheus-prometheus 9090

# create pod monitor for Spark apps works with Prometheus
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

echo "==============================================="
echo "  Setup Karpenter ......"
echo "==============================================="
echo "Check and create Karpenter controller policy"
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}" 2>/dev/null; then
    echo "Policy ${KARPENTER_CONTROLLER_POLICY} already exists"
else
    sed -i='' 's/${AWS_ACCOUNT_ID}/'$ACCOUNT_ID'/g' ./resources/karpenter/karpenter-controller-policy.json
    sed -i='' 's/${AWS_REGION}/'$AWS_REGION'/g' ./resources/karpenter/karpenter-controller-policy.json
    sed -i='' 's/${CLUSTER_NAME}/'$CLUSTER_NAME'/g' ./resources/karpenter/karpenter-controller-policy.json

    aws iam create-policy --policy-name "${KARPENTER_CONTROLLER_POLICY}" --policy-document file://resources/karpenter-controller-policy.json
fi

sleep 5

echo "Check and create Karpenter controller role"
if aws iam get-role --role-name "${KARPENTER_CONTROLLER_ROLE}" >/dev/null 2>&1; then
    echo "Role ${KARPENTER_CONTROLLER_ROLE} already exists"
else
    cat <<EOF > /tmp/controller-trust.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
                    "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:karpenter"
                }
            }
        }
    ]
}
EOF
    aws iam create-role --role-name "${KARPENTER_CONTROLLER_ROLE}" --assume-role-policy-document file:///tmp/controller-trust.json
    aws iam attach-role-policy --role-name "${KARPENTER_CONTROLLER_ROLE}" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}"
fi


echo "Check and create Karpenter node role"
if aws iam get-role --role-name "${KARPENTER_NODE_ROLE}" >/dev/null 2>&1; then
    echo "Role ${KARPENTER_NODE_ROLE} already exists"
else
    echo "Creating role ${KARPENTER_NODE_ROLE}..."
    cat <<EOF > /tmp/node-role-trust.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
    aws iam create-role --role-name "${KARPENTER_NODE_ROLE}" --assume-role-policy-document file:///tmp/node-role-trust.json
    aws iam attach-role-policy --role-name "${KARPENTER_NODE_ROLE}" --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
    aws iam attach-role-policy --role-name "${KARPENTER_NODE_ROLE}" --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
    aws iam attach-role-policy --role-name "${KARPENTER_NODE_ROLE}" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
    aws iam attach-role-policy --role-name "${KARPENTER_NODE_ROLE}" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
fi


echo "==============================================="
echo "  Configure AWS Auth and Security Groups For Karpenter ......"
echo "==============================================="
# create tags for subnets
for NODEGROUP in $(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups' --output text); do
    aws ec2 create-tags \
        --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
        --resources $(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${NODEGROUP}" --query 'nodegroup.subnets' --output text )
done


# Tag security groups for Karpenter discovery
SECURITY_GROUPS=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} \
    --query 'cluster.resourcesVpcConfig.securityGroupIds[*]' \
    --output text)

# Add additional security group from cluster control plane
CLUSTER_SG=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
    --output text)

echo "Found security groups: $SECURITY_GROUPS $CLUSTER_SG"

# Tag each security group
for SG in ${SECURITY_GROUPS} ${CLUSTER_SG}; do
    echo "Tagging security group: $SG"
    aws ec2 create-tags \
        --resources "$SG" \
        --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" || true
done

# Update aws-auth ConfigMap
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - groups:
      - system:bootstrappers
      - system:nodes
      rolearn: arn:aws:iam::${ACCOUNT_ID}:role/${KARPENTER_NODE_ROLE}
      username: system:node:{{EC2PrivateDNSName}}
EOF

helm template karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" --namespace kube-system \
    --set "settings.clusterName=${CLUSTER_NAME}" \
    --set "settings.interruptionQueue=${CLUSTER_NAME}" \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
    --set controller.resources.requests.cpu=4 \
    --set controller.resources.requests.memory=1Gi \
    --set controller.resources.limits.cpu=4 \
    --set controller.resources.limits.memory=1Gi \
    --set nodeSelector.operational="true" > karpenter-${KARPENTER_VERSION}.yaml

sed -i='' 's|KarpenterControllerRole_ARN|arn:aws:iam::'$ACCOUNT_ID':role/'$KARPENTER_CONTROLLER_ROLE'|g' ./resources/karpenter/karpenter-1.6.1.yaml
sed -i='' 's|CLUSTER_NAME_VALUE|'$CLUSTER_NAME'|g' ./resources/karpenter/karpenter-1.6.1.yaml

kubectl create -f \
    "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodepools.yaml"
kubectl create -f \
    "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml"
kubectl create -f \
    "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodeclaims.yaml"
kubectl apply -f karpenter.yaml

echo "====================================================="
echo "  Create Karpenter Nodepools ......"
echo "====================================================="

# Create NodePools for Karpenter:
sed -i='' 's/${NODE_ROLE_NAME}/'$KARPENTER_NODE_ROLE'/g' ./resources/karpenter/shared-nodeclass.yaml
sed -i='' 's/${CLUSTER_NAME}/'$CLUSTER_NAME'/g' ./resources/karpenter/shared-nodeclass.yaml

kubectl apply -f ./resources/karpenter/driver-nodepoolyaml
kubectl apply -f ./resources/karpenter/executor-nodepool.yaml
kubectl apply -f ./resources/karpenter/shared-nodeclass.yaml

echo "==============================================="
echo "  Set up Prometheus ServiceMonitor and PodMonitor ......"
echo "==============================================="
# kubectl apply -f spark-podmonitor.yaml
kubectl apply -f karpenter-srvmonitor
kubectl apply -f aws-cni-podmonitor.yaml


if [[ $USE_AMG == "true" ]]
then 
    echo "==============================================="
    echo "  Set up Amazon Managed Grafana ......"
    echo "==============================================="
    echo "Creating Grafana workspace: $CLUSTER_NAME-amg"

    RESULT=$(aws grafana create-workspace \
        --workspace-name "$CLUSTER_NAME-amg" \
        --region $REGION \
        --account-access-type "CURRENT_ACCOUNT" \
        --permission-type "SERVICE_MANAGED" \
        --authentication-providers "AWS_SSO" \
        --output json 2>&1) \
    && grafana_workspace_id=$(echo "$RESULT" | jq -r '.workspace.id')

    if [[ $grafana_workspace_id != "" ]]
    then 
        echo "Created AWS Manged Grafana workspace $grafana_workspace_id"
    fi
fi