#!/bin/bash

# Parse command-line arguments
for arg in "$@"; do
  case $arg in
    eks-version=*)
      EKS_VERSION="${arg#*=}"
      shift
      ;;
    karpenter-version=*)
      KARPENTER_VERSION="${arg#*=}"
      shift
      ;;
    cluster-name=*)
      CLUSTER_NAME="${arg#*=}"
      shift
      ;;  
    aws-region=*)
      AWS_REGION="${arg#*=}"
      shift
      ;;  
    *)
      echo "Unknown argument: $arg"
      exit 1
      ;;
  esac
done

if [[ -z "$EKS_VERSION" ]] || [[ -z "$KARPENTER_VERSION" ]] || [[ -z "$CLUSTER_NAME" ]] || [[ -z "$AWS_REGION" ]]; then
  echo "Usage: $0 eks-version=<EKS_VERSION> karpenter-version=<KARPENTER_VERSION> cluster-name=<CLUSTER_NAME> aws-region=<AWS_REGION>"
  echo "Example: $0 eks-version=1.32 karpenter-version=1.8.5 cluster-name=eks-test-1-32 aws-region=us-west-2"
  exit 1
fi

create_and_attach_ebs_encryption_policy() {
  local ROLE_NAME="$1"
  local CLUSTER_NAME="$2"
  local POLICY_NAME="KarpenterEBSEncryptionPolicy-${CLUSTER_NAME}"

  echo "Creating EBS encryption policy: ${POLICY_NAME}"

  # Create the EBS encryption policy document
  cat <<EOF > /tmp/ebs-encryption-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "kms:CreateGrant",
                "kms:Decrypt",
                "kms:DescribeKey",
                "kms:Encrypt",
                "kms:GenerateDataKey",
                "kms:GenerateDataKeyWithoutPlaintext",
                "kms:ReEncrypt*"
            ],
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "kms:ViaService": [
                        "ec2.${AWS_REGION}.amazonaws.com"
                    ]
                }
            }
        }
    ]
}
EOF

  # Check if policy already exists
  POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" --output text)

  if [[ -z "$POLICY_ARN" ]]; then
    echo "Creating new policy: ${POLICY_NAME}"
    POLICY_ARN=$(aws iam create-policy \
      --policy-name "${POLICY_NAME}" \
      --policy-document file:///tmp/ebs-encryption-policy.json \
      --query 'Policy.Arn' \
      --output text)
    echo "Created policy with ARN: ${POLICY_ARN}"
  else
    echo "Policy ${POLICY_NAME} already exists with ARN: ${POLICY_ARN}"
  fi

  # Attach the policy to the role
  if aws iam list-attached-role-policies --role-name "${ROLE_NAME}" --query "AttachedPolicies[?PolicyArn=='${POLICY_ARN}'].PolicyArn" --output text | grep -q "${POLICY_ARN}"; then
    echo "Policy ${POLICY_NAME} is already attached to role ${ROLE_NAME}"
  else
    echo "Attaching policy ${POLICY_NAME} to role ${ROLE_NAME}"
    aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${POLICY_ARN}"
    echo "Successfully attached EBS encryption policy to ${ROLE_NAME}"
  fi

  # Clean up temporary file
  rm -f /tmp/ebs-encryption-policy.json
}

