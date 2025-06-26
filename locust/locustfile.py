from locust import User, task, between, events
import boto3
import json
import uuid
import time
import random
import copy
from datetime import datetime
import yaml
import os
from prometheus_client import start_http_server, Counter, Gauge

# Prometheus metrics
jobs_sent_counter = Counter('locust_sqs_jobs_sent_total', 'Total jobs sent to SQS', ['priority', 'organization', 'project'])
jobs_failed_counter = Counter('locust_sqs_jobs_failed_total', 'Total failed job submissions to SQS', ['priority', 'organization', 'project'])
queue_submission_time = Counter('locust_sqs_submission_time_seconds', 'Time spent submitting to SQS')
concurrent_user_gauge = Gauge('locust_sqs_concurrent_users', 'Number of concurrent locust users')

@events.init_command_line_parser.add_listener
def on_locust_init(parser):
    parser.add_argument("--job-ns-count", type=int, default=2, help="Number of job namespaces")
    parser.add_argument("--job-azs", type=str, default='["us-west-2a", "us-west-2b"]', help="List of AZs for task allocation")
    parser.add_argument("--job-name", type=str, default="sqs-spark-job", help="Name prefix for Spark jobs")
    parser.add_argument("--binpacking", type=str, default="true", help="Enable or disable binpacking")
    parser.add_argument("--karpenter_driver_not_evict", type=str, default="true", help="Enable or disable driver not evict when using karpenter")
    parser.add_argument("--sqs-queue-url", type=str, required=True, help="SQS Queue URL")
    parser.add_argument("--aws-region", type=str, default="us-west-2", help="AWS Region")

