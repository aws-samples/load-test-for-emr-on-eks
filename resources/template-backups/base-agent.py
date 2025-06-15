#!/usr/bin/env python3

"""
Base Agent for LLM-powered Spark Job Management System

This module provides the foundational functionality for all AI agents
in the system, including Redis communication, Kubernetes API access,
AWS service integration, and LLM interaction capabilities.

Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
SPDX-License-Identifier: MIT-0
"""

import os
import sys
import time
import json
import redis
import logging
import structlog
from datetime import datetime, timezone
from typing import Dict, Any, Optional, List
from kubernetes import client, config
import boto3
from botocore.exceptions import ClientError, BotoCoreError


class BaseAgent:
    """
    Base class for all AI agents in the system.
    
    Provides common functionality including:
    - Redis communication for inter-agent messaging
    - Kubernetes API access for cluster monitoring
    - AWS service integration (SQS, Bedrock, CloudWatch)
    - Structured logging
    - Health check endpoints
    - LLM interaction capabilities
    """
    
    def __init__(self, agent_type: str):
        """
        Initialize the base agent.
        
        Args:
            agent_type: Type of agent (metrics, logs, master, scheduler)
        """
        self.agent_type = agent_type
        self.start_time = datetime.now(timezone.utc)
        
        # Configure structured logging
        structlog.configure(
            processors=[
                structlog.stdlib.filter_by_level,
                structlog.stdlib.add_logger_name,
                structlog.stdlib.add_log_level,
                structlog.stdlib.PositionalArgumentsFormatter(),
                structlog.processors.TimeStamper(fmt="iso"),
                structlog.processors.StackInfoRenderer(),
                structlog.processors.format_exc_info,
                structlog.processors.UnicodeDecoder(),
                structlog.processors.JSONRenderer()
            ],
            context_class=dict,
            logger_factory=structlog.stdlib.LoggerFactory(),
            wrapper_class=structlog.stdlib.BoundLogger,
            cache_logger_on_first_use=True,
        )
        
        self.logger = structlog.get_logger().bind(agent_type=agent_type)
        
        # Initialize connections
        self._init_redis()
        self._init_kubernetes()
        self._init_aws_clients()
        
        self.logger.info("Agent initialized successfully")
    
    def _init_redis(self):
        """Initialize Redis connection for inter-agent communication."""
        try:
            redis_host = os.getenv('REDIS_HOST', 'redis-agents')
            redis_port = int(os.getenv('REDIS_PORT', '6379'))
            
            self.redis_client = redis.Redis(
                host=redis_host,
                port=redis_port,
                decode_responses=True,
                socket_connect_timeout=5,
                socket_timeout=5,
                retry_on_timeout=True
            )
            
            # Test connection
            self.redis_client.ping()
            self.logger.info("Redis connection established", host=redis_host, port=redis_port)
            
        except Exception as e:
            self.logger.error("Failed to initialize Redis connection", error=str(e))
            raise
    
    def _init_kubernetes(self):
        """Initialize Kubernetes API client."""
        try:
            # Load in-cluster config
            config.load_incluster_config()
            
            self.k8s_core_v1 = client.CoreV1Api()
            self.k8s_apps_v1 = client.AppsV1Api()
            self.k8s_custom = client.CustomObjectsApi()
            
            # Test connection
            version = self.k8s_core_v1.get_api_resources()
            self.logger.info("Kubernetes connection established")
            
        except Exception as e:
            self.logger.error("Failed to initialize Kubernetes client", error=str(e))
            raise
    
    def _init_aws_clients(self):
        """Initialize AWS service clients."""
        try:
            self.aws_region = os.getenv('AWS_REGION', 'us-west-2')
            
            # Initialize AWS clients
            self.sqs_client = boto3.client('sqs', region_name=self.aws_region)
            self.bedrock_client = boto3.client('bedrock-runtime', region_name=self.aws_region)
            self.cloudwatch_client = boto3.client('cloudwatch', region_name=self.aws_region)
            
            self.logger.info("AWS clients initialized", region=self.aws_region)
            
        except Exception as e:
            self.logger.error("Failed to initialize AWS clients", error=str(e))
            raise
    
    def share_data(self, key: str, data: Any, ttl: int = 300):
        """
        Share data with other agents via Redis.
        
        Args:
            key: Redis key for the data
            data: Data to share (will be JSON serialized)
            ttl: Time to live in seconds
        """
        try:
            redis_key = f"{self.agent_type}:{key}"
            serialized_data = json.dumps(data, default=str)
            
            self.redis_client.setex(redis_key, ttl, serialized_data)
            self.logger.debug("Data shared via Redis", key=redis_key, ttl=ttl)
            
        except Exception as e:
            self.logger.error("Failed to share data via Redis", key=key, error=str(e))
    
    def get_shared_data(self, agent_type: str, key: str) -> Optional[Any]:
        """
        Get data shared by another agent.
        
        Args:
            agent_type: Type of agent that shared the data
            key: Redis key for the data
            
        Returns:
            Deserialized data or None if not found
        """
        try:
            redis_key = f"{agent_type}:{key}"
            data = self.redis_client.get(redis_key)
            
            if data:
                return json.loads(data)
            return None
            
        except Exception as e:
            self.logger.error("Failed to get shared data", key=key, error=str(e))
            return None
    
    def call_llm(self, prompt: str, model_id: str = None) -> Optional[str]:
        """
        Call LLM (Bedrock Claude) for intelligent decision making.
        
        Args:
            prompt: The prompt to send to the LLM
            model_id: Bedrock model ID (defaults to Claude 3.5 Sonnet)
            
        Returns:
            LLM response text or None if failed
        """
        try:
            if model_id is None:
                model_id = os.getenv('BEDROCK_MODEL_ID', 'anthropic.claude-3-5-sonnet-20241022-v2:0')
            
            # Prepare the request
            request_body = {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 4000,
                "messages": [
                    {
                        "role": "user",
                        "content": prompt
                    }
                ]
            }
            
            # Call Bedrock
            response = self.bedrock_client.invoke_model(
                modelId=model_id,
                body=json.dumps(request_body),
                contentType='application/json'
            )
            
            # Parse response
            response_body = json.loads(response['body'].read())
            
            if 'content' in response_body and len(response_body['content']) > 0:
                return response_body['content'][0]['text']
            
            self.logger.warning("Empty response from LLM")
            return None
            
        except Exception as e:
            self.logger.error("Failed to call LLM", error=str(e), model_id=model_id)
            return None
    
    def get_cluster_info(self) -> Dict[str, Any]:
        """Get basic cluster information."""
        try:
            nodes = self.k8s_core_v1.list_node()
            pods = self.k8s_core_v1.list_pod_for_all_namespaces()
            
            return {
                'node_count': len(nodes.items),
                'pod_count': len(pods.items),
                'ready_nodes': len([n for n in nodes.items if 
                                  any(c.type == 'Ready' and c.status == 'True' 
                                      for c in n.status.conditions)]),
                'running_pods': len([p for p in pods.items if 
                                   p.status.phase == 'Running'])
            }
        except Exception as e:
            self.logger.error("Failed to get cluster info", error=str(e))
            return {}
    
    def health_check(self) -> Dict[str, Any]:
        """Perform health check and return status."""
        try:
            # Test Redis connection
            redis_healthy = self.redis_client.ping()
            
            # Test Kubernetes connection
            k8s_healthy = bool(self.k8s_core_v1.list_namespace())
            
            # Calculate uptime
            uptime = (datetime.now(timezone.utc) - self.start_time).total_seconds()
            
            return {
                'status': 'healthy' if redis_healthy and k8s_healthy else 'unhealthy',
                'agent_type': self.agent_type,
                'uptime_seconds': uptime,
                'redis_connected': redis_healthy,
                'kubernetes_connected': k8s_healthy,
                'timestamp': datetime.now(timezone.utc).isoformat()
            }
            
        except Exception as e:
            self.logger.error("Health check failed", error=str(e))
            return {
                'status': 'unhealthy',
                'agent_type': self.agent_type,
                'error': str(e),
                'timestamp': datetime.now(timezone.utc).isoformat()
            }
    
    def run_cycle(self) -> bool:
        """
        Run one cycle of the agent's main logic.
        
        This method should be overridden by subclasses.
        
        Returns:
            True if cycle completed successfully, False otherwise
        """
        raise NotImplementedError("Subclasses must implement run_cycle()")
    
    def start(self):
        """Start the agent's main loop."""
        self.logger.info("Starting agent main loop")
        
        cycle_interval = int(os.getenv('AGENT_CYCLE_INTERVAL', '30'))
        
        while True:
            try:
                cycle_start = time.time()
                
                # Run agent cycle
                success = self.run_cycle()
                
                cycle_duration = time.time() - cycle_start
                
                if success:
                    self.logger.info("Agent cycle completed", 
                                   duration_seconds=round(cycle_duration, 2))
                else:
                    self.logger.warning("Agent cycle failed", 
                                      duration_seconds=round(cycle_duration, 2))
                
                # Update health status
                health = self.health_check()
                self.share_data("health_status", health, ttl=120)
                
                # Sleep until next cycle
                sleep_time = max(0, cycle_interval - cycle_duration)
                if sleep_time > 0:
                    time.sleep(sleep_time)
                    
            except KeyboardInterrupt:
                self.logger.info("Agent stopped by user")
                break
            except Exception as e:
                self.logger.error("Unexpected error in agent main loop", 
                                error=str(e), exc_info=True)
                time.sleep(cycle_interval)


if __name__ == "__main__":
    # This is a base class, so just run a simple test
    agent = BaseAgent("test")
    print("Base agent initialized successfully")
    print("Health check:", agent.health_check())
