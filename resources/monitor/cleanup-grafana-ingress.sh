#!/bin/bash

set -e

if [[ -e env.sh ]]
then
    source env.sh
else
    echo "env.sh does not exist. Exit..."
    exit 1
fi

# Configuration
NAMESPACE="prometheus"
INGRESS_NAME="grafana-ingress"
CERT_NAME="grafana-tls"
ALB_CONTROLLER_NAMESPACE="kube-system"

# Accept command-line arguments
CLUSTER_NAME="$1"
AWS_REGION="$2"
AWS_ACCOUNT_ID="$3"

# Get cluster information
get_cluster_info() {
  # Validate required parameters
  if [ -z "$CLUSTER_NAME" ]; then
    echo "Error: CLUSTER_NAME is required"
    echo "Usage: $0 <cluster-name> <aws-region> [aws-account-id]"
    exit 1
  fi
  
  if [ -z "$AWS_REGION" ]; then
    echo "Error: AWS_REGION is required"
    echo "Usage: $0 <cluster-name> <aws-region> [aws-account-id]"
    exit 1
  fi
  
  # Get AWS account ID if not provided
  if [ -z "$AWS_ACCOUNT_ID" ]; then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  fi
}

# Delete Ingress resource
delete_ingress() {
  echo "Deleting Ingress..."
  if kubectl get ingress ${INGRESS_NAME} -n ${NAMESPACE} &>/dev/null; then
    kubectl delete ingress ${INGRESS_NAME} -n ${NAMESPACE}
    echo "Ingress ${INGRESS_NAME} deleted."
  else
    echo "Ingress ${INGRESS_NAME} not found, skipping."
  fi
}

# Wait for ALB deprovisioning
wait_for_alb_deletion() {
  echo "Waiting for ALB to be deprovisioned (this may take a few minutes)..."
  sleep 10
}

# Delete TLS secret
delete_tls_secret() {
  echo "Deleting TLS secret..."
  if kubectl get secret ${CERT_NAME} -n ${NAMESPACE} &>/dev/null; then
    kubectl delete secret ${CERT_NAME} -n ${NAMESPACE}
    echo "Secret ${CERT_NAME} deleted."
  else
    echo "Secret ${CERT_NAME} not found, skipping."
  fi
}

# Delete ACM certificate
delete_acm_certificate() {
  echo "Checking for ACM certificates to delete..."
  # Find certificates with grafana.local CN
  CERT_ARNS=$(aws acm list-certificates --region ${AWS_REGION} --query "CertificateSummaryList[?DomainName=='grafana.local'].CertificateArn" --output text)
  
  if [ -n "$CERT_ARNS" ]; then
    for CERT_ARN in $CERT_ARNS; do
      echo "Deleting ACM certificate: ${CERT_ARN}"
      aws acm delete-certificate --certificate-arn ${CERT_ARN} --region ${AWS_REGION} 2>/dev/null || echo "Certificate may be in use or already deleted."
    done
  else
    echo "No ACM certificates found for grafana.local"
  fi
}

# Uninstall ALB Controller Helm chart
uninstall_alb_controller_helm() {
  if helm list -n ${ALB_CONTROLLER_NAMESPACE} | grep -q aws-load-balancer-controller; then
    helm uninstall aws-load-balancer-controller -n ${ALB_CONTROLLER_NAMESPACE}
    echo "AWS Load Balancer Controller Helm chart uninstalled."
  else
    echo "AWS Load Balancer Controller Helm chart not found."
  fi
}

# Delete IAM service account
delete_iam_service_account() {
  echo "Deleting IAM service account..."
  eksctl delete iamserviceaccount \
    --cluster=${CLUSTER_NAME} \
    --namespace=${ALB_CONTROLLER_NAMESPACE} \
    --name=aws-load-balancer-controller \
    --region=${AWS_REGION} 2>/dev/null || echo "IAM service account not found or already deleted."
}

# Delete IAM policy
delete_iam_policy() {
  echo "Deleting IAM policy 'AWSLoadBalancerControllerIAMPolicy'..."
  POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"
  if aws iam get-policy --policy-arn ${POLICY_ARN} &>/dev/null; then
    aws iam delete-policy --policy-arn ${POLICY_ARN}
    echo "IAM policy deleted."
  else
    echo "IAM policy not found."
  fi
}

# Delete additional IAM policy
delete_additional_iam_policy() {
  echo "Deleting additional IAM policy 'AWSLoadBalancerControllerAdditionalPolicy'..."
  ADDITIONAL_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerAdditionalPolicy"
  if aws iam get-policy --policy-arn ${ADDITIONAL_POLICY_ARN} &>/dev/null; then
    aws iam delete-policy --policy-arn ${ADDITIONAL_POLICY_ARN}
    echo "Additional IAM policy deleted."
  else
    echo "Additional IAM policy not found."
  fi
}

# Uninstall ALB Controller
uninstall_alb_controller() {
  echo ""
  echo "Uninstalling AWS Load Balancer Controller..."
  uninstall_alb_controller_helm
  delete_iam_service_account
  delete_iam_policy
  delete_additional_iam_policy
  echo "AWS Load Balancer Controller cleanup complete."
}

# Cleanup temporary files
cleanup_temp_files() {
  echo "Cleaning up local certificate files..."
  rm -f tls.key tls.crt iam-policy.json
}

# Main execution
main() {
  echo "Cleaning up AWS ALB Ingress and related resources for Grafana..."
  
  get_cluster_info
  echo "Cluster: ${CLUSTER_NAME}"
  echo "Region: ${AWS_REGION}"
  echo ""
  
  # Delete Grafana ingress resources
  delete_ingress
  wait_for_alb_deletion
  delete_acm_certificate
  delete_tls_secret
  
  # Optionally uninstall ALB Controller
  uninstall_alb_controller
  
  # Cleanup temporary files
  cleanup_temp_files
  
  echo ""
  echo "Cleanup complete!"
  echo "All resources created by setup-grafana-ingress.sh have been removed."
}

# Run main function
main
