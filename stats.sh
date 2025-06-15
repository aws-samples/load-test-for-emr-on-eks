#!/bin/bash

# Error-Free Queue Statistics - Clean and simple
source env.sh

echo "==============================================="
echo "  Error-Free Queue Metadata Analysis"
echo "==============================================="

# Function to get queue count safely
get_queue_count() {
    local queue_name=$1
    local count=$(aws sqs get-queue-attributes \
        --queue-url $(aws sqs get-queue-url --queue-name "$queue_name" --region ${AWS_REGION} --query 'QueueUrl' --output text 2>/dev/null) \
        --attribute-names ApproximateNumberOfMessages \
        --region ${AWS_REGION} \
        --query 'Attributes.ApproximateNumberOfMessages' \
        --output text 2>/dev/null)
    
    # Ensure we always return a valid number
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
    else
        echo "0"
    fi
}

# Get queue counts
HIGH_COUNT=$(get_queue_count "${SQS_HIGH_PRIORITY_QUEUE}")
MEDIUM_COUNT=$(get_queue_count "${SQS_MEDIUM_PRIORITY_QUEUE}")
LOW_COUNT=$(get_queue_count "${SQS_LOW_PRIORITY_QUEUE}")
DLQ_COUNT=$(get_queue_count "${SQS_DLQ}")
TOTAL_PENDING=$((HIGH_COUNT + MEDIUM_COUNT + LOW_COUNT))

echo ""
echo "📊 Current Queue Status:"
echo "  🔴 High Priority:   ${HIGH_COUNT} jobs pending"
echo "  🟡 Medium Priority: ${MEDIUM_COUNT} jobs pending"
echo "  🟢 Low Priority:    ${LOW_COUNT} jobs pending"
echo "  ⚠️  Dead Letter:    ${DLQ_COUNT} failed jobs"
echo "  📈 Total Pending:   ${TOTAL_PENDING} jobs"

if [ $TOTAL_PENDING -gt 0 ]; then
    echo "  ⏱️  Est. completion: $((TOTAL_PENDING / 6)) minutes (6 jobs/min)"
fi

echo ""
echo "📋 Job Metadata Analysis:"

# Get total jobs safely
TOTAL_JOBS=$(kubectl get sparkapplications --all-namespaces -l managed-by=scheduler-agent --no-headers 2>/dev/null | wc -l)
TOTAL_JOBS=$(echo "$TOTAL_JOBS" | tr -d ' ')

if [ "$TOTAL_JOBS" = "0" ] || [ -z "$TOTAL_JOBS" ]; then
    echo "  ℹ️  No jobs processed yet by the scheduler agent"
    echo ""
    echo "💡 To generate cost-optimized jobs:"
    echo "   ./cost-optimized-demo.sh     # 10 jobs, 2 executors each"
    echo "   ./run-locust-load-test.sh 5 1 2m  # Small load test"
    echo ""
    echo "==============================================="
    exit 0
fi

echo "  📊 Total jobs processed: ${TOTAL_JOBS}"
echo ""

# Safe organization counting
echo "🏢 Jobs by Organization:"
ORG_A=$(kubectl get sparkapplications --all-namespaces -l managed-by=scheduler-agent -o json 2>/dev/null | jq -r ".items[].metadata.name" 2>/dev/null | grep -c "^org-a-" 2>/dev/null)
ORG_B=$(kubectl get sparkapplications --all-namespaces -l managed-by=scheduler-agent -o json 2>/dev/null | jq -r ".items[].metadata.name" 2>/dev/null | grep -c "^org-b-" 2>/dev/null)
ORG_C=$(kubectl get sparkapplications --all-namespaces -l managed-by=scheduler-agent -o json 2>/dev/null | jq -r ".items[].metadata.name" 2>/dev/null | grep -c "^org-c-" 2>/dev/null)
ORG_D=$(kubectl get sparkapplications --all-namespaces -l managed-by=scheduler-agent -o json 2>/dev/null | jq -r ".items[].metadata.name" 2>/dev/null | grep -c "^org-d-" 2>/dev/null)
ORG_E=$(kubectl get sparkapplications --all-namespaces -l managed-by=scheduler-agent -o json 2>/dev/null | jq -r ".items[].metadata.name" 2>/dev/null | grep -c "^org-e-" 2>/dev/null)

# Ensure counts are valid numbers
ORG_A=${ORG_A:-0}; ORG_B=${ORG_B:-0}; ORG_C=${ORG_C:-0}; ORG_D=${ORG_D:-0}; ORG_E=${ORG_E:-0}

if [ "$ORG_A" -gt 0 ]; then echo "   📊 DataCorp Analytics (org-a): $ORG_A jobs"; fi
if [ "$ORG_B" -gt 0 ]; then echo "   🏭 TechStart Solutions (org-b): $ORG_B jobs"; fi
if [ "$ORG_C" -gt 0 ]; then echo "   🔬 Research Institute (org-c): $ORG_C jobs"; fi
if [ "$ORG_D" -gt 0 ]; then echo "   💰 Financial Services (org-d): $ORG_D jobs"; fi
if [ "$ORG_E" -gt 0 ]; then echo "   🏥 Healthcare Systems (org-e): $ORG_E jobs"; fi

