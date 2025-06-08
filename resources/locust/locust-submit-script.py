from locust import HttpUser, task, between
import os
import yaml
import time
import uuid
from kubernetes import client, config
from kubernetes.client.rest import ApiException
import logging
import random
import copy

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class SparkSubmitUser(HttpUser):
    wait_time = between(1, 5)  
    
    def on_start(self):
        """Initialize Kubernetes client"""
        try:
            config.load_incluster_config()
            logger.info("Successfully loaded in-cluster Kubernetes configuration")
        except Exception as e:
            logger.error(f"Failed to load cluster configuration: {str(e)}")
            config.load_kube_config()
            logger.info("Loaded kubeconfig from default location")
            
        self.k8s_client = client.CustomObjectsApi()
    
        try:
            template_path = "/locust/locust-spark-pi.yaml"
            logger.info(f"Attempting to load template: {template_path}")
            with open(template_path, "r") as f:
                self.spark_template = yaml.safe_load(f)
                logger.info(f"Successfully loaded Spark template: {self.spark_template['metadata']['name']}")
        except Exception as e:
            logger.error(f"Failed to load template: {str(e)}")
            try:
                logger.info(f"Directory contents of /locust/: {os.listdir('/locust/')}")
            except Exception as e2:
                logger.error(f"Cannot list directory: {str(e2)}")
            self.spark_template = None
    
    @task
    def submit_spark_job(self):
        """Submit a Spark job through the Spark Operator"""
        if not self.spark_template:
            logger.error("No Spark template available, skipping submission")
            return
            
        try:
            namespace_index = random.randint(0, SPARK_JOB_NS_NUM - 1)
            target_namespace = f"spark-job{namespace_index}"
            service_account = f"spark-job-sa{namespace_index}"
            
            unique_id = str(uuid.uuid4())[:8]
            job_name = f"spark-pi-{unique_id}"
            
            template_path = "/locust/locust-spark-pi.yaml"
            with open(template_path, "r") as f:
                template_content = f.read()
            
            template_content = template_content.replace("JOB_NAME", job_name)
            template_content = template_content.replace("JOB_NS", target_namespace)
            template_content = template_content.replace("JOB_SA", service_account)
        
            spark_job = yaml.safe_load(template_content)
            
            start_time = time.time()
            
            logger.info(f"Submitting job to {target_namespace}: {job_name}, using service account: {service_account}")
            self.k8s_client.create_namespaced_custom_object(
                group="sparkoperator.k8s.io",
                version="v1beta2",
                namespace=target_namespace,
                plural="sparkapplications",
                body=spark_job
            )
            
            request_time = int((time.time() - start_time) * 1000)
            
            self.environment.events.request.fire(
                request_type="SparkSubmit",
                name=f"Submission to {target_namespace}: {job_name}",
                response_time=request_time,
                response_length=0,
                exception=None,
            )
            
            logger.info(f"Successfully submitted job {job_name} to namespace {target_namespace}")
            
        except ApiException as e:
            try:
                self.environment.events.request.fire(
                    request_type="SparkSubmit",
                    name=f"Submission to {target_namespace}: {job_name}",
                    response_time=int((time.time() - start_time) * 1000),
                    response_length=0,
                    exception=e,
                )
            except Exception:
                self.environment.events.request.fire(
                    request_type="SparkSubmit",
                    name="Submission failed",
                    response_time=0,
                    response_length=0,
                    exception=e,
                )
            logger.error(f"Failed to submit job: {str(e)}")
