#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Load environment variables
source env.sh
VPC_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.resourcesVpcConfig.vpcId" --output text)

echo "Starting cleanup process..."

echo "==============================================="
echo "  Cleaning up SQS resources ......"
echo "==============================================="

# Use modular SQS cleanup
 bash ./resources/sqs/sqs-provision.sh cleanup    

# Clean up SQS scheduler namespace
echo "Cleaning up SQS scheduler namespace..."


echo "deleting all spark jobs"
kubectl delete sparkapplications --all --all-namespaces

kubectl delete namespace ${JOB_SCHEDULER_NAMESPACE} --ignore-not-found
echo "Cleaning up OSS Spark Operator..."

echo "Deleting Spark Operator resources..."
for i in $(seq 0 $((SPARK_JOB_NS_NUM-1))); do
    helm uninstall spark-operator$i -n spark-operator
    kubectl delete namespace spark-job$i || true
done


kubectl delete namespace spark-operator --ignore-not-found





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

# Enhanced cleanup for any remaining CloudFormation stack issues
echo "==============================================="
echo "  Enhanced cleanup for remaining resources..."
echo "==============================================="

# Check if CloudFormation stack deletion failed or is stuck
STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "eksctl-${CLUSTER_NAME}-cluster" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "STACK_NOT_FOUND")

