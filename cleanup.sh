#!/bin/bash

# Enhanced Complete Cleanup Script
# Automatically removes ALL resources without manual intervention

set -e  # Exit on error
source env.sh

echo "==============================================="
echo "  🧹 ENHANCED COMPLETE CLEANUP"
echo "  Automatic removal of ALL resources"
echo "==============================================="
echo ""
echo "Project: ${LOAD_TEST_PREFIX}"
echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"
echo ""

# Function to safely delete resources with retries
safe_delete() {
    local resource_type=$1
    local delete_command=$2
    local max_retries=3
    local retry=0
    
    while [ $retry -lt $max_retries ]; do
        if eval "$delete_command" 2>/dev/null; then
            echo "   ✅ $resource_type deleted successfully"
            return 0
        else
            retry=$((retry + 1))
            if [ $retry -lt $max_retries ]; then
                echo "   ⏳ $resource_type deletion failed, retrying ($retry/$max_retries)..."
                sleep 5
            else
                echo "   ⚠️  $resource_type deletion failed after $max_retries attempts"
                return 1
            fi
        fi
    done
}

# Function to force delete IAM role with all dependencies
force_delete_iam_role() {
    local role_name=$1
    echo "🗑️  Force deleting IAM role: $role_name"
    
    if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
        # Remove from instance profiles
        echo "   Removing from instance profiles..."
        aws iam list-instance-profiles-for-role --role-name "$role_name" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null | while read profile_name; do
            if [[ -n "$profile_name" && "$profile_name" != "None" ]]; then
                echo "     Removing from profile: $profile_name"
                aws iam remove-role-from-instance-profile --instance-profile-name "$profile_name" --role-name "$role_name" 2>/dev/null || true
                aws iam delete-instance-profile --instance-profile-name "$profile_name" 2>/dev/null || true
            fi
        done
        
        # Detach managed policies (handle multiple policies in one line)
        echo "   Detaching managed policies..."
        aws iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | tr '\t' '\n' | while read policy_arn; do
            if [[ -n "$policy_arn" && "$policy_arn" != "None" ]]; then
                echo "     Detaching policy: $policy_arn"
                aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" 2>/dev/null || true
            fi
        done
        
        # Delete inline policies
        echo "   Deleting inline policies..."
        aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames[]' --output text 2>/dev/null | tr '\t' '\n' | while read policy_name; do
            if [[ -n "$policy_name" && "$policy_name" != "None" ]]; then
                echo "     Deleting inline policy: $policy_name"
                aws iam delete-role-policy --role-name "$role_name" --policy-name "$policy_name" 2>/dev/null || true
            fi
        done
        
        # Wait for policies to detach
        sleep 3
        
        # Delete the role
        echo "   Deleting role: $role_name"
        if aws iam delete-role --role-name "$role_name" 2>/dev/null; then
            echo "   ✅ Role $role_name deleted successfully"
        else
            echo "   ⚠️  Failed to delete role $role_name"
        fi
    else
        echo "   ✅ Role $role_name already deleted"
    fi
}

# Function to clean up all SQS queues
cleanup_sqs_queues() {
    echo "🗑️  Cleaning up ALL SQS queues..."
    
    # Get all queues that contain our prefix
    aws sqs list-queues --region ${AWS_REGION} --query 'QueueUrls[]' --output text 2>/dev/null | while read queue_url; do
        if [[ -n "$queue_url" && "$queue_url" == *"${LOAD_TEST_PREFIX}"* ]]; then
            queue_name=$(basename "$queue_url")
            echo "   Deleting queue: $queue_name"
            aws sqs delete-queue --queue-url "$queue_url" --region ${AWS_REGION} 2>/dev/null || true
        fi
    done
    
    # Also try specific queue names
    for queue_name in "${SQS_HIGH_PRIORITY_QUEUE}" "${SQS_MEDIUM_PRIORITY_QUEUE}" "${SQS_LOW_PRIORITY_QUEUE}" "${SQS_DLQ}"; do
        queue_url=$(aws sqs get-queue-url --queue-name "$queue_name" --region ${AWS_REGION} --query 'QueueUrl' --output text 2>/dev/null)
        if [[ -n "$queue_url" && "$queue_url" != "None" ]]; then
            echo "   Deleting specific queue: $queue_name"
            aws sqs delete-queue --queue-url "$queue_url" --region ${AWS_REGION} 2>/dev/null || true
        fi
    done
}

