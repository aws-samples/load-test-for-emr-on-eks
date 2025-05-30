#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Load environment variables
source env.sh
VPC_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.resourcesVpcConfig.vpcId" --output text)



echo "Starting cleanup process..."

echo "deleting all spark jobs"
kubectl delete sparkapplications --all --all-namespaces




if [[ $USE_AMG == "true" ]]
then 
    # delete grafana
    export grafana_workspace_id=$(aws grafana list-workspaces --query 'workspaces[?name==`'${LOAD_TEST_PREFIX}'`].id' --region $AWS_REGION --output text)
    if [[ $grafana_workspace_id != "" ]]
    then 
        aws grafana delete-workspace --workspace-id $grafana_workspace_id --region $AWS_REGION && echo "Deleted AWS Manged Grafana workspace $grafana_workspace_id"
    fi 

    # detach grafana service role policy from service role 
    export grafana_service_role_policy_arn=$(aws iam list-policies --query 'Policies[?PolicyName==`'${LOAD_TEST_PREFIX}-grafana-service-role-policy'`].Arn' --output text)
    export grafana_service_role_arn=$(aws iam list-roles --query 'Roles[?RoleName==`'${LOAD_TEST_PREFIX}-grafana-service-role'`].Arn' --output text)
    if [[ $grafana_service_role_arn != "" && $grafana_service_role_policy_arn != "" ]]
    then 
        aws iam detach-role-policy --role-name ${LOAD_TEST_PREFIX}-grafana-service-role --policy-arn $grafana_service_role_policy_arn && echo "Detach policy $grafana_service_role_policy_arn from role $grafana_service_role_arn"
    fi 

    # delete grafana-service role 
    if [[ $grafana_service_role_arn != "" ]]
    then 
        aws iam delete-role --role-name ${LOAD_TEST_PREFIX}-grafana-service-role --region ${AWS_REGION} && echo "Deleted AWS Managed Grafana service role $grafana_service_role_arn"
    fi 

    # delete grafana service role policy 
    if [[ $grafana_service_role_policy_arn != "" ]]
    then 
        aws iam delete-policy --policy-arn $grafana_service_role_policy_arn && echo "Deleted AWS Deleted AWS Managed Grafana service role policy $grafana_service_role_policy_arn"
    fi 
fi 




# 1. Delete Kubernetes resources first to stop new provisioning
kubectl delete -f ./resources/karpenter-nodepool.yaml || true
kubectl delete -f ./resources/karpenter-0.37.0.yaml || true
helm uninstall karpenter --namespace "kube-system"

# 2. Terminate EC2 instances and WAIT for them to terminate
echo "Terminating Karpenter-managed EC2 instances..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=pending,running" \
  --query "Reservations[*].Instances[*].InstanceId" \
  --output text)

if [ -n "$INSTANCE_IDS" ]; then
  echo "Terminating instances: $INSTANCE_IDS"
  aws ec2 terminate-instances --instance-ids $(echo $INSTANCE_IDS | tr '\t' ' ')
  echo "Waiting for instances to terminate..."
  aws ec2 wait instance-terminated --instance-ids $(echo $INSTANCE_IDS | tr '\t' ' ')
fi

# 3. Delete launch templates
echo "Deleting launch templates..."
aws ec2 describe-launch-templates \
  --filters "Name=tag:karpenter.k8s.aws/cluster,Values=${CLUSTER_NAME}" \
  --query "LaunchTemplates[].LaunchTemplateName" \
  --output text | tr '\t' '\n' | while read -r name; do
    [ -n "$name" ] && aws ec2 delete-launch-template --launch-template-name "$name"
  done

# 4. Try CloudFormation stack deletion FIRST
echo "Deleting Karpenter CloudFormation stack..."
aws cloudformation delete-stack --stack-name "Karpenter-${CLUSTER_NAME}"

