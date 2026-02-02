#!/bin/bash

# Parse command-line arguments
for arg in "$@"; do
  case $arg in
    eks-version=*)
      EKS_VERSION="${arg#*=}"
      shift
      ;;
    *)
      echo "Unknown argument: $arg"
      exit 1
      ;;
  esac
done

if [[ -z "$EKS_VERSION" ]]; then
  echo "Usage: $0 eks-version=<EKS_VERSION>"
  exit 1
fi

remove_karpenter() {
  local EKS_VERSION="$1"
  local KARPENTER_VERSION
  local CLUSTER_NAME

  # Determine Karpenter version and cluster name based on EKS version
  if [[ "$EKS_VERSION" == "1.30" ]]; then
    KARPENTER_VERSION="1.0.3"
    CLUSTER_NAME="eks-test-1-30"
  elif [[ "$EKS_VERSION" == "1.32" ]]; then
    KARPENTER_VERSION="1.8.5"
    CLUSTER_NAME="eks-test-1-32"
  else
    echo "Unsupported EKS version: $EKS_VERSION"
    return 1
  fi

  echo "====================================================="
  echo " Removing Karpenter resources from cluster ${CLUSTER_NAME} (EKS ${EKS_VERSION})."
  echo "====================================================="

  # Delete Karpenter Nodepools and Nodeclass
  echo "Deleting Karpenter Nodepools and Nodeclass..."
  kubectl delete -f "./resources/karpenter/*-nodepool.yaml" --ignore-not-found
  kubectl delete -f "./resources/karpenter/nodeclass-${KARPENTER_VERSION}.yaml" --ignore-not-found

  # Delete Karpenter Helm resources
  echo "Deleting Karpenter Helm resources..."
  kubectl delete -f ./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml --ignore-not-found

  # Delete Karpenter CRDs
  echo "Deleting Karpenter CRDs..."
  kubectl delete -f \
      "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodepools.yaml" --ignore-not-found
  kubectl delete -f \
      "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml" --ignore-not-found
  kubectl delete -f \
      "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodeclaims.yaml" --ignore-not-found

  # Delete Karpenter namespace
  echo "Deleting Karpenter namespace..."
  kubectl delete namespace karpenter --ignore-not-found

  # Remove IAM roles and policies
  echo "Removing IAM roles and policies..."
  local KARPENTER_CONTROLLER_ROLE="KarpenterControllerRole-${CLUSTER_NAME}"
  local KARPENTER_CONTROLLER_POLICY="KarpenterControllerPolicy-${CLUSTER_NAME}"
  local KARPENTER_NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"

  if aws iam get-role --role-name "${KARPENTER_NODE_ROLE}" >/dev/null 2>&1; then
    # Detach all policies from the role
    ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name "${KARPENTER_NODE_ROLE}" --query 'AttachedPolicies[].PolicyArn' --output text)
    for POLICY_ARN in $ATTACHED_POLICIES; do
      echo "Detaching policy $POLICY_ARN from role ${KARPENTER_NODE_ROLE}..."
      aws iam detach-role-policy --role-name "${KARPENTER_NODE_ROLE}" --policy-arn "$POLICY_ARN" || true
    done

    # Detach the role from any instance profiles
    INSTANCE_PROFILES=$(aws iam list-instance-profiles-for-role --role-name "${KARPENTER_NODE_ROLE}" --query 'InstanceProfiles[].InstanceProfileName' --output text)
    for PROFILE in $INSTANCE_PROFILES; do
      echo "Detaching role ${KARPENTER_NODE_ROLE} from instance profile ${PROFILE}..."
      aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE" --role-name "${KARPENTER_NODE_ROLE}" || true
    done

    # Delete the role
    echo "Deleting role ${KARPENTER_NODE_ROLE}..."
    aws iam delete-role --role-name "${KARPENTER_NODE_ROLE}" || true
  fi

  if aws iam get-role --role-name "${KARPENTER_CONTROLLER_ROLE}" >/dev/null 2>&1; then
    aws iam detach-role-policy --role-name "${KARPENTER_CONTROLLER_ROLE}" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}" || true
    aws iam delete-role --role-name "${KARPENTER_CONTROLLER_ROLE}" || true
  fi

  # Delete CloudFormation stack
  echo "Deleting CloudFormation stack..."
  aws cloudformation delete-stack --stack-name "karpenter-infra-${CLUSTER_NAME}" || true

  # Remove tags from subnets and security groups
  echo "Removing tags from subnets and security groups..."
  for NODEGROUP in $(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups' --output text); do
      aws ec2 delete-tags \
          --tags "Key=karpenter.sh/discovery" \
          --resources $(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
          --nodegroup-name "${NODEGROUP}" --query 'nodegroup.subnets' --output text ) || true
  done

  # Remove access entry
  echo "Removing access entry for Karpenter node role..."
  aws eks delete-access-entry --cluster-name ${CLUSTER_NAME} --principal-arn arn:aws:iam::${ACCOUNT_ID}:role/${KARPENTER_NODE_ROLE} || true

  echo "====================================================="
  echo " Completed removal of Karpenter resources from cluster ${CLUSTER_NAME} (EKS ${EKS_VERSION})."
  echo "====================================================="
}

# Call the function with the parsed EKS version
remove_karpenter "$EKS_VERSION"