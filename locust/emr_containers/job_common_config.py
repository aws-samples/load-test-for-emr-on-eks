# Amazon EMR on EKS Job related configuration parameters
REGION = "us-west-2"
EKS_CLUSTER_NAME = "load-test-cluster-10"
JOB_SCRIPT_NAME_PATH = "./resources/emr-eks-benchmark-oom.sh"

# IAM role Arn to run workloads on Amazon EMR on EKS
# Steps to create Job execution role:
# https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/creating-job-execution-role.html
# Format: arn:<AWS_PARTITION>:iam::<AWS_ACCOUNT_ID>:role/<JOB_EXECUTION_ROLE_NAME>
# JOB_EXECUTION_ROLE_ARN = "arn:aws:iam::061698477416:role/emr-on-load-test-cluster-10-execution-role"

# We are using Sample Pi calculation job for a default scale test run.
# Please modify below parameters based on the Job that you may want to run as a part of scale test.
# Documentation - https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/emr-eks-jobs-CLI.html#emr-eks-jobs-parameters

# This is the HCFS (Hadoop compatible file system) reference to the main jar/py file you want to run.
# JOB_ENTRY_POINT = "local:///usr/lib/spark/examples/jars/eks-spark-benchmark-assembly-1.0.jar"
# STREAMING_JOB_ENTRY_POINT = "s3://streaming-workflow/streaming_job.py"


# This is the argument you want to pass to your JAR. You should handle reading this parameter using your entry-point code.
# JOB_ENTRY_POINT_ARGS = ["s3://blogpost-sparkoneks-us-east-1/blog/tpc30/","s3://emr-on-load-test-cluster-10-061698477416-us-west-2/EMRONEKS_PVC-REUSE-TEST-RESULT","/opt/tpcds-kit/tools","parquet","30","1","false","q4-v2.4,q23a-v2.4,q23b-v2.4,q24a-v2.4,q24b-v2.4,q67-v2.4,q50-v2.4,q93-v2.4","false"]
# These are the additional spark parameters you want to sensd to the job.
# Use this parameter to override default Spark properties such as driver memory or number of executors like —conf or —class
                                #  "--conf spark.kubernetes.driver.podTemplateFile=s3://zyulin-chicago-dev/load-test-pod-template.yaml " + \
                                #  "--conf spark.kubernetes.executor.podTemplateFile=s3://zyulin-chicago-dev/load-test-pod-template.yaml"

# Amazon EMR on EKS release version
# https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/emr-eks-releases.html
# RELEASE_LABEL = "emr-7.9.0-latest"

# Name of the Amazon Cloudwatch log group for publishing job logs.
# https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/emr-eks-jobs-CLI.html#emr-eks-jobs-cloudwatch
# CLOUD_WATCH_LOG_GROUP_NAME = "scaling"

# Amazon S3 bucket URI for publishing logs
# https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/emr-eks-jobs-CLI.html#emr-eks-jobs-s3
# Format: "s3://path-to-log-bucket"
# S3_LOG_PATH = "s3://emr-on-load-test-cluster-10-061698477416-us-west-2/elasticmapreduce/emr-containers"

# Scale Test tool report local file path.
# After a successful execution of scale test, a folder "scale-test-output" will be created (only if it doesn't exist)
# at the path "<path-to-repo>/amazon-emr-on-eks-scale-test-tool/" and a file with prefix "scale-test-run-report" will be
# generated.
# JOB_RUN_OUTPUT_FILE_PATH_PREFIX = "scale-test-output/scale-test-run-report"