# Function to clean up all IAM resources
cleanup_all_iam_resources() {
    echo "🗑️  Cleaning up ALL IAM resources..."
    
    # Get all roles with our prefix
    aws iam list-roles --query 'Roles[?contains(RoleName, `'${LOAD_TEST_PREFIX}'`)].RoleName' --output text 2>/dev/null | tr '\t' '\n' | while read role_name; do
        if [[ -n "$role_name" && "$role_name" != "None" ]]; then
            force_delete_iam_role "$role_name"
        fi
    done
    
    # Clean up policies
    echo "🗑️  Cleaning up IAM policies..."
    aws iam list-policies --scope Local --query 'Policies[?contains(PolicyName, `'${LOAD_TEST_PREFIX}'`)].Arn' --output text 2>/dev/null | tr '\t' '\n' | while read policy_arn; do
        if [[ -n "$policy_arn" && "$policy_arn" != "None" ]]; then
            echo "   Deleting policy: $policy_arn"
            # First detach from all entities
            aws iam list-entities-for-policy --policy-arn "$policy_arn" --query 'PolicyRoles[].RoleName' --output text 2>/dev/null | tr '\t' '\n' | while read role_name; do
                if [[ -n "$role_name" ]]; then
                    aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" 2>/dev/null || true
                fi
            done
            aws iam delete-policy --policy-arn "$policy_arn" 2>/dev/null || true
        fi
    done
}

# Function to force terminate EC2 instances
force_terminate_ec2_instances() {
    echo "🗑️  Force terminating EC2 instances..."
    
    # Get all instances with our prefix
    aws ec2 describe-instances --region ${AWS_REGION} \
        --filters "Name=tag:Name,Values=*${LOAD_TEST_PREFIX}*" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n' | while read instance_id; do
        if [[ -n "$instance_id" && "$instance_id" != "None" ]]; then
            echo "   Terminating instance: $instance_id"
            aws ec2 terminate-instances --instance-ids "$instance_id" --region ${AWS_REGION} 2>/dev/null || true
        fi
    done
    
    # Also check for Karpenter instances
    aws ec2 describe-instances --region ${AWS_REGION} \
        --filters "Name=tag:karpenter.sh/cluster,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n' | while read instance_id; do
        if [[ -n "$instance_id" && "$instance_id" != "None" ]]; then
            echo "   Terminating Karpenter instance: $instance_id"
            aws ec2 terminate-instances --instance-ids "$instance_id" --region ${AWS_REGION} 2>/dev/null || true
        fi
    done
}

