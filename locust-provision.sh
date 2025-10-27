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
    "BUCKET_NAME"
    "CLUSTER_NAME"
)

for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR}" ]; then
        echo "Error: Required environment variable $VAR is not set"
        exit 1
    fi
done

# Upload the testing pyspark code
aws s3 sync ./locust/resources/ "s3://${BUCKET_NAME}/app-code/"
# Set context of Locust's EKS cluster
export LOCUST_CONTEXT=$(kubectl config get-contexts | sed -e 's/\*/ /' | grep "@${CLUSTER_NAME}." | awk -F" " '{print $1}')
kubectl config use-context ${LOCUST_CONTEXT}
# Check
kubectl config current-context

# helm install Locust
helm repo add deliveryhero "https://charts.deliveryhero.io/"
helm repo update deliveryhero
kubectl create configmap eks-loadtest-locustfile --from-file ./locust/

helm upgrade --install locust deliveryhero/locust \
    --set loadtest.name=${CLUSTER_NAME} \
    --set loadtest.locust_locustfile_configmap=eks-loadtest-locustfile \
    --set loadtest.locust_locustfile=locustfile.py \
    --set worker.hpa.enabled=true \
    --set worker.hpa.minReplicas=2 \
    --set master.nodeselector."eks\.amazonaws\.com/nodegroup"=ng-10

# helm uninstall locust