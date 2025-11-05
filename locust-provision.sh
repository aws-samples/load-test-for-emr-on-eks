# Source environment variables
if [ ! -f "env.sh" ]; then
    echo "Error: env.sh file not found"
    exit 1
fi
cp ./env.sh ./locust/env.sh
source env.sh

# Check required environment variables
echo "Checking required environment variables..."
REQUIRED_VARS=(
    "AWS_REGION"
    "CLUSTER_NAME"
    "LOCUST_EKS_ROLE",
    "JOB_SCRIPT_NAME"
)
for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR}" ]; then
        echo "Error: Required environment variable $VAR is not set"
        exit 1
    fi
done

# # Upload load test artifacts to s3
# aws s3 sync ./locust/resources/ "s3://${BUCKET_NAME}/app-code/"

echo "==============================================="
echo "  Setup Locust IRSA role ......"
echo "==============================================="

echo "Create Locust IRSA role"
OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
if aws iam get-role --role-name $LOCUST_EKS_ROLE >/dev/null 2>&1; then
    echo "Role ${LOCUST_EKS_ROLE} already exists"
else
    cat <<EOF > /tmp/locust-trust.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": [
                    "ec2.amazonaws.com",
                    "eks.amazonaws.com"
                ]
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
                "StringEquals": {
                    "${OIDC_PROVIDER}:sub": "system:serviceaccount::locust:locust-operator"
                }
            }
        },
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_PROVIDER}:sub": "system:serviceaccount::locust:default"
                }
            }
        }
    ]
}
EOF
    aws iam create-role --role-name ${LOCUST_EKS_ROLE} --assume-role-policy-document "file:///tmp/locust-trust.json"
    aws iam attach-role-policy --role-name "${LOCUST_EKS_ROLE}" --policy-arn "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
    aws iam attach-role-policy --role-name "${LOCUST_EKS_ROLE}" --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    sed -i='' 's|${BUCKET_NAME}|'$BUCKET_NAME'|g' locust/locust-operator/eks-role-policy.json
    aws iam put-role-policy --role-name "$LOCUST_EKS_ROLE" --policy-name "LocustCustomPolicy" --policy-document "file://locust/locust-operator/eks-role-policy.json"
fi

echo "==============================================="
echo " Install Locust Operator to EKS ......"
echo "==============================================="
# Confirm the eks cluster
kubectl config current-context
# if needed, switch to the correct target eks cluster:
# aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}

# grant EKS admin role to locust IAM role in order to create namespaces and VCs
echo "add access entry for Locust access on EKS"
aws eks create-access-entry --cluster-name $CLUSTER_NAME \
    --principal-arn arn:aws:iam::${ACCOUNT_ID}:role/${LOCUST_EKS_ROLE} \
    --type STANDARD --region ${AWS_REGION}

aws eks associate-access-policy --cluster-name $CLUSTER_NAME \
    --principal-arn arn:aws:iam::${ACCOUNT_ID}:role/${LOCUST_EKS_ROLE} \
    --policy-arn "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" \
    --access-scope type=cluster --region $AWS_REGION

# Install Locust Operator
kubectl create namespace locust || true
helm repo add locust-operator http://locustcloud.github.io/k8s-operator
helm repo update
helm upgrade --install locust-operator locust-operator/locust-operator --namespace locust
# patch RBAC permission and IRSA
kubectl apply -f locust/locust-operator/patch-role-binding.yaml
kubectl annotate serviceaccount -n locust default eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/$LOCUST_EKS_ROLE
# view the operator's logs (optional)
# kubectl logs -n locust -l app.kubernetes.io/name=locust-operator
# uninstall the operator if needed
# helm uninstall locust-operator -n locust

echo "=============================================================="
echo " Configure load test application ......"
echo "=============================================================="
# map locust entry files
# dependencies are already created via dockerfile
kubectl create configmap emr-loadtest-locustfile -n locust --from-file=locust/locustfiles

# run an exmaple load test
export ECR_URL=${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
sed -i='' 's|${CLUSTER_NAME}|'$CLUSTER_NAME'|g' examples/load-test-pvc-reuse.yaml
sed -i='' 's|${ECR_URL}|'$ECR_URL'|g' examples/load-test-pvc-reuse.yaml
sed -i='' 's|${REGION}|'$AWS_REGION'|g' examples/load-test-pvc-reuse.yaml
sed -i='' 's|${JOB_SCRIPT_NAME}|'$JOB_SCRIPT_NAME'|g' examples/load-test-pvc-reuse.yaml

# kubectl apply -f examples/load-test-pvc-reuse.yaml
