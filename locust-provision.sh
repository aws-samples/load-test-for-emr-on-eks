#!/bin/bash

set -e 

replace_in_file() {
    local search=$1
    local replace=$2
    local file=$3
    local temp_file=$(mktemp)
    
    cat "$file" | sed "s|$search|$replace|g" > "$temp_file"
    mv "$temp_file" "$file"
}


# Source environment variables
if [ ! -f "env.sh" ]; then
    echo "Error: env.sh file not found"
    exit 1
fi
source env.sh

# Check required environment variables
echo "Checking required environment variables..."
REQUIRED_VARS=(
    "LOAD_TEST_PREFIX"
    "AWS_REGION"
    "CLUSTER_NAME"
)

for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR}" ]; then
        echo "Error: Required environment variable $VAR is not set"
        exit 1
    fi
done


# Get VPC ID
echo "Getting VPC ID..."
vpc_id=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} \
    --query 'cluster.resourcesVpcConfig.vpcId' \
    --output text)

if [ -z "$vpc_id" ] || [ "$vpc_id" == "None" ]; then
    echo "Error: Could not retrieve VPC ID from EKS cluster ${CLUSTER_NAME}"
    exit 1
fi

echo "Using VPC ID: ${vpc_id}"

# Function to check if IAM role exists
check_role() {
    aws iam get-role --role-name "$1" 2>/dev/null
    return $?
}

# Function to check if instance profile exists
check_instance_profile() {
    aws iam get-instance-profile --instance-profile-name "$1" 2>/dev/null
    return $?
}

# Function to update EKS aws-auth configmap
update_aws_auth() {
    local ROLE_ARN="$1"
    local TEMP_FILE="/tmp/aws-auth-cm.yaml"
    local NEW_TEMP_FILE="/tmp/new-aws-auth-cm.yaml"

    echo "Updating EKS cluster aws-auth ConfigMap..."
    
    # Get current aws-auth configmap
    if ! kubectl get configmap aws-auth -n kube-system -o yaml > "$TEMP_FILE" 2>/dev/null; then
        # If aws-auth doesn't exist, create a new one
        cat << EOF > "$TEMP_FILE"
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${ROLE_ARN}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
        - system:masters
EOF
    else
        # Check if role already exists in mapRoles
        if ! grep -q "${ROLE_ARN}" "$TEMP_FILE"; then
            # Create new content with added role
            awk -v role_arn="${ROLE_ARN}" '
            /mapRoles: \|/ {
                print $0
                print "    - rolearn: " role_arn
                print "      username: system:node:{{EC2PrivateDNSName}}"
                print "      groups:"
                print "        - system:bootstrappers"
                print "        - system:nodes"
                print "        - system:masters"
                next
            }
            { print }' "$TEMP_FILE" > "$NEW_TEMP_FILE"
            
            # Replace original file with new content
            mv "$NEW_TEMP_FILE" "$TEMP_FILE"
        else
            echo "Role already exists in aws-auth ConfigMap"
            return 0
        fi
    fi

    # Apply the updated configmap
    kubectl apply -f "$TEMP_FILE"
    rm -f "$TEMP_FILE"
}

