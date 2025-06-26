#!/usr/bin/env python3

import boto3
import json
import time
import logging
import os
import yaml
from datetime import datetime
from kubernetes import client, config
from prometheus_client import start_http_server, Counter, Gauge, Histogram
import threading
from collections import defaultdict
import uuid

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Prometheus metrics
jobs_received_counter = Counter('sqs_jobs_received_total', 'Total jobs received from SQS', ['priority', 'organization', 'project'])
jobs_submitted_counter = Counter('spark_jobs_submitted_total', 'Total Spark jobs submitted to operator', ['namespace', 'priority', 'organization', 'project'])
jobs_failed_counter = Counter('spark_jobs_failed_total', 'Total failed Spark job submissions', ['namespace', 'priority', 'organization', 'project'])
queue_depth_gauge = Gauge('sqs_queue_depth', 'Current SQS queue depth')
running_jobs_gauge = Gauge('spark_jobs_running', 'Currently running Spark jobs', ['namespace', 'priority', 'organization', 'project'])
pending_jobs_gauge = Gauge('spark_jobs_pending', 'Currently pending Spark jobs', ['namespace'])
pending_drivers_gauge = Gauge('spark_drivers_pending', 'Currently pending Spark driver pods', ['namespace'])
job_processing_time = Histogram('job_processing_seconds', 'Time spent processing jobs')
scheduler_health_gauge = Gauge('scheduler_health', 'Scheduler health status (1=healthy, 0=unhealthy)')
driver_check_time = Histogram('driver_check_seconds', 'Time spent checking pending drivers')
sqs_poll_skipped_counter = Counter('sqs_poll_skipped_total', 'Total SQS polls skipped due to pending drivers')