# Function to force cleanup VPC and all dependencies
force_cleanup_vpc() {
    local vpc_pattern=$1
    echo "🗑️  Force cleaning up VPCs matching pattern: $vpc_pattern"
    
    # Find VPCs with our cluster name in tags
    aws ec2 describe-vpcs --region ${AWS_REGION} --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=${CLUSTER_NAME}" --query "Vpcs[*].VpcId" --output text 2>/dev/null | tr '\t' '\n' | while read vpc_id; do
        if [[ -n "$vpc_id" && "$vpc_id" != "None" ]]; then
            echo "   Processing VPC: $vpc_id"
            
            # Delete subnets
            aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --region ${AWS_REGION} --query "Subnets[*].SubnetId" --output text | tr '\t' '\n' | while read subnet_id; do
                if [[ -n "$subnet_id" && "$subnet_id" != "None" ]]; then
                    echo "     Deleting subnet: $subnet_id"
                    aws ec2 delete-subnet --subnet-id "$subnet_id" --region ${AWS_REGION} 2>/dev/null || true
                fi
            done
            
            # Detach and delete internet gateways
            aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" --region ${AWS_REGION} --query "InternetGateways[*].InternetGatewayId" --output text | tr '\t' '\n' | while read igw_id; do
                if [[ -n "$igw_id" && "$igw_id" != "None" ]]; then
                    aws ec2 detach-internet-gateway --internet-gateway-id "$igw_id" --vpc-id "$vpc_id" --region ${AWS_REGION} 2>/dev/null || true
                    aws ec2 delete-internet-gateway --internet-gateway-id "$igw_id" --region ${AWS_REGION} 2>/dev/null || true
                fi
            done
            
            # Delete custom route tables
            aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" --region ${AWS_REGION} --query "RouteTables[?Associations[0].Main==`false`].RouteTableId" --output text | tr '\t' '\n' | while read rt_id; do
                if [[ -n "$rt_id" && "$rt_id" != "None" ]]; then
                    aws ec2 delete-route-table --route-table-id "$rt_id" --region ${AWS_REGION} 2>/dev/null || true
                fi
            done
            
            # Delete custom security groups
            aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" --region ${AWS_REGION} --query "SecurityGroups[?GroupName!=`default`].GroupId" --output text | tr '\t' '\n' | while read sg_id; do
                if [[ -n "$sg_id" && "$sg_id" != "None" ]]; then
                    aws ec2 delete-security-group --group-id "$sg_id" --region ${AWS_REGION} 2>/dev/null || true
                fi
            done
            
            # Disassociate additional CIDR blocks
            aws ec2 describe-vpcs --vpc-ids "$vpc_id" --region ${AWS_REGION} --query "Vpcs[0].CidrBlockAssociationSet[?CidrBlock!=`10.0.0.0/16`].AssociationId" --output text | tr '\t' '\n' | while read assoc_id; do
                if [[ -n "$assoc_id" && "$assoc_id" != "None" ]]; then
                    aws ec2 disassociate-vpc-cidr-block --association-id "$assoc_id" --region ${AWS_REGION} 2>/dev/null || true
                fi
            done
            
            # Wait and delete VPC
            sleep 10
            aws ec2 delete-vpc --vpc-id "$vpc_id" --region ${AWS_REGION} 2>/dev/null || true
        fi
    done
}
# Function to clean up CloudFormation stacks with force
cleanup_cloudformation_stacks() {
    echo "🗑️  Cleaning up CloudFormation stacks..."
    
    # List of potential stack patterns
    local stack_patterns=(
        "Karpenter-${LOAD_TEST_PREFIX}"
        "eksctl-${CLUSTER_NAME}-*"
        "${LOAD_TEST_PREFIX}-*"
    )
    
    for pattern in "${stack_patterns[@]}"; do
        aws cloudformation list-stacks --region ${AWS_REGION} \
            --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
            --query 'StackSummaries[].StackName' --output text 2>/dev/null | tr '\t' '\n' | while read stack_name; do
            if [[ -n "$stack_name" && "$stack_name" == $pattern ]]; then
                echo "   Force deleting stack: $stack_name"
                aws cloudformation delete-stack --stack-name "$stack_name" --region ${AWS_REGION} 2>/dev/null || true
            fi
        done
    done
}

# Start the enhanced cleanup process
echo "🚀 Starting enhanced automatic cleanup..."
echo ""

# Step 1: Delete Spark applications first
echo "1️⃣  Deleting Spark applications..."
kubectl delete sparkapplications --all --all-namespaces 2>/dev/null || true

# Step 2: Clean up Kubernetes resources
echo "2️⃣  Cleaning up Kubernetes resources..."
if kubectl cluster-info >/dev/null 2>&1; then
    # Delete AI Agents
    kubectl delete namespace spark-agents --ignore-not-found=true 2>/dev/null || true
    kubectl delete clusterrole spark-agents-cluster-role --ignore-not-found=true 2>/dev/null || true
    kubectl delete clusterrolebinding spark-agents-cluster-role-binding --ignore-not-found=true 2>/dev/null || true
    
    # Delete Locust
    kubectl delete namespace locust --ignore-not-found=true 2>/dev/null || true
    
    # Delete Prometheus
    helm uninstall prometheus -n prometheus 2>/dev/null || true
    kubectl delete namespace prometheus --ignore-not-found=true 2>/dev/null || true
    
    # Delete Spark Operators
    kubectl delete namespace spark-operator --ignore-not-found=true 2>/dev/null || true
    for i in {0..9}; do
        kubectl delete namespace "spark-job$i" --ignore-not-found=true 2>/dev/null || true
    done
    
    # Delete Karpenter
    helm uninstall karpenter -n kube-system 2>/dev/null || true
    kubectl delete -f ./resources/karpenter-nodepool.yaml --ignore-not-found=true 2>/dev/null || true
