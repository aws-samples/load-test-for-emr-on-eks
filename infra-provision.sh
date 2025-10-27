#!/bin/bash


# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

source env.sh

echo "==============================================="
echo "  Setup Bucket ......"
echo "==============================================="
# Create S3 bucket for load test
echo "Creating S3 bucket: $BUCKET_NAME"
aws s3api create-bucket \
    --bucket $BUCKET_NAME \
    --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_REGION || {
    echo "Error: Failed to create S3 bucket $BUCKET_NAME"
    exit 1
}

echo "==============================================="
echo "  Create EKS Cluster ......"
echo "==============================================="
echo "Create EKS Cluster: ${CLUSTER_NAME}"
if ! aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} >/dev/null 2>&1; then

    sed -i='' 's|${AWS_REGION}|'$AWS_REGION'|g' ./resources/eks-cluster-values.yaml
      sed -i='' 's|${ACCOUNT_ID}|'$ACCOUNT_ID'|g' ./resources/eks-cluster-values.yaml
    sed -i='' 's|${CLUSTER_NAME}|'$CLUSTER_NAME'|g' ./resources/eks-cluster-values.yaml
    sed -i='' 's|${EKS_VERSION}|'$EKS_VERSION'|g' ./resources/eks-cluster-values.yaml
    sed -i='' 's|${EKS_VPC_CIDR}|'$EKS_VPC_CIDR'|g' ./resources/eks-cluster-values.yaml
    
    eksctl create cluster -f ./resources/eks-cluster-values.yaml
fi

echo "==============================================="
echo "  Get OIDC ......"
echo "==============================================="
echo "Get OIDC"
OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
echo $OIDC_PROVIDER

echo "==============================================="
echo "  Create a default gp3 storageclass ......"
echo "==============================================="
echo "Create a default gp3 storageclass"
kubectl apply -f resources/storageclass.yaml

echo "==============================================="
echo "  Setup Cluster Autoscaler ......"
echo "==============================================="
echo "  Setup Cluster Autoscaler"
sed -i='' 's/${CLUSTER_NAME}/'$CLUSTER_NAME'/g' ./resources/autoscaler-values.yaml
sed -i='' 's/${AWS_REGION}/'$AWS_REGION'/g' ./resources/autoscaler-values.yaml

helm repo update
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade --install nodescaler autoscaler/cluster-autoscaler -n kube-system --values ./resources/autoscaler-values.yaml

echo "==============================================="
echo "  Setup Load Balancer Controller ......"
echo "==============================================="
echo "Setup AWS Load Balancer Controller"
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=${CLUSTER_NAME} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
  
aws ec2 create-tags \
    --tags "Key=kubernetes.io/role/elb,Value=1" \
    --resources "$(aws ec2 describe-subnets --filters 'Name=tag:Name,Values=PublicSubnet*' --query 'Subnets[*].SubnetId')"

echo "==============================================="
echo "  Setup BinPacking ......"
echo "==============================================="
echo "Setup BinPacking"
git clone https://github.com/aws-samples/custom-scheduler-eks
cd custom-scheduler-eks/deploy
helm install custom-scheduler-eks charts/custom-scheduler-eks \
-n kube-system \
-f ./resources/binpacking-values.yaml

echo "==============================================="
echo "  Create EMR on EKS Execution Role ......"
echo "==============================================="
echo "Create EMR on EKS execution role only"
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

echo "==============================================="
echo "  Setup Prometheus ......"
echo "==============================================="
echo "Setup Prometheus"
kubectl create ns prometheus || true
# SA name and IRSA role were created at EKS cluster creation time
amp=$(aws amp list-workspaces --query "workspaces[?alias=='$CLUSTER_NAME'].workspaceId" --output text)
if [ -z "$amp" ]; then
    echo "Creating a new prometheus workspace..."
    export WORKSPACE_ID=$(aws amp create-workspace --alias $CLUSTER_NAME --query workspaceId --output text)
