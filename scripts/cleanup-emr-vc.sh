#!/bin/bash
# Cleanup all EMR virtual clusters and their namespaces on the current EKS cluster
set -euo pipefail

REGION="${AWS_REGION:-ap-southeast-2}"
CLUSTER_NAME="${CLUSTER_NAME:-emr-eks-load-test-load-test-1-32}"

echo "=== Cleaning up EMR virtual clusters for EKS cluster: ${CLUSTER_NAME} ==="

# Cancel all running job runs first
for vc_id in $(aws emr-containers list-virtual-clusters --region "$REGION" \
  --container-provider-id "$CLUSTER_NAME" \
  --states RUNNING \
  --query 'virtualClusters[].id' --output text); do

  echo "Processing virtual cluster: ${vc_id}"

  for job_id in $(aws emr-containers list-job-runs --region "$REGION" \
    --virtual-cluster-id "$vc_id" \
    --states RUNNING SUBMITTED PENDING \
    --query 'jobRuns[].id' --output text 2>/dev/null); do
    echo "  Cancelling job: ${job_id}"
    aws emr-containers cancel-job-run --region "$REGION" \
      --virtual-cluster-id "$vc_id" --id "$job_id" 2>/dev/null || true
  done
done

echo "Waiting 10s for jobs to cancel..."
sleep 10

# Delete all virtual clusters (RUNNING and ARRESTED)
for state in RUNNING ARRESTED; do
  for vc_id in $(aws emr-containers list-virtual-clusters --region "$REGION" \
    --container-provider-id "$CLUSTER_NAME" \
    --states "$state" \
    --query 'virtualClusters[].id' --output text 2>/dev/null); do
    echo "Deleting virtual cluster: ${vc_id} (${state})"
    aws emr-containers delete-virtual-cluster --region "$REGION" --id "$vc_id" 2>/dev/null || true
  done
done

echo "Waiting 15s for virtual clusters to delete..."
sleep 15

# Delete EMR namespaces from Kubernetes
for ns in $(kubectl get ns --no-headers -o custom-columns=':metadata.name' | grep '^emr-'); do
  echo "Deleting namespace: ${ns}"
  kubectl delete ns "$ns" --timeout=60s 2>/dev/null || true
done

# Delete locust test
kubectl delete locusttest -n locust --all 2>/dev/null || true

echo "=== Cleanup complete ==="
echo "Remaining virtual clusters:"
aws emr-containers list-virtual-clusters --region "$REGION" \
  --container-provider-id "$CLUSTER_NAME" \
  --states RUNNING --query 'virtualClusters[].{id:id,name:name,state:state}' --output table
