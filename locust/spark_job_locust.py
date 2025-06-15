#!/usr/bin/env python3

"""
Enhanced Locust Load Testing for LLM-Powered Spark Job Management System

This script simulates realistic job submission patterns with rich metadata including:
- Organizations (org-a, org-b, org-c)
- Projects (project-alpha, project-beta, project-gamma)
- Priorities (high, medium, low)
- Job types (data-processing, ml-training, etl, analytics)
- Customer tiers (premium, standard, basic)
"""

import json
import random
import time
from datetime import datetime, timezone
from locust import HttpUser, task, between
import boto3
import os
from botocore.exceptions import ClientError

class SparkJobSubmitter(HttpUser):
    wait_time = between(5, 15)  # Wait 5-15 seconds between job submissions
    
    def on_start(self):
        """Initialize AWS SQS client and job metadata"""
        self.aws_region = os.getenv('AWS_REGION', 'us-west-2')
        self.load_test_prefix = os.getenv('LOAD_TEST_PREFIX', 'eks-load-test-e543')
        
        # Initialize SQS client
        try:
            self.sqs_client = boto3.client('sqs', region_name=self.aws_region)
            print(f"✅ SQS client initialized for region: {self.aws_region}")
        except Exception as e:
            print(f"❌ Failed to initialize SQS client: {e}")
            return
        
        # Get queue URLs
        self.queues = {
            'high': self._get_queue_url(f'{self.load_test_prefix}-spark-jobs-high.fifo'),
            'medium': self._get_queue_url(f'{self.load_test_prefix}-spark-jobs-medium.fifo'),
            'low': self._get_queue_url(f'{self.load_test_prefix}-spark-jobs-low.fifo')
        }
        
        # Job metadata templates
        self.organizations = [
            {'id': 'org-a', 'name': 'DataCorp Analytics', 'tier': 'premium'},
            {'id': 'org-b', 'name': 'TechStart Solutions', 'tier': 'standard'},
            {'id': 'org-c', 'name': 'Research Institute', 'tier': 'basic'},
            {'id': 'org-d', 'name': 'Financial Services', 'tier': 'premium'},
            {'id': 'org-e', 'name': 'Healthcare Systems', 'tier': 'standard'}
        ]
        
        self.projects = [
            {'id': 'project-alpha', 'type': 'data-processing', 'complexity': 'high'},
            {'id': 'project-beta', 'type': 'ml-training', 'complexity': 'medium'},
            {'id': 'project-gamma', 'type': 'etl-pipeline', 'complexity': 'low'},
            {'id': 'project-delta', 'type': 'analytics', 'complexity': 'medium'},
            {'id': 'project-epsilon', 'type': 'reporting', 'complexity': 'low'},
            {'id': 'project-zeta', 'type': 'real-time-processing', 'complexity': 'high'}
        ]
        
        self.job_types = {
            'data-processing': {
                'main_class': 'org.apache.spark.examples.SparkPi',
                'args': ['1000'],
                'resources': {'driver_memory': '2g', 'executor_memory': '4g', 'executor_instances': 4}
            },
            'ml-training': {
                'main_class': 'org.apache.spark.examples.SparkPi',
                'args': ['500'],
                'resources': {'driver_memory': '4g', 'executor_memory': '8g', 'executor_instances': 8}
            },
            'etl-pipeline': {
                'main_class': 'org.apache.spark.examples.SparkPi',
                'args': ['100'],
                'resources': {'driver_memory': '1g', 'executor_memory': '2g', 'executor_instances': 2}
            },
            'analytics': {
                'main_class': 'org.apache.spark.examples.SparkPi',
                'args': ['200'],
                'resources': {'driver_memory': '2g', 'executor_memory': '4g', 'executor_instances': 3}
            },
            'reporting': {
                'main_class': 'org.apache.spark.examples.SparkPi',
                'args': ['50'],
                'resources': {'driver_memory': '512m', 'executor_memory': '1g', 'executor_instances': 1}
            },
            'real-time-processing': {
                'main_class': 'org.apache.spark.examples.SparkPi',
                'args': ['2000'],
                'resources': {'driver_memory': '4g', 'executor_memory': '6g', 'executor_instances': 6}
            }
        }
        
        print("✅ Spark Job Submitter initialized with rich metadata support")
    
    def _get_queue_url(self, queue_name):
        """Get SQS queue URL"""
        try:
            response = self.sqs_client.get_queue_url(QueueName=queue_name)
            return response['QueueUrl']
        except Exception as e:
            print(f"❌ Failed to get queue URL for {queue_name}: {e}")
            return None
    
    def _generate_job_metadata(self):
        """Generate realistic job metadata"""
        org = random.choice(self.organizations)
        project = random.choice(self.projects)
        
        # Priority distribution: 20% high, 50% medium, 30% low
        priority_weights = [('high', 0.2), ('medium', 0.5), ('low', 0.3)]
        priority = random.choices([p[0] for p in priority_weights], 
                                weights=[p[1] for p in priority_weights])[0]
        
        # Job type based on project
        job_type = project['type']
        job_config = self.job_types[job_type]
        
        # Generate unique job ID with metadata
        timestamp = int(time.time())
        job_id = f"{org['id']}-{project['id']}-{priority}-{timestamp}"
        
        return {
            'job_id': job_id,
            'priority': priority,
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'organization': {
                'id': org['id'],
                'name': org['name'],
                'tier': org['tier']
            },
            'project': {
                'id': project['id'],
                'name': project['id'].replace('-', ' ').title(),
                'type': project['type'],
                'complexity': project['complexity']
            },
            'job_metadata': {
                'job_type': job_type,
                'environment': random.choice(['production', 'staging', 'development']),
                'region': self.aws_region,
                'cost_center': f"cc-{random.randint(1000, 9999)}",
                'department': random.choice(['engineering', 'data-science', 'analytics', 'research']),
                'tags': {
                    'team': random.choice(['team-alpha', 'team-beta', 'team-gamma']),
                    'version': f"v{random.randint(1, 5)}.{random.randint(0, 9)}",
                    'batch_id': f"batch-{random.randint(100, 999)}"
                }
            },
            'spark_config': {
                'driver_memory': job_config['resources']['driver_memory'],
                'executor_memory': job_config['resources']['executor_memory'],
                'executor_instances': job_config['resources']['executor_instances'],
                'driver_cores': 1,
                'executor_cores': random.choice([1, 2])
            },
            'main_class': job_config['main_class'],
            'main_application_file': 'local:///usr/lib/spark/examples/jars/spark-examples.jar',
            'job_args': job_config['args'],
            'retry_count': 3 if priority == 'high' else 2 if priority == 'medium' else 1,
            'customer_tier': org['tier']
        }
    
    @task(3)
    def submit_high_priority_job(self):
        """Submit high priority job (30% of tasks)"""
        self._submit_job_with_priority('high')
    
    @task(5)
    def submit_medium_priority_job(self):
        """Submit medium priority job (50% of tasks)"""
        self._submit_job_with_priority('medium')
    
    @task(2)
    def submit_low_priority_job(self):
        """Submit low priority job (20% of tasks)"""
        self._submit_job_with_priority('low')
    
    def _submit_job_with_priority(self, priority):
        """Submit job to specific priority queue"""
        start_time = time.time()
        
        try:
            # Generate job metadata
            job_data = self._generate_job_metadata()
            job_data['priority'] = priority  # Override with specific priority
            
            queue_url = self.queues.get(priority)
            if not queue_url:
                raise Exception(f"Queue URL not found for priority: {priority}")
            
            # Submit to SQS
            response = self.sqs_client.send_message(
                QueueUrl=queue_url,
                MessageBody=json.dumps(job_data, default=str),
                MessageGroupId=f"{job_data['organization']['id']}-{job_data['project']['id']}"
            )
            
            # Record success
            total_time = int((time.time() - start_time) * 1000)
            self.environment.events.request.fire(
                request_type="SQS",
                name=f"submit_{priority}_priority_job",
                response_time=total_time,
                response_length=len(json.dumps(job_data)),
                context={
                    'job_id': job_data['job_id'],
                    'organization': job_data['organization']['id'],
                    'project': job_data['project']['id'],
                    'priority': priority
                }
            )
            
            print(f"✅ Submitted {priority} priority job: {job_data['job_id']}")
            
        except Exception as e:
            # Record failure
            total_time = int((time.time() - start_time) * 1000)
            self.environment.events.request.fire(
                request_type="SQS",
                name=f"submit_{priority}_priority_job",
                response_time=total_time,
                response_length=0,
                exception=e
            )
            print(f"❌ Failed to submit {priority} priority job: {e}")
    
    @task(1)
    def submit_batch_jobs(self):
        """Submit a batch of jobs from the same organization (10% of tasks)"""
        start_time = time.time()
        
        try:
            # Select organization and project for batch
            org = random.choice(self.organizations)
            project = random.choice(self.projects)
            batch_size = random.randint(3, 8)
            
            batch_jobs = []
            for i in range(batch_size):
                job_data = self._generate_job_metadata()
                job_data['organization'] = org
                job_data['project'] = project
                job_data['job_metadata']['tags']['batch_id'] = f"batch-{int(time.time())}"
                job_data['job_id'] = f"{org['id']}-{project['id']}-batch-{i}-{int(time.time())}"
                
                # Submit to appropriate queue
                priority = job_data['priority']
                queue_url = self.queues.get(priority)
                
                if queue_url:
                    self.sqs_client.send_message(
                        QueueUrl=queue_url,
                        MessageBody=json.dumps(job_data, default=str),
                        MessageGroupId=f"batch-{org['id']}-{project['id']}"
                    )
                    batch_jobs.append(job_data['job_id'])
            
            # Record success
            total_time = int((time.time() - start_time) * 1000)
            self.environment.events.request.fire(
                request_type="SQS",
                name="submit_batch_jobs",
                response_time=total_time,
                response_length=len(batch_jobs),
                context={
                    'batch_size': batch_size,
                    'organization': org['id'],
                    'project': project['id']
                }
            )
            
            print(f"✅ Submitted batch of {batch_size} jobs for {org['id']}/{project['id']}")
            
        except Exception as e:
            # Record failure
            total_time = int((time.time() - start_time) * 1000)
            self.environment.events.request.fire(
                request_type="SQS",
                name="submit_batch_jobs",
                response_time=total_time,
                response_length=0,
                exception=e
            )
            print(f"❌ Failed to submit batch jobs: {e}")


if __name__ == "__main__":
    # For testing purposes
    import sys
    print("Spark Job Submitter for LLM-Powered Job Management System")
    print("Run with: locust -f spark_job_locust.py --host=http://localhost")
