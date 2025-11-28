#!/bin/bash
# SPDX-FileCopyrightText: Copyright 2021 Amazon.com, Inc. or its affiliates.
# SPDX-License-Identifier: MIT-0   
# NOTE: For internal testings, ensure to use a gamma endpoint to avoid productiomn impact

    # "spark.dynamicAllocation.enabled": "true"
    # "spark.dynamicAllocation.shuffleTracking.enabled": "true"
    # "spark.dynamicAllocation.executorIdleTimeout": "30s"
    # "spark.dynamicAllocation.maxExecutors": "23"


export SHARED_PREFIX_NAME=emr-on-$CLUSTER_NAME
export ACCOUNTID=$(aws sts get-caller-identity --query Account --output text)
export EMR_ROLE_ARN="arn:aws:iam::$ACCOUNTID:role/$SHARED_PREFIX_NAME-execution-role"
export S3BUCKET="${SHARED_PREFIX_NAME}-${ACCOUNTID}-${AWS_REGION}"
export ECR_URL="${ACCOUNTID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export EMR_VERSION="emr-${EMR_IMAGE_VERSION:-"7.9.0"}-latest"
export SELECTED_AZ=${SELECTED_AZ:-"us-west-2a"}
export KMS_ARN=$(aws kms describe-key --key-id arn:aws:kms:${AWS_REGION}:${ACCOUNTID}:alias/cmk_locust_pvc_reuse --query 'KeyMetadata.Arn' --output text)

aws emr-containers start-job-run \
--virtual-cluster-id $VIRTUAL_CLUSTER_ID \
--name $JOB_UNIQUE_ID-5userpersec-apilift \
--execution-role-arn $EMR_ROLE_ARN \
--release-label $EMR_VERSION \
--job-driver '{
  "sparkSubmitJobDriver": {
      "entryPoint": "local:///usr/lib/spark/examples/jars/eks-spark-benchmark-assembly-1.0.jar",
      "entryPointArguments":["s3://blogpost-sparkoneks-us-east-1/blog/tpc30","s3://'$S3BUCKET'/EMRONEKS_PVC-REUSE-TEST-RESULT","/opt/tpcds-kit/tools","parquet","30","1","false","q4-v2.4,q24a-v2.4,q24b-v2.4,q67-v2.4","false"],
      "sparkSubmitParameters": "--class com.amazonaws.eks.tpcds.BenchmarkSQL --conf spark.driver.cores=2 --conf spark.driver.memory=2g --conf spark.executor.cores=3 --conf spark.executor.memory=6g --conf spark.executor.instances=30"}}' \
--configuration-overrides '{
    "applicationConfiguration": [
      {
        "classification": "spark-defaults", 
        "properties": {
          "spark.kubernetes.container.image.pullPolicy": "IfNotPresent",
          "spark.kubernetes.container.image": "'$ECR_URL'/eks-spark-benchmark:emr7.9.0-tpcds2.4",
          "spark.network.timeout": "3600s",
          "spark.executor.heartbeatInterval": "300s",

          "spark.hadoop.fs.s3.maxRetries": "20",
          "spark.hadoop.fs.s3.retry.interval.millis": "5000",
          "spark.hadoop.fs.s3.fast.upload": "true",
          "spark.scheduler.maxRegisteredResourcesWaitingTime": "1800s",

          "spark.kubernetes.executor.node.selector.karpenter.sh/nodepool": "executor-memorynodepool",
          "spark.kubernetes.driver.node.selector.karpenter.sh/nodepool": "driver-nodepool",
          "spark.kubernetes.node.selector.topology.kubernetes.io/zone": "'$SELECTED_AZ'",

          "spark.kubernetes.driver.waitToReusePersistentVolumeClaim": "true",
          "spark.kubernetes.driver.ownPersistentVolumeClaim": "true",
          "spark.kubernetes.driver.reusePersistentVolumeClaim": "true",
          "spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.mount.readOnly": "false",
          "spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.options.claimName": "OnDemand",
          "spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.options.storageClass": "gp3",
          "spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.options.sizeLimit": "5Gi",
          "spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.mount.path": "/data1",

          "spark.ui.prometheus.enabled":"true",
          "spark.executor.processTreeMetrics.enabled":"true",
          "spark.kubernetes.driver.annotation.prometheus.io/scrape":"true",
          "spark.kubernetes.driver.annotation.prometheus.io/path":"/metrics/executors/prometheus/",
          "spark.kubernetes.driver.annotation.prometheus.io/port":"4040",
          "spark.kubernetes.driver.service.annotation.prometheus.io/scrape":"true",
          "spark.kubernetes.driver.service.annotation.prometheus.io/path":"/metrics/driver/prometheus/",
          "spark.kubernetes.driver.service.annotation.prometheus.io/port":"4040",
          "spark.metrics.conf.*.sink.prometheusServlet.class":"org.apache.spark.metrics.sink.PrometheusServlet",
          "spark.metrics.conf.*.sink.prometheusServlet.path":"/metrics/driver/prometheus/",
          "spark.metrics.conf.master.sink.prometheusServlet.path":"/metrics/master/prometheus/",
          "spark.metrics.conf.applications.sink.prometheusServlet.path":"/metrics/applications/prometheus/"
      }},
      {
        "classification": "emr-containers-defaults",
        "properties": {
          "job-start-timeout":"3600"
      }}
    ], 
    "monitoringConfiguration": {
      "managedLogs": {
        "allowAWSToRetainLogs": "ENABLED",
        "encryptionKeyArn": "'$KMS_ARN'"
      },
      "s3MonitoringConfiguration": {"logUri": "s3://'$S3BUCKET'/elasticmapreduce/emr-containers"}}}'