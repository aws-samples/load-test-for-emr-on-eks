#!/bin/bash


# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Idempotent provisioning: works for a NEW cluster or an EXISTING one. Each
# component (EKS cluster, gp3 StorageClass, EBS CSI, CoreDNS, ALB controller,
# BinPacking, Prometheus/Grafana, EMR roles, Karpenter) is only created/installed
# if it isn't already present, so re-running fills in only what's missing.

source env.sh

echo "==============================================="
echo " 1. Setup Bucket ......"
echo "==============================================="
# Create S3 bucket for load test
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    echo "S3 bucket $BUCKET_NAME already exists. Skipping creation."
else
    echo "Creating S3 bucket: $BUCKET_NAME"
    if [ "$AWS_REGION" = "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket $BUCKET_NAME \
            --region $AWS_REGION || {
            echo "Error: Failed to create S3 bucket $BUCKET_NAME"
            exit 1
        }
    else
        aws s3api create-bucket \
            --bucket $BUCKET_NAME \
            --region $AWS_REGION \
            --create-bucket-configuration LocationConstraint=$AWS_REGION || {
            echo "Error: Failed to create S3 bucket $BUCKET_NAME"
            exit 1
        }
    fi
    echo "S3 bucket $BUCKET_NAME created successfully."
fi   

echo "==============================================="
echo " 2. Create EKS Cluster ......"
echo "==============================================="
if ! aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} >/dev/null 2>&1; then
    echo "Create EKS Cluster: ${CLUSTER_NAME}"
    cp ./resources/eks-cluster-values.yaml ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml
    sed -i='' 's|${AWS_REGION}|'$AWS_REGION'|g' ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml
    sed -i='' 's|${CLUSTER_NAME}|'$CLUSTER_NAME'|g' ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml
    sed -i='' 's|${EKS_VERSION}|'$EKS_VERSION'|g' ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml
    sed -i='' 's|${EKS_VPC_CIDR}|'$EKS_VPC_CIDR'|g' ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml
    sed -i='' 's|${ACCOUNT_ID}|'$ACCOUNT_ID'|g' ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml 

    eksctl create cluster -f ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml
    aws eks update-kubeconfig  --region ${AWS_REGION} --name ${CLUSTER_NAME}