# Function to create IAM role and instance profile
create_iam_resources() {
    local ROLE_NAME="$1"
    local PROFILE_NAME="$2"

    # Create IAM role if it doesn't exist
    if ! check_role "$ROLE_NAME"; then
        echo "Creating IAM role: $ROLE_NAME"
        aws iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document '{
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Principal": {
                            "Service": "ec2.amazonaws.com"
                        },
                        "Action": "sts:AssumeRole"
                    }
                ]
            }'

        # Attach necessary policies
        aws iam attach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
        
        aws iam attach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
        
        aws iam attach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"

        aws iam attach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"

        aws iam attach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"

        aws iam attach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

        aws iam attach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonSSMPatchAssociation"


        
        # Create custom policy for EKS cluster access
        # First create the policy document file
        cat <<EOF > /tmp/ec2_custom_policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "eks:*",
                "iam:*",
                "ec2:*",
                "s3:ListAllMyBuckets",
                "s3:CreateBucket",
                "cloudformation:*"
            ],
            "Resource": "*"
        },
        {
            "Sid": "s3FullAccessForTestingBucket",
            "Effect": "Allow",
            "Action": [
                "s3:*"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}*",
                "arn:aws:s3:::${BUCKET_NAME}*/*"
            ]
        }
    ]
}
EOF

        # Then attach the policy to the role
        aws iam put-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-name "EC2ClientCustomPolicy" \
            --policy-document "file:///tmp/ec2_custom_policy.json"

        # Optionally, cleanup the temporary file
        rm -f /tmp/ec2_custom_policy.json
        
    else
        echo "IAM role $ROLE_NAME already exists"
    fi


    # Create instance profile if it doesn't exist
    if ! check_instance_profile "$PROFILE_NAME"; then
        echo "Creating instance profile: $PROFILE_NAME"
        aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME"
        
        # Wait for instance profile to be created
        sleep 5
        
        # Add role to instance profile
        aws iam add-role-to-instance-profile \
            --instance-profile-name "$PROFILE_NAME" \
            --role-name "$ROLE_NAME"
    else
        echo "Instance profile $PROFILE_NAME already exists"
    fi

    # Get Instance Profile ARN
    INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile --instance-profile-name ${PROFILE_NAME} \
        --query 'InstanceProfile.Arn' --output text)

    echo "Using Instance Profile ARN: ${INSTANCE_PROFILE_ARN}"
    return 0
}

# Function to delete IAM resources
delete_iam_resources() {
    local ROLE_NAME="$1"
    local PROFILE_NAME="$2"

    if check_instance_profile "$PROFILE_NAME"; then
        echo "Removing role from instance profile..."
        aws iam remove-role-from-instance-profile \
            --instance-profile-name "$PROFILE_NAME" \
            --role-name "$ROLE_NAME" || true

        echo "Deleting instance profile..."
        aws iam delete-instance-profile \
            --instance-profile-name "$PROFILE_NAME"
    fi

    if check_role "$ROLE_NAME"; then
        echo "Detaching policies from role..."
        # Get all attached policies and detach them
        POLICY_ARNS=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[*].PolicyArn' --output text)
        
        for POLICY_ARN in $POLICY_ARNS; do
            echo "Detaching policy: $POLICY_ARN"
            aws iam detach-role-policy \
                --role-name "$ROLE_NAME" \
                --policy-arn "$POLICY_ARN" || true
        done

        # Delete custom policy
        aws iam delete-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-name "EC2ClientCustomPolicy" || true

        echo "Deleting IAM role..."
        aws iam delete-role --role-name "$ROLE_NAME"
    fi
}

# Function to get security group ID if exists
get_security_group_id() {
    local sg_name=$1
    local sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${sg_name}" "Name=vpc-id,Values=${vpc_id}" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null)
    
    if [ -n "$sg_id" ] && [ "$sg_id" != "None" ]; then
        echo "$sg_id"
        return 0
    else
        return 1
    fi
}

# Function to check if an EC2 instance with a specific tag exists
check_ec2_instance() {
    local instance_id=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)
    if [ -n "$instance_id" ]; then
        echo "$instance_id"
        return 0
    else
        return 1
    fi
}

# Function to get public subnet ID from VPC
get_public_subnet() {
    PUBLIC_SUBNET_ID=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=map-public-ip-on-launch,Values=true" \
        --query 'Subnets[0].SubnetId' \
        --output text)
    
    if [ -z "$PUBLIC_SUBNET_ID" ] || [ "$PUBLIC_SUBNET_ID" == "None" ]; then
        echo "Error: Could not find a public subnet in VPC ${vpc_id}"
        exit 1
    fi
    echo "Public Subnet ID: ${PUBLIC_SUBNET_ID}"
}


# Set default action to apply if not specified
ACTION="apply"

# Override default if action parameter is provided
if [ ! -z "$1" ] && [ "$1" == "-action" ]; then
    if [ -z "$2" ] || { [ "$2" != "apply" ] && [ "$2" != "delete" ]; }; then
        echo "When using -action, it must be either 'apply' or 'delete'"
        exit 1
    fi
    ACTION=$2
fi

# Resource names
SECURITY_GROUP_NAME="${LOAD_TEST_PREFIX}-locust-sg"
INSTANCE_NAME="${LOAD_TEST_PREFIX}-eks-locust-client"
ROLE_NAME="${LOAD_TEST_PREFIX}-Locust-EC2-Role"
CLIENT_INSTANCE_PROFILE="${LOAD_TEST_PREFIX}-Locust-Instance-Profile"