setup_karpenter() {
  local EKS_VERSION="$1"
  local KARPENTER_VERSION="$2"
  local CLUSTER_NAME="$3"
  local AWS_REGION="$4"

  # Validate EKS version and cluster name
  CLUSTER_VERSION=$(echo "$CLUSTER_NAME" | grep -oE '([0-9]+\.[0-9]+|[0-9]+-[0-9]+)' | tail -1 | sed 's/-/\./')
  if [[ "$EKS_VERSION" != "$CLUSTER_VERSION" ]]; then
    echo "$EKS_VERSION and $CLUSTER_NAME suffix do not match. Please provide matching EKS version and cluster name."
    return 1
  fi

  local KARPENTER_CONTROLLER_ROLE="KarpenterControllerRole-${CLUSTER_NAME}"
  local KARPENTER_CONTROLLER_POLICY="KarpenterControllerPolicy-${CLUSTER_NAME}"
  local KARPENTER_NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"

  echo "====================================================="
  echo " 1. Connect to the EKS cluster ${CLUSTER_NAME} to install Karpenter ${KARPENTER_VERSION})."
  echo "====================================================="

  aws eks update-kubeconfig --region $AWS_REGION --name "${CLUSTER_NAME}"

  echo "================================================================================================================"
  echo " Ref to https://karpenter.sh/v1.8/reference/cloudformation/"
  echo " 2. Create Karpenter IAM roles, SQS queue, and event rules for EC2 interruption handling."
  echo "================================================================================================================"

  curl https://raw.githubusercontent.com/aws/karpenter-provider-aws/v"${KARPENTER_VERSION}"/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml > ./resources/karpenter/cloudformation-${KARPENTER_VERSION}.yaml
  aws cloudformation deploy \
    --stack-name "karpenter-infra-${CLUSTER_NAME}" \
    --template-file ./resources/karpenter/cloudformation-${KARPENTER_VERSION}.yaml \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides "ClusterName=${CLUSTER_NAME}" \
    --region $AWS_REGION

  OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
  eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --approve
  echo $OIDC_PROVIDER

  echo "================================================================================================================"
  echo " 3. Create Karpenter controller role"
  echo "================================================================================================================"

  if aws iam get-role --role-name "${KARPENTER_CONTROLLER_ROLE}" >/dev/null 2>&1; then
      echo "Role ${KARPENTER_CONTROLLER_ROLE} already exists"
  else
      cat <<EOF > /tmp/controller-trust.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:karpenter"
                }
            }
        }
    ]
}
EOF
      karpenter_role=$(aws iam create-role --role-name "${KARPENTER_CONTROLLER_ROLE}" --assume-role-policy-document file:///tmp/controller-trust.json)
      aws iam attach-role-policy --role-name "${KARPENTER_CONTROLLER_ROLE}" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}"
  fi

  echo "================================================================================================================"
  echo " 3a. Create and attach EBS encryption policy to Karpenter controller role"
  echo "================================================================================================================"
  
  create_and_attach_ebs_encryption_policy "${setup-karpenter.sh
  {CLUSTER_NAME}"
  
  echo "================================================================================================================"
  echo " 4. Tag Subnets and Security Groups for Karpenter"
  echo "================================================================================================================"
 
  for NODEGROUP in $(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups' --output text); do
      aws ec2 create-tags \
          --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
          --resources $(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
          --nodegroup-name "${NODEGROUP}" --query 'nodegroup.subnets' --output text )
  done

  NODEGROUP=$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups[0]' --output text)
  LAUNCH_TEMPLATE=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
      --nodegroup-name "${NODEGROUP}" --query 'nodegroup.launchTemplate.{id:id,version:version}' \
      --output text | tr -s "\t" ",")

  SECURITY_GROUPS=$(aws eks describe-cluster \
      --name "${CLUSTER_NAME}" --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
  SECURITY_GROUPS2=$(aws ec2 describe-launch-template-versions \
      --launch-template-id "${LAUNCH_TEMPLATE%,*}" --versions "${LAUNCH_TEMPLATE#*,}" \
      --query 'LaunchTemplateVersions[0].LaunchTemplateData.[NetworkInterfaces[0].Groups||SecurityGroupIds]' \
      --output text || true)

  aws ec2 create-tags \
      --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
      --resources ${SECURITY_GROUPS} ${SECURITY_GROUPS2}

  echo "================================================================================================================"
  echo " 5. Install Karpenter via Helm Chart"
  echo "================================================================================================================"
  # helm registry logout public.ecr.aws
  helm template karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" --namespace kube-system \
      --set "settings.clusterName=${CLUSTER_NAME}" \
      --set "settings.interruptionQueue=${CLUSTER_NAME}" \
      --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
      --set controller.resources.requests.cpu=2 \
      --set controller.resources.requests.memory=2Gi \
      --set controller.resources.limits.cpu=10 \
      --set controller.resources.limits.memory=20Gi \
      --set webhook.serviceName="karpenter" \
      --set webhook.port=8443 > ./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml

  export NG=$(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $AWS_REGION --output json | jq -r '.nodegroups[0]')
  sed -i='' '/operator: DoesNotExist/a\
              - key: eks.amazonaws.com/nodegroup\
                operator: In\
                values:\
                - '"$(eval echo \$NG)"'\
' ./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml

  sed -i='' '/livenessProbe:/,/timeoutSeconds: 30/c\
          livenessProbe:\
            initialDelaySeconds: 30\
            periodSeconds: 30\
            timeoutSeconds: 10\
            failureThreshold: 5\
' ./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml

  echo "================================================================================================================"
  echo " 6. Create Karpenter CRDs and deploy Karpenter controller"
  echo "================================================================================================================"
  kubectl create -f \
      "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodepools.yaml"
  kubectl create -f \
      "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml"
  kubectl create -f \
      "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodeclaims.yaml"
  
  kubectl apply -f ./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml

  echo "================================================================================================================"
  echo " 7. Create Karpenter Nodepools and Nodeclass"
  echo "================================================================================================================"
  cp ./resources/karpenter/shared-nodeclass.yaml ./resources/karpenter/nodeclass-${KARPENTER_VERSION}.yaml

  sed -i='' 's/${KARPENTER_NODE_ROLE}/'$KARPENTER_NODE_ROLE'/g' ./resources/karpenter/nodeclass-${KARPENTER_VERSION}.yaml
  sed -i='' 's/${CLUSTER_NAME}/'$CLUSTER_NAME'/g' ./resources/karpenter/nodeclass-${KARPENTER_VERSION}.yaml

  rm ./resources/karpenter/*=
  kubectl apply -f "./resources/karpenter/*-nodepool.yaml"
  kubectl apply -f ./resources/karpenter/nodeclass-${KARPENTER_VERSION}.yaml

  aws eks create-access-entry --cluster-name ${CLUSTER_NAME} --principal-arn arn:aws:iam::${ACCOUNT_ID}:role/${KARPENTER_NODE_ROLE} --type EC2_LINUX

  echo "====================================================="
  echo " Completed Karpenter setup on the cluster ${CLUSTER_NAME} (Karpenter v${KARPENTER_VERSION}, EKS v${EKS_VERSION})."
  echo "====================================================="
}

# Call the function with the parsed arguments
setup_karpenter "$EKS_VERSION" "$KARPENTER_VERSION" "$CLUSTER_NAME" "$AWS_REGION"