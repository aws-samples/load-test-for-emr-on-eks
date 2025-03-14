#!/bin/bash


# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0


source env.sh


echo "Checking required environment variables..."
echo "CLUSTER_NAME: ${CLUSTER_NAME}"
echo "AWS_REGION: ${AWS_REGION}"
echo "EKS_VERSION: ${EKS_VERSION}"
echo "EKS_VPC_CIDR: ${EKS_VPC_CIDR}"
echo "LOAD_TEST_PREFIX: ${LOAD_TEST_PREFIX}"


replace_in_file() {
    local search=$1
    local replace=$2
    local file=$3
    local temp_file=$(mktemp)
    
    cat "$file" | sed "s|$search|$replace|g" > "$temp_file"
    mv "$temp_file" "$file"
}

echo "==============================================="
echo "  Setup Bucket ......"
echo "==============================================="

# Create S3 bucket for testing
echo "Creating S3 bucket: $BUCKET_NAME"

if [ "$AWS_REGION" = "us-east-1" ]; then
    # For us-east-1, don't specify LocationConstraint
    aws s3api create-bucket \
        --bucket $BUCKET_NAME \
        --region $AWS_REGION || {
        echo "Error: Failed to create S3 bucket \$BUCKET_NAME"
        exit 1
    }
else
    # For other regions, specify LocationConstraint
    aws s3api create-bucket \
        --bucket $BUCKET_NAME \
        --region $AWS_REGION \
        --create-bucket-configuration LocationConstraint=$AWS_REGION || {
        echo "Error: Failed to create S3 bucket $BUCKET_NAME"
        exit 1
    }
fi

# Upload the testing pyspark code
aws s3 cp ./locust/resources/custom-spark-pi.py "s3://${BUCKET_NAME}/testing-code/custom-spark-pi.py" || {
    echo "Error: Failed to upload custom-spark-pi.py to S3"
    exit 1
}

# Update the testing spark job yaml config
replace_in_file "{ECR_REGISTRY_ACCOUNT}" "$ECR_REGISTRY_ACCOUNT" "./locust/resources/spark-pi.yaml"
replace_in_file "{AWS_REGION}" "$AWS_REGION" "./locust/resources/spark-pi.yaml"
replace_in_file "{BUCKET_NAME}" "$BUCKET_NAME" "./locust/resources/spark-pi.yaml"

replace_in_file "{ECR_REGISTRY_ACCOUNT}" "$ECR_REGISTRY_ACCOUNT" "./locust/locustfile.py" 
replace_in_file "{AWS_REGION}" "$AWS_REGION" "./locust/locustfile.py"


echo "==============================================="
echo "  Create EKS Cluster ......"
echo "==============================================="

if ! aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} >/dev/null 2>&1; then

    replace_in_file "\${AWS_REGION}" "$AWS_REGION" "./resources/eks-cluster-values.yaml"
    replace_in_file "\${CLUSTER_NAME}" "$CLUSTER_NAME" "./resources/eks-cluster-values.yaml"
    replace_in_file "\${EKS_VERSION}" "$EKS_VERSION" "./resources/eks-cluster-values.yaml"
    replace_in_file "\${EKS_VPC_CIDR}" "$EKS_VPC_CIDR" "./resources/eks-cluster-values.yaml"
    replace_in_file "\${LOAD_TEST_PREFIX}" "$LOAD_TEST_PREFIX" "./resources/eks-cluster-values.yaml"
    
    eksctl create cluster -f ./resources/eks-cluster-values.yaml

fi

echo "==============================================="
echo "  Adding WSParticipantRole to EKS cluster as admin..."
echo "==============================================="


WS_PARTICIPANT_ROLE_ARN=$(aws iam get-role --role-name WSParticipantRole --query Role.Arn --output text)


if [[ -z "\$WS_PARTICIPANT_ROLE_ARN" ]]; then

  WS_PARTICIPANT_ROLE_ARN=$(aws iam list-roles --path-prefix /WSParticipantRole/ --query 'Roles[0].Arn' --output text)
fi

echo "Role ARN to add: $WS_PARTICIPANT_ROLE_ARN"

eksctl create iamidentitymapping \
  --cluster $CLUSTER_NAME \
  --region $AWS_REGION \
  --arn $WS_PARTICIPANT_ROLE_ARN \
  --username admin \
  --group system:masters

echo "WSParticipantRole has been added as admin to the EKS cluster"


echo "Verifying aws-auth ConfigMap:"
kubectl get configmap aws-auth -n kube-system -o yaml






echo "==============================================="
echo "  Get OIDC ......"
echo "==============================================="

OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
echo $OIDC_PROVIDER


echo "==============================================="
echo "  Setup Cluster Autoscaler ......"
echo "==============================================="

replace_in_file "\${CLUSTER_NAME}" "$CLUSTER_NAME" "./resources/autoscaler-values.yaml"
replace_in_file "\${AWS_REGION}" "$AWS_REGION" "./resources/autoscaler-values.yaml"

helm repo update
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade --install nodescaler autoscaler/cluster-autoscaler -n kube-system --values ./resources/autoscaler-values.yaml



# echo "==============================================="
# echo "  Setup BinPacking ......"
# echo "==============================================="

# kubectl apply -f ./resources/binpacking-values.yaml



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
    
    # Install operators (Helm will create the necessary roles)
    for i in $(seq 0 $((SPARK_JOB_NS_NUM-1)))
    do
        echo "Installing spark-operator$i..."
        helm install spark-operator$i \
            oci://${ECR_REGISTRY_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/spark-operator \
            --version 6.11.0 \
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
        --version 6.11.0 \
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

eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --approve

kubectl create namespace prometheus --dry-run=client -o yaml | kubectl apply -f -

amp=$(aws amp list-workspaces --query "workspaces[?alias=='${CLUSTER_NAME}'].workspaceId" --output text)
if [ -z "$amp" ]; then
    echo "Creating a new prometheus workspace..."
    export WORKSPACE_ID=$(aws amp create-workspace --alias ${CLUSTER_NAME} --query workspaceId --output text)
else
    echo "A prometheus workspace already exists"
    export WORKSPACE_ID=$amp
fi

replace_in_file "{AWS_REGION}" "$AWS_REGION" "./resources/prometheus-values.yaml"
replace_in_file "{ACCOUNTID}" "$ACCOUNT_ID" "./resources/prometheus-values.yaml"
replace_in_file "{WORKSPACE_ID}" "$WORKSPACE_ID" "./resources/prometheus-values.yaml"
replace_in_file "{LOAD_TEST_PREFIX}" "$LOAD_TEST_PREFIX" "./resources/prometheus-values.yaml"


helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack -n prometheus -f ./resources/prometheus-values.yaml




echo "==============================================="
echo "  Setup Karpenter ......"
echo "==============================================="


echo "Check and create Karpenter controller policy"
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}" 2>/dev/null; then
    echo "Policy ${KARPENTER_CONTROLLER_POLICY} already exists"
else
    replace_in_file "\${ACCOUNT_ID}" "$ACCOUNT_ID" "./resources/karpenter-controller-policy.json"
    replace_in_file "\${NODE_ROLE_NAME}" "$KARPENTER_NODE_ROLE" "./resources/karpenter-controller-policy.json"
    replace_in_file "\${AWS_REGION}" "$AWS_REGION" "./resources/karpenter-controller-policy.json"
    replace_in_file "\${CLUSTER_NAME}" "$CLUSTER_NAME" "./resources/karpenter-controller-policy.json"

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
fi


echo "==============================================="
echo "  Configure AWS Auth and Security Groups For Karpenter ......"
echo "==============================================="

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


# Get VPC ID
VPC_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.resourcesVpcConfig.vpcId" --output text)

# Get subnets and clean output
subnet_1_priv=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=false" --query 'Subnets[*].SubnetId' --output text | awk '{print $1}')
subnet_2_priv=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=false" --query 'Subnets[*].SubnetId' --output text | awk '{print $2}')


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

replace_in_file "KarpenterControllerRole_ARN" "arn:aws:iam::$ACCOUNT_ID:role/$KARPENTER_CONTROLLER_ROLE" "./resources/karpenter-0.37.0.yaml"
replace_in_file "CLUSTER_NAME_VALUE" "$CLUSTER_NAME" "./resources/karpenter-0.37.0.yaml"

kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/refs/tags/v0.37.0/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/refs/tags/v0.37.0/pkg/apis/crds/karpenter.sh_nodeclaims.yaml
kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/refs/tags/v0.37.0/pkg/apis/crds/karpenter.sh_nodepools.yaml
kubectl apply -f ./resources/karpenter-0.37.0.yaml


echo "==============================================="
echo "  Set up Karpenter Nodepools ......"
echo "==============================================="

# Create NodePools for Karpenter:
replace_in_file "\${AWS_REGION}" "$AWS_REGION" "./resources/karpenter-nodepool.yaml"
replace_in_file "\${NODE_ROLE_NAME}" "$KARPENTER_NODE_ROLE" "./resources/karpenter-nodepool.yaml"
replace_in_file "\${CLUSTER_NAME}" "$CLUSTER_NAME" "./resources/karpenter-nodepool.yaml"
replace_in_file "\${private_subnet_1}" "$subnet_1_priv" "./resources/karpenter-nodepool.yaml"
replace_in_file "\${private_subnet_2}" "$subnet_2_priv" "./resources/karpenter-nodepool.yaml"

kubectl apply -f ./resources/karpenter-nodepool.yaml



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
    replace_in_file "\${ACCOUNT_ID}" "$ACCOUNT_ID" "./grafana/grafana-service-role-assume-policy.json"
    replace_in_file "\${AWS_REGION}" "$AWS_REGION" "./grafana/grafana-service-role-assume-policy.json"

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

echo "==============================================="
echo "  Packaging and uploading all files to s3 as locust assets..."
echo "==============================================="

# Function to package and upload locust assets
upload_locust_assets() {
    echo "Packaging and uploading all files to s3 as locust assets..."
    
    # Copy the current env.sh to locust
    cp ./env.sh ./locust/env.sh && cd ..
    
    # Create temporary zip file
    local temp_zip="load-test-for-emr-on-eks.zip"

    # Create zip file
    if ! zip -r "${temp_zip}" ./load-test-for-emr-on-eks; then
        echo "Error: Failed to create zip file"
        return 1
    fi

    # Upload to S3
    if ! aws s3 cp "${temp_zip}" "s3://${BUCKET_NAME}/locust-asset/${temp_zip}"; then
        echo "Error: Failed to upload to S3"
        rm -f "${temp_zip}"
        return 1
    fi

    # Clean up
    rm -f "${temp_zip}"

    echo "Successfully uploaded locust assets to S3"
    return 0
}

upload_locust_assets

echo "==============================================="
echo " Completed Infrastructure Deployment .."
echo "==============================================="

