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

kubectl create configmap emr-loadtest-locustfile -n locust-operator --from-file ./locust/locustfiles
# kubectl create configmap emr-loadtest-locustfile -n locust-operator --from-file=./locust/locustfiles \
#  --from-file=lib/boto_client_config.py=./locust/locustfiles/lib/boto_client_config.py \
#  --from-file=lib.emr_job.py=./locust/locustfiles/lib/emr_job.py \
#  --from-file=lib.shared.py=./locust/locustfiles/lib/shared.py \
#  --from-file=lib.virtual_cluster.py=./locust/locustfiles/lib/virtual_cluster.py \
#  --from-file=resources.create_new_ns_setup_emr_eks.sh=./locust/locustfiles/resources/create_new_ns_setup_emr_eks.sh \
#  --from-file=resources.emr-job-run.sh=./locust/locustfiles/resources/emr-job-run.sh
 
# kubectl create configmap emr-loadtest-lib -n locust-operator --from-file ./locust/lib
# kubectl create configmap emr-loadtest-resource -n locust-operator --from-file ./locust/resources

echo "helm install Locust"
# helm repo add deliveryhero "https://charts.deliveryhero.io/"
# helm repo update deliveryhero
helm repo add locust-operator http://locustcloud.github.io/k8s-operator
helm repo update
export ECR_URL=${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

sed -i='' 's|${CLUSTER_NAME}|'$CLUSTER_NAME'|g' ./locust/locust-operator.yaml 
# sed -i='' 's|${LOCUST_EKS_ROLE}|'$LOCUST_EKS_ROLE'|g' ./locust/locust-values.yaml 
sed -i='' 's|${ECR_URL}|'$ECR_URL'|g' ./locust/locust-operator.yaml 
# sed -i='' 's|${ACCOUNT_ID}|'$ACCOUNT_ID'|g' ./locust/locust-values.yaml 
sed -i='' 's|${REGION}|'$AWS_REGION'|g' ./locust/locust-operator.yaml 
sed -i='' 's|${JOB_SCRIPT_NAME}|'$JOB_SCRIPT_NAME'|g' ./locust/locust-operator.yaml 

# helm upgrade --install locust oci://ghcr.io/deliveryhero/helm-charts/locust \
# -f ./locust/locust-values.yaml\
#  -n locust

helm install locust-operator locust-operator/locust-operator \
  --namespace locust-operator --create-namespace

kubectl annotate serviceaccount -n locust-operator locust-operator \
 eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/$LOCUST_EKS_ROLE
# helm uninstall locust -n locust