if [ "$STACK_STATUS" = "DELETE_FAILED" ] || [ "$STACK_STATUS" = "DELETE_IN_PROGRESS" ]; then
    echo "CloudFormation stack is in $STACK_STATUS state, performing enhanced cleanup..."
    
    # Get VPC ID from the stack
    VPC_ID=$(aws cloudformation describe-stack-resources --stack-name "eksctl-${CLUSTER_NAME}-cluster" --query 'StackResources[?ResourceType==`AWS::EC2::VPC`].PhysicalResourceId' --output text 2>/dev/null)
    
    if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
        echo "Found stuck VPC: $VPC_ID, performing forced cleanup..."
        
        # 1. Force delete any remaining ENIs in the VPC
        echo "1. Cleaning up network interfaces..."
        ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query 'NetworkInterfaces[?Status!=`in-use`].NetworkInterfaceId' --output text 2>/dev/null)
        if [ -n "$ENI_IDS" ]; then
            for eni in $ENI_IDS; do
                aws ec2 delete-network-interface --network-interface-id $eni 2>/dev/null && echo "  ✅ Deleted ENI $eni" || echo "  ❌ Failed to delete ENI $eni"
            done
        fi
        
        # 2. Clean up security group cross-references
        echo "2. Removing security group cross-references..."
        SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null)
        
        if [ -n "$SG_IDS" ]; then
            # Remove all cross-references between security groups
            for sg1 in $SG_IDS; do
                for sg2 in $SG_IDS; do
                    if [ "$sg1" != "$sg2" ]; then
                        # Remove ingress rules
                        aws ec2 revoke-security-group-ingress --group-id $sg1 --source-group $sg2 --protocol -1 2>/dev/null || true
                        # Remove egress rules  
                        aws ec2 revoke-security-group-egress --group-id $sg1 --source-group $sg2 --protocol -1 2>/dev/null || true
                    fi
                done
            done
            
            # Delete non-default security groups
            echo "3. Deleting security groups..."
            for sg in $SG_IDS; do
                aws ec2 delete-security-group --group-id $sg 2>/dev/null && echo "  ✅ Deleted security group $sg" || echo "  ❌ Failed to delete security group $sg"
            done
        fi
        
        # 3. Clean up route table associations and routes
        echo "4. Cleaning up route tables..."
        RT_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[?Associations[0].Main==`false`].RouteTableId' --output text 2>/dev/null)
        
        if [ -n "$RT_IDS" ]; then
            for rt in $RT_IDS; do
                # Disassociate route table from subnets
                ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-ids $rt --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text 2>/dev/null)
                for assoc in $ASSOC_IDS; do
                    aws ec2 disassociate-route-table --association-id $assoc 2>/dev/null || true
                done
                
                # Delete custom routes
                aws ec2 describe-route-tables --route-table-ids $rt --query 'RouteTables[0].Routes[?GatewayId!=`local`]' --output json 2>/dev/null | jq -r '.[] | select(.DestinationCidrBlock) | .DestinationCidrBlock' | while read cidr; do
                    aws ec2 delete-route --route-table-id $rt --destination-cidr-block $cidr 2>/dev/null || true
                done
                
                # Delete route table
                aws ec2 delete-route-table --route-table-id $rt 2>/dev/null && echo "  ✅ Deleted route table $rt" || echo "  ❌ Failed to delete route table $rt"
            done
        fi
        
        # 4. Clean up internet gateways
        echo "5. Cleaning up internet gateways..."
        IGW_IDS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null)
        if [ -n "$IGW_IDS" ]; then
            for igw in $IGW_IDS; do
                aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $VPC_ID 2>/dev/null || true
                aws ec2 delete-internet-gateway --internet-gateway-id $igw 2>/dev/null && echo "  ✅ Deleted IGW $igw" || echo "  ❌ Failed to delete IGW $igw"
            done
        fi
        
        # 5. Clean up NAT gateways
        echo "6. Cleaning up NAT gateways..."
        NAT_IDS=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text 2>/dev/null)
        if [ -n "$NAT_IDS" ]; then
            for nat in $NAT_IDS; do
                aws ec2 delete-nat-gateway --nat-gateway-id $nat 2>/dev/null && echo "  ✅ Deleted NAT Gateway $nat" || echo "  ❌ Failed to delete NAT Gateway $nat"
            done
            echo "  ⏳ Waiting for NAT gateways to be deleted..."
            sleep 60
        fi
        
        # 6. Clean up subnets
        echo "7. Cleaning up subnets..."
        SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text 2>/dev/null)
        if [ -n "$SUBNET_IDS" ]; then
            for subnet in $SUBNET_IDS; do
                aws ec2 delete-subnet --subnet-id $subnet 2>/dev/null && echo "  ✅ Deleted subnet $subnet" || echo "  ❌ Failed to delete subnet $subnet"
            done
        fi
        
        # 7. Try to delete VPC
        echo "8. Attempting to delete VPC..."
        aws ec2 delete-vpc --vpc-id $VPC_ID 2>/dev/null && echo "  ✅ Deleted VPC $VPC_ID" || echo "  ❌ Failed to delete VPC $VPC_ID"
    fi
    
    # 8. Cancel the stuck CloudFormation stack deletion and retry
    if [ "$STACK_STATUS" = "DELETE_IN_PROGRESS" ]; then
        echo "9. Cancelling stuck CloudFormation stack deletion..."
        aws cloudformation cancel-update-stack --stack-name "eksctl-${CLUSTER_NAME}-cluster" 2>/dev/null || true
        sleep 30
    fi
    
    # 9. Retry CloudFormation stack deletion
    echo "10. Retrying CloudFormation stack deletion..."
    aws cloudformation delete-stack --stack-name "eksctl-${CLUSTER_NAME}-cluster" 2>/dev/null || true
    
    # 10. Wait for stack deletion with timeout
    echo "11. Waiting for stack deletion (max 10 minutes)..."
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt 20 ]; do
        CURRENT_STATUS=$(aws cloudformation describe-stacks --stack-name "eksctl-${CLUSTER_NAME}-cluster" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "STACK_NOT_FOUND")
        if [ "$CURRENT_STATUS" = "STACK_NOT_FOUND" ]; then
            echo "  ✅ CloudFormation stack deleted successfully"
            break
        elif [ "$CURRENT_STATUS" = "DELETE_FAILED" ]; then
            echo "  ❌ CloudFormation stack deletion failed again"
            break
        else
            echo "  ⏳ Stack status: $CURRENT_STATUS - waiting... ($((WAIT_COUNT + 1))/20)"
            sleep 30
            WAIT_COUNT=$((WAIT_COUNT + 1))
        fi
    done
    
    if [ $WAIT_COUNT -eq 20 ]; then
        echo "  ⚠️  Stack deletion timeout - may need manual intervention"
    fi
fi

# Clean up any remaining Locust-related resources
echo "Cleaning up any remaining Locust resources..."
LOCUST_INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=*${LOAD_TEST_PREFIX}*locust*" "Name=instance-state-name,Values=running,stopped,stopping,pending" --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null)

if [ -n "$LOCUST_INSTANCE_IDS" ]; then
    echo "Terminating remaining Locust instances: $LOCUST_INSTANCE_IDS"
    aws ec2 terminate-instances --instance-ids $LOCUST_INSTANCE_IDS 2>/dev/null || true
fi

# Clean up any remaining key pairs
aws ec2 delete-key-pair --key-name "${LOAD_TEST_PREFIX}-locust-key" 2>/dev/null || true

