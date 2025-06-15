#!/usr/bin/env python3

"""
Main Locustfile for LLM-Powered Spark Job Management System Load Testing

This file imports and configures the enhanced Spark job submission patterns
with rich metadata support for realistic load testing scenarios.
"""

from spark_job_locust import SparkJobSubmitter

# Export the main user class for Locust
__all__ = ['SparkJobSubmitter']

# Locust will automatically discover and use SparkJobSubmitter class
