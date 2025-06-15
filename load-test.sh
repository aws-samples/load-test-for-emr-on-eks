#!/bin/bash

# Enhanced Locust Load Testing Script for LLM-Powered Spark Job Management
# This script runs load tests with rich job metadata and realistic patterns

source env.sh

# Default parameters
USERS=${1:-10}
SPAWN_RATE=${2:-2}
RUN_TIME=${3:-5m}
TEST_NAME=${4:-"spark-job-load-test"}

echo "==============================================="
echo "  Enhanced Locust Load Testing"
echo "  LLM-Powered Spark Job Management System"
echo "==============================================="
echo ""
echo "Test Configuration:"
echo "  👥 Users: ${USERS}"
echo "  🚀 Spawn Rate: ${SPAWN_RATE} users/second"
echo "  ⏱️  Duration: ${RUN_TIME}"
echo "  📝 Test Name: ${TEST_NAME}"
echo ""
echo "Job Metadata Features:"
echo "  🏢 Organizations: org-a, org-b, org-c, org-d, org-e"
echo "  📊 Projects: alpha, beta, gamma, delta, epsilon, zeta"
echo "  🎯 Priorities: high (20%), medium (50%), low (30%)"
echo "  🔧 Job Types: data-processing, ml-training, etl, analytics, reporting"
echo "  🏷️  Rich Tags: teams, versions, batch-ids, cost-centers"
echo ""

# Check if Locust is ready
echo "Checking Locust deployment status..."
kubectl get pods -n locust

LOCUST_READY=$(kubectl get pods -n locust -l app=locust-master --no-headers | awk '{print $3}')
if [ "$LOCUST_READY" != "Running" ]; then
    echo "❌ Locust master is not running. Status: $LOCUST_READY"
    exit 1
fi

echo "✅ Locust is ready"
echo ""

# Port forward to Locust UI
echo "Setting up port forwarding to Locust UI..."
kubectl port-forward svc/locust-master 8089:8089 -n locust &
PORT_FORWARD_PID=$!

# Wait for port forward to establish
sleep 5

echo "🌐 Locust UI available at: http://localhost:8089"
echo ""

# Function to cleanup on exit
cleanup() {
    echo ""
    echo "Cleaning up..."
    kill $PORT_FORWARD_PID 2>/dev/null
    exit 0
}

trap cleanup SIGINT SIGTERM

# Run load test via API
echo "Starting load test via Locust API..."
echo ""

# Start the test
curl -X POST http://localhost:8089/swarm \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "user_count=${USERS}&spawn_rate=${SPAWN_RATE}&host=http://localhost" \
  --silent > /dev/null

if [ $? -eq 0 ]; then
    echo "✅ Load test started successfully!"
    echo ""
    echo "📊 Monitor the test at: http://localhost:8089"
    echo "📈 Real-time job submissions with rich metadata:"
    echo "   - Organization-based job grouping"
    echo "   - Project-specific resource allocation"
    echo "   - Priority-based queue distribution"
    echo "   - Realistic batch job patterns"
    echo ""
    echo "🔍 Monitor system status with:"
    echo "   ./check-system-status.sh"
    echo ""
    echo "⏹️  Press Ctrl+C to stop the test and cleanup"
    echo ""
    
    # Keep the script running to maintain port forward
    while true; do
        sleep 10
        # Check if Locust is still running
        if ! curl -s http://localhost:8089/stats/requests > /dev/null; then
            echo "❌ Lost connection to Locust"
            break
        fi
    done
else
    echo "❌ Failed to start load test"
    cleanup
fi

cleanup