fi
rm ./resources/*.yaml=

echo "==============================================="
echo " 3. Get OIDC ......"
echo "==============================================="
echo "Get OIDC"
export OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
echo $OIDC_PROVIDER
# Fail fast rather than create a role with an unusable trust policy.
if [ -z "$OIDC_PROVIDER" ]; then
    echo "ERROR: could not resolve OIDC provider for cluster '$CLUSTER_NAME' in region '$AWS_REGION'." >&2
    echo "       Check the cluster name/region; aborting before creating a broken execution role." >&2
    exit 1
fi

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

echo "Adding KMS permissions to EBS CSI driver IAM role for encrypted volumes..."
# Get the EBS CSI driver IAM role name
EBS_CSI_ROLE=$(aws iam list-roles --query "Roles[?contains(RoleName, '${CLUSTER_NAME}') && contains(RoleName, 'ebs-csi')].RoleName" --output text | head -1)
if [ -z "$EBS_CSI_ROLE" ]; then
    echo "Warning: Could not find EBS CSI driver IAM role. Skipping KMS policy attachment."
else
    echo "Found EBS CSI driver role: $EBS_CSI_ROLE"
    
    # Create KMS policy for EBS CSI driver
    cat <<EOF > /tmp/ebs-csi-kms-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kms:CreateGrant",
        "kms:ListGrants",
        "kms:RevokeGrant"
      ],
      "Resource": ["arn:aws:kms:${AWS_REGION}:${ACCOUNT_ID}:key/*"],
      "Condition": {
        "Bool": {
          "kms:GrantIsForAWSResource": "true"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ],
      "Resource": ["arn:aws:kms:${AWS_REGION}:${ACCOUNT_ID}:key/*"]
    }
  ]
}
EOF
    
    # Attach the KMS policy to the EBS CSI driver role
    aws iam put-role-policy \
        --role-name "$EBS_CSI_ROLE" \
        --policy-name EBS-CSI-KMS-Policy \
        --policy-document file:///tmp/ebs-csi-kms-policy.json
    
    echo "KMS policy attached to EBS CSI driver role successfully."
fi

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
# echo " 8. Setup Cluster Autoscaler ......"
# echo "==============================================="
# echo " Setup Cluster Autoscaler for an OPS managed NodeGroup"
# cp ./resources/autoscaler-values.yaml ./resources/autoscaler-values-${CLUSTER_NAME}.yaml
# sed -i='' 's/${CLUSTER_NAME}/'$CLUSTER_NAME'/g' ./resources/autoscaler-values-${CLUSTER_NAME}.yaml
# sed -i='' 's/${AWS_REGION}/'$AWS_REGION'/g' ./resources/autoscaler-values-${CLUSTER_NAME}.yaml

# helm repo update
# helm repo add autoscaler https://kubernetes.github.io/autoscaler
# helm upgrade --install nodescaler autoscaler/cluster-autoscaler -n kube-system --values ./resources/autoscaler-values-${CLUSTER_NAME}.yaml
# echo "Disable the autoscaler before using Karpenter first"
# # Enable it manually later on, when testing the scalability based on the autoscaler.
# kubectl scale deploy/nodescaler-aws-cluster-autoscaler  -n kube-system --replicas=0
# for NODEGROUP in $(aws eks list-nodegroups --cluster-name ${CLUSTER_NAME} \
#     --query 'nodegroups' --output text); do aws eks update-nodegroup-config --cluster-name ${CLUSTER_NAME} \
#     --nodegroup-name ${NODEGROUP} \
#     --scaling-config "minSize=2,maxSize=2,desiredSize=2"
# done
echo "==============================================="
echo " 9. Setup Load Balancer Controller ......"
echo "==============================================="
echo "Setup AWS Load Balancer Controller"
if helm status aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
    echo "AWS Load Balancer Controller already installed. Skipping."
else
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update eks
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
      -n kube-system \
      --set clusterName=${CLUSTER_NAME} \
      --set serviceAccount.create=false \
      --set serviceAccount.name=aws-load-balancer-controller
fi
  
# aws ec2 create-tags \
#     --tags "Key=kubernetes.io/role/elb,Value=1" \
#     --resources "$(aws ec2 describe-subnets --filters 'Name=tag:Name,Values=PublicSubnet*' --query 'Subnets[*].SubnetId')"

echo "==============================================="
echo " 10. Setup BinPacking ......"
echo "==============================================="
echo "Setup BinPacking"
if helm status custom-scheduler-eks -n kube-system >/dev/null 2>&1; then
    echo "BinPacking custom-scheduler-eks already installed. Skipping."
else
    [ -d custom-scheduler-eks ] || git clone https://github.com/aws-samples/custom-scheduler-eks
    helm upgrade --install custom-scheduler-eks custom-scheduler-eks/deploy/charts/custom-scheduler-eks \
    -n kube-system \
    --set eksVersion="$EKS_VERSION" \
    --set schedulerName="custom-scheduler-eks" \
    -f ./resources/binpacking-values.yaml
fi


echo "==============================================="
echo " 11. Create EMR on EKS Execution Role ......"
echo "==============================================="
echo "Create EMR on EKS execution role only"

# Check if the CMK alias exists and create it if necessary
if ! aws kms list-aliases --query "Aliases[?AliasName=='alias/$CMK_ALIAS']" --output text | grep -q "alias/$CMK_ALIAS"; then
    echo "CMK alias $CMK_ALIAS not found. Creating a new CMK..."
    CMK_ID=$(aws kms create-key --description "CMK for Locust PVC Reuse" --query 'KeyMetadata.KeyId' --output text)
    aws kms create-alias --alias-name alias/$CMK_ALIAS --target-key-id $CMK_ID
    echo "CMK created with alias $CMK_ALIAS and Key ID $CMK_ID"
else
    echo "CMK alias $CMK_ALIAS already exists."
fi
export KMS_ARN=$(aws kms describe-key --key-id alias/$CMK_ALIAS --query 'KeyMetadata.Arn' --output text)


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
                "arn:aws:s3:::${BUCKET_NAME}/*",
                "arn:aws:s3:::blogpost-sparkoneks-us-east-1",
                "arn:aws:s3:::blogpost-sparkoneks-us-east-1/*"
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
    },
    {
        "Effect": "Allow",
        "Principal": {
            "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
            "StringLike": {
                "${OIDC_PROVIDER}:sub": "system:serviceaccount:*:emr-containers-sa-*-*-${ACCOUNT_ID}-*"
            }
        }
    }
  ]
}
EOF
    emr_exec_role=$(aws iam create-role --role-name ${EXECUTION_ROLE} --assume-role-policy-document file:///tmp/trust-relationship.json)
    aws iam attach-role-policy --role-name ${EXECUTION_ROLE} --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/${EXECUTION_ROLE_POLICY}
fi

echo "==============================================="
echo " 12. Setup Prometheus ......"
echo "==============================================="
echo "Setup Prometheus"
kubectl create ns prometheus || true

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add kube-state-metrics https://kubernetes.github.io/kube-state-metrics
helm repo update


cp ./resources/monitor/prometheus-values.yaml ./resources/monitor/prometheus-values-${CLUSTER_NAME}.yaml
# Monitoring uses the open-source kube-prometheus-stack with its built-in
# Grafana. We do NOT use Amazon Managed Prometheus/Grafana, so there is no IRSA
# / remote-write config to substitute here.
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack -n prometheus -f  ./resources/monitor/prometheus-values-${CLUSTER_NAME}.yaml --debug
# validate in a web browser - localhost:9090, go to menu of status->targets
# kubectl --namespace prometheus port-forward service/prometheus-kube-prometheus-prometheus 9090

# Install metrics server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

echo "========================================================="
echo " 13. Set up Prometheus ServiceMonitor and PodMonitor ......"
echo "========================================================="
echo "Create Prometheus service monitor and pod monitor"
kubectl apply -f ./resources/monitor/karpenter-svcmonitor.yaml
kubectl apply -f ./resources/monitor/aws-cni-podmonitor.yaml
# # kubectl apply -f ./resources/monitor/ebs-csi-controller-svcmonitor.yaml
kubectl apply -f ./resources/monitor/locust-podmonitor.yaml
echo "================================================================================================================"
echo " Ref to https://karpenter.sh/v1.8/reference/cloudformation/"
echo " 14. Create Karpenter IAM roles, SQS queue and event rules for EC2 interruption handling ......"
echo "================================================================================================================"
# the CFN stack creates Controller Policy, Node Role, SQS Queue and Event Bridge Rules
curl https://raw.githubusercontent.com/aws/karpenter-provider-aws/v"${KARPENTER_VERSION}"/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml > ./resources/karpenter/cloudformation-${KARPENTER_VERSION}.yaml
aws cloudformation deploy \
  --stack-name "karpenter-infra-${CLUSTER_NAME}" \
  --template-file ./resources/karpenter/cloudformation-${KARPENTER_VERSION}.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}" \
  --region $AWS_REGION

# Encrypt all EBS volumes when Karpenter provisions nodes
echo "Creating EBS encryption policy ${EBS_POLICY_NAME} for Karpenter Controller Role"
EBS_POLICY_NAME=KarpenterEBSEncryptionPolicy-${CLUSTER_NAME}
if [ -n "$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${EBS_POLICY_NAME}'].Arn" --output text)" ]; then
    echo "Policy ${EBS_POLICY_NAME} already exists"
else
    cat <<EOF > /tmp/ebs-encryption-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "kms:CreateGrant",
                "kms:Decrypt",
                "kms:DescribeKey",
                "kms:Encrypt",
                "kms:GenerateDataKey",
                "kms:GenerateDataKeyWithoutPlaintext",
                "kms:ReEncrypt*"
            ],
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "kms:ViaService": [
                        "ec2.${AWS_REGION}.amazonaws.com"
                    ]
                }
            }
        }
    ]
}
EOF
    aws iam create-policy --policy-name "${EBS_POLICY_NAME}" \
      --policy-document file:///tmp/ebs-encryption-policy.json \
      --query 'Policy.Arn' \
      --output text
    rm -f /tmp/ebs-encryption-policy.json  
fi

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
                    "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:karpenter"
                }
            }
        }
    ]
}
EOF
    aws iam create-role --role-name "${KARPENTER_CONTROLLER_ROLE}" --assume-role-policy-document file:///tmp/controller-trust.json
    aws iam attach-role-policy --role-name "${KARPENTER_CONTROLLER_ROLE}" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}"
    aws iam attach-role-policy --role-name "${KARPENTER_CONTROLLER_ROLE}" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${EBS_POLICY_NAME}"
fi

echo "=============================================================================================================="
echo " 15. Tag Subnets, SGs for Karpenter ......"
echo "=============================================================================================================="
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

echo "========================================================="
echo " 16. Install Karpenter via Helm Chart ....."
echo "========================================================="
echo "Install Karpenter via Helm Chart"
if kubectl get deployment karpenter -n kube-system >/dev/null 2>&1; then
    echo "Karpenter already installed in kube-system. Skipping helm install + CRDs."
else
helm registry logout public.ecr.aws || true
# Before enable the "interruptionQueue", the SQS queue must exist
helm template karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" --namespace kube-system \
    --set "settings.clusterName=${CLUSTER_NAME}" \
    --set "settings.interruptionQueue=${CLUSTER_NAME}" \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
    --set controller.resources.requests.cpu=2 \
    --set controller.resources.requests.memory=2Gi \
    --set controller.resources.limits.cpu=10 \
    --set controller.resources.limits.memory=20Gi \
    --set webhook.serviceName="karpenter" \
    --set webhook.port=8443 > ./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml
# run Karpenter pods on a managed nodegroup
export NG=$(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $AWS_REGION --output json | jq -r '.nodegroups[0]')
sed -i='' '/operator: DoesNotExist/a\
              - key: eks.amazonaws.com/nodegroup\
                operator: In\
                values:\
                - '"$(eval echo \$NG)"'
' ./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml
# increase livenessProbe to avoid throttling
sed -i='' '/livenessProbe:/,/timeoutSeconds: 30/c\
          livenessProbe:\
            initialDelaySeconds: 30\
            periodSeconds: 30\
            timeoutSeconds: 10\
            failureThreshold: 5\
' ./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml
#crds (apply is idempotent: installs if missing, updates if present)
kubectl apply --server-side -f \
    "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodepools.yaml"
kubectl apply --server-side -f \
    "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml"
kubectl apply --server-side -f \
    "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodeclaims.yaml"
kubectl apply -f ./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml
fi

echo "====================================================="
echo " 17. Create Karpenter Nodepools and nodeclass ......"
echo "====================================================="
echo "Create Karpenter nodepools ......"
# Render the nodeclass placeholders into a per-cluster copy (keeps the template
# reusable), then apply the nodeclass + both nodepools. kubectl apply is
# idempotent, so this is safe to re-run on an existing cluster.
cp ./resources/karpenter/shared-nodeclass.yaml ./resources/karpenter/shared-nodeclass-${CLUSTER_NAME}.yaml
sed -i='' 's/${KARPENTER_NODE_ROLE}/'$KARPENTER_NODE_ROLE'/g' ./resources/karpenter/shared-nodeclass-${CLUSTER_NAME}.yaml
sed -i='' 's/${CLUSTER_NAME}/'$CLUSTER_NAME'/g' ./resources/karpenter/shared-nodeclass-${CLUSTER_NAME}.yaml
rm -f ./resources/karpenter/*=
kubectl apply \
    -f ./resources/karpenter/shared-nodeclass-${CLUSTER_NAME}.yaml \
    -f ./resources/karpenter/driver-nodepool.yaml \
    -f ./resources/karpenter/executor-nodepool.yaml

# Add authorized entry for Karpenter node role (idempotent)
aws eks describe-access-entry --cluster-name ${CLUSTER_NAME} \
    --principal-arn arn:aws:iam::${ACCOUNT_ID}:role/${KARPENTER_NODE_ROLE} >/dev/null 2>&1 \
    || aws eks create-access-entry --cluster-name ${CLUSTER_NAME} \
        --principal-arn arn:aws:iam::${ACCOUNT_ID}:role/${KARPENTER_NODE_ROLE} --type EC2_LINUX

echo "================================================================="
echo " 19. Create multi-platform Image for Spark benchmark Utility ......"
echo "================================================================="   

echo "Logging into ECR..."
# Source ECR for the base/benchmark images. Defaults to the public ECR; override
# SRC_ECR_URL (including ecr repo URL and image name) for internal testing,
# e.g. the Spark Connect image repo from the PenTester runbook.
export SRC_ECR_URL=${SRC_ECR_URL:-public.ecr.aws/myang-poc/eks-spark-benchmark:emr}
export ECR_URL=${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
echo "Logging into ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_URL

# --- Locust image -------------------------------------------------------
# Ensure the repo exists (idempotent), then ALWAYS (re)build & push the image
# -- repo existence must NOT skip the build, or the image is never produced.
aws ecr describe-repositories --repository-names locust >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name locust --image-scanning-configuration scanOnPush=true
docker run --privileged --rm tonistiigi/binfmt --install all
# Create the multi-arch builder if it doesn't already exist, then select it.
docker buildx use arm64-builder 2>/dev/null \
    || docker buildx create --name arm64-builder --driver docker-container --use
docker buildx build --platform linux/amd64,linux/arm64 \
    -t $ECR_URL/locust:latest \
    -f ./locust/Dockerfile \
    --push .
echo "Pushed $ECR_URL/locust:latest"

# --- Spark benchmark image(s) ------------------------------------------
# Ensure the repo exists (idempotent), then ALWAYS copy the requested
# EMR_VERSIONS from SRC_ECR_URL -- existing repo must NOT short-circuit.
aws ecr describe-repositories --repository-names eks-spark-benchmark >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name eks-spark-benchmark --image-scanning-configuration scanOnPush=true
# EMR_VERSIONS may be set via env.sh / the environment; default if unset.
if [ -z "${EMR_VERSIONS:-}" ]; then
    export EMR_VERSIONS=("6.10.0" "7.3.0" "7.9.0")
fi
for version in "${EMR_VERSIONS[@]}"; do
    docker buildx imagetools create \
        --tag "$ECR_URL/eks-spark-benchmark:emr${version}" \
        "$SRC_ECR_URL${version}"
    echo "Copied $ECR_URL/eks-spark-benchmark:emr${version} with all architectures"
done
echo "Infrastructure provision is completed."