echo ""
echo "📊 Jobs by Project:"
ALPHA=$(kubectl get sparkapplications --all-namespaces -l managed-by=scheduler-agent -o json 2>/dev/null | jq -r ".items[].metadata.name" 2>/dev/null | grep -c "project-alpha" 2>/dev/null)
BETA=$(kubectl get sparkapplications --all-namespaces -l managed-by=scheduler-agent -o json 2>/dev/null | jq -r ".items[].metadata.name" 2>/dev/null | grep -c "project-beta" 2>/dev/null)
GAMMA=$(kubectl get sparkapplications --all-namespaces -l managed-by=scheduler-agent -o json 2>/dev/null | jq -r ".items[].metadata.name" 2>/dev/null | grep -c "project-gamma" 2>/dev/null)
DELTA=$(kubectl get sparkapplications --all-namespaces -l managed-by=scheduler-agent -o json 2>/dev/null | jq -r ".items[].metadata.name" 2>/dev/null | grep -c "project-delta" 2>/dev/null)

ALPHA=${ALPHA:-0}; BETA=${BETA:-0}; GAMMA=${GAMMA:-0}; DELTA=${DELTA:-0}

if [ "$ALPHA" -gt 0 ]; then echo "   🚀 Data Processing Alpha: $ALPHA jobs"; fi
if [ "$BETA" -gt 0 ]; then echo "   🤖 ML Training Beta: $BETA jobs"; fi
if [ "$GAMMA" -gt 0 ]; then echo "   📈 Analytics Gamma: $GAMMA jobs"; fi
if [ "$DELTA" -gt 0 ]; then echo "   🔄 ETL Pipeline Delta: $DELTA jobs"; fi

echo ""
echo "🎯 Jobs by Priority:"
HIGH_JOBS=$(kubectl get sparkapplications --all-namespaces -l priority=high,managed-by=scheduler-agent --no-headers 2>/dev/null | wc -l)
MEDIUM_JOBS=$(kubectl get sparkapplications --all-namespaces -l priority=medium,managed-by=scheduler-agent --no-headers 2>/dev/null | wc -l)
LOW_JOBS=$(kubectl get sparkapplications --all-namespaces -l priority=low,managed-by=scheduler-agent --no-headers 2>/dev/null | wc -l)

HIGH_JOBS=$(echo "$HIGH_JOBS" | tr -d ' ')
MEDIUM_JOBS=$(echo "$MEDIUM_JOBS" | tr -d ' ')
LOW_JOBS=$(echo "$LOW_JOBS" | tr -d ' ')

if [ "$HIGH_JOBS" -gt 0 ]; then echo "   🔴 High Priority: $HIGH_JOBS jobs"; fi
if [ "$MEDIUM_JOBS" -gt 0 ]; then echo "   🟡 Medium Priority: $MEDIUM_JOBS jobs"; fi
if [ "$LOW_JOBS" -gt 0 ]; then echo "   🟢 Low Priority: $LOW_JOBS jobs"; fi

echo ""
echo "📈 Job Status:"
COMPLETED=$(kubectl get sparkapplications --all-namespaces -l managed-by=scheduler-agent --no-headers 2>/dev/null | grep -c "COMPLETED" 2>/dev/null)
RUNNING=$(kubectl get sparkapplications --all-namespaces -l managed-by=scheduler-agent --no-headers 2>/dev/null | grep -c "RUNNING" 2>/dev/null)

COMPLETED=${COMPLETED:-0}; RUNNING=${RUNNING:-0}

if [ "$COMPLETED" -gt 0 ]; then echo "   ✅ Completed: $COMPLETED jobs"; fi
if [ "$RUNNING" -gt 0 ]; then echo "   🟢 Running: $RUNNING jobs"; fi

echo ""
echo "🕐 Recent Jobs (last 5):"
kubectl get sparkapplications --all-namespaces -l managed-by=scheduler-agent --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -5 | while read line; do
    if [[ "$line" != "NAMESPACE"* ]] && [[ "$line" != "" ]]; then
        job_name=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $3}')
        
        org_tag=""
        if [[ "$job_name" == org-a-* ]]; then org_tag="[DataCorp]"
        elif [[ "$job_name" == org-b-* ]]; then org_tag="[TechStart]"
        elif [[ "$job_name" == org-c-* ]]; then org_tag="[Research]"
        elif [[ "$job_name" == org-d-* ]]; then org_tag="[Financial]"
        elif [[ "$job_name" == org-e-* ]]; then org_tag="[Healthcare]"
        fi
        
        case $status in
            COMPLETED) echo "   ✅ $job_name $org_tag" ;;
            RUNNING) echo "   🟢 $job_name $org_tag" ;;
            *) echo "   ⏳ $job_name $org_tag" ;;
        esac
    fi
done

echo ""
echo "💡 System Status:"
if [ $TOTAL_PENDING -eq 0 ]; then
    echo "   ✅ All queues empty - system ready"
else
    echo "   🟡 Processing $TOTAL_PENDING jobs"
fi

if [ $DLQ_COUNT -gt 0 ]; then
    echo "   ⚠️  $DLQ_COUNT jobs in dead letter queue - check logs"
fi

if [ "$TOTAL_JOBS" -gt 0 ] && [ "$COMPLETED" -gt 0 ]; then
    SUCCESS_RATE=$(( (COMPLETED * 100) / TOTAL_JOBS ))
    echo "   📊 Success rate: ${SUCCESS_RATE}% ($COMPLETED/$TOTAL_JOBS completed)"
fi

echo ""
echo "==============================================="
echo "🔄 Refresh: # Stats functionality integrated"
echo "📊 Status: ./status.sh"
echo "💰 Cost demo: ./cost-optimized-demo.sh"