# Clean up any remaining IAM resources
echo "Cleaning up IAM resources..."
IAM_ROLES=$(aws iam list-roles --query "Roles[?contains(RoleName, '${LOAD_TEST_PREFIX}') || contains(RoleName, '${CLUSTER_NAME}')].RoleName" --output text 2>/dev/null)
if [ -n "$IAM_ROLES" ]; then
    echo "Found IAM roles to clean up: $IAM_ROLES"
    for role in $IAM_ROLES; do
        echo "Cleaning up role: $role"
        
        # Detach all managed policies
        ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)
        if [ -n "$ATTACHED_POLICIES" ]; then
            for policy_arn in $ATTACHED_POLICIES; do
                aws iam detach-role-policy --role-name "$role" --policy-arn "$policy_arn" 2>/dev/null || true
            done
        fi
        
        # Delete inline policies
        INLINE_POLICIES=$(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text 2>/dev/null)
        if [ -n "$INLINE_POLICIES" ]; then
            for policy_name in $INLINE_POLICIES; do
                aws iam delete-role-policy --role-name "$role" --policy-name "$policy_name" 2>/dev/null || true
            done
        fi
        
        # Remove role from instance profiles
        INSTANCE_PROFILES=$(aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null)
        if [ -n "$INSTANCE_PROFILES" ]; then
            for profile in $INSTANCE_PROFILES; do
                aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" 2>/dev/null || true
                # Also try to delete the instance profile
                aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null || true
            done
        fi
        
        # Delete the role
        aws iam delete-role --role-name "$role" 2>/dev/null && echo "  ✅ Deleted role: $role" || echo "  ❌ Failed to delete role: $role"
    done
fi

# Clean up IAM policies
IAM_POLICIES=$(aws iam list-policies --scope Local --query "Policies[?contains(PolicyName, '${LOAD_TEST_PREFIX}') || contains(PolicyName, '${CLUSTER_NAME}')].Arn" --output text 2>/dev/null)
if [ -n "$IAM_POLICIES" ]; then
    echo "Found IAM policies to clean up: $IAM_POLICIES"
    for policy_arn in $IAM_POLICIES; do
        echo "Cleaning up policy: $policy_arn"
        
        # Detach from all entities first
        ATTACHED_ROLES=$(aws iam list-entities-for-policy --policy-arn "$policy_arn" --query 'PolicyRoles[].RoleName' --output text 2>/dev/null)
        if [ -n "$ATTACHED_ROLES" ]; then
            for role in $ATTACHED_ROLES; do
                aws iam detach-role-policy --role-name "$role" --policy-arn "$policy_arn" 2>/dev/null || true
            done
        fi
        
        ATTACHED_USERS=$(aws iam list-entities-for-policy --policy-arn "$policy_arn" --query 'PolicyUsers[].UserName' --output text 2>/dev/null)
        if [ -n "$ATTACHED_USERS" ]; then
            for user in $ATTACHED_USERS; do
                aws iam detach-user-policy --user-name "$user" --policy-arn "$policy_arn" 2>/dev/null || true
            done
        fi
        
        ATTACHED_GROUPS=$(aws iam list-entities-for-policy --policy-arn "$policy_arn" --query 'PolicyGroups[].GroupName' --output text 2>/dev/null)
        if [ -n "$ATTACHED_GROUPS" ]; then
            for group in $ATTACHED_GROUPS; do
                aws iam detach-group-policy --group-name "$group" --policy-arn "$policy_arn" 2>/dev/null || true
            done
        fi
        
        # Delete all policy versions except default
        POLICY_VERSIONS=$(aws iam list-policy-versions --policy-arn "$policy_arn" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null)
        if [ -n "$POLICY_VERSIONS" ]; then
            for version in $POLICY_VERSIONS; do
                aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$version" 2>/dev/null || true
            done
        fi
        
        # Delete the policy
        aws iam delete-policy --policy-arn "$policy_arn" 2>/dev/null && echo "  ✅ Deleted policy: $policy_arn" || echo "  ❌ Failed to delete policy: $policy_arn"
    done
fi

echo "Enhanced cleanup completed."