if [ "$ACTION" == "apply" ]; then
    echo "Starting resource creation process..."
    
    # Create IAM resources
    create_iam_resources "$ROLE_NAME" "$CLIENT_INSTANCE_PROFILE"
    
    # Update EKS cluster aws-auth
    ROLE_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/${ROLE_NAME}"
    update_aws_auth "$ROLE_ARN"
    
    # Get public subnet
    get_public_subnet

    # Create or get security group
    echo "Checking security group: ${SECURITY_GROUP_NAME}"
    if SECURITY_GROUP_ID=$(get_security_group_id "${SECURITY_GROUP_NAME}"); then
        echo "Security group ${SECURITY_GROUP_NAME} already exists with ID: ${SECURITY_GROUP_ID}"
    else
        echo "Creating new security group: ${SECURITY_GROUP_NAME}"
        SECURITY_GROUP_ID=$(aws ec2 create-security-group \
            --group-name ${SECURITY_GROUP_NAME} \
            --description "Security group for EKS client EC2" \
            --vpc-id ${vpc_id}  | jq .GroupId | sed 's/\"//g')
    fi

    # Add EKS cluster security group rules
    echo "Adding EKS cluster security group rules..."

    # Get EKS cluster security group
    CLUSTER_SG=$(aws eks describe-cluster \
        --name ${CLUSTER_NAME} \
        --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
        --output text)

    if [ -n "$CLUSTER_SG" ] && [ "$CLUSTER_SG" != "None" ]; then
        echo "Adding rules for EKS cluster security group: ${CLUSTER_SG}"
        
        # Check if the rule already exists
        EXISTING_RULE=$(aws ec2 describe-security-group-rules \
            --filters "Name=group-id,Values=${CLUSTER_SG}" \
            --query "SecurityGroupRules[?Protocol=='-1' && SourceGroupId=='${SECURITY_GROUP_ID}']" \
            --output text)
        
        if [ -z "$EXISTING_RULE" ]; then
            # Add rule to cluster security group to allow all traffic from client security group
            aws ec2 authorize-security-group-ingress \
                --group-id ${CLUSTER_SG} \
                --protocol all \
                --source-group ${SECURITY_GROUP_ID}

            # Add rule to client security group to allow all traffic from cluster
            aws ec2 authorize-security-group-ingress \
                --group-id ${SECURITY_GROUP_ID} \
                --protocol all \
                --source-group ${CLUSTER_SG}
        else
            echo "EKS cluster security group rules already exist"
        fi
    fi

    # Get EKS control plane security group
    CONTROL_PLANE_SG=$(aws eks describe-cluster \
        --name ${CLUSTER_NAME} \
        --query 'cluster.resourcesVpcConfig.securityGroupIds[0]' \
        --output text)

    if [ -n "$CONTROL_PLANE_SG" ] && [ "$CONTROL_PLANE_SG" != "None" ]; then
        echo "Adding rules for EKS control plane security group: ${CONTROL_PLANE_SG}"
        
        # Check if the rule already exists
        EXISTING_RULE=$(aws ec2 describe-security-group-rules \
            --filters "Name=group-id,Values=${SECURITY_GROUP_ID}" \
            --query "SecurityGroupRules[?Protocol=='-1' && SourceGroupId=='${CONTROL_PLANE_SG}']" \
            --output text)
        
        if [ -z "$EXISTING_RULE" ]; then
            # Add rule to allow communication with EKS control plane
            aws ec2 authorize-security-group-ingress \
                --group-id ${SECURITY_GROUP_ID} \
                --protocol all \
                --source-group ${CONTROL_PLANE_SG}
        else
            echo "EKS control plane security group rules already exist"
        fi
    fi

    # Create EC2 instance if it doesn't exist
    if ! check_ec2_instance "$INSTANCE_NAME"; then
        echo "Creating EC2 instance: ${INSTANCE_NAME}"
        # Get latest Amazon Linux 2023 AMI
        AMI_ID=$(aws ec2 describe-images \
            --owners amazon \
            --filters "Name=name,Values=al2023-ami-*-x86_64" \
            --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
            --output text)

        # Create user data script
        cat << EOF > /tmp/user-data.sh
#!/bin/bash
set -e

