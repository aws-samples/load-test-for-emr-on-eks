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
    "BUCKET_NAME"
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
aws s3 sync ./locust/resources/ "s3://${BUCKET_NAME}/app-code/"

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
                    "eks.amazonaws.com",
                    "emr-containers.amazonaws.com"
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
                    "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
                    "${OIDC_PROVIDER}:sub": "system:serviceaccount:locust:locust-master"
                }
            }
        }
    ]
}
EOF
    aws iam create-role --role-name ${LOCUST_EKS_ROLE} --assume-role-policy-document "file:///tmp/locust-trust.json"
    # aws iam attach-role-policy --role-name "${LOCUST_EKS_ROLE}" --policy-arn "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
    aws iam attach-role-policy --role-name "${LOCUST_EKS_ROLE}" --policy-arn "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
    aws iam attach-role-policy --role-name "${LOCUST_EKS_ROLE}" --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    aws iam attach-role-policy --role-name "${LOCUST_EKS_ROLE}" --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"

    sed -i='' 's|${BUCKET_NAME}|'$BUCKET_NAME'|g' ./locust/resources/locust-eks-role-policy.json
    aws iam put-role-policy --role-name "$LOCUST_EKS_ROLE" --policy-name "LocustCustomPolicy" --policy-document "file://locust/resources/locust-eks-role-policy.json"
fi

echo "==============================================="
echo " Install Locust onto EKS ......"
echo "==============================================="
echo "Set context to Locust's EKS cluster..."
export LOCUST_CONTEXT=$(kubectl config get-contexts | sed -e 's/\*/ /' | grep "@${CLUSTER_NAME}." | awk -F" " '{print $1}')
kubectl config use-context ${LOCUST_CONTEXT}
# Check
kubectl config current-context

echo "add access entry for locust's IRSA role"
aws eks create-access-entry --cluster-name ${CLUSTER_NAME} --principal-arn arn:aws:iam::${ACCOUNT_ID}:role/${LOCUST_EKS_ROLE} --type EC2_LINUX


echo "Map locust main file and dependencies into pods via configmaps"
kubectl create namespace locust || true

kubectl create configmap emr-loadtest-locustfile -n locust --from-file ./locust/locustfile.py
kubectl create configmap emr-loadtest-lib -n locust --from-file ./locust/lib

echo "helm install Locust"
helm repo add deliveryhero "https://charts.deliveryhero.io/"
helm repo update deliveryhero

sed -i='' 's|${CLUSTER_NAME}|'$CLUSTER_NAME'|g' ./locust/locust-values.yaml 
sed -i='' 's|${LOCUST_EKS_ROLE}|'$LOCUST_EKS_ROLE'|g' ./locust/locust-values.yaml 
sed -i='' 's|${ECR_URL}|'$ECR_URL'|g' ./locust/locust-values.yaml 
sed -i='' 's|${ACCOUNT_ID}|'$ACCOUNT_ID'|g' ./locust/locust-values.yaml 
helm upgrade --install locust deliveryhero/locust -f ./locust/locust-values.yaml -n locust

# helm uninstall locust -n locust
