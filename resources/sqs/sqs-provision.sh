#!/bin/bash

# SQS Infrastructure Provisioning Script
# Can be run standalone or called from infra-provision.sh
# Usage: ./sqs-provision.sh [setup|cleanup]

set -e
source ./env.sh

ACTION=${1:-setup}

setup_sqs() {
    echo "==============================================="
    echo "  Setting up SQS Infrastructure ......"
    echo "==============================================="

# Create Dead Letter Queue first
echo "Creating SQS Dead Letter Queue: $SQS_DLQ_NAME"
DLQ_URL=$(aws sqs create-queue \
    --queue-name $SQS_DLQ_NAME \
    --region $AWS_REGION \
    --attributes '{
        "MessageRetentionPeriod": "1209600",
        "VisibilityTimeout": "300"
    }' \
    --query 'QueueUrl' --output text)

echo "Dead Letter Queue URL: $DLQ_URL"

# Get DLQ ARN
DLQ_ARN=$(aws sqs get-queue-attributes \
    --queue-url $DLQ_URL \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' --output text)

echo "Dead Letter Queue ARN: $DLQ_ARN"

# Create main SQS queue with DLQ configuration
echo "Creating SQS Queue: $SQS_QUEUE_NAME"
SQS_QUEUE_URL=$(aws sqs create-queue \
    --queue-name $SQS_QUEUE_NAME \
    --region $AWS_REGION \
    --attributes '{
        "MessageRetentionPeriod": "1209600",
        "VisibilityTimeout": "300", 
        "ReceiveMessageWaitTimeSeconds": "20",
        "RedrivePolicy": "{\"deadLetterTargetArn\":\"'$DLQ_ARN'\",\"maxReceiveCount\":3}"
    }' \
    --query 'QueueUrl' --output text)

echo "Queue URL: $SQS_QUEUE_URL"

# Get Queue ARN
QUEUE_ARN=$(aws sqs get-queue-attributes \
    --queue-url $SQS_QUEUE_URL \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' --output text)

echo "Queue ARN: $QUEUE_ARN"

# Create IAM policy for SQS access
echo "Creating IAM policy for SQS Scheduler: $SQS_SCHEDULER_POLICY"
cat > /tmp/sqs-scheduler-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sqs:ReceiveMessage",
                "sqs:DeleteMessage",
                "sqs:GetQueueAttributes",
                "sqs:GetQueueUrl",
                "sqs:SendMessage"
            ],
            "Resource": [
                "$QUEUE_ARN",
                "$DLQ_ARN"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "sqs:ListQueues"
            ],
            "Resource": "*"
        }
    ]
}
EOF

aws iam create-policy \
    --policy-name $SQS_SCHEDULER_POLICY \
    --policy-document file:///tmp/sqs-scheduler-policy.json || echo "Policy may already exist"

# Store queue URLs for later use
echo $SQS_QUEUE_URL > /tmp/sqs-queue-url.txt
echo $DLQ_URL > /tmp/sqs-dlq-url.txt
echo $QUEUE_ARN > /tmp/sqs-queue-arn.txt
echo $DLQ_ARN > /tmp/sqs-dlq-arn.txt

    echo "✅ SQS infrastructure setup completed!"
    echo "📋 Main Queue URL: $SQS_QUEUE_URL"
    echo "📋 Dead Letter Queue URL: $DLQ_URL"
    echo "📁 Queue URLs saved to /tmp/sqs-*-url.txt files"
}

cleanup_sqs() {
    echo "==============================================="
    echo "  Cleaning up SQS Infrastructure ......"
    echo "==============================================="
    
    # Read queue URLs if they exist
    if [ -f /tmp/sqs-queue-url.txt ]; then
        SQS_QUEUE_URL=$(cat /tmp/sqs-queue-url.txt)
        echo "🗑️  Deleting main SQS queue: $SQS_QUEUE_URL"
        aws sqs delete-queue --queue-url "$SQS_QUEUE_URL" 2>/dev/null || echo "Queue may not exist"
    fi
    
    if [ -f /tmp/sqs-dlq-url.txt ]; then
        DLQ_URL=$(cat /tmp/sqs-dlq-url.txt)
        echo "🗑️  Deleting dead letter queue: $DLQ_URL"
        aws sqs delete-queue --queue-url "$DLQ_URL" 2>/dev/null || echo "DLQ may not exist"
    fi
    
    # Delete IAM policy
    echo "🗑️  Deleting IAM policy: $SQS_SCHEDULER_POLICY"
    aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${SQS_SCHEDULER_POLICY}" 2>/dev/null || echo "Policy may not exist"
    
    # Clean up temp files
    rm -f /tmp/sqs-*.txt /tmp/sqs-scheduler-policy.json
    
    echo "✅ SQS cleanup completed!"
}

# Main execution
case $ACTION in
    "setup")
        setup_sqs
        ;;
    "cleanup")
        cleanup_sqs
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "  setup   - Create SQS queues and IAM policies"
        echo "  cleanup - Delete SQS queues and IAM policies"
        exit 1
        ;;
esac
