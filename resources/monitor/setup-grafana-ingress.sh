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
SERVICE_NAME="prometheus-grafana"
SERVICE_PORT=80
INGRESS_NAME="grafana-ingress"
CERT_NAME="grafana-tls"
ALB_CONTROLLER_VERSION="v2.7.1"
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

# Check if ALB Controller is installed
check_alb_controller() {
  kubectl get deployment -n ${ALB_CONTROLLER_NAMESPACE} aws-load-balancer-controller &>/dev/null
}

# Create IAM policy for ALB Controller
create_iam_policy() {
  echo "Creating IAM policy for ALB Controller..."
  
  # Download and create official policy
  curl -sS -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${ALB_CONTROLLER_VERSION}/docs/install/iam_policy.json
  
  aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam-policy.json
  
  echo "IAM policy created."
  rm -f iam-policy.json
}

# Create additional IAM policy for missing permissions
create_additional_iam_policy() {
  echo "Creating additional IAM policy for missing permissions..."
  
  cat > additional-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:DescribeListenerAttributes"
      ],
      "Resource": "*"
    }
  ]
}
EOF
  
  aws iam create-policy \
    --policy-name AWSLoadBalancerControllerAdditionalPolicy \
    --policy-document file://additional-policy.json
  
  echo "Additional IAM policy created."
  rm -f additional-policy.json
}

# Create IAM service account
create_iam_service_account() {
  echo "Creating IAM service account for ALB Controller..."
  POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"
  ADDITIONAL_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerAdditionalPolicy"
  
  eksctl create iamserviceaccount \
    --cluster=${CLUSTER_NAME} \
    --namespace=${ALB_CONTROLLER_NAMESPACE} \
    --name=aws-load-balancer-controller \
    --attach-policy-arn=${POLICY_ARN} \
    --attach-policy-arn=${ADDITIONAL_POLICY_ARN} \
    --override-existing-serviceaccounts \
    --region=${AWS_REGION} \
    --approve
}

# Install ALB Controller via Helm
install_alb_controller_helm() {
  echo "Adding eks-charts Helm repository..."
  helm repo add eks https://aws.github.io/eks-charts
  helm repo update
  
  echo "Installing AWS Load Balancer Controller..."
  VPC_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query "cluster.resourcesVpcConfig.vpcId" --output text)
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n ${ALB_CONTROLLER_NAMESPACE} \
    --set clusterName=${CLUSTER_NAME} \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region=${AWS_REGION} \
    --set vpcId=${VPC_ID}
  
  echo "Waiting for AWS Load Balancer Controller to be ready..."
  kubectl wait --for=condition=available --timeout=300s \
    deployment/aws-load-balancer-controller -n ${ALB_CONTROLLER_NAMESPACE}
  
  echo "AWS Load Balancer Controller installed successfully!"
}

# Install ALB Controller
install_alb_controller() {
  echo "Installing AWS Load Balancer Controller..."
  create_iam_policy
  create_additional_iam_policy
  create_iam_service_account
  install_alb_controller_helm
}

# Generate self-signed SSL certificate
generate_ssl_certificate() {
  echo "Generating self-signed SSL certificate..."
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout tls.key -out tls.crt \
    -subj "/CN=grafana.local/O=grafana"
}

# Upload certificate to ACM
upload_certificate_to_acm() {
  echo "Uploading certificate to AWS Certificate Manager..."
  CERT_ARN=$(aws acm import-certificate \
    --certificate fileb://tls.crt \
    --private-key fileb://tls.key \
    --region ${AWS_REGION} \
    --query CertificateArn \
    --output text)
  
  echo "Certificate uploaded to ACM: ${CERT_ARN}"
}

# Create Kubernetes TLS secret
create_tls_secret() {
  echo "Creating Kubernetes TLS secret..."
  kubectl create secret tls ${CERT_NAME} \
    --key tls.key \
    --cert tls.crt \
    -n ${NAMESPACE} \
    --dry-run=client -o yaml | kubectl apply -f -
}

# Create Ingress resource
create_ingress() {
  echo "Creating Ingress manifest..."
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  namespace: ${NAMESPACE}
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: ${CERT_ARN}
    alb.ingress.kubernetes.io/healthcheck-path: /api/health
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
    alb.ingress.kubernetes.io/success-codes: '200'
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${SERVICE_NAME}
            port:
              number: ${SERVICE_PORT}
EOF
}

# Wait for ALB provisioning
wait_for_alb() {
  echo "Waiting for ALB to be provisioned..."
  kubectl wait --for=condition=available --timeout=300s \
    ingress/${INGRESS_NAME} -n ${NAMESPACE} 2>/dev/null || true
}

# Display ALB endpoint
display_endpoint() {
  echo ""
  echo "=========================================="
  echo "  Grafana Ingress Setup Complete!"
  echo "=========================================="
  echo ""
  
  # Get ALB endpoint
  ALB_ENDPOINT=$(kubectl get ingress ${INGRESS_NAME} -n ${NAMESPACE} \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

  if [ -z "$ALB_ENDPOINT" ]; then
    echo "⏳ ALB is still provisioning..."
    echo ""
    echo "Run this command to check status:"
    echo "  kubectl get ingress ${INGRESS_NAME} -n ${NAMESPACE}"
  else
    # Get Grafana password
    GRAFANA_PASSWORD=$(kubectl get secret prometheus-grafana -n ${NAMESPACE} -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 --decode)
    
    echo "🌐 Grafana URL:"
    echo "  https://${ALB_ENDPOINT}"
    echo ""
    echo "🔐 Login Credentials:"
    echo "  Username: admin"
    if [ -n "$GRAFANA_PASSWORD" ]; then
      echo "  Password: ${GRAFANA_PASSWORD}"
    else
      echo "  Password: (run command below to retrieve)"
    fi
    echo ""
    echo "📋 Retrieve password command:"
    echo "  kubectl get secret prometheus-grafana -n ${NAMESPACE} -o jsonpath=\"{.data.admin-password}\" | base64 --decode"
    echo ""
    echo "⚠️  Note: You may see a certificate warning due to the self-signed certificate."
  fi
  echo ""
  echo "=========================================="
}

# Cleanup temporary files
cleanup_temp_files() {
  rm -f tls.key tls.crt iam-policy.json
}

# Main execution
main() {
  echo "Setting up AWS ALB Ingress for Grafana with self-signed SSL certificate..."
  
  get_cluster_info
  echo "Cluster: ${CLUSTER_NAME}"
  echo "Region: ${AWS_REGION}"
  echo "Account: ${AWS_ACCOUNT_ID}"
  echo ""
  
  # Check and install ALB Controller if needed
  echo "Checking if AWS Load Balancer Controller is installed..."
  if check_alb_controller; then
    echo "AWS Load Balancer Controller is already installed."
  else
    install_alb_controller
  fi
  
  echo ""
  
  # Setup Grafana ingress
  generate_ssl_certificate
  upload_certificate_to_acm
  create_tls_secret
  create_ingress
  wait_for_alb
  display_endpoint
  
  # Cleanup
  cleanup_temp_files
}

# Run main function
main
