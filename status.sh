#!/bin/bash

# System Status Checker for LLM-powered Spark Job Management System
# This script checks queue status and running jobs

source env.sh

echo "==============================================="
echo "  LLM-Powered Spark Job System Status"
echo "==============================================="
echo ""

# Function to get queue message count
get_queue_count() {
    local queue_name=$1
    aws sqs get-queue-attributes \
        --queue-url $(aws sqs get-queue-url --queue-name "$queue_name" --region ${AWS_REGION} --query 'QueueUrl' --output text 2>/dev/null) \
        --attribute-names ApproximateNumberOfMessages \
        --region ${AWS_REGION} \
        --query 'Attributes.ApproximateNumberOfMessages' \
        --output text 2>/dev/null || echo "0"
}

# 1. Check SQS Queue Status
echo "📋 SQS Queue Status:"
HIGH_COUNT=$(get_queue_count "${SQS_HIGH_PRIORITY_QUEUE}")
MEDIUM_COUNT=$(get_queue_count "${SQS_MEDIUM_PRIORITY_QUEUE}")
LOW_COUNT=$(get_queue_count "${SQS_LOW_PRIORITY_QUEUE}")
DLQ_COUNT=$(get_queue_count "${SQS_DLQ}")

echo "  🔴 High Priority:   ${HIGH_COUNT} messages"
echo "  🟡 Medium Priority: ${MEDIUM_COUNT} messages"
echo "  🟢 Low Priority:    ${LOW_COUNT} messages"
echo "  ⚠️  Dead Letter:    ${DLQ_COUNT} messages"
echo ""

# 2. Check Scheduler Agent Status
echo "🤖 AI Scheduler Agent Status:"
SCHEDULER_STATUS=$(kubectl get pods -n ${AGENT_NAMESPACE} -l app=scheduler-agent --no-headers 2>/dev/null | awk '{print $3}' || echo "Not Found")
echo "  Status: ${SCHEDULER_STATUS}"
if [ "$SCHEDULER_STATUS" = "Running" ]; then
    echo "  ✅ Scheduler is actively monitoring queues (10s cycle)"
else
    echo "  ❌ Scheduler is not running properly"
fi
echo ""

# 3. Check Running Spark Applications
echo "⚡ Spark Applications Status:"
TOTAL_APPS=$(kubectl get sparkapplications --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
echo "  Total Applications: ${TOTAL_APPS}"

if [ "$TOTAL_APPS" -gt 0 ]; then
    echo ""
    echo "  Recent Applications:"
    kubectl get sparkapplications --all-namespaces --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -5 | while read line; do
        if [[ "$line" != "NAMESPACE"* ]]; then
            echo "    $line"
        fi
    done
fi
echo ""

# 4. Check Applications by Status
echo "📊 Applications by Status:"
RUNNING=$(kubectl get sparkapplications --all-namespaces --no-headers 2>/dev/null | grep -c "RUNNING" || echo "0")
COMPLETED=$(kubectl get sparkapplications --all-namespaces --no-headers 2>/dev/null | grep -c "COMPLETED" || echo "0")
FAILED=$(kubectl get sparkapplications --all-namespaces --no-headers 2>/dev/null | grep -c "FAILED" || echo "0")
PENDING=$(kubectl get sparkapplications --all-namespaces --no-headers 2>/dev/null | grep -c "PENDING\|SUBMITTED" || echo "0")

echo "  🟢 Running:   ${RUNNING}"
echo "  ✅ Completed: ${COMPLETED}"
echo "  ❌ Failed:    ${FAILED}"
echo "  ⏳ Pending:   ${PENDING}"
echo ""

# 5. Recent Scheduler Logs
echo "📝 Recent Scheduler Activity (last 5 lines):"
kubectl logs -n ${AGENT_NAMESPACE} deployment/scheduler-agent --tail=5 2>/dev/null | while read line; do
    echo "    $line"
done
echo ""

# 6. System Health Summary
echo "🏥 System Health Summary:"
TOTAL_QUEUED=$((HIGH_COUNT + MEDIUM_COUNT + LOW_COUNT))

if [ "$SCHEDULER_STATUS" = "Running" ] && [ "$DLQ_COUNT" -eq 0 ]; then
    echo "  ✅ System Status: HEALTHY"
elif [ "$DLQ_COUNT" -gt 0 ]; then
    echo "  ⚠️  System Status: WARNING (${DLQ_COUNT} jobs in DLQ)"
else
    echo "  ❌ System Status: CRITICAL (Scheduler not running)"
fi

echo "  📊 Queue Load: ${TOTAL_QUEUED} jobs pending"
echo "  🎯 Processing Rate: ~6 jobs/minute (10s cycle)"
echo ""

echo "==============================================="
echo "  Status Check Complete"
echo "==============================================="
