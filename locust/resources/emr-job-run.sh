#!/bin/bash
# SPDX-FileCopyrightText: Copyright 2021 Amazon.com, Inc. or its affiliates.
# SPDX-License-Identifier: MIT-0   

    # "spark.dynamicAllocation.enabled": "true"
    # "spark.dynamicAllocation.shuffleTracking.enabled": "true"
    # "spark.dynamicAllocation.executorIdleTimeout": "30s"
    # "spark.dynamicAllocation.maxExecutors": "23"

# export EMRCLUSTER_NAME=emr-on-load-test-cluster-10
# export AWS_REGION=us-west-2
# export JOB_UNIQUE_ID=pvcreuse-test
export ACCOUNTID=$(aws sts get-caller-identity --query Account --output text)                    
# export VIRTUAL_CLUSTER_ID=$(aws emr-containers list-virtual-clusters --query "virtualClusters[?name == '$EMRCLUSTER_NAME' && state == 'RUNNING' && info.eksInfo.namespace == 'emr'].id" --output text)
export EMR_ROLE_ARN=arn:aws:iam::$ACCOUNTID:role/$EMRCLUSTER_NAME-execution-role
export S3BUCKET=$EMRCLUSTER_NAME-$ACCOUNTID-$AWS_REGION
export ECR_URL="$ACCOUNTID.dkr.ecr.$AWS_REGION.amazonaws.com"
export EMR_VERSION=${EMR_VERSION:-"emr-7.9.0-latest"}
export SELECTED_AZ=${SELECTED_AZ:-"us-west-2a"}

aws emr-containers start-job-run \
--virtual-cluster-id $VIRTUAL_CLUSTER_ID \
--name $JOB_UNIQUE_ID \
--execution-role-arn $EMR_ROLE_ARN \
--release-label $EMR_VERSION \
--job-driver '{
  "sparkSubmitJobDriver": {
      "entryPoint": "local:///usr/lib/spark/examples/jars/eks-spark-benchmark-assembly-1.0.jar",
      "entryPointArguments":["s3://blogpost-sparkoneks-us-east-1/blog/tpc30/","s3://'$S3BUCKET'/EMRONEKS_PVC-REUSE-TEST-RESULT","/opt/tpcds-kit/tools","parquet","30","1","false","q4-v2.4,q23a-v2.4,q23b-v2.4,q24a-v2.4,q24b-v2.4,q67-v2.4,q50-v2.4,q93-v2.4","false"],
      "sparkSubmitParameters": "--class com.amazonaws.eks.tpcds.BenchmarkSQL --conf spark.driver.cores=1 --conf spark.driver.memory=1g --conf spark.executor.cores=2 --conf spark.executor.memory=2g --conf spark.executor.instances=23"}}' \
--configuration-overrides '{
    "applicationConfiguration": [
      {
        "classification": "spark-defaults", 
        "properties": {
          "spark.kubernetes.container.image.pullPolicy": "IfNotPresent",
          "spark.kubernetes.container.image": "'$ECR_URL'/eks-spark-benchmark:emr7.9.0-tpcds2.4",
          "spark.kubernetes.driver.podTemplateFile": "s3://'$S3BUCKET'/app_code/pod-template/driver-pod-template.yaml",
          "spark.kubernetes.executor.podTemplateFile": "s3://'$S3BUCKET'/app_code/pod-template/executor-pod-template.yaml",
          "spark.network.timeout": "2000s",
          "spark.executor.heartbeatInterval": "300s",
          
          "spark.kubernetes.scheduler.name": "custom-scheduler-eks",
          "spark.kubernetes.executor.node.selector.karpenter.sh/nodepool": "executor-memorynodepool",
          "spark.kubernetes.driver.node.selector.karpenter.sh/nodepool": "driver-nodepool",
          "spark.kubernetes.executor.node.selector.karpenter.sh/capacity-type": "ON_DEMAND",
          "spark.kubernetes.node.selector.topology.kubernetes.io/zone": "'$SELECTED_AZ'",

          "spark.kubernetes.driver.waitToReusePersistentVolumeClaim": "true",
          "spark.kubernetes.driver.ownPersistentVolumeClaim": "true",
          "spark.kubernetes.driver.reusePersistentVolumeClaim": "true",
          "spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.mount.readOnly": "false",
          "spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.options.claimName": "OnDemand",
          "spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.options.storageClass": "gp3",
          "spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.options.sizeLimit": "3Gi",
          "spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.mount.path": "/data1"
         }}
    ], 
    "monitoringConfiguration": {
      "s3MonitoringConfiguration": {"logUri": "s3://'$S3BUCKET'/elasticmapreduce/emr-containers"}}}'