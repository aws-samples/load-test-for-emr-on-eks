#!/bin/bash


# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

source env.sh

echo "==============================================="
echo "  Setup Bucket ......"
echo "==============================================="

echo "Creating S3 bucket: $BUCKET_NAME"
aws s3api create-bucket \
    --bucket $BUCKET_NAME \
    --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_REGION || {
    echo "Error: Failed to create S3 bucket $BUCKET_NAME"
    exit 1
}

# Upload the testing pyspark code
aws s3 cp ./locust/resources/custom-spark-pi.py "s3://${BUCKET_NAME}/testing-code/custom-spark-pi.py"

# Update the testing spark job yaml config
sed -i '' 's|${BUCKET_NAME}|'$BUCKET_NAME'|g' ./resources/spark-pi.yaml
sed -i '' 's|${SPARK_VERSION}|'$SPARK_VERSION'|g' ./resources/spark-pi.yaml
sed -i '' 's|${EMR_IMAGE_URL}|'$EMR_IMAGE_URL'|g' ./resources/spark-pi.yaml



echo "==============================================="
echo "  Create EKS Cluster ......"
echo "==============================================="

# Create CloudFormation stack for Karpenter resources
echo "Creating CloudFormation stack for Karpenter resources..."
curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v"${KARPENTER_VERSION}"/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml > /tmp/karpenter-cf.yaml

aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file /tmp/karpenter-cf.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"



if ! aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} >/dev/null 2>&1; then
    sed -i '' 's|${AWS_REGION}|'$AWS_REGION'|g' ./resources/eks-cluster-values.yaml
    sed -i '' 's|${CLUSTER_NAME}|'$CLUSTER_NAME'|g' ./resources/eks-cluster-values.yaml
    sed -i '' 's|${EKS_VERSION}|'$EKS_VERSION'|g' ./resources/eks-cluster-values.yaml
    sed -i '' 's|${EKS_VPC_CIDR}|'$EKS_VPC_CIDR'|g' ./resources/eks-cluster-values.yaml
    sed -i '' 's|${LOAD_TEST_PREFIX}|'$LOAD_TEST_PREFIX'|g' ./resources/eks-cluster-values.yaml
    sed -i '' 's|${ACCOUNT_ID}|'$ACCOUNT_ID'|g' ./resources/eks-cluster-values.yaml
    eksctl create cluster -f ./resources/eks-cluster-values.yaml
fi


# Create service linked role for EC2 Spot if it doesn't exist
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true


export OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
echo $OIDC_PROVIDER


# Get VPC ID and subnets
VPC_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.resourcesVpcConfig.vpcId" --output text)

aws ec2 associate-vpc-cidr-block --vpc-id $VPC_ID --cidr-block $EKS_VPC_CIDR_SECONDARY

BASE_PREFIX=$(echo $EKS_VPC_CIDR_SECONDARY | cut -d/ -f1 | cut -d. -f1-2)

SUBNET_A="${BASE_PREFIX}.0.0/17"
SUBNET_B="${BASE_PREFIX}.128.0/17"

# Create subnet in zone a
NEW_SUBNET_a=$(
aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block $SUBNET_A \
  --availability-zone ${AWS_REGION}a \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=\"$CLUSTER_NAME-cluster/private-secondary-a\"},{Key=Type,Value=private},{Key=\"eksctl.cluster.k8s.io/v1alpha1/cluster-name\",Value=\"$CLUSTER_NAME\"}]" \
  --query Subnet.SubnetId --output text)

# Create subnet in zone b
NEW_SUBNET_b=$(
aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block $SUBNET_B \
  --availability-zone ${AWS_REGION}b \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=\"$CLUSTER_NAME-cluster/private-secondary-b\"},{Key=Type,Value=private},{Key=\"eksctl.cluster.k8s.io/v1alpha1/cluster-name\",Value=\"$CLUSTER_NAME\"}]" \
  --query Subnet.SubnetId --output text)


ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=\"$CLUSTER_NAME-cluster/private-rt-secondary\"},{Key=\"eksctl.cluster.k8s.io/v1alpha1/cluster-name\",Value=\"$CLUSTER_NAME\"}]" \
  --query 'RouteTable.RouteTableId' --output text)


aws ec2 associate-route-table --route-table-id $ROUTE_TABLE_ID --subnet-id $NEW_SUBNET_a
aws ec2 associate-route-table --route-table-id $ROUTE_TABLE_ID --subnet-id $NEW_SUBNET_b