fi

# Step 3: Force terminate EC2 instances
echo "3️⃣  Force terminating EC2 instances..."
force_terminate_ec2_instances

# Wait for instances to terminate
echo "   Waiting 30 seconds for instances to terminate..."
sleep 30

# Step 4: Clean up SQS queues
echo "4️⃣  Cleaning up SQS queues..."
cleanup_sqs_queues

# Step 5: Clean up ECR repositories
echo "5️⃣  Cleaning up ECR repositories..."
if aws ecr describe-repositories --repository-names "${AGENT_ECR_REPO}" --region ${AWS_REGION} >/dev/null 2>&1; then
    echo "   Deleting ECR repository: ${AGENT_ECR_REPO}"
    aws ecr delete-repository --repository-name "${AGENT_ECR_REPO}" --region ${AWS_REGION} --force 2>/dev/null || true
fi

# Step 6: Clean up S3 buckets
echo "6️⃣  Cleaning up S3 buckets..."
if aws s3 ls "s3://${BUCKET_NAME}" >/dev/null 2>&1; then
    echo "   Emptying and deleting S3 bucket: ${BUCKET_NAME}"
    aws s3 rm "s3://${BUCKET_NAME}" --recursive 2>/dev/null || true
    aws s3 rb "s3://${BUCKET_NAME}" 2>/dev/null || true
fi

# Step 7: Clean up Grafana workspaces
echo "7️⃣  Cleaning up Grafana workspaces..."
GRAFANA_ID=$(aws grafana list-workspaces --region ${AWS_REGION} --query 'workspaces[?name==`'${LOAD_TEST_PREFIX}'`].id' --output text 2>/dev/null)
if [[ -n "$GRAFANA_ID" && "$GRAFANA_ID" != "None" ]]; then
    echo "   Deleting Grafana workspace: $GRAFANA_ID"
    aws grafana delete-workspace --workspace-id "$GRAFANA_ID" --region ${AWS_REGION} 2>/dev/null || true
fi

# Step 7.5: Force cleanup VPCs
echo "7️⃣.5️⃣ Force cleaning up VPCs..."
force_cleanup_vpc "${CLUSTER_NAME}"
# Step 8: Clean up CloudFormation stacks
echo "8️⃣  Cleaning up CloudFormation stacks..."
cleanup_cloudformation_stacks

# Step 9: Force delete EKS cluster
echo "9️⃣  Force deleting EKS cluster..."
if aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} >/dev/null 2>&1; then
    echo "   Force deleting EKS cluster: ${CLUSTER_NAME}"
    eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --force --disable-nodegroup-eviction --wait 2>/dev/null || true
fi

# Step 10: Clean up all IAM resources (after EKS deletion)
echo "🔟 Cleaning up ALL IAM resources..."
cleanup_all_iam_resources

# Step 11: Clean up local files
echo "1️⃣1️⃣ Cleaning up local files..."
rm -f *.pem *.log spark-operator-*.tgz 2>/dev/null || true

# Step 12: Wait and final verification
echo "1️⃣2️⃣ Final verification (waiting 30 seconds for propagation)..."
sleep 30

echo ""
echo "==============================================="
echo "  🔍 AUTOMATIC CLEANUP VERIFICATION"
echo "==============================================="
echo ""

# Comprehensive verification
verification_failed=false

echo "🔍 Verifying cleanup results:"
echo ""

# Check EKS clusters
EKS_CHECK=$(aws eks list-clusters --region ${AWS_REGION} --query 'clusters[?contains(@, `'${CLUSTER_NAME}'`)]' --output text 2>/dev/null)
if [[ -z "$EKS_CHECK" ]]; then
    echo "✅ EKS Clusters: CLEAN"
else
    echo "❌ EKS Clusters: $EKS_CHECK"
    verification_failed=true
fi

