from locust import HttpUser, task, between
import os
import yaml
import time
import uuid
from kubernetes import client, config
from kubernetes.client.rest import ApiException
import logging
import random

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class SparkSubmitUser(HttpUser):
    wait_time = between(1, 5)  # Wait 1-5 seconds between tasks
    
    def on_start(self):
        """Initialize Kubernetes client when user starts"""
        try:
            # Try to load in-cluster config
            config.load_incluster_config()
            logger.info("Successfully loaded in-cluster Kubernetes configuration")
        except Exception as e:
            logger.error(f"Failed to load cluster config: {str(e)}")
            # Fall back to kubeconfig for local development
            config.load_kube_config()
            logger.info("Loaded kubeconfig from default location")
            
        self.k8s_client = client.CustomObjectsApi()
        
        # Load SparkApplication template
        try:
            # Use absolute path to read the template
            template_path = "/locust/spark-pi.yaml"
            logger.info(f"Attempting to load template: {template_path}")
            with open(template_path, "r") as f:
                self.spark_template = yaml.safe_load(f)
                logger.info(f"Successfully loaded Spark template: {self.spark_template['metadata']['name']}")
                logger.info(f"Template content summary: {self.spark_template['kind']}, {self.spark_template['apiVersion']}")
        except Exception as e:
            logger.error(f"Failed to load template: {str(e)}")
            try:
                # List directory contents for debugging
                import os
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
            # Randomly select a target namespace
            namespace_index = random.randint(0, SPARK_JOB_NS_NUM - 1)
            target_namespace = f"spark-job{namespace_index}"
            
            # Generate a unique job name
            unique_id = str(uuid.uuid4())[:8]
            job_name = f"spark-pi-{unique_id}"
            
            # Modify template with unique name and target namespace
            spark_job = self.spark_template.copy()
            spark_job["metadata"]["name"] = job_name
            spark_job["metadata"]["namespace"] = target_namespace
            
            # Record operation start time for Locust statistics
            start_time = time.time()
            
            # Submit the job using Kubernetes API
            logger.info(f"Submitting job to {target_namespace}: {job_name}")
            self.k8s_client.create_namespaced_custom_object(
                group="sparkoperator.k8s.io",
                version="v1beta2",
                namespace=target_namespace,
                plural="sparkapplications",
                body=spark_job
            )
            
            # Calculate request time
            request_time = int((time.time() - start_time) * 1000)
            
            # Log success to Locust statistics
            self.environment.events.request.fire(
                request_type="SparkSubmit",
                name=f"Submit to {target_namespace}: {job_name}",
                response_time=request_time,
                response_length=0,
                exception=None,
            )
            
            logger.info(f"Successfully submitted job {job_name} to namespace {target_namespace}")
            
        except ApiException as e:
            # Log failure to Locust statistics
            self.environment.events.request.fire(
                request_type="SparkSubmit",
                name=f"Submit to {target_namespace}: {job_name}",
                response_time=int((time.time() - start_time) * 1000),
                response_length=0,
                exception=e,
            )
            logger.error(f"Failed to submit job: {str(e)}")