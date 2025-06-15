#!/bin/bash

# Ultimate Setup Script - Deploy Everything in One Command
# Creates: EKS cluster, AI agents, SQS, Prometheus, Grafana, Locust EC2

set -e  # Exit on any error

source env.sh

echo "==============================================="
echo "  🚀 ULTIMATE SETUP - DEPLOY EVERYTHING"
echo "  LLM-Powered Spark Job Management System"
echo "==============================================="
echo ""
echo "This script will deploy:"
echo "  ✅ EKS Cluster with Spark Operators"
echo "  ✅ AI Agents with LLM (Claude 3.5 Sonnet)"
echo "  ✅ SQS Priority Queues"
echo "  ✅ Prometheus & Grafana Monitoring"
echo "  ✅ Karpenter Auto-scaling"
echo "  ✅ Locust Load Testing (EC2)"
echo ""
echo "Configuration:"
echo "  📊 Cluster: ${CLUSTER_NAME}"
echo "  🌍 Region: ${AWS_REGION}"
echo "  🤖 AI Agents: ${AI_AGENTS_ENABLED}"
echo "  📈 Grafana: ${USE_AMG}"
echo ""

read -p "🚀 Ready to deploy everything? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Setup cancelled"
    exit 1
fi

echo ""
echo "🎯 Starting complete infrastructure deployment..."
echo ""

# Step 1: Deploy main infrastructure
echo "==============================================="
echo "  Step 1/2: Deploying Main Infrastructure"
echo "==============================================="
echo ""
echo "⏱️  This will take ~15-20 minutes..."
echo "📊 Deploying: EKS, Spark Operators, AI Agents, SQS, Prometheus, Grafana"
echo ""

if ./infra-provision.sh; then
    echo ""
    echo "✅ Main infrastructure deployed successfully!"
else
    echo ""
    echo "❌ Main infrastructure deployment failed!"
    echo "💡 Check logs above for errors"
    exit 1
fi

# Step 2: Deploy Locust EC2 (optional)
echo ""
echo "==============================================="
echo "  Step 2/2: Deploying Locust Load Testing (EC2)"
echo "==============================================="
echo ""

read -p "🧪 Deploy Locust EC2 for load testing? (Y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "⏭️  Skipping Locust EC2 deployment"
else
    echo "⏱️  This will take ~5-10 minutes..."
    echo "🧪 Deploying: EC2 instance with Locust load testing"
    echo ""
    
    if ./locust-provision.sh; then
        echo ""
        echo "✅ Locust EC2 deployed successfully!"
        
        # Extract SSH command
        SSH_COMMAND=$(grep "To connect to the instance" locust-provision.log 2>/dev/null | tail -1 || echo "Check locust-provision.log for SSH details")
        if [[ "$SSH_COMMAND" != "Check"* ]]; then
            echo ""
            echo "🔑 SSH Access:"
            echo "   $SSH_COMMAND"
        fi
    else
        echo ""
        echo "⚠️  Locust EC2 deployment failed (non-critical)"
        echo "💡 You can still use Kubernetes-based Locust"
    fi
fi

echo ""
echo "==============================================="
echo "  🎉 COMPLETE SETUP FINISHED!"
echo "==============================================="
echo ""

# Display access information
echo "🌐 Access Information:"
echo ""

# Kubernetes access
echo "📊 Kubernetes Cluster:"
echo "   kubectl get nodes"
echo "   kubectl get pods --all-namespaces"
echo ""

# Locust access
echo "🧪 Locust Load Testing:"
echo "   kubectl port-forward svc/locust-master 8089:8089 -n locust"
echo "   Open: http://localhost:8089"
echo ""

# Prometheus access
echo "📈 Prometheus Monitoring:"
echo "   kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n prometheus"
echo "   Open: http://localhost:9090"
echo ""

# Grafana access
if [[ $USE_AMG == "true" ]]; then
    GRAFANA_ID=$(aws grafana list-workspaces --query 'workspaces[?name==`'${LOAD_TEST_PREFIX}'`].id' --region $AWS_REGION --output text 2>/dev/null || echo "")
    if [[ -n "$GRAFANA_ID" && "$GRAFANA_ID" != "None" ]]; then
        echo "📊 Amazon Managed Grafana:"
        echo "   Workspace ID: $GRAFANA_ID"
        echo "   URL: https://g-${GRAFANA_ID}.grafana-workspace.${AWS_REGION}.amazonaws.com"
        echo "   Note: Configure IAM Identity Center access in AWS Console"
    fi
fi

echo ""
echo "🎯 Quick Start Commands:"
echo ""
echo "1. 📊 Check system status:"
echo "   ./stats.sh"
echo ""
echo "2. 🧪 Run demo (10 cost-optimized jobs):"
echo "   ./cost-optimized-demo.sh"
echo ""
echo "3. 🚀 Run load test:"
echo "   ./load-test.sh 5 1 2m"
echo ""
echo "4. 🧹 Clean up everything:"
echo "   ./cleanup.sh"
echo ""

# Final system check
echo "🔍 Final System Check:"
echo ""
kubectl get nodes --no-headers | wc -l | xargs echo "   EKS Nodes:"
kubectl get pods -n spark-agents --no-headers 2>/dev/null | wc -l | xargs echo "   AI Agent Pods:"
kubectl get pods -n locust --no-headers 2>/dev/null | wc -l | xargs echo "   Locust Pods:"
kubectl get pods -n prometheus --no-headers 2>/dev/null | wc -l | xargs echo "   Prometheus Pods:"

echo ""
echo "✅ Your LLM-powered Spark job management system is ready!"
echo "🎉 Happy load testing! 🚀"
