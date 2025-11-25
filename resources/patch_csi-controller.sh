#!/bin/bash

NAMESPACE="kube-system"
DEPLOYMENT_NAME="ebs-csi-controller"

echo "Namespace: $NAMESPACE"
echo "Deployment: $DEPLOYMENT_NAME"

echo "patch the csi-provisioner container"
kubectl patch deployment $DEPLOYMENT_NAME -n $NAMESPACE --type='json' -p='[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/1/args/9",
    "value": "--worker-threads=300"
  }
]'

# Update csi-provisioner memory limit
kubectl patch deployment $DEPLOYMENT_NAME -n $NAMESPACE --type='json' -p='[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/1/resources/limits/memory",
    "value": "2Gi"
  }
]'

echo "Creating patch for csi-attacher..."
# Now patch the csi-attacher container
kubectl patch deployment $DEPLOYMENT_NAME -n $NAMESPACE --type='json' -p='[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/2/args/6",
    "value": "--worker-threads=500"
  }
]'
kubectl patch deployment $DEPLOYMENT_NAME -n $NAMESPACE --type='json' -p='[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/2/resources/limits/memory",
    "value": "2Gi"
  }
]'

if [ $? -eq 0 ]; then
    echo "✅ Patches applied successfully!"
    echo
    
    echo "⏳ Waiting for rollout to complete..."
    kubectl rollout status deployment/$DEPLOYMENT_NAME -n $NAMESPACE --timeout=300s
    
    if [ $? -eq 0 ]; then
        echo "✅ Rollout completed successfully!"
        echo
        
        echo "🔍 Verifying the changes..."
        echo "Current pod status:"
        kubectl get pods -n $NAMESPACE -l app=ebs-csi-controller
        echo
        
        echo "📊 Checking container arguments and resources:"
        POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=ebs-csi-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        
        if [ -n "$POD_NAME" ]; then
            echo "Pod name: $POD_NAME"
            
            echo "CSI Provisioner configuration:"
            kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.spec.containers[?(@.name=="csi-provisioner")].args}' | tr ',' '
' | grep worker-threads || echo "Worker threads not found in args"
            
            echo "CSI Provisioner memory limit:"
            kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.spec.containers[?(@.name=="csi-provisioner")].resources.limits.memory}'
            
            echo "CSI Attacher configuration:"
            kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.spec.containers[?(@.name=="csi-attacher")].args}' | tr ',' '
' | grep worker-threads || echo "Worker threads not found in args"

            echo "CSI Attacher memory limit:"
            kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.spec.containers[?(@.name=="csi-attacher")].resources.limits.memory}'

        else
            echo "⚠️  Could not find running pod, checking deployment spec..."
            kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[?(@.name=="csi-provisioner")].args}' | tr ',' '
' | grep worker-threads
            kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[?(@.name=="csi-attacher")].args}' | tr ',' '
' | grep worker-threads
        fi
    fi    
        
else
    echo "❌ Failed to apply patches"
    exit 1
fi