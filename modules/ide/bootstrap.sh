#!/bin/bash
set -euo pipefail

# Install Terraform
yum install -y yum-utils
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
yum install -y terraform

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install Python 3 and Locust
yum install -y python3 python3-pip
pip3 install locust

# Configure kubeconfig for all clusters
%{ for cluster in cluster_names ~}
aws eks update-kubeconfig --region ${region} --name ${cluster}
%{ endfor ~}

echo "IDE bootstrap complete"