kubectl set env daemonset aws-node -n kube-system AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true
kubectl set env daemonset aws-node -n kube-system ENI_CONFIG_LABEL_DEF=topology.kubernetes.io/zone

cluster_security_group_id=$(aws eks describe-cluster --name $CLUSTER_NAME --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)

kubectl apply -f - <<EOF
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata:
  name: "${AWS_REGION}a"
spec:
  securityGroups:
    - "$cluster_security_group_id"
  subnet: "$NEW_SUBNET_a"
EOF

# Create ENIConfig for zone b
kubectl apply -f - <<EOF
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata:
  name: "${AWS_REGION}b"
spec:
  securityGroups:
    - "$cluster_security_group_id"
  subnet: "$NEW_SUBNET_b"
EOF


kubectl get ENIConfigs


NAT_GATEWAY_ID=$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
  --query "NatGateways[0].NatGatewayId" \
  --output text)

if [ -n "$NAT_GATEWAY_ID" ]; then
  aws ec2 create-route \
    --route-table-id $ROUTE_TABLE_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id $NAT_GATEWAY_ID
else
  echo "Unable to find NAT Gateway, please check VPC Configs"
fi


# Tag security groups and subnets for Karpenter discovery
echo "Tagging resources for Karpenter discovery..."
SECURITY_GROUPS=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} \
    --query 'cluster.resourcesVpcConfig.securityGroupIds[*]' \
    --output text)

CLUSTER_SG=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
    --output text)

# Tag each security group
for SG in ${SECURITY_GROUPS} ${CLUSTER_SG}; do
    echo "Tagging security group: $SG"
    aws ec2 create-tags \
        --resources "$SG" \
        --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" || true
done

# Get subnets and tag each one individually
for SUBNET_ID in $(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[*].SubnetId" \
    --output text); do
    echo "Tagging subnet: $SUBNET_ID"
    aws ec2 create-tags \
        --resources "$SUBNET_ID" \
        --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" || true
done

# Install Karpenter CRDs
echo "Installing Karpenter CRDs..."
kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodeclaims.yaml
kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodepools.yaml

# Install Karpenter controller via Helm
echo "Installing Karpenter controller..."
helm registry logout public.ecr.aws || true

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version ${KARPENTER_VERSION} \
  --namespace ${KARPENTER_NAMESPACE} \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --set "controller.nodeSelector.operational=true" \
  --wait

subnet_1_priv=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=false" --query 'Subnets[*].SubnetId' --output text | awk '{print $1}')
subnet_2_priv=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=false" --query 'Subnets[*].SubnetId' --output text | awk '{print $2}')

# Create NodePools for Karpenter:
export ALIAS_VERSION="$(aws ssm get-parameter --name "/aws/service/eks/optimized-ami/${EKS_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" --query Parameter.Value | xargs aws ec2 describe-images --query 'Images[0].Name' --image-ids | sed -r 's/^.*(v[[:digit:]]+).*$/\1/')"

sed -i '' 's/${AWS_REGION}/'$AWS_REGION'/g' ./resources/karpenter-nodepool.yaml
sed -i '' 's/${CLUSTER_NAME}/'$CLUSTER_NAME'/g' ./resources/karpenter-nodepool.yaml
sed -i '' 's/${ALIAS_VERSION}/'$ALIAS_VERSION'/g' ./resources/karpenter-nodepool.yaml
sed -i '' 's/${private_subnet_1}/'$subnet_1_priv'/g' ./resources/karpenter-nodepool.yaml
sed -i '' 's/${private_subnet_2}/'$subnet_2_priv'/g' ./resources/karpenter-nodepool.yaml
sed -i '' 's/${new_private_subnet_1}/'$NEW_SUBNET_a'/g' ./resources/karpenter-nodepool.yaml
sed -i '' 's/${new_private_subnet_2}/'$NEW_SUBNET_b'/g' ./resources/karpenter-nodepool.yaml


kubectl apply -f ./resources/karpenter-nodepool.yaml

echo "Karpenter installation complete!"



echo "==============================================="
echo "  Setup Prometheus ......"
echo "==============================================="

# Check and create IAM Policy
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${AMP_SERVICE_ACCOUNT_IAM_INGEST_POLICY}" 2>/dev/null; then
    echo "Policy ${AMP_SERVICE_ACCOUNT_IAM_INGEST_POLICY} already exists"
else
    echo "Creating policy ${AMP_SERVICE_ACCOUNT_IAM_INGEST_POLICY}..."
    cat <<EOF > /tmp/PermissionPolicyIngest.json
{
  "Version": "2012-10-17",
   "Statement": [
       {"Effect": "Allow",
        "Action": [
           "aps:RemoteWrite", 
           "aps:GetSeries", 
           "aps:GetLabels",
           "aps:GetMetricMetadata"
        ], 
        "Resource": "*"
      }
   ]
}
EOF
    aws iam create-policy --policy-name ${AMP_SERVICE_ACCOUNT_IAM_INGEST_POLICY} --policy-document file:///tmp/PermissionPolicyIngest.json
fi

sleep 5
# Check and create IAM Role
if aws iam get-role --role-name "${AMP_SERVICE_ACCOUNT_IAM_INGEST_ROLE}" >/dev/null 2>&1; then
    echo "Role ${AMP_SERVICE_ACCOUNT_IAM_INGEST_ROLE} already exists"
else
    echo "Creating role ${AMP_SERVICE_ACCOUNT_IAM_INGEST_ROLE}..."
    cat <<EOF > /tmp/TrustPolicyIngest.json
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
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:prometheus:amp-iamproxy-ingest-service-account"
        }
      }
    }
  ]
}
EOF
    aws iam create-role --role-name ${AMP_SERVICE_ACCOUNT_IAM_INGEST_ROLE} --assume-role-policy-document file:///tmp/TrustPolicyIngest.json
    aws iam attach-role-policy --role-name ${AMP_SERVICE_ACCOUNT_IAM_INGEST_ROLE} --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${AMP_SERVICE_ACCOUNT_IAM_INGEST_POLICY}"