# Configure simple logging - only errors and important messages
exec > >(tee /var/log/user-data.log) 2>&1
echo "[$(date)] Starting user-data script execution"

# Install required packages
echo "[$(date)] Installing required packages"
sudo yum install -y unzip git

# Switch to ec2-user for all operations
sudo -i -u ec2-user bash << 'EEOF'
echo "[$(date)] Setting up environment as ec2-user"

# Create working directory
mkdir -p ~/load-test
cd ~/load-test

# Download assets from S3
echo "[$(date)] Downloading assets from S3"
aws s3 cp "s3://${BUCKET_NAME}/locust-asset/load-test-for-emr-on-eks.zip" ./load-test-for-emr-on-eks.zip || { echo "[ERROR] Failed to download from S3"; exit 1; }
unzip load-test-for-emr-on-eks.zip || { echo "[ERROR] Failed to unzip assets"; exit 1; }
rm load-test-for-emr-on-eks.zip

# Load environment variables
source ./load-test-for-emr-on-eks/locust/env.sh || { echo "[ERROR] Failed to source env.sh"; exit 1; }

# Install kubectl
echo "[$(date)] Installing kubectl"
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" || { echo "[ERROR] Failed to download kubectl"; exit 1; }
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl || { echo "[ERROR] Failed to install kubectl"; exit 1; }

# Install helm
echo "[$(date)] Installing helm"
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 || { echo "[ERROR] Failed to download helm script"; exit 1; }
chmod 700 get_helm.sh
./get_helm.sh || { echo "[ERROR] Failed to install helm"; exit 1; }
rm -f get_helm.sh

# Install eksctl
echo "[$(date)] Installing eksctl"
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp || { echo "[ERROR] Failed to download eksctl"; exit 1; }
sudo mv /tmp/eksctl /usr/local/bin || { echo "[ERROR] Failed to install eksctl"; exit 1; }

# Setup kubeconfig
echo "[$(date)] Setting up kubeconfig"
mkdir -p ~/.kube
aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME} || { echo "[ERROR] Failed to update kubeconfig"; exit 1; }

# Install pip and packages
echo "[$(date)] Installing pip and required packages"
curl -O https://bootstrap.pypa.io/get-pip.py || { echo "[ERROR] Failed to download pip"; exit 1; }
python3 get-pip.py --user || { echo "[ERROR] Failed to install pip"; exit 1; }
export PATH=$PATH:~/.local/bin
echo 'export PATH=$PATH:~/.local/bin' >> ~/.bashrc
echo 'export PATH=$PATH:~/.local/bin' >> ~/.profile

cd ~/load-test/load-test-for-emr-on-eks/locust
pip3 install --user -r requirements.txt || { echo "[ERROR] Failed to install Python requirements"; exit 1; }

# Verify installations
echo "[$(date)] Verifying installations"
which pip3 || echo "[WARNING] pip3 not found in PATH"
which locust || echo "[WARNING] locust not found in PATH"
pip3 list | grep locust || echo "[WARNING] locust package not installed"
EEOF

echo "[$(date)] Locust EC2 setup completed"
EOF

        INSTANCE_ID=$(aws ec2 run-instances \
            --image-id ${AMI_ID} \
            --instance-type m5.2xlarge \
            --subnet-id ${PUBLIC_SUBNET_ID} \
            --security-group-ids ${SECURITY_GROUP_ID} \
            --iam-instance-profile Arn=${INSTANCE_PROFILE_ARN} \
            --user-data file:///tmp/user-data.sh \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Environment,Value=${LOAD_TEST_PREFIX}},{Key=CreatedBy,Value=automation},{Key=Purpose,Value=eks-locust}]" \
            --query 'Instances[0].InstanceId' \
            --output text)

        # Wait for instance to be running
        echo "Waiting for instance to be running..."
        aws ec2 wait instance-running --instance-ids ${INSTANCE_ID}

        # Get Private IP for Prometheus 
        PRIVATE_IP=$(aws ec2 describe-instances \
            --instance-ids ${INSTANCE_ID} \
            --query 'Reservations[0].Instances[0].PrivateIpAddress' \
            --output text)
        
        # Replace the IP to Prometheus on eks
        echo "Update the Locust Private IP to Prometheus on EKS, re-installing Prometheus"
        replace_in_file "{LOCUST_IP_PRIV}" "$PRIVATE_IP" "./resources/prometheus-values.yaml"

        helm uninstall prometheus -n prometheus 
        helm upgrade --install prometheus prometheus-community/kube-prometheus-stack -n prometheus -f ./resources/prometheus-values.yaml
        echo "Prometheus has been re-installed."

        echo "EC2 instance created successfully!"
        echo "Instance ID: ${INSTANCE_ID}"
        echo "Private IP: ${PRIVATE_IP}"
        echo "==============================================="
        echo "To connect to the instance use AWS Systems Manager (SSM)"
        echo "==============================================="
    else
        INSTANCE_ID=$(check_ec2_instance "$INSTANCE_NAME")
        PRIVATE_IP=$(aws ec2 describe-instances \
            --instance-ids ${INSTANCE_ID} \
            --query 'Reservations[0].Instances[0].PrivateIpAddress' \
            --output text)

        echo "EC2 instance ${INSTANCE_NAME} already exists"
        echo "Instance ID: ${INSTANCE_ID}"
        echo "Private IP: ${PRIVATE_IP}"
        echo "==============================================="
        echo "To connect to the instance use AWS Systems Manager (SSM)"
        echo "==============================================="
    fi

