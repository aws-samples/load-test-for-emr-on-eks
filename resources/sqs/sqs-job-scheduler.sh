source ./env.sh

# Get SQS URLs from temporary files
export SQS_QUEUE_URL=$(cat /tmp/sqs-queue-url.txt)
export SQS_DLQ_URL=$(cat /tmp/sqs-dlq-url.txt)

kubectl create namespace ${JOB_SCHEDULER_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -


export OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
echo $OIDC_PROVIDER

# Create IAM role for SQS Scheduler
cat > /tmp/sqs-scheduler-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER#*//}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_PROVIDER#*//}:sub": "system:serviceaccount:${JOB_SCHEDULER_NAMESPACE}:${JOB_SCHEDULER_SERVICE_ACCOUNT}",
                    "${OIDC_PROVIDER#*//}:aud": "sts.amazonaws.com"
                }
            }
        }
    ]
}
EOF

aws iam create-role \
    --role-name ${SQS_SCHEDULER_ROLE} \
    --assume-role-policy-document file:///tmp/sqs-scheduler-trust-policy.json || echo "Role may already exist"

aws iam attach-role-policy \
    --role-name ${SQS_SCHEDULER_ROLE} \
    --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/${SQS_SCHEDULER_POLICY}

# Create the deployment YAML with substitutions
sed -e "s|\${ACCOUNT_ID}|${ACCOUNT_ID}|g" \
    -e "s|\${SQS_SCHEDULER_ROLE}|${SQS_SCHEDULER_ROLE}|g" \
    -e "s|\${AWS_REGION}|${AWS_REGION}|g" \
    -e "s|\${SQS_QUEUE_URL}|${SQS_QUEUE_URL}|g" \
    -e "s|\${SQS_DLQ_URL}|${SQS_DLQ_URL}|g" \
    -e "s|\${JOB_SCHEDULER_BATCH_SIZE}|${JOB_SCHEDULER_BATCH_SIZE}|g" \
    -e "s|\${JOB_SCHEDULER_POLL_INTERVAL}|${JOB_SCHEDULER_POLL_INTERVAL}|g" \
    ./resources/sqs/sqs-job-scheduler-development.yaml > /tmp/sqs-job-scheduler-deployment.yaml

# Update the ConfigMap with the actual scheduler script
kubectl create configmap scheduler-script \
    --from-file=sqs-job-scheduler.py=./resources/sqs/sqs-job-scheduler.py \
    --namespace=${JOB_SCHEDULER_NAMESPACE} \
    --dry-run=client -o yaml | kubectl apply -f -

# Apply the scheduler deployment
kubectl apply -f /tmp/sqs-job-scheduler-deployment.yaml

echo "Waiting for SQS Job Scheduler to be ready..."
kubectl rollout status deployment/sqs-job-scheduler -n ${JOB_SCHEDULER_NAMESPACE} --timeout=120s

# Create ServiceMonitor for scheduler metrics
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: sqs-job-scheduler-monitor
  namespace: prometheus
  labels:
    release: prometheus
spec:
  namespaceSelector:
    matchNames:
    - ${JOB_SCHEDULER_NAMESPACE}
  selector:
    matchLabels:
      app: sqs-job-scheduler
  endpoints:
    - port: metrics
      interval: 15s
EOF