fi



kubectl create namespace prometheus --dry-run=client -o yaml | kubectl apply -f -

amp=$(aws amp list-workspaces --query "workspaces[?alias=='${CLUSTER_NAME}'].workspaceId" --output text)
if [ -z "$amp" ]; then
    echo "Creating a new prometheus workspace..."
    export WORKSPACE_ID=$(aws amp create-workspace --alias ${CLUSTER_NAME} --query workspaceId --output text)
else
    echo "A prometheus workspace already exists"
    export WORKSPACE_ID=$amp
fi

sed -i '' 's/{AWS_REGION}/'$AWS_REGION'/g' ./resources/prometheus-values.yaml
sed -i '' 's/{ACCOUNTID}/'$ACCOUNT_ID'/g' ./resources/prometheus-values.yaml
sed -i '' 's/{WORKSPACE_ID}/'$WORKSPACE_ID'/g' ./resources/prometheus-values.yaml
sed -i '' 's/{LOAD_TEST_PREFIX}/'$LOAD_TEST_PREFIX'/g' ./resources/prometheus-values.yaml


helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack -n prometheus -f ./resources/prometheus-values.yaml


# # Setup Prometheus with Karpenter dashboards
# echo "Setting up Prometheus with Karpenter dashboards..."

# # Create monitoring namespace if not exists
# kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# # Download Karpenter monitoring configurations
# curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v"${KARPENTER_VERSION}"/website/content/en/preview/getting-started/getting-started-with-karpenter/prometheus-values.yaml > ./resources/prometheus-values.yaml
# curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v"${KARPENTER_VERSION}"/website/content/en/preview/getting-started/getting-started-with-karpenter/grafana-values.yaml > ./resources/grafana-values.yaml

# # Update Prometheus values
# sed -i '' 's/{AWS_REGION}/'$AWS_REGION'/g' ./resources/prometheus-values.yaml
# sed -i '' 's/{ACCOUNTID}/'$ACCOUNT_ID'/g' ./resources/prometheus-values.yaml
# sed -i '' 's/{WORKSPACE_ID}/'$WORKSPACE_ID'/g' ./resources/prometheus-values.yaml
# sed -i '' 's/{LOAD_TEST_PREFIX}/'$LOAD_TEST_PREFIX'/g' ./resources/prometheus-values.yaml

# # Install Prometheus and Grafana with Karpenter dashboards
# helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
# helm repo add grafana-charts https://grafana.github.io/helm-charts
# helm repo update

# helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
#   -n monitoring \
#   -f ./resources/prometheus-values.yaml

# helm upgrade --install grafana grafana-charts/grafana \
#   -n monitoring \
#   -f ./resources/grafana-values.yaml

echo "==============================================="
echo "  Setup BinPacking ......"
echo "==============================================="

kubectl apply -f ./resources/binpacking-values.yaml



echo "==============================================="
echo "  Setup Spark Operator ......"
echo "Spark Operator Testing Mode: ${OPERATOR_TEST_MODE}" Operators
echo "Number of Job namespaces: ${SPARK_JOB_NS_NUM}"
echo "==============================================="