elif [ "$ACTION" == "delete" ]; then
    echo "Starting resource deletion process..."
    
    # Delete EC2 instance if exists
    if INSTANCE_ID=$(check_ec2_instance "$INSTANCE_NAME"); then
        echo "Terminating EC2 instance: ${INSTANCE_ID}"
        aws ec2 terminate-instances --instance-ids ${INSTANCE_ID}
        echo "Waiting for instance termination..."
        aws ec2 wait instance-terminated --instance-ids ${INSTANCE_ID}
    else
        echo "No EC2 instance found with name: ${INSTANCE_NAME}"
    fi

    # Delete security group if exists
    if SECURITY_GROUP_ID=$(get_security_group_id "${SECURITY_GROUP_NAME}"); then
        echo "Found security group ${SECURITY_GROUP_NAME} (${SECURITY_GROUP_ID})"
        
        # Get EKS cluster security group
        CLUSTER_SG=$(aws eks describe-cluster \
            --name ${CLUSTER_NAME} \
            --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
            --output text)

        if [ -n "$CLUSTER_SG" ] && [ "$CLUSTER_SG" != "None" ]; then
            echo "Removing rules from EKS cluster security group: ${CLUSTER_SG}"
            # Remove ingress rule from cluster security group
            aws ec2 revoke-security-group-ingress \
                --group-id ${CLUSTER_SG} \
                --protocol all \
                --source-group ${SECURITY_GROUP_ID} || true

            # Remove ingress rule from client security group
            aws ec2 revoke-security-group-ingress \
                --group-id ${SECURITY_GROUP_ID} \
                --protocol all \
                --source-group ${CLUSTER_SG} || true
        fi

        # Get EKS control plane security group
        CONTROL_PLANE_SG=$(aws eks describe-cluster \
            --name ${CLUSTER_NAME} \
            --query 'cluster.resourcesVpcConfig.securityGroupIds[0]' \
            --output text)

        if [ -n "$CONTROL_PLANE_SG" ] && [ "$CONTROL_PLANE_SG" != "None" ]; then
            echo "Removing rules for EKS control plane security group: ${CONTROL_PLANE_SG}"
            # Remove ingress rule for control plane access
            aws ec2 revoke-security-group-ingress \
                --group-id ${SECURITY_GROUP_ID} \
                --protocol all \
                --source-group ${CONTROL_PLANE_SG} || true
        fi

        # Wait a bit to ensure all rules are removed
        echo "Waiting for security group rules to be removed..."
        sleep 5

        echo "Deleting security group: ${SECURITY_GROUP_NAME} (${SECURITY_GROUP_ID})"
        # Try to delete the security group
        if aws ec2 delete-security-group --group-id ${SECURITY_GROUP_ID}; then
            echo "Security group deleted successfully"
        else
            echo "Warning: Failed to delete security group. It might still be attached to running instances or network interfaces."
            echo "Please check the AWS console and try again later."
        fi
    else
        echo "No security group found with name: ${SECURITY_GROUP_NAME}"
    fi

    # Delete IAM resources
    delete_iam_resources "$ROLE_NAME" "$CLIENT_INSTANCE_PROFILE"

    echo "Resource deletion completed"
fi