class SQSSparkJobUser(User):
    wait_time = between(1, 5)
    
    def on_start(self):
        """Initialize SQS client and load job template"""
        self.sqs = boto3.client('sqs', region_name=self.environment.parsed_options.aws_region)
        self.queue_url = self.environment.parsed_options.sqs_queue_url
        self.job_name_prefix = self.environment.parsed_options.job_name
        self.job_ns_count = self.environment.parsed_options.job_ns_count
        self.job_azs = json.loads(self.environment.parsed_options.job_azs)
        self.binpacking = self.environment.parsed_options.binpacking.lower() == 'true'
        self.karpenter_driver_not_evict = self.environment.parsed_options.karpenter_driver_not_evict.lower() == 'true'
        
        # Load Spark job template
        self.spark_job_template = self._load_spark_job_template()
        
        # Organizations and projects for testing
        self.organizations = ['org-a', 'org-b', 'org-c', 'org-d']
        self.projects = ['project-alpha', 'project-beta', 'project-gamma', 'project-delta']
        self.priorities = ['high', 'medium', 'low']
        
        concurrent_user_gauge.inc()
    
    def on_stop(self):
        concurrent_user_gauge.dec()
    
    def _load_spark_job_template(self):
        """Load the Spark job YAML template from file"""
        template_path = './resources/spark-pi.yaml'
        
        with open(template_path, 'r') as file:
            template = yaml.safe_load(file)
        
        return template

    
    def _generate_job_metadata(self):
        """Generate job metadata with random values and modify template"""
        job_id = str(uuid.uuid4())
        random_num = random.randint(0, self.job_ns_count - 1)
        priority = random.choice(self.priorities)
        organization = random.choice(self.organizations)
        project = random.choice(self.projects)
        namespace = f"spark-job{random_num}"
        spark_sa = f"spark-job-sa{random_num}"
        
        # Get base template and modify it (same as modify_yaml_file function)
        job_template = copy.deepcopy(self.spark_job_template)
        
        # Basic metadata modifications
        if 'metadata' in job_template and 'name' in job_template['metadata']:
            job_template['metadata']['name'] = f"{self.job_name_prefix}-{job_id}"
            job_template['metadata']['namespace'] = namespace
            job_template['spec']['driver']['serviceAccount'] = spark_sa
        
        # Image configuration
        default_image = "895885662937.dkr.ecr.us-west-2.amazonaws.com/spark/emr-7.7.0:latest"
        job_template['spec']['image'] = os.environ.get('EMR_IMAGE_URL', default_image)
        
        # Spec modifications (simplified for Karpenter-only usage)
        if 'spec' in job_template:
            # Select a single AZ for both driver and executor
            selected_az = random.choice(self.job_azs) if self.job_azs else None
            
            for component in ['driver', 'executor']:
                if component in job_template['spec']:
                    # Ensure nodeSelector exists and is a dictionary
                    if 'nodeSelector' not in job_template['spec'][component] or job_template['spec'][component]['nodeSelector'] is None:
                        job_template['spec'][component]['nodeSelector'] = {}
                    
                    # AZ selection
                    if selected_az:
                        job_template['spec'][component]['nodeSelector']['topology.kubernetes.io/zone'] = selected_az
                    
                    # Binpacking configuration
                    if self.binpacking:
                        job_template['spec'][component]['schedulerName'] = "my-scheduler"
                    
                    # Karpenter provisioner (always enabled since we're Karpenter-only)
                    job_template['spec'][component]['nodeSelector']['karpenter.sh/nodepool'] = f"spark-{component}-provisioner"
                    
                    # Driver eviction protection
                    if self.karpenter_driver_not_evict and component == 'driver':
                        if 'annotations' not in job_template['spec']['driver']:
                            job_template['spec']['driver']['annotations'] = {}
                        job_template['spec']['driver']['annotations']['karpenter.sh/do-not-evict'] = "true"
        
        # Add priority-based resource adjustments
        if priority == 'high':
            job_template["spec"]["executor"]["instances"] = 4
            job_template["spec"]["executor"]["memory"] = "1g"
        elif priority == 'medium':
            job_template["spec"]["executor"]["instances"] = 2
            job_template["spec"]["executor"]["memory"] = "512m"
        else:  # low priority
            job_template["spec"]["executor"]["instances"] = 1
            job_template["spec"]["executor"]["memory"] = "512m"
        
        return {
            'job_id': job_id,
            'priority': priority,
            'organization': organization,
            'project': project,
            'namespace': namespace,
            'spark_job_yaml': yaml.dump(job_template),
            'created_at': datetime.utcnow().isoformat(),
            'tags': {
                'environment': 'load-test',
                'generator': 'locust',
                'test_run': os.getenv('TEST_RUN_ID', 'default'),
                'user_id': str(self.user_id) if hasattr(self, 'user_id') else 'unknown'
            }
        }
    
    @task(weight=3)
    def submit_high_priority_job(self):
        """Submit a high priority job"""
        self._submit_job_with_priority('high')
    
    @task(weight=5)
    def submit_medium_priority_job(self):
        """Submit a medium priority job"""
        self._submit_job_with_priority('medium')
    
    @task(weight=2)
    def submit_low_priority_job(self):
        """Submit a low priority job"""
        self._submit_job_with_priority('low')
    
    def _submit_job_with_priority(self, priority):
        """Submit a job with specified priority to SQS"""
        start_time = time.time()
        
        try:
            # Generate job metadata
            job_metadata = self._generate_job_metadata()
            job_metadata['priority'] = priority  # Override with specified priority
            
            # Create SQS message
            message_body = json.dumps(job_metadata)
            
            # Add message attributes for SQS filtering/routing
            message_attributes = {
                'Priority': {
                    'StringValue': priority,
                    'DataType': 'String'
                },
                'Organization': {
                    'StringValue': job_metadata['organization'],
                    'DataType': 'String'
                },
                'Project': {
                    'StringValue': job_metadata['project'],
                    'DataType': 'String'
                },
                'Namespace': {
                    'StringValue': job_metadata['namespace'],
                    'DataType': 'String'
                }
            }
            
            # Send message to SQS
            response = self.sqs.send_message(
                QueueUrl=self.queue_url,
                MessageBody=message_body,
                MessageAttributes=message_attributes
            )
            
            # Record success
            jobs_sent_counter.labels(
                priority=priority,
                organization=job_metadata['organization'],
                project=job_metadata['project']
            ).inc()
            
            # Record response time
            response_time = (time.time() - start_time) * 1000
            self.environment.events.request.fire(
                request_type="SQS",
                name=f"submit_{priority}_priority_job",
                response_time=response_time,
                response_length=len(message_body),
                exception=None,
                context={}
            )
            
            print(f"Successfully submitted {priority} priority job {job_metadata['job_id']} to SQS")
            
        except Exception as e:
            # Record failure
            jobs_failed_counter.labels(
                priority=priority,
                organization=job_metadata.get('organization', 'unknown'),
                project=job_metadata.get('project', 'unknown')
            ).inc()
            
            response_time = (time.time() - start_time) * 1000
            self.environment.events.request.fire(
                request_type="SQS",
                name=f"submit_{priority}_priority_job",
                response_time=response_time,
                response_length=0,
                exception=e,
                context={}
            )
            
            print(f"Failed to submit {priority} priority job to SQS: {e}")
    
    @task(weight=1)
    def check_queue_status(self):
        """Check SQS queue status (optional monitoring task)"""
        start_time = time.time()
        
        try:
            response = self.sqs.get_queue_attributes(
                QueueUrl=self.queue_url,
                AttributeNames=['ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible']
            )
            
            visible_messages = int(response['Attributes'].get('ApproximateNumberOfMessages', 0))
            invisible_messages = int(response['Attributes'].get('ApproximateNumberOfMessagesNotVisible', 0))
            
            response_time = (time.time() - start_time) * 1000
            self.environment.events.request.fire(
                request_type="SQS",
                name="check_queue_status",
                response_time=response_time,
                response_length=len(str(response)),
                exception=None,
                context={}
            )
            
            print(f"Queue status - Visible: {visible_messages}, Processing: {invisible_messages}")
            
        except Exception as e:
            response_time = (time.time() - start_time) * 1000
            self.environment.events.request.fire(
                request_type="SQS",
                name="check_queue_status",
                response_time=response_time,
                response_length=0,
                exception=e,
                context={}
            )
            
            print(f"Failed to check queue status: {e}")

@events.init.add_listener
def on_locust_init(environment, **kwargs):
    """Initialize Prometheus metrics server"""
    if environment.parsed_options.master:
        start_http_server(8089)
        print("Prometheus metrics server started on port 8089")

if __name__ == "__main__":
    import sys
    print("This is the SQS-based Locust file for Spark job load testing")
    print("Usage: locust -f sqs_locustfile.py --sqs-queue-url <queue-url> [other options]")
