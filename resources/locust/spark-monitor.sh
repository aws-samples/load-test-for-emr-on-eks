#!/bin/bash

# Real-time SparkApplication Monitor
echo "🔄 Real-time SparkApplication Monitor"
echo "Press Ctrl+C to stop"
echo "========================================"

while true; do
    clear
    echo "🕐 $(date)"
    echo "========================================"
    
    # Overall status count
    echo "📊 CURRENT STATUS DISTRIBUTION:"
    kubectl get sparkapplications -A -o json 2>/dev/null | jq -r '
        .items[] | 
        if .status.applicationState.state then .status.applicationState.state 
        else "NEW" end
    ' | sort | uniq -c | awk '{printf "  %-12s: %3d\n", $2, $1}'
    
    echo ""
    
    # Total count
    TOTAL=$(kubectl get sparkapplications -A --no-headers 2>/dev/null | wc -l)
    echo "📈 Total Applications: $TOTAL"
    
    echo ""
    echo "🏃 CURRENTLY RUNNING:"
    kubectl get sparkapplications -A -o json 2>/dev/null | jq -r '
        .items[] | 
        select(.status.applicationState.state == "RUNNING") | 
        "\(.metadata.namespace)/\(.metadata.name)"
    ' | head -5
    
    echo ""
    echo "⏳ RECENTLY SUBMITTED:"
    kubectl get sparkapplications -A -o json 2>/dev/null | jq -r '
        .items[] | 
        select(.status.applicationState.state == "SUBMITTED") | 
        "\(.metadata.namespace)/\(.metadata.name)"
    ' | head -3
    
    echo ""
    echo "========================================"
    echo "Refreshing in 10 seconds... (Ctrl+C to stop)"
    
    sleep 10
done