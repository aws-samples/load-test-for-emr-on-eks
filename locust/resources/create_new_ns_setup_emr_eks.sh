#!/bin/bash

readonly REGION=$1
readonly EKS_CLUSTER_NAME=$2
readonly NAMESPACE=$3

# create new namespace
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
  labels:
    environment: $EKS_CLUSTER_NAME
    team: chicago-dev
    owner: meloyang
EOF

echo "New namespace $NAMESPACE created in cluster $EKS_CLUSTER_NAME"

# Enable cluster access for Amazon EMR on EKS on the newly created namespace
# Prerequisite: You must download the latest eksctl (https://eksctl.io/)
eksctl create iamidentitymapping \
    --cluster $EKS_CLUSTER_NAME \
    --service-name "emr-containers" \
    --namespace $NAMESPACE \
    --region=$REGION