echo "Deleting tmp files...."
rm -rf /tmp/load_test/*


# Final cleanup verification
echo "==============================================="
echo "  Final cleanup verification..."
echo "==============================================="

echo "Checking for any remaining resources..."

# Check CloudFormation stacks
REMAINING_STACKS=$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED --query "StackSummaries[?contains(StackName, '${LOAD_TEST_PREFIX}') || contains(StackName, '${CLUSTER_NAME}')].StackName" --output text 2>/dev/null)
if [ -n "$REMAINING_STACKS" ]; then
    echo "⚠️  Remaining CloudFormation stacks: $REMAINING_STACKS"
    
    # Try to clean up remaining stacks
    for stack in $REMAINING_STACKS; do
        echo "Attempting to delete remaining stack: $stack"
        STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$stack" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "STACK_NOT_FOUND")
        
        if [ "$STACK_STATUS" = "DELETE_FAILED" ]; then
            echo "Stack $stack is in DELETE_FAILED state, checking for IAM policy issues..."
            
            # Check if it's a Karpenter stack with policy attachment issues
            if [[ "$stack" == *"Karpenter"* ]]; then
                echo "Handling Karpenter stack with policy attachment issues..."
                
                # Get the policy ARN from stack resources
                POLICY_ARN=$(aws cloudformation describe-stack-resources --stack-name "$stack" --query 'StackResources[?ResourceType==`AWS::IAM::ManagedPolicy`].PhysicalResourceId' --output text 2>/dev/null)
                
                if [ -n "$POLICY_ARN" ] && [ "$POLICY_ARN" != "None" ]; then
                    echo "Found policy: $POLICY_ARN"
                    
                    # Detach policy from all entities
                    echo "Detaching policy from all entities..."
                    
                    # Detach from roles
                    ATTACHED_ROLES=$(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" --query 'PolicyRoles[].RoleName' --output text 2>/dev/null)
                    if [ -n "$ATTACHED_ROLES" ]; then
                        for role in $ATTACHED_ROLES; do
                            aws iam detach-role-policy --role-name "$role" --policy-arn "$POLICY_ARN" 2>/dev/null && echo "  ✅ Detached from role $role" || echo "  ❌ Failed to detach from role $role"
                        done
                    fi
                    
                    # Detach from users
                    ATTACHED_USERS=$(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" --query 'PolicyUsers[].UserName' --output text 2>/dev/null)
                    if [ -n "$ATTACHED_USERS" ]; then
                        for user in $ATTACHED_USERS; do
                            aws iam detach-user-policy --user-name "$user" --policy-arn "$POLICY_ARN" 2>/dev/null && echo "  ✅ Detached from user $user" || echo "  ❌ Failed to detach from user $user"
                        done
                    fi
                    
                    # Detach from groups
                    ATTACHED_GROUPS=$(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" --query 'PolicyGroups[].GroupName' --output text 2>/dev/null)
                    if [ -n "$ATTACHED_GROUPS" ]; then
                        for group in $ATTACHED_GROUPS; do
                            aws iam detach-group-policy --group-name "$group" --policy-arn "$POLICY_ARN" 2>/dev/null && echo "  ✅ Detached from group $group" || echo "  ❌ Failed to detach from group $group"
                        done
                    fi
                fi
            fi
            
            # Retry stack deletion
            echo "Retrying deletion of stack: $stack"
            aws cloudformation delete-stack --stack-name "$stack" 2>/dev/null || true
            
            # Wait for deletion with timeout
            echo "Waiting for stack deletion (max 5 minutes)..."
            aws cloudformation wait stack-delete-complete --stack-name "$stack" --cli-read-timeout 300 2>/dev/null && echo "  ✅ Stack $stack deleted successfully" || echo "  ❌ Stack $stack deletion failed"
        fi
    done
    
    # Re-check remaining stacks
    REMAINING_STACKS_AFTER=$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED --query "StackSummaries[?contains(StackName, '${LOAD_TEST_PREFIX}') || contains(StackName, '${CLUSTER_NAME}')].StackName" --output text 2>/dev/null)
    if [ -n "$REMAINING_STACKS_AFTER" ]; then
        echo "⚠️  Still remaining CloudFormation stacks: $REMAINING_STACKS_AFTER"
    else
        echo "✅ All CloudFormation stacks cleaned up"
    fi
else
    echo "✅ No remaining CloudFormation stacks"
fi

# Check EKS clusters
REMAINING_CLUSTERS=$(aws eks list-clusters --query "clusters[?contains(@, '${LOAD_TEST_PREFIX}') || contains(@, '${CLUSTER_NAME}')]" --output text 2>/dev/null)
if [ -n "$REMAINING_CLUSTERS" ]; then
    echo "⚠️  Remaining EKS clusters: $REMAINING_CLUSTERS"
else
    echo "✅ No remaining EKS clusters"
fi

# Check and clean up SQS queues
echo "Checking and cleaning up SQS queues..."
ALL_SQS_QUEUES=$(aws sqs list-queues --queue-name-prefix "${LOAD_TEST_PREFIX}" --query 'QueueUrls[]' --output text 2>/dev/null)
if [ -n "$ALL_SQS_QUEUES" ] && [ "$ALL_SQS_QUEUES" != "None" ]; then
    echo "⚠️  Found remaining SQS queues, cleaning up..."
    for queue_url in $ALL_SQS_QUEUES; do
        if [ "$queue_url" != "None" ] && [[ "$queue_url" == *"$LOAD_TEST_PREFIX"* ]]; then
            aws sqs delete-queue --queue-url "$queue_url" 2>/dev/null && echo "  ✅ Deleted queue: $queue_url" || echo "  ❌ Failed to delete queue: $queue_url"
        fi
    done
else
    echo "✅ No remaining SQS queues"
fi

# Check and clean up S3 buckets
echo "Checking and cleaning up S3 buckets..."
REMAINING_BUCKETS=$(aws s3 ls | grep "${LOAD_TEST_PREFIX}" | awk '{print $3}' 2>/dev/null)
if [ -n "$REMAINING_BUCKETS" ]; then
    echo "⚠️  Found remaining S3 buckets, cleaning up..."
    for bucket in $REMAINING_BUCKETS; do
        echo "  Cleaning bucket: $bucket"
        aws s3 rm s3://$bucket --recursive 2>/dev/null || true
        aws s3 rb s3://$bucket 2>/dev/null && echo "  ✅ Deleted bucket: $bucket" || echo "  ❌ Failed to delete bucket: $bucket"
    done
else
    echo "✅ No remaining S3 buckets"
fi

# Check EC2 instances
REMAINING_INSTANCES=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=*${LOAD_TEST_PREFIX}*,*${CLUSTER_NAME}*" "Name=instance-state-name,Values=running,stopped,stopping,pending" --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null)
if [ -n "$REMAINING_INSTANCES" ]; then
    echo "⚠️  Remaining EC2 instances: $REMAINING_INSTANCES"
else
    echo "✅ No remaining EC2 instances"
fi

echo "==============================================="
echo "🎉 CLEANUP COMPLETED!"
echo "==============================================="

# Final status check
FINAL_STACKS=$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED --query "StackSummaries[?contains(StackName, '${LOAD_TEST_PREFIX}') || contains(StackName, '${CLUSTER_NAME}')].StackName" --output text 2>/dev/null)
FINAL_CLUSTERS=$(aws eks list-clusters --query "clusters[?contains(@, '${LOAD_TEST_PREFIX}') || contains(@, '${CLUSTER_NAME}')]" --output text 2>/dev/null)
FINAL_QUEUES=$(aws sqs list-queues --queue-name-prefix "${LOAD_TEST_PREFIX}" --query 'QueueUrls' --output text 2>/dev/null)
FINAL_BUCKETS=$(aws s3 ls | grep "${LOAD_TEST_PREFIX}" | awk '{print $3}' 2>/dev/null)
FINAL_INSTANCES=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=*${LOAD_TEST_PREFIX}*,*${CLUSTER_NAME}*" "Name=instance-state-name,Values=running,stopped,stopping,pending" --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null)

if [ -z "$FINAL_STACKS" ] && [ -z "$FINAL_CLUSTERS" ] && [ -z "$FINAL_QUEUES" ] && [ -z "$FINAL_BUCKETS" ] && [ -z "$FINAL_INSTANCES" ]; then
    echo "✅ All resources have been successfully cleaned up!"
    echo "✅ System is ready for fresh deployment."
else
    echo "⚠️  Some resources may still exist:"
    [ -n "$FINAL_STACKS" ] && echo "   - CloudFormation stacks: $FINAL_STACKS"
    [ -n "$FINAL_CLUSTERS" ] && echo "   - EKS clusters: $FINAL_CLUSTERS"
    [ -n "$FINAL_QUEUES" ] && echo "   - SQS queues: $FINAL_QUEUES"
    [ -n "$FINAL_BUCKETS" ] && echo "   - S3 buckets: $FINAL_BUCKETS"
    [ -n "$FINAL_INSTANCES" ] && echo "   - EC2 instances: $FINAL_INSTANCES"
    echo ""
    echo "Manual cleanup commands:"
    echo "   - CloudFormation: aws cloudformation list-stacks"
    echo "   - EKS: aws eks list-clusters"
    echo "   - EC2: aws ec2 describe-instances"
    echo "   - S3: aws s3 ls"
    echo "   - SQS: aws sqs list-queues"
fi

echo "==============================================="