# Create S3 access policy if it doesn't exist
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${SPARK_OPERATOR_POLICY}" 2>/dev/null; then
    echo "IAM policy ${SPARK_OPERATOR_POLICY} already exists"
else
    cat <<EOF > /tmp/spark-job-s3-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:*"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}",
                "arn:aws:s3:::${BUCKET_NAME}/*"
            ]
        }
    ]
}
EOF
    aws iam create-policy --policy-name ${SPARK_OPERATOR_POLICY} --policy-document file:///tmp/spark-job-s3-policy.json
fi

if aws iam get-role --role-name "$SPARK_OPERATOR_ROLE" 2>/dev/null; then
    echo "IAM role ${SPARK_OPERATOR_ROLE} already exists"
else
    echo "Creating IAM role ${SPARK_OPERATOR_ROLE}..."
    cat <<EOF > /tmp/trust-relationship.json
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
        "StringLike": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:spark-job*:spark-job-sa*"
        }
      }
    }
  ]
}
EOF
    aws iam create-role --role-name ${SPARK_OPERATOR_ROLE} --assume-role-policy-document file:///tmp/trust-relationship.json
    aws iam attach-role-policy --role-name ${SPARK_OPERATOR_ROLE} --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/${SPARK_OPERATOR_POLICY}
fi

# ECR Login
echo "Logging into ECR..."
aws ecr get-login-password \
--region ${AWS_REGION} | helm registry login \
--username AWS \
--password-stdin ${ECR_REGISTRY_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com


# Create namespace and service accounts
echo "Creating spark-operator namespace..."
kubectl create namespace spark-operator --dry-run=client -o yaml | kubectl apply -f -

for i in $(seq 0 $((SPARK_JOB_NS_NUM-1)))
do
    echo "Setting up namespace spark-job$i..."
    # Create namespace
    kubectl create namespace spark-job$i --dry-run=client -o yaml | kubectl apply -f -
    
    # Create service accounts
    kubectl create serviceaccount spark-job-sa$i -n spark-job$i --dry-run=client -o yaml | kubectl apply -f -
    kubectl create serviceaccount emr-containers-sa-spark -n spark-job$i --dry-run=client -o yaml | kubectl apply -f -
    
    # Annotate service accounts
    kubectl annotate serviceaccount -n spark-job$i spark-job-sa$i \
        eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/${SPARK_OPERATOR_ROLE} --overwrite
    kubectl annotate serviceaccount -n spark-job$i emr-containers-sa-spark \
        eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/${SPARK_OPERATOR_ROLE} --overwrite

    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: spark-job-sa$i-binding
  namespace: spark-job$i
subjects:
- kind: ServiceAccount
  name: spark-job-sa$i
  namespace: spark-job$i
- kind: ServiceAccount
  name: emr-containers-sa-spark
  namespace: spark-job$i
roleRef:
  kind: Role
  name: spark-role
  apiGroup: rbac.authorization.k8s.io
EOF
done

if [ "$OPERATOR_TEST_MODE" = "multiple" ]; then
    # For multiple Operators
    echo "Installing multiple operators..."
    
    # Install operators (Helm will create the necessary roles), comments as current limitation. Bug fix with TT: https://t.corp.amazon.com/P239850734/overview
    # for i in $(seq 0 $((SPARK_JOB_NS_NUM-1)))
    # do
    #     echo "Installing spark-operator$i..."
    #     helm install spark-operator$i \
    #         oci://${ECR_REGISTRY_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/spark-operator \
    #         --version ${SPARK_OPERATOR_VERSION} \
    #         --namespace spark-operator \
    #         --set sparkJobNamespace=spark-job$i \
    #         --set rbac.create=true \
    #         --set serviceAccounts.sparkoperator.create=true \
    #         --set serviceAccounts.sparkoperator.name=spark-operator-sa$i \
    #         --set serviceAccounts.spark.create=false \
    #         --set nameOverride=spark-operator$i \
    #         --set fullnameOverride=spark-operator$i \
    #         --set emrContainers.awsRegion=${AWS_REGION} \
    #         -f ./resources/spark-operator-values.yaml
    # done

    mkdir -p custom-spark-operator
    helm pull oci://895885662937.dkr.ecr.us-west-2.amazonaws.com/spark-operator --version 7.7.0 --untar -d custom-spark-operator
    cd custom-spark-operator/spark-operator
    perl -i -pe 's/name: emr-eks-region-to-account-lookup/name: {{ include "spark-operator.fullname" . }}-region-lookup/g' templates/deployment.yaml
    perl -i -pe 's/configMap:\n\s+name: emr-eks-region-to-account-lookup/configMap:\n      name: {{ include "spark-operator.fullname" . }}-region-lookup/g' templates/deployment.yaml
    helm template test-operator . --namespace spark-operator > rendered.yaml
    cd ../../
    helm package ./custom-spark-operator/spark-operator -d .


    # Install multiple instances
    for i in $(seq 0 $((SPARK_JOB_NS_NUM-1)))
    do
        echo "Installing spark-operator$i..."
        helm install spark-operator$i \
            ./spark-operator-7.7.0.tgz \
            --namespace spark-operator \
            --set sparkJobNamespace=spark-job$i \
            --set rbac.create=true \
            --set serviceAccounts.sparkoperator.create=true \
            --set serviceAccounts.sparkoperator.name=spark-operator-sa$i \
            --set serviceAccounts.spark.create=false \
            --set nameOverride=spark-operator$i \
            --set fullnameOverride=spark-operator$i \
            --set emrContainers.awsRegion=${AWS_REGION} \
            -f ./resources/spark-operator-values.yaml
    done

    echo "Waiting for operators to be ready..."
    for i in $(seq 0 $((SPARK_JOB_NS_NUM-1)))
    do
        kubectl rollout status deployment/spark-operator$i -n spark-operator --timeout=120s
    done

    for i in $(seq 0 $((SPARK_JOB_NS_NUM-1)))
    do
        echo "Creating rolebinding for spark-operator$i..."
        kubectl create rolebinding spark-operator$i-rb-spark-job$i \
            --clusterrole=spark-operator$i \
            --serviceaccount=spark-operator:spark-operator-sa$i \
            --namespace=spark-job$i \
            --dry-run=client -o yaml | kubectl apply -f -
    done

else
    # One spark-operator0 operator for multiple namespace
    echo "Installing single operator..."
    
    for i in $(seq 0 $((SPARK_JOB_NS_NUM-1)))
    do
        cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: spark-role
  namespace: spark-job$i
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "persistentvolumeclaims"]
  verbs: ["create", "get", "list", "watch", "update", "delete"]