# 5. Only manually clean up IAM resources if CloudFormation stack deletion fails
echo "Waiting for stack deletion..."
if ! aws cloudformation wait stack-delete-complete --stack-name "Karpenter-${CLUSTER_NAME}"; then
  echo "CloudFormation stack deletion failed, cleaning up IAM resources manually..."
  
  # Clean up instance profiles
  instance_profiles=$(aws iam list-instance-profiles-for-role --role-name "${KARPENTER_NODE_ROLE}" --query 'InstanceProfiles[*].InstanceProfileName' --output text)
  for profile in $instance_profiles; do
    [ -n "$profile" ] && aws iam remove-role-from-instance-profile \
      --instance-profile-name "$profile" \
      --role-name "${KARPENTER_NODE_ROLE}" && \
    aws iam delete-instance-profile --instance-profile-name "$profile"
  done
  
  # Clean up role policies
  aws iam list-attached-role-policies --role-name "${KARPENTER_NODE_ROLE}" --query 'AttachedPolicies[*].PolicyArn' --output text | tr '\t' '\n' | while read -r arn; do
    [ -n "$arn" ] && aws iam detach-role-policy --role-name "${KARPENTER_NODE_ROLE}" --policy-arn "$arn"
  done
  
  # Delete roles and policies
  aws iam delete-role --role-name "${KARPENTER_NODE_ROLE}" || true
  aws iam detach-role-policy --role-name "${KARPENTER_CONTROLLER_ROLE}" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}" || true
  aws iam delete-role --role-name "${KARPENTER_CONTROLLER_ROLE}" || true
  aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}" || true
  
  # Try deleting CloudFormation stack again
  aws cloudformation delete-stack --stack-name "Karpenter-${CLUSTER_NAME}"
  aws cloudformation wait stack-delete-complete --stack-name "Karpenter-${CLUSTER_NAME}"
fi

echo "Karpenter cleanup completed"


# Delete Prometheus resources
echo "Deleting Prometheus resources..."
helm uninstall prometheus -n prometheus || true
kubectl delete namespace prometheus || true

aws iam detach-role-policy --role-name "${AMP_SERVICE_ACCOUNT_IAM_INGEST_ROLE}" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${AMP_SERVICE_ACCOUNT_IAM_INGEST_POLICY}" || true
aws iam delete-role --role-name "${AMP_SERVICE_ACCOUNT_IAM_INGEST_ROLE}" || true
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${AMP_SERVICE_ACCOUNT_IAM_INGEST_POLICY}" || true

# Delete AMP workspace
amp=$(aws amp list-workspaces --query "workspaces[?alias=='${CLUSTER_NAME}'].workspaceId" --output text)
if [ ! -z "$amp" ]; then
    aws amp delete-workspace --workspace-id $amp
fi

# Delete Spark Operator resources
echo "Deleting Spark Operator resources..."
for i in $(seq 0 $((NUM_NS-1))); do
    kubectl delete namespace spark-job$i || true
done
kubectl delete namespace spark-operator || true

aws iam detach-role-policy --role-name "${SPARK_OPERATOR_ROLE}" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${SPARK_OPERATOR_POLICY}" || true
aws iam delete-role --role-name "${SPARK_OPERATOR_ROLE}" || true
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${SPARK_OPERATOR_POLICY}" || true

# Delete S3 bucket
echo "Deleting S3 bucket..."
aws s3 rm s3://${BUCKET_NAME} --recursive
aws s3api delete-bucket --bucket ${BUCKET_NAME} --region ${AWS_REGION}

# Restore backup files
echo "Restoring backup files..."

if [ -f "./resources/template-backups/prometheus-values.yaml" ]; then
    cp -f ./resources/template-backups/prometheus-values.yaml ./resources/prometheus-values.yaml
fi
if [ -f "./resources/template-backups/karpenter-nodepool.yaml" ]; then
    cp -f ./resources/template-backups/karpenter-nodepool.yaml ./resources/karpenter-nodepool.yaml
fi
if [ -f "./resources/template-backups/karpenter-controller-policy.json" ]; then
    cp -f ./resources/template-backups/karpenter-controller-policy.json ./resources/karpenter-controller-policy.json
fi
if [ -f "./resources/template-backups/karpenter-0.37.0.yaml" ]; then
    cp -f ./resources/template-backups/karpenter-0.37.0.yaml ./resources/karpenter-0.37.0.yaml
fi
if [ -f "./resources/template-backups/eks-cluster-values.yaml" ]; then
    cp -f ./resources/template-backups/eks-cluster-values.yaml ./resources/eks-cluster-values.yaml
fi

if [ -f "./resources/template-backups/locust-spark-submit.py" ]; then
    cp -f ./resources/template-backups/locust-spark-submit.py ./resources/locust-spark-submit.py
fi

if [ -f "./resources/template-backups/spark-pi.yaml" ]; then
    cp -f ./resources/template-backups/spark-pi.yaml ./resources/spark-pi.yaml
fi

if [ -f "./resources/template-backups/grafana-service-role-assume-policy.json" ]; then
    cp -f ./resources/template-backups/grafana-service-role-assume-policy.json ./grafana/grafana-service-role-assume-policy.json
fi
# Delete EKS cluster
echo "Deleting EKS cluster..."
eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_REGION}

echo "Deleting tmp files...."
rm -rf /tmp/load_test/*
rm -rf custom-spark-operator/
rm -rf spark-operator-7.7.0.tgz 

echo "Cleanup completed!"