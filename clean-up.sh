#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Load environment variables
source env.sh

echo "Starting cleanup process..."

echo "Finding EMR virtual clusters for EKS cluster: $CLUSTER_NAME"
CLUSTER_IDS=$(aws emr-containers list-virtual-clusters \
    --region "$AWS_REGION" \
    --query "virtualClusters[?state=='RUNNING' && contains(containerProvider.id, '$CLUSTER_NAME')].id" \
    --output text)

if [ -z "$CLUSTER_IDS" ]; then
    echo "No virtual clusters found for EKS cluster: $CLUSTER_NAME"
else
    # Delete each virtual cluster
    for cluster_id in $CLUSTER_IDS; do
        echo "Deleting virtual cluster: $cluster_id"
        aws emr-containers delete-virtual-cluster --id "$cluster_id" --region "$AWS_REGION"
    done
fi

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
# Delete AMP workspace
echo "Deleting AMP workspace..."
amp=$(aws amp list-workspaces --query "workspaces[?alias=='${CLUSTER_NAME}'].workspaceId" --output text)
if [ ! -z "$amp" ]; then
    aws amp delete-workspace --workspace-id $amp
fi
# Delete S3 bucket
echo "Deleting S3 bucket..."
aws s3 rm s3://${BUCKET_NAME} --recursive
aws s3api delete-bucket --bucket ${BUCKET_NAME} --region ${AWS_REGION}

echo "Delete EKS cluster..."
# eksctl automatically deletes managed nodegroups,addons,iam,vpc,CFN stacks created by eksctl)
echo "Deleting EKS cluster..."
cp ./resources/eks-cluster-values.yaml ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml
sed -i='' 's|${AWS_REGION}|'$AWS_REGION'|g' ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml
sed -i='' 's|${CLUSTER_NAME}|'$CLUSTER_NAME'|g' ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml
sed -i='' 's|${EKS_VERSION}|'$EKS_VERSION'|g' ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml
sed -i='' 's|${EKS_VPC_CIDR}|'$EKS_VPC_CIDR'|g' ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml
sed -i='' 's|${ACCOUNT_ID}|'$ACCOUNT_ID'|g' ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml 

eksctl delete cluster -f ./resources/eks-cluster-values-${CLUSTER_NAME}.yaml

echo "Delete all IAM roles created for this cluster..."
iam_roles=$(aws iam list-roles --query "Roles[?contains(RoleName, '${CLUSTER_NAME}')].RoleName" --output text)
for role in $iam_roles; do
    echo "Detaching managed policies..."
    policies=$(aws iam list-attached-role-policies --role-name "$role" \
        --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null)

    if [ -n "$policies" ] && [ "$policies" != "None" ]; then
        echo "$policies" | tr '\t' '\n' | while read policy_arn; do
            if [ -n "$policy_arn" ]; then
                echo "Detaching $policy_arn from $role"
                aws iam detach-role-policy --role-name "$role" --policy-arn "$policy_arn"
            fi
        done
    fi

    echo "Deleting inline policies..."
    inline_policies=$(aws iam list-role-policies --role-name "$role" \
        --query 'PolicyNames' --output text 2>/dev/null)

    if [ -n "$inline_policies" ] && [ "$inline_policies" != "None" ]; then
        echo "$inline_policies" | tr '\t' '\n' | while read policy_name; do
            if [ -n "$policy_name" ]; then
                echo "Deleting inline policy $policy_name from $role"
                aws iam delete-role-policy --role-name "$role" --policy-name "$policy_name"
            fi
        done
    fi
    sleep 2

    echo "Deleting IAM role: $role"
    aws iam delete-role --role-name "$role"
done

echo "Deleting spark execution policy: $EXECUTION_ROLE_POLICY"
EXECUTION_ROLE_POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$EXECUTION_ROLE_POLICY'].Arn" --output text)
aws iam delete-policy --policy-arn $EXECUTION_ROLE_POLICY_ARN

# Delete Karpenter resources for Interruption handler
stacks=$(aws cloudformation list-stacks \
  --query 'StackSummaries[? StackStatus==`CREATE_COMPLETE` && contains(StackName, `'"$CLUSTER_NAME"'`)].StackName' \
  --output text)
if [ -n "$stacks" ]; then
  for stack in $stacks; do
    echo "Deleting stack: $stack"
    aws cloudformation delete-stack --stack-name "$stack"
  done
fi

echo "Cleanup completed!"