# Check S3 buckets
S3_CHECK=$(aws s3 ls 2>/dev/null | grep ${LOAD_TEST_PREFIX} || echo "")
if [[ -z "$S3_CHECK" ]]; then
    echo "✅ S3 Buckets: CLEAN"
else
    echo "❌ S3 Buckets: $S3_CHECK"
    verification_failed=true
fi

# Check SQS queues
SQS_CHECK=$(aws sqs list-queues --region ${AWS_REGION} --query 'QueueUrls[?contains(@, `'${LOAD_TEST_PREFIX}'`)]' --output text 2>/dev/null)
if [[ -z "$SQS_CHECK" || "$SQS_CHECK" == "None" ]]; then
    echo "✅ SQS Queues: CLEAN"
else
    echo "❌ SQS Queues: $SQS_CHECK"
    verification_failed=true
fi

# Check ECR repositories
ECR_CHECK=$(aws ecr describe-repositories --region ${AWS_REGION} --query 'repositories[?contains(repositoryName, `'${LOAD_TEST_PREFIX}'`) || contains(repositoryName, `spark-agents`)].repositoryName' --output text 2>/dev/null)
if [[ -z "$ECR_CHECK" ]]; then
    echo "✅ ECR Repositories: CLEAN"
else
    echo "❌ ECR Repositories: $ECR_CHECK"
    verification_failed=true
fi

# Check IAM roles
IAM_CHECK=$(aws iam list-roles --query 'Roles[?contains(RoleName, `'${LOAD_TEST_PREFIX}'`)].RoleName' --output text 2>/dev/null)
if [[ -z "$IAM_CHECK" ]]; then
    echo "✅ IAM Roles: CLEAN"
else
    echo "❌ IAM Roles: $IAM_CHECK"
    verification_failed=true
fi

# Check IAM policies
POLICY_CHECK=$(aws iam list-policies --scope Local --query 'Policies[?contains(PolicyName, `'${LOAD_TEST_PREFIX}'`)].PolicyName' --output text 2>/dev/null)
if [[ -z "$POLICY_CHECK" ]]; then
    echo "✅ IAM Policies: CLEAN"
else
    echo "❌ IAM Policies: $POLICY_CHECK"
    verification_failed=true
fi

# Check EC2 instances
EC2_CHECK=$(aws ec2 describe-instances --region ${AWS_REGION} --filters "Name=tag:Name,Values=*${LOAD_TEST_PREFIX}*" "Name=instance-state-name,Values=running,pending,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)
if [[ -z "$EC2_CHECK" ]]; then
    echo "✅ EC2 Instances: CLEAN"
else
    echo "❌ EC2 Instances: $EC2_CHECK"
    verification_failed=true
fi

# Check Grafana workspaces
GRAFANA_CHECK=$(aws grafana list-workspaces --region ${AWS_REGION} --query 'workspaces[?name==`'${LOAD_TEST_PREFIX}'`].id' --output text 2>/dev/null)
if [[ -z "$GRAFANA_CHECK" || "$GRAFANA_CHECK" == "None" ]]; then
    echo "✅ Grafana Workspaces: CLEAN"
else
    echo "❌ Grafana Workspaces: $GRAFANA_CHECK"
    verification_failed=true
fi

echo ""
echo "==============================================="
if [ "$verification_failed" = false ]; then
    echo "  🎉 ENHANCED CLEANUP SUCCESSFUL!"
    echo "==============================================="
    echo ""
    echo "✅ ALL RESOURCES AUTOMATICALLY DELETED!"
    echo "💰 No ongoing AWS costs from this project!"
    echo "🎯 Your AWS account is completely clean!"
    echo ""
    echo "🚀 Ready for next deployment with:"
    echo "   ./setup-everything.sh"
else
    echo "  ⚠️  CLEANUP PARTIALLY COMPLETED"
    echo "==============================================="
    echo ""
    echo "Some resources may still exist (see above)."
    echo "This could be due to:"
    echo "• AWS propagation delays (wait 5-10 minutes)"
    echo "• Resource dependencies still resolving"
    echo "• Permissions issues"
    echo ""
    echo "💡 You can re-run this script or check manually."
fi

echo ""
echo "✨ Enhanced cleanup script execution completed!"