- apiGroups: ["sparkoperator.k8s.io"]
  resources: ["sparkapplications", "scheduledsparkapplications"]
  verbs: ["create", "get", "list", "watch", "update", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: spark-role-binding
  namespace: spark-job$i
subjects:
- kind: ServiceAccount
  name: spark-job-sa$i
  namespace: spark-job$i
roleRef:
  kind: Role
  name: spark-role
  apiGroup: rbac.authorization.k8s.io
EOF
    done

    helm install spark-operator0 \
        oci://${ECR_REGISTRY_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/spark-operator \
        --version ${SPARK_OPERATOR_VERSION} \
        --namespace spark-operator \
        --set rbac.create=true \
        --set serviceAccounts.sparkoperator.create=true \
        --set serviceAccounts.sparkoperator.name=spark-operator-sa0 \
        --set serviceAccounts.spark.create=false \
        --set nameOverride=spark-operator0 \
        --set fullnameOverride=spark-operator0 \
        --set sparkJobNamespace="" \
        -f /tmp/spark-operator-installation-values.yaml
fi


echo "Spark operator installation completed"


echo "==============================================="
echo "  Setup Locust for Spark Operator Testing ......"
echo "==============================================="


# Create the Required Namespace and Service Account
kubectl create namespace locust --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: locust-spark-submitter
  namespace: locust
EOF

# Create roles and rolebindings for each Spark namespace
for i in $(seq 0 $((SPARK_JOB_NS_NUM-1)))
do
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: spark-submitter-role
  namespace: spark-job$i
rules:
- apiGroups: ["sparkoperator.k8s.io"]
  resources: ["sparkapplications"]
  verbs: ["get", "list", "create", "delete", "watch"]
- apiGroups: [""]
  resources: ["pods", "pods/log", "services"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: locust-spark-submitter-binding
  namespace: spark-job$i
subjects:
- kind: ServiceAccount
  name: locust-spark-submitter
  namespace: locust
roleRef:
  kind: Role
  name: spark-submitter-role
  apiGroup: rbac.authorization.k8s.io
EOF
done


sed -i '' 's|SPARK_JOB_NS_NUM|'$SPARK_JOB_NS_NUM'|g' ./resources/locust-spark-submit.py

# Create ConfigMap with the test script and Spark job template
kubectl delete configmap spark-locust-scripts -n locust --ignore-not-found
kubectl create configmap spark-locust-scripts \
  --from-file=locust-spark-submit.py=./resources/locust-spark-submit.py \
  --from-file=spark-pi.yaml=./resources/spark-pi.yaml \
  -n locust


# Apply deployment
kubectl apply -f ./resources/locust-deployment.yaml

echo "==============================================="
echo "  Locust setup completed ......"
echo "==============================================="


echo "==============================================="
echo "  Set up Prometheus ServiceMonitor and PodMonitor ......"
echo "==============================================="

cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: karpenter-monitor
  namespace: prometheus
  labels:
    release: prometheus
spec:
  namespaceSelector:
    matchNames:
    - kube-system
  selector:
    matchLabels:
      app.kubernetes.io/name: karpenter
  endpoints:
    - port: http-metrics
      interval: 15s
      path: /metrics
EOF

cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: aws-cni-metrics
  namespace: prometheus
spec:
  jobLabel: k8s-app
  namespaceSelector:
    matchNames:
    - kube-system
  podMetricsEndpoints:
  - interval: 30s
    path: /metrics
    port: metrics
  selector:
    matchLabels:
      k8s-app: aws-node
EOF


cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: locust-exporter-monitor
  namespace: prometheus
  labels:
    release: prometheus
spec:
  namespaceSelector:
    matchNames:
    - locust
  selector:
    matchLabels:
      app: locust-exporter
  endpoints:
    - port: metrics
      interval: 15s
EOF


kubectl apply -f ./resources/locust-exporter-deployment.yaml

if [[ $USE_AMG == "true" ]]
then 
    # Create AMG
    echo "==============================================="
    echo "  Set up Amazon Managed Grafana ......"
    echo "==============================================="
    # create grafana service role policy
    aws iam create-policy --policy-name ${LOAD_TEST_PREFIX}-grafana-service-role-policy --policy-document file://./grafana/grafana-service-role-policy.json \
    && export grafana_service_role_policy_arn=$(aws iam list-policies --query 'Policies[?PolicyName==`'${LOAD_TEST_PREFIX}-grafana-service-role-policy'`].Arn' --output text)
    if [[ $$grafana_service_role_policy_arn != "" ]]
    then 
        echo "Create AWS Managed Grafana service role policy $grafana_service_role_policy_arn"
    fi 

    # create grafana service role
    sed -i '' "s/\${ACCOUNT_ID}/$ACCOUNT_ID/g" ./grafana/grafana-service-role-assume-policy.json
    sed -i '' "s/\${AWS_REGION}/$AWS_REGION/g" ./grafana/grafana-service-role-assume-policy.json

    aws iam create-role --role-name ${LOAD_TEST_PREFIX}-grafana-service-role \
        --assume-role-policy-document file://./grafana/grafana-service-role-assume-policy.json \
        --tags Key=Name,Value=${LOAD_TEST_PREFIX}-grafana-service-role && \
        export grafana_service_role_arn=$(aws iam list-roles --query 'Roles[?RoleName==`'${LOAD_TEST_PREFIX}-grafana-service-role'`].Arn' --output text)
    
    if [[ $grafana_service_role_arn != "" ]]
    then 
        echo "Created AWS Managed Grafana service role $grafana_service_role_arn" 
    fi

    aws iam attach-role-policy --role-name  ${LOAD_TEST_PREFIX}-grafana-service-role --policy-arn $grafana_service_role_policy_arn \
    && echo "Attached policy $grafana_service_role_policy_arn to role ${LOAD_TEST_PREFIX}-grafana-service-role"

    # create grafana workspace in public network
    aws grafana create-workspace --workspace-name ${LOAD_TEST_PREFIX} --account-access-type CURRENT_ACCOUNT --authentication-providers AWS_SSO --permission-type SERVICE_MANAGED --workspace-role-arn $grafana_service_role_arn --region $AWS_REGION \
    && export grafana_workspace_id=$(aws grafana list-workspaces --query 'workspaces[?name==`'${LOAD_TEST_PREFIX}'`].id' --region $AWS_REGION --output text)
    if [[ $grafana_workspace_id != "" ]]
    then 
        echo "Created AWS Manged Grafana workspace $grafana_workspace_id"
    fi
fi

# AI Agents Setup (Optional)
if [[ $AI_AGENTS_ENABLED == "true" ]]
then
    echo "==============================================="
    echo "  Setup AI Agents for LLM-Powered Job Management"
    echo "==============================================="
    
    # Create ECR repository for agent images
    echo "Creating ECR repository for AI agents..."
    if ! aws ecr describe-repositories --repository-names "${AGENT_ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1; then
        aws ecr create-repository \
            --repository-name "${AGENT_ECR_REPO}" \
            --region "${AWS_REGION}" \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256
        echo "✅ ECR repository created: ${AGENT_ECR_REPO}"
    else
        echo "ECR repository ${AGENT_ECR_REPO} already exists"
    fi
    
    # Create SQS queues for job management
    echo "Creating SQS queues for job management..."
    
    # Create Dead Letter Queue first
    aws sqs create-queue \
        --queue-name "${SQS_DLQ}" \
        --attributes '{
            "FifoQueue": "true",
            "ContentBasedDeduplication": "true",
            "VisibilityTimeout": "60",
            "MessageRetentionPeriod": "1209600",
            "ReceiveMessageWaitTimeSeconds": "20"
        }' \
        --region ${AWS_REGION} >/dev/null 2>&1 || echo "DLQ already exists"
    
    # Get DLQ ARN for redrive policy
    DLQ_URL=$(aws sqs get-queue-url --queue-name "${SQS_DLQ}" --region ${AWS_REGION} --query 'QueueUrl' --output text)
    DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "${DLQ_URL}" --attribute-names QueueArn --region ${AWS_REGION} --query 'Attributes.QueueArn' --output text)
    
    # Create priority queues with DLQ
    for queue in "${SQS_HIGH_PRIORITY_QUEUE}" "${SQS_MEDIUM_PRIORITY_QUEUE}" "${SQS_LOW_PRIORITY_QUEUE}"; do
        aws sqs create-queue \
            --queue-name "${queue}" \
            --attributes '{
                "FifoQueue": "true",
                "ContentBasedDeduplication": "true",
                "VisibilityTimeout": "300",
                "MessageRetentionPeriod": "1209600",
                "ReceiveMessageWaitTimeSeconds": "20",
                "RedrivePolicy": "{\"deadLetterTargetArn\":\"'${DLQ_ARN}'\",\"maxReceiveCount\":3}"
            }' \
            --region ${AWS_REGION} >/dev/null 2>&1 || echo "Queue $queue already exists"
    done
    echo "✅ SQS queues created"
    
    # Create IAM policies for agents
    echo "Creating IAM policies for AI agents..."
    
    # SQS Agent Policy
    cat > /tmp/sqs-agent-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sqs:SendMessage",
                "sqs:ReceiveMessage",
                "sqs:DeleteMessage",
                "sqs:GetQueueAttributes",
                "sqs:GetQueueUrl",
                "sqs:ChangeMessageVisibility"
            ],
            "Resource": [
                "arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${SQS_HIGH_PRIORITY_QUEUE}",
                "arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${SQS_MEDIUM_PRIORITY_QUEUE}",
                "arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${SQS_LOW_PRIORITY_QUEUE}",
                "arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${SQS_DLQ}"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "cloudwatch:PutMetricData",
                "cloudwatch:GetMetricStatistics",
                "cloudwatch:ListMetrics"
            ],
            "Resource": "*"
        }
    ]
}
EOF
    
    aws iam create-policy \
        --policy-name "${SQS_AGENT_POLICY}" \
        --policy-document file:///tmp/sqs-agent-policy.json \
        --description "Policy for AI agents to access SQS queues" >/dev/null 2>&1 || echo "SQS policy already exists"
    
    # Bedrock Agent Policy
    cat > /tmp/bedrock-agent-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "bedrock:InvokeModel",
                "bedrock:InvokeModelWithResponseStream"
            ],
            "Resource": [
                "arn:aws:bedrock:${AWS_REGION}::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0",
                "arn:aws:bedrock:${AWS_REGION}::foundation-model/anthropic.claude-3-haiku-20240307-v1:0"
            ]
        }
    ]
}
EOF
    
    aws iam create-policy \
        --policy-name "${BEDROCK_AGENT_POLICY}" \
        --policy-document file:///tmp/bedrock-agent-policy.json \
        --description "Policy for AI agents to access Bedrock models" >/dev/null 2>&1 || echo "Bedrock policy already exists"
    
    # Agent Policy
    cat > /tmp/agent-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "cloudwatch:GetMetricStatistics",
                "cloudwatch:ListMetrics",
                "cloudwatch:PutMetricData"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "logs:DescribeLogGroups",
                "logs:DescribeLogStreams",
                "logs:FilterLogEvents"
            ],
            "Resource": [
                "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/aws/eks/${CLUSTER_NAME}/*",
                "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:*spark*",
                "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:*karpenter*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "eks:DescribeCluster",
                "eks:ListClusters"
            ],
            "Resource": "*"
        }
    ]
}
EOF
    
    aws iam create-policy \
        --policy-name "${AGENT_POLICY}" \
        --policy-document file:///tmp/agent-policy.json \
        --description "Policy for AI agents to access AWS services" >/dev/null 2>&1 || echo "Agent policy already exists"
    
    # Create IAM role for agents
    echo "Creating IAM role for AI agents..."
    cat > /tmp/agent-trust-policy.json << EOF
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
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${AGENT_NAMESPACE}:spark-agents-sa",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
    
    aws iam create-role \
        --role-name "${AGENT_ROLE}" \
        --assume-role-policy-document file:///tmp/agent-trust-policy.json \
        --description "IAM role for AI agents in EKS cluster" >/dev/null 2>&1 || echo "Agent role already exists"
    
    # Attach policies to role
    aws iam attach-role-policy --role-name "${AGENT_ROLE}" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${AGENT_POLICY}" >/dev/null 2>&1 || true
    aws iam attach-role-policy --role-name "${AGENT_ROLE}" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${SQS_AGENT_POLICY}" >/dev/null 2>&1 || true
    aws iam attach-role-policy --role-name "${AGENT_ROLE}" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${BEDROCK_AGENT_POLICY}" >/dev/null 2>&1 || true
    
    echo "✅ IAM roles and policies created"
    
    # Create Kubernetes namespace and RBAC for agents
    echo "Creating Kubernetes resources for AI agents..."
    kubectl create namespace "${AGENT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create serviceaccount spark-agents-sa -n "${AGENT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    
    # Annotate service account with IAM role
    kubectl annotate serviceaccount -n "${AGENT_NAMESPACE}" spark-agents-sa \
        eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/${AGENT_ROLE} --overwrite
    
    # Create cluster role for agents
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: spark-agents-cluster-role
rules:
- apiGroups: [""]
  resources: ["nodes", "pods", "services", "endpoints", "namespaces"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["nodes", "pods"]
  verbs: ["get", "list"]
- apiGroups: ["sparkoperator.k8s.io"]
  resources: ["sparkapplications", "scheduledsparkapplications"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: spark-agents-cluster-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: spark-agents-cluster-role
subjects:
- kind: ServiceAccount
  name: spark-agents-sa
  namespace: ${AGENT_NAMESPACE}
EOF
    
    # Deploy Redis for inter-agent communication
    echo "Deploying Redis for inter-agent communication..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-agents
  namespace: ${AGENT_NAMESPACE}
  labels:
    app: redis-agents
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-agents
  template:
    metadata:
      labels:
        app: redis-agents
    spec:
      nodeSelector:
        operational: "true"
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
          name: redis
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        command:
        - redis-server
        - --appendonly
        - "yes"
        - --maxmemory
        - "100mb"
        - --maxmemory-policy
        - "allkeys-lru"
        volumeMounts:
        - name: redis-data
          mountPath: /data
      volumes:
      - name: redis-data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: redis-agents
  namespace: ${AGENT_NAMESPACE}
  labels:
    app: redis-agents
spec:
  selector:
    app: redis-agents
  ports:
  - port: 6379
    targetPort: 6379
    name: redis
  type: ClusterIP
EOF
    
    # Wait for Redis to be ready
    kubectl wait --for=condition=available deployment/redis-agents -n "${AGENT_NAMESPACE}" --timeout=120s
    
    echo "✅ AI Agents infrastructure setup completed"
    echo "   - ECR Repository: ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${AGENT_ECR_REPO}"
    echo "   - SQS Queues: High/Medium/Low priority + DLQ"
    echo "   - IAM Roles: Agent role with Bedrock and SQS access"
    echo "   - Kubernetes: Namespace, RBAC, and Redis deployed"
    echo ""
    echo "   To deploy AI agents, build and push agent images to ECR, then apply agent deployments"
    
    # Clean up temporary files
    rm -f /tmp/sqs-agent-policy.json /tmp/bedrock-agent-policy.json /tmp/agent-policy.json /tmp/agent-trust-policy.json
fi

echo "==============================================="
echo "  Setup completed successfully ......"
echo "  Access the Locust UI by port-forwarding:"
echo "  kubectl port-forward svc/locust-master 8089:8089 -n locust"
echo "  Access the Prometheus UI by port-forwarding:"
echo "  kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n prometheus"
echo "==============================================="