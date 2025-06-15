#!/bin/bash

# Simple Demo Script - Submit 10 cost-optimized jobs and monitor
source env.sh

echo "==============================================="
echo "  🧪 DEMO: LLM-Powered Job Management"
echo "  10 cost-optimized jobs across 5 organizations"
echo "==============================================="
echo ""

# Check if system is ready
if ! kubectl get pods -n spark-agents >/dev/null 2>&1; then
    echo "❌ System not ready. Please run: ./setup-everything.sh"
    exit 1
fi

echo "📤 Submitting 10 cost-optimized jobs..."
echo "   💰 2 executors, 512MB memory each"
echo "   🏢 5 organizations: DataCorp, TechStart, Research, Financial, Healthcare"
echo "   📊 6 projects: Alpha, Beta, Gamma, Delta, Epsilon, Zeta"
echo ""

# Submit jobs quickly
for i in {1..10}; do
    case $i in
        1) org="org-a"; project="project-alpha"; priority="high"; queue="${SQS_HIGH_PRIORITY_QUEUE}" ;;
        2) org="org-b"; project="project-beta"; priority="medium"; queue="${SQS_MEDIUM_PRIORITY_QUEUE}" ;;
        3) org="org-c"; project="project-gamma"; priority="low"; queue="${SQS_LOW_PRIORITY_QUEUE}" ;;
        4) org="org-d"; project="project-delta"; priority="high"; queue="${SQS_HIGH_PRIORITY_QUEUE}" ;;
        5) org="org-e"; project="project-epsilon"; priority="medium"; queue="${SQS_MEDIUM_PRIORITY_QUEUE}" ;;
        6) org="org-a"; project="project-zeta"; priority="high"; queue="${SQS_HIGH_PRIORITY_QUEUE}" ;;
        7) org="org-b"; project="project-alpha"; priority="medium"; queue="${SQS_MEDIUM_PRIORITY_QUEUE}" ;;
        8) org="org-c"; project="project-beta"; priority="low"; queue="${SQS_LOW_PRIORITY_QUEUE}" ;;
        9) org="org-d"; project="project-gamma"; priority="high"; queue="${SQS_HIGH_PRIORITY_QUEUE}" ;;
        10) org="org-e"; project="project-delta"; priority="medium"; queue="${SQS_MEDIUM_PRIORITY_QUEUE}" ;;
    esac
    
    echo "   📤 Job $i/10: $org $project ($priority priority)"
    
    aws sqs send-message \
      --queue-url $(aws sqs get-queue-url --queue-name "$queue" --query 'QueueUrl' --output text) \
      --message-body '{
        "job_id": "'$org'-'$project'-'$priority'-demo-'$i'-'$(date +%s)'",
        "priority": "'$priority'",
        "organization": {"id": "'$org'", "tier": "standard"},
        "project": {"id": "'$project'", "type": "demo"},
        "spark_config": {
          "driver_memory": "512m",
          "executor_memory": "512m", 
          "executor_instances": 2,
          "driver_cores": 1,
          "executor_cores": 1
        },
        "main_class": "org.apache.spark.examples.SparkPi",
        "job_args": ["10"],
        "customer_tier": "standard"
      }' \
      --message-group-id "demo-$org" >/dev/null
done

echo ""
echo "✅ 10 jobs submitted successfully!"
echo ""
echo "⏱️  Jobs will be processed in priority order:"
echo "   🔴 High priority jobs first"
echo "   🟡 Medium priority jobs second" 
echo "   🟢 Low priority jobs last"
echo ""
echo "📊 Monitor progress:"
echo "   ./stats.sh"
echo ""
echo "🔄 Jobs should complete in ~2-3 minutes"

# Show initial stats
echo "==============================================="
echo "  📊 Initial Queue Status"
echo "==============================================="
./stats.sh
