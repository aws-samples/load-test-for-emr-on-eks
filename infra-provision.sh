#!/bin/bash


# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

source env.sh

echo "==============================================="
echo " 1. Setup Bucket ......"
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
echo " 2. Create EKS Cluster ......"
echo "==============================================="
echo "Create EKS Cluster: ${CLUSTER_NAME}"
if ! aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} >/dev/null 2>&1; then

    sed -i='' 's|${AWS_REGION}|'$AWS_REGION'|g' ./resources/eks-cluster-values.yaml
    sed -i='' 's|${CLUSTER_NAME}|'$CLUSTER_NAME'|g' ./resources/eks-cluster-values.yaml
    sed -i='' 's|${EKS_VERSION}|'$EKS_VERSION'|g' ./resources/eks-cluster-values.yaml
    sed -i='' 's|${EKS_VPC_CIDR}|'$EKS_VPC_CIDR'|g' ./resources/eks-cluster-values.yaml
    
    eksctl create cluster -f ./resources/eks-cluster-values.yaml
fi

echo "==============================================="
echo " 3. Get OIDC ......"
echo "==============================================="
echo "Get OIDC"
OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --approve
echo $OIDC_PROVIDER

echo "==============================================="
echo " 4. Create a default gp3 storageclass ......"
echo "==============================================="
echo "Create a storageclass for EBS"
kubectl apply -f resources/ebs/storageclass.yaml

echo "============================================================="
echo " 5. Tune EBS Controller by patch the existing addon ......"
echo "============================================================="
echo "Patching existing EBS CSI driver for large scale API calls..."
bash ./resources/ebs/patch_csi-controller.sh
bash ./resources/ebs/patch_csi-node-daemonset.sh

# echo "[OPTIONAL] Enable EBS controller Metrics for monitoring..."
# aws eks update-addon --cluster-name ${CLUSTER_NAME} \
# --addon-name aws-ebs-csi-driver --resolve-conflicts OVERWRITE   \
# --configuration-values '{"controller":{"enableMetrics":true}}' \
# --service-account-role-arn arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-AWSLoadBalancerControllerRole

# echo "[OPTIONAL]scale up EBS CSI controller"
# kubectl scale deployment ebs-csi-controller -n kube-system --replicas=3 

echo "==============================================="
echo " 6. Scale up CoreDNS ......"
echo "==============================================="
kubectl scale deployment coredns -n kube-system --replicas=3

echo "==============================================="
echo " 7. Tune aws-node daemonset for IP efficiency ......"
echo "==============================================="
# Enable prefix delegation to reduce ENI, EC2 throttles. 
# The catch is when subnet becomes fragmented, if IPs were not in contiguous /28 blocks, even if the subnet has enough IPs available, prefix delegation cannot allocate them.
# NOTE: 1 prefix=16 IPs, only 2 prefixes per node are needed in a normal  case. 
# However, to avoid "fragmented subnet", we should assign extra warm IPs or enough warm prefixes if needed.
kubectl set env daemonset aws-node -n kube-system \
ENABLE_PREFIX_DELEGATION=true \
WARM_IP_TARGET=0 \
MINIMUM_IP_TARGET=32 \
WARM_ENI_TARGET=0 \
WARM_PREFIX_TARGET=1 \
ENABLE_IP_COOLDOWN_COUNTING=false

echo "Turn off CNI debug mode to improve node start-up time"
kubectl set env daemonset aws-node -n kube-system \
AWS_VPC_K8S_CNI_LOGLEVEL=INFO \
AWS_VPC_K8S_PLUGIN_LOG_LEVEL=INFO


# echo "==============================================="
# echo " 9. Setup Load Balancer Controller ......"
# echo "==============================================="
# echo "Setup AWS Load Balancer Controller"
# helm repo add eks https://aws.github.io/eks-charts
# helm repo update eks
# helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
#   -n kube-system \
#   --set clusterName=${CLUSTER_NAME} \
#   --set serviceAccount.create=false \
#   --set serviceAccount.name=aws-load-balancer-controller
  
# aws ec2 create-tags \
#     --tags "Key=kubernetes.io/role/elb,Value=1" \
#     --resources "$(aws ec2 describe-subnets --filters 'Name=tag:Name,Values=PublicSubnet*' --query 'Subnets[*].SubnetId')"

echo "==============================================="
echo " 11. Create EMR on EKS Execution Role ......"
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
        },
		{
			"Action": [
                "kms:DescribeKey",
                "kms:Decrypt",
                "kms:GenerateDataKey"
			],
			"Resource": "$KMS_ARN",
			"Effect": "Allow"
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
echo " 19. Create multi-platform Image for Spark benchmark Utility ......"
echo "================================================================="   

echo "Logging into ECR..."
export SRC_ECR_URL=${PUB_ECR_REGISTRY_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com
export ECR_URL=${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin $SRC_ECR_URL
docker pull $SRC_ECR_URL/spark/emr-${EMR_IMAGE_VERSION}:latest

# Custom image on top of the EMR Spark
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_URL
# One-off task: create new ECR repositories
aws ecr create-repository --repository-name eks-spark-benchmark --image-scanning-configuration scanOnPush=true || true

wget -O Dockerfile https://raw.githubusercontent.com/aws-samples/emr-on-eks-benchmark/refs/heads/main/docker/benchmark-util/Dockerfile
# Spark load test image
docker buildx build --platform linux/amd64,linux/arm64 \
-t $ECR_URL/eks-spark-benchmark:emr${EMR_IMAGE_VERSION} \
-f ./Dockerfile \
--build-arg SPARK_BASE_IMAGE=$SRC_ECR_URL/spark/emr-${EMR_IMAGE_VERSION}:latest \
--push .
# Locust image
docker buildx build --platform linux/amd64,linux/arm64 \
-t $ECR_URL/locust \
-f ./locust/Dockerfile \
--push .