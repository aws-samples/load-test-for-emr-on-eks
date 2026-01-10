kubectl -n kube-system patch ds ebs-csi-node --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/1/livenessProbe/initialDelaySeconds", "value": 10},
  {"op": "replace", "path": "/spec/template/spec/containers/1/livenessProbe/failureThreshold", "value": 5},
  {"op": "replace", "path": "/spec/template/spec/containers/1/livenessProbe/periodSeconds", "value": 60}
]'