class SparkJobScheduler:
    def __init__(self):
        # Load Kubernetes config
        try:
            config.load_incluster_config()
        except:
            config.load_kube_config()
        
        self.k8s_client = client.ApiClient()
        self.custom_api = client.CustomObjectsApi()
        self.core_api = client.CoreV1Api()
        
        # AWS SQS client
        self.sqs = boto3.client('sqs', region_name=os.getenv('AWS_REGION', 'us-west-2'))
        self.queue_url = os.getenv('SQS_QUEUE_URL')
        self.dlq_url = os.getenv('SQS_DLQ_URL')
        
        # Configuration
        self.batch_size = int(os.getenv('JOB_SCHEDULER_BATCH_SIZE', '10'))
        self.poll_interval = int(os.getenv('JOB_SCHEDULER_POLL_INTERVAL', '5'))
        self.driver_check_interval = int(os.getenv('DRIVER_CHECK_INTERVAL', '1'))  # Check every 1 second
        self.spark_job_namespaces = self._get_spark_job_namespaces()
        self.namespace_index = 0
        
        # Priority mapping
        self.priority_weights = {'high': 3, 'medium': 2, 'low': 1}
        
        # Job tracking
        self.running_jobs = defaultdict(list)
        self.job_stats = defaultdict(lambda: defaultdict(int))
        
        logger.info(f"Scheduler initialized with queue: {self.queue_url}")
        logger.info(f"Driver check interval: {self.driver_check_interval} seconds")
        logger.info(f"SQS poll interval: {self.poll_interval} seconds")

    def _get_spark_job_namespaces(self):
        """Get list of Spark job namespaces"""
        try:
            namespaces = self.core_api.list_namespace()
            spark_namespaces = []
            for ns in namespaces.items:
                if ns.metadata.name.startswith('spark-job'):
                    spark_namespaces.append(ns.metadata.name)
            
            if not spark_namespaces:
                spark_namespaces = ['spark-job0', 'spark-job1']  # Default fallback
            
            logger.info(f"Found Spark job namespaces: {spark_namespaces}")
            return sorted(spark_namespaces)
        except Exception as e:
            logger.error(f"Error getting namespaces: {e}")
            return ['spark-job0', 'spark-job1']

    def _check_pending_driver_pods(self):
        """Check if there are any pending Spark driver pods across all namespaces"""
        with driver_check_time.time():
            try:
                total_pending_drivers = 0
                
                for namespace in self.spark_job_namespaces:
                    try:
                        # Get all pods in the namespace
                        pods = self.core_api.list_namespaced_pod(
                            namespace=namespace,
                            label_selector="spark-role=driver"
                        )
                        
                        pending_count = 0
                        for pod in pods.items:
                            if pod.status.phase == 'Pending':
                                pending_count += 1
                                logger.debug(f"Found pending driver pod: {pod.metadata.name} in {namespace}")
                        
                        # Update metrics for this namespace
                        pending_drivers_gauge.labels(namespace=namespace).set(pending_count)
                        total_pending_drivers += pending_count
                        
                        if pending_count > 0:
                            logger.info(f"Namespace {namespace}: {pending_count} pending driver pods")
                    
                    except Exception as e:
                        logger.warning(f"Error checking pods in namespace {namespace}: {e}")
                        continue
                
                logger.debug(f"Total pending driver pods across all namespaces: {total_pending_drivers}")
                return total_pending_drivers > 0
                
            except Exception as e:
                logger.error(f"Error checking pending driver pods: {e}")
                return False  # If we can't check, assume no pending drivers to avoid blocking

    def _parse_job_message(self, message):
        """Parse SQS message and extract job metadata"""
        try:
            body = json.loads(message['Body'])
            
            # Extract metadata
            metadata = {
                'job_id': body.get('job_id', str(uuid.uuid4())),
                'priority': body.get('priority', 'medium'),
                'organization': body.get('organization', 'unknown'),
                'project': body.get('project', 'unknown'),
                'namespace': body.get('namespace', 'spark-job0'),
                'spark_job_yaml': body.get('spark_job_yaml', ''),
                'created_at': body.get('created_at', datetime.utcnow().isoformat()),
                'tags': body.get('tags', {})
            }
            
            # Validate priority
            if metadata['priority'] not in self.priority_weights:
                metadata['priority'] = 'medium'
            
            return metadata
        except Exception as e:
            logger.error(f"Error parsing job message: {e}")
            return None

    def _create_spark_application(self, job_metadata):
        """Create Spark application YAML from job metadata"""
        try:
            # Parse the base spark job YAML
            spark_job_yaml = yaml.safe_load(job_metadata['spark_job_yaml'])
            
            # Update metadata
            spark_job_yaml['metadata']['name'] = f"{job_metadata['job_id']}-{int(time.time())}"
            spark_job_yaml['metadata']['namespace'] = job_metadata['namespace']
            
            # Add labels for tracking
            if 'labels' not in spark_job_yaml['metadata']:
                spark_job_yaml['metadata']['labels'] = {}
            
            spark_job_yaml['metadata']['labels'].update({
                'priority': job_metadata['priority'],
                'organization': job_metadata['organization'],
                'project': job_metadata['project'],
                'job-id': job_metadata['job_id'],
                'managed-by': 'sqs-scheduler'
            })
            
            # Add annotations
            if 'annotations' not in spark_job_yaml['metadata']:
                spark_job_yaml['metadata']['annotations'] = {}
            
            spark_job_yaml['metadata']['annotations'].update({
                'sqs-scheduler/created-at': job_metadata['created_at'],
                'sqs-scheduler/priority': job_metadata['priority'],
                'sqs-scheduler/tags': json.dumps(job_metadata['tags'])
            })
            
            return spark_job_yaml
        except Exception as e:
            logger.error(f"Error creating Spark application: {e}")
            return None

    def _submit_spark_job(self, spark_app_yaml, job_metadata):
        """Submit Spark job to Kubernetes"""
        try:
            namespace = job_metadata['namespace']
            
            # Submit to Kubernetes
            result = self.custom_api.create_namespaced_custom_object(
                group="sparkoperator.k8s.io",
                version="v1beta2",
                namespace=namespace,
                plural="sparkapplications",
                body=spark_app_yaml
            )
            
            # Record success metrics
            jobs_submitted_counter.labels(
                namespace=namespace,
                priority=job_metadata['priority'],
                organization=job_metadata['organization'],
                project=job_metadata['project']
            ).inc()
            
            logger.info(f"Successfully submitted Spark job {spark_app_yaml['metadata']['name']} to {namespace}")
            return True
            
        except Exception as e:
            # Record failure metrics
            jobs_failed_counter.labels(
                namespace=job_metadata['namespace'],
                priority=job_metadata['priority'],
                organization=job_metadata['organization'],
                project=job_metadata['project']
            ).inc()
            
            logger.error(f"Failed to submit Spark job: {e}")
            return False

    def _update_job_metrics(self):
        """Update job metrics from Kubernetes"""
        try:
            for namespace in self.spark_job_namespaces:
                # Get Spark applications
                apps = self.custom_api.list_namespaced_custom_object(
                    group="sparkoperator.k8s.io",
                    version="v1beta2",
                    namespace=namespace,
                    plural="sparkapplications"
                )
                
                # Count by status and labels
                status_counts = defaultdict(lambda: defaultdict(lambda: defaultdict(int)))
                
                for app in apps.get('items', []):
                    labels = app.get('metadata', {}).get('labels', {})
                    status = app.get('status', {}).get('applicationState', {}).get('state', 'unknown')
                    
                    priority = labels.get('priority', 'unknown')
                    organization = labels.get('organization', 'unknown')
                    project = labels.get('project', 'unknown')
                    
                    if status in ['RUNNING', 'SUBMITTED']:
                        running_jobs_gauge.labels(
                            namespace=namespace,
                            priority=priority,
                            organization=organization,
                            project=project
                        ).set(status_counts[status][priority][(organization, project)])
                        status_counts[status][priority][(organization, project)] += 1
                    
                    if status in ['PENDING', 'SUBMITTED']:
                        pending_jobs_gauge.labels(namespace=namespace).inc()
                
        except Exception as e:
            logger.error(f"Error updating job metrics: {e}")

    def _get_queue_depth(self):
        """Get current SQS queue depth"""
        try:
            response = self.sqs.get_queue_attributes(
                QueueUrl=self.queue_url,
                AttributeNames=['ApproximateNumberOfMessages']
            )
            depth = int(response['Attributes']['ApproximateNumberOfMessages'])
            queue_depth_gauge.set(depth)
            return depth
        except Exception as e:
            logger.error(f"Error getting queue depth: {e}")
            return 0

    def _process_messages_batch(self, messages):
        """Process a batch of SQS messages with priority sorting"""
        jobs = []
        
        # Parse all messages
        for message in messages:
            job_metadata = self._parse_job_message(message)
            if job_metadata:
                jobs.append((message, job_metadata))
                jobs_received_counter.labels(
                    priority=job_metadata['priority'],
                    organization=job_metadata['organization'],
                    project=job_metadata['project']
                ).inc()
        
        # Sort by priority (high -> medium -> low)
        jobs.sort(key=lambda x: self.priority_weights.get(x[1]['priority'], 0), reverse=True)
        
        # Process jobs in priority order
        for message, job_metadata in jobs:
            with job_processing_time.time():
                try:
                    # Create Spark application YAML
                    spark_app_yaml = self._create_spark_application(job_metadata)
                    if not spark_app_yaml:
                        continue
                    
                    # Submit job
                    if self._submit_spark_job(spark_app_yaml, job_metadata):
                        # Delete message from queue on successful submission
                        self.sqs.delete_message(
                            QueueUrl=self.queue_url,
                            ReceiptHandle=message['ReceiptHandle']
                        )
                        logger.info(f"Successfully processed job {job_metadata['job_id']}")
                    else:
                        logger.error(f"Failed to submit job {job_metadata['job_id']}")
                        
                except Exception as e:
                    logger.error(f"Error processing job {job_metadata.get('job_id', 'unknown')}: {e}")

    def run(self):
        """Main scheduler loop with driver pod checking"""
        logger.info("Starting SQS Job Scheduler with driver pod checking...")
        
        # Start Prometheus metrics server
        start_http_server(8080)
        logger.info("Prometheus metrics server started on port 8080")
        
        # Start metrics update thread
        metrics_thread = threading.Thread(target=self._metrics_updater, daemon=True)
        metrics_thread.start()
        
        scheduler_health_gauge.set(1)
        last_sqs_poll = 0
        
        while True:
            try:
                current_time = time.time()
                
                # Check for pending driver pods every second
                has_pending_drivers = self._check_pending_driver_pods()
                
                if has_pending_drivers:
                    logger.info("⏸️  Pending driver pods detected - skipping SQS polling")
                    sqs_poll_skipped_counter.inc()
                    time.sleep(self.driver_check_interval)
                    continue
                
                # Only poll SQS if no pending drivers and enough time has passed
                if current_time - last_sqs_poll >= self.poll_interval:
                    logger.info("✅ No pending drivers - polling SQS for new jobs")
                    
                    # Get queue depth
                    queue_depth = self._get_queue_depth()
                    logger.info(f"Queue depth: {queue_depth}")
                    
                    # Receive messages from SQS
                    response = self.sqs.receive_message(
                        QueueUrl=self.queue_url,
                        MaxNumberOfMessages=self.batch_size,
                        WaitTimeSeconds=1,  # Short wait since we're checking frequently
                        MessageAttributeNames=['All']
                    )
                    
                    messages = response.get('Messages', [])
                    if messages:
                        logger.info(f"📨 Received {len(messages)} messages from SQS")
                        self._process_messages_batch(messages)
                    else:
                        logger.debug("No messages received from SQS")
                    
                    last_sqs_poll = current_time
                
                scheduler_health_gauge.set(1)
                time.sleep(self.driver_check_interval)  # Check drivers every second
                
            except Exception as e:
                logger.error(f"Error in main loop: {e}")
                scheduler_health_gauge.set(0)
                time.sleep(self.driver_check_interval)

    def _metrics_updater(self):
        """Background thread to update metrics"""
        while True:
            try:
                self._update_job_metrics()
                time.sleep(30)  # Update every 30 seconds
            except Exception as e:
                logger.error(f"Error updating metrics: {e}")
                time.sleep(30)

if __name__ == "__main__":
    scheduler = SparkJobScheduler()
    scheduler.run()

