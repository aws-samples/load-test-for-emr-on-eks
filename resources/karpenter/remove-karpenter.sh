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
    *)
      echo "Unknown argument: $arg"
      exit 1
      ;;
  esac
done

if [[ -z "$EKS_VERSION" ]] || [[ -z "$KARPENTER_VERSION" ]] || [[ -z "$CLUSTER_NAME" ]]; then
  echo "Usage: $0 eks-version=<EKS_VERSION> karpenter-version=<KARPENTER_VERSION> cluster-name=<CLUSTER_NAME>"
  echo "Example: $0 eks-version=1.32 karpenter-version=1.8.5 cluster-name=eks-test-1-32"
  exit 1
fi

remove_karpenter() {
  local EKS_VERSION="$1"
  local KARPENTER_VERSION="$2"
  local CLUSTER_NAME="$3"

  # Validate EKS version and cluster name
  CLUSTER_VERSION=$(echo "$CLUSTER_NAME" | grep -oE '([0-9]+\.[0-9]+|[0-9]+-[0-9]+)' | tail -1 | sed 's/-/\./')
  if [[ "$EKS_VERSION" != "$CLUSTER_VERSION" ]]; then
    echo "$EKS_VERSION and $CLUSTER_NAME suffix do not match. Please provide matching EKS version and cluster name."
    return 1
  fi

  echo "====================================================="
  echo " 1. Deleting Karpenter Nodepools and Nodeclass..."
  echo "====================================================="
  # Delete Karpenter Nodepools and Nodeclass
  # Use --wait=false to avoid blocking on finalizers
  if kubectl get crd nodepools.karpenter.sh &>/dev/null; then
    kubectl delete -f "./resources/karpenter/*-nodepool.yaml" --ignore-not-found --wait=false
  else
    echo "  Skipping nodepools - CRD not found"
  fi

  if kubectl get crd ec2nodeclasses.karpenter.k8s.aws &>/dev/null; then
    kubectl delete -f "./resources/karpenter/nodeclass-${KARPENTER_VERSION}.yaml" --ignore-not-found --wait=false
  else
    echo "  Skipping nodeclass - CRD not found"
  fi


  echo "====================================================="
  echo " 2. Deleting Karpenter Controller via helm chart..."
  echo "====================================================="
  if [[ -f "./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml" ]]; then
    kubectl delete -f ./resources/karpenter/karpenter-${KARPENTER_VERSION}.yaml --ignore-not-found --wait=false
  else
    echo "  Skipping - karpenter-${KARPENTER_VERSION}.yaml not found"
  fi

  echo "====================================================="
  echo " 3. Deleting Karpenter CRDs..."
  echo "====================================================="
  kubectl delete -f \
      "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodepools.yaml" --ignore-not-found --wait=false
  kubectl delete -f \
      "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml" --ignore-not-found --wait=false
  kubectl delete -f \
      "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodeclaims.yaml" --ignore-not-found --wait=false


  echo "====================================================="
  echo " 4. Deleting Karpenter namespace..."
  echo "====================================================="
  kubectl delete namespace karpenter --ignore-not-found


  echo "====================================================="
  echo " 5. Removing IAM roles and policies..."
  echo "====================================================="
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

  echo "====================================================="
  echo " 6. Deleting CloudFormation stack..."
  echo "====================================================="

  local STACK_NAME="karpenter-infra-${CLUSTER_NAME}"
  
  if aws cloudformation describe-stacks --stack-name "${STACK_NAME}" &>/dev/null; then
    aws cloudformation delete-stack --stack-name "${STACK_NAME}"
    echo "Waiting for CloudFormation stack ${STACK_NAME} to be deleted..."
    
    while true; do
      STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
      
      if [[ -z "$STACK_STATUS" ]] || [[ "$STACK_STATUS" == "None" ]]; then
        echo "Stack ${STACK_NAME} deleted successfully."
        break
      elif [[ "$STACK_STATUS" == "DELETE_FAILED" ]]; then
        echo "ERROR: Stack deletion failed. Check AWS Console for details."
        aws cloudformation describe-stack-events --stack-name "${STACK_NAME}" --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' --output table
        break
      else
        echo "  Stack status: ${STACK_STATUS}. Waiting..."
        sleep 10
      fi
    done
  else
    echo "  Stack ${STACK_NAME} does not exist, skipping."
  fi

  echo "====================================================="
  echo " 7. Removing tags from subnets and security groups..."
  echo "====================================================="
  for NODEGROUP in $(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups' --output text); do
      aws ec2 delete-tags \
          --tags "Key=karpenter.sh/discovery" \
          --resources $(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
          --nodegroup-name "${NODEGROUP}" --query 'nodegroup.subnets' --output text ) || true
  done

  echo "====================================================="
  echo " 8. Removing access entry for Karpenter node role..."
  echo "====================================================="

  aws eks delete-access-entry --cluster-name ${CLUSTER_NAME} --principal-arn arn:aws:iam::${ACCOUNT_ID}:role/${KARPENTER_NODE_ROLE} || true

  echo "====================================================="
  echo " Completed removal of Karpenter resources from cluster ${CLUSTER_NAME} (Karpenter v${KARPENTER_VERSION}, EKS v${EKS_VERSION})."
  echo "====================================================="
}

# Call the function with the parsed arguments
remove_karpenter "$EKS_VERSION" "$KARPENTER_VERSION" "$CLUSTER_NAME"