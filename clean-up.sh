#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Load environment variables
source env.sh

echo "Starting cleanup process..."

echo "Finding EMR virtual clusters for EKS cluster: $CLUSTER_NAME"
CLUSTER_IDS=$(aws emr-containers list-virtual-clusters \
    --region "$AWS_REGION" \
    --query "virtualClusters[?state=='RUNNING' && contains(containerProvider.id, '$CLUSTER_NAME')].id"
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

# Delete EKS cluster 
# eksctl automatically deletes managed nodegroups,addons,iam,vpc,CFN stacks created by eksctl)
echo "Deleting EKS cluster..."
eksctl delete cluster -f ./resources/eks-cluster-values.yaml --region ${AWS_REGION}

echo "Cleanup completed!"