else
    echo "A prometheus workspace already exists"
    export WORKSPACE_ID=$amp
fi
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

# Install metrics server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

echo "==============================================="
echo "  Setup Karpenter ......"
echo "==============================================="
echo "Create Karpenter controller policy"
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}" 2>/dev/null; then
    echo "Policy ${KARPENTER_CONTROLLER_POLICY} already exists"
else
    sed -i='' 's/${AWS_ACCOUNT_ID}/'$ACCOUNT_ID'/g' ./resources/karpenter/karpenter-controller-policy.json
    sed -i='' 's/${AWS_REGION}/'$AWS_REGION'/g' ./resources/karpenter/karpenter-controller-policy.json
    sed -i='' 's/${CLUSTER_NAME}/'$CLUSTER_NAME'/g' ./resources/karpenter/karpenter-controller-policy.json

    aws iam create-policy --policy-name "${KARPENTER_CONTROLLER_POLICY}" --policy-document file://resources/karpenter/karpenter-controller-policy.json
fi
sleep 5

echo "Create Karpenter controller role"
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

echo "Create Karpenter node role"
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

echo "Create karpenter tags for subnets, SGs"
for NODEGROUP in $(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups' --output text); do
    aws ec2 create-tags \
        --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
        --resources $(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${NODEGROUP}" --query 'nodegroup.subnets' --output text )
done
# launch template
NODEGROUP=$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups[0]' --output text)
LAUNCH_TEMPLATE=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name "${NODEGROUP}" --query 'nodegroup.launchTemplate.{id:id,version:version}' \
    --output text | tr -s "\t" ",")

SECURITY_GROUPS=$(aws eks describe-cluster \
    --name "${CLUSTER_NAME}" --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
# If your setup uses the security groups in the Launch template of a managed node group, then :
SECURITY_GROUPS2="$(aws ec2 describe-launch-template-versions \
    --launch-template-id "${LAUNCH_TEMPLATE%,*}" --versions "${LAUNCH_TEMPLATE#*,}" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.[NetworkInterfaces[0].Groups||SecurityGroupIds]' \
    --output text)" || true

aws ec2 create-tags \
    --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
    --resources ${SECURITY_GROUPS} ${SECURITY_GROUPS2}

aws eks create-access-entry --cluster-name ${CLUSTER_NAME} --principal-arn arn:aws:iam::${ACCOUNT_ID}:role/${KARPENTER_NODE_ROLE} --type EC2_LINUX

echo "Install Karpenter via Helm Chart"
helm registry logout public.ecr.aws
helm template karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" --namespace kube-system \
    --set "settings.clusterName=${CLUSTER_NAME}" \
    --set "settings.interruptionQueue=${CLUSTER_NAME}" \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/${KARPENTER_CONTROLLER_ROLE}" \
    --set controller.resources.requests.cpu=4 \
    --set controller.resources.requests.memory=1Gi \
    --set controller.resources.limits.cpu=4 \
    --set controller.resources.limits.memory=1Gi > ./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml

kubectl create -f \
    "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodepools.yaml"
kubectl create -f \
    "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml"
kubectl create -f \
    "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodeclaims.yaml"
kubectl apply -f ./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml

echo "====================================================="
echo "  Create Karpenter Nodepools and nodeclass ......"
echo "====================================================="
echo "Create Karpenter nodepools ......"
sed -i='' 's/${KARPENTER_NODE_ROLE}/'$KARPENTER_NODE_ROLE'/g' ./resources/karpenter/shared-nodeclass.yaml
sed -i='' 's/${CLUSTER_NAME}/'$CLUSTER_NAME'/g' ./resources/karpenter/shared-nodeclass.yaml

kubectl apply -f "./resources/karpenter/*.yaml"

echo "==============================================="
echo "  Set up Prometheus ServiceMonitor and PodMonitor ......"
echo "==============================================="
echo "Create Prometheus service monitor and pod monitor"
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
