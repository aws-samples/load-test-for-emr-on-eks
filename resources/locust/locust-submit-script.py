from locust import HttpUser, task, between, events
import os
import yaml
import time
import uuid
from kubernetes import client, config
from kubernetes.client.rest import ApiException
import logging
import random
import copy
import threading
from datetime import datetime
from prometheus_client import start_http_server, Counter, Gauge

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Global variables
SPARK_JOB_NS_NUM = int(os.environ.get('SPARK_JOB_NS_NUM', '2'))
exit_event = threading.Event()
last_metrics_update = time.time()
metrics_thread = None
locust_environment = None  # Store environment reference for event listeners

# Prometheus metrics - defined at module level for proper export
success_counter = Counter('locust_spark_application_submit_success_total', 'Number of successful submitted spark application')
failed_counter = Counter('locust_spark_application_submit_fail_total', 'Number of failed submitted spark application')
execution_time_gauge = Gauge('locust_spark_application_submit_gauge', 'Execution time for submitting spark application')

# EKS SparkApplication status gauges
running_spark_application_gauge = Gauge('locust_running_spark_application_gauge', 'Number of concurrent running spark application calculated from locust')
submitted_spark_application_gauge = Gauge('locust_submitted_spark_application_gauge', 'Number of submitted spark application calculated from locust')
succeeding_spark_application_gauge = Gauge('locust_succeeding_spark_application_gauge', 'Number of succeeding spark application calculated from locust')
new_spark_application_gauge = Gauge('locust_new_spark_application_gauge', 'Number of new spark application calculated from locust')
completed_spark_application_gauge = Gauge('locust_completed_spark_application_gauge', 'Number of completed spark application calculated from locust')
failed_spark_application_gauge = Gauge('locust_failed_spark_application_gauge', 'Number of failed spark application calculated from locust')

# Additional metrics
concurrent_user_gauge = Gauge('locust_concurrent_user', 'Number of concurrent locust users')
metrics_thread_heartbeat = Gauge('locust_metrics_thread_heartbeat', 'Timestamp of last metrics collection (for monitoring thread health)')

def printlog(log):
    """Print log with timestamp"""
    now = str(datetime.now())
    print(f"[{now}] {log}")

def start_metrics_thread_if_needed(environment):
    """Start metrics thread if it's not running"""
    global metrics_thread
    
    # Only on master
    if environment.runner.__class__.__name__ == "MasterRunner" or environment.runner.__class__.__name__ == "LocalRunner":
        if metrics_thread is None or not metrics_thread.is_alive():
            printlog("Starting/restarting background EKS metrics collection thread")
            exit_event.clear()
            metrics_thread = threading.Thread(target=collect_spark_application_metrics, args=(environment,))
            metrics_thread.daemon = True
            metrics_thread.start()
            return True
    return False

class SparkSubmitUser(HttpUser):
    wait_time = between(10, 30)  
    
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
    def count_locust_user(self):
        """Update concurrent user count"""
        if hasattr(self.environment, 'runner') and hasattr(self.environment.runner, 'user_count'):
            concurrent_user_gauge.set(self.environment.runner.user_count)

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
            
            # Submit the Spark job
            self.k8s_client.create_namespaced_custom_object(
                group="sparkoperator.k8s.io",
                version="v1beta2",
                namespace=target_namespace,
                plural="sparkapplications",
                body=spark_job
            )
            
            # Calculate execution time
            execution_time = time.time() - start_time
            request_time = int(execution_time * 1000)
            
            # Direct counter increment on worker (for worker metrics export)
            success_counter.inc()
            execution_time_gauge.set(execution_time)
            
            # Fire Locust request event for correlation
            self.environment.events.request.fire(
                request_type="SparkSubmit",
                name=f"Submission to {target_namespace}: {job_name}",
                response_time=request_time,
                response_length=0,
                exception=None,
            )
            
            logger.info(f"Successfully submitted job {job_name} to namespace {target_namespace}")
            printlog(f"Sparkapplication created successfully with name: {job_name} in namespace {target_namespace}")
            
        except ApiException as e:
            # Calculate execution time for failed request
            execution_time = time.time() - start_time if 'start_time' in locals() else 0
            request_time = int(execution_time * 1000)
            
            # Direct counter increment on worker (for worker metrics export)
            failed_counter.inc()
            
            try:
                self.environment.events.request.fire(
                    request_type="SparkSubmit",
                    name=f"Submission to {target_namespace}: {job_name}",
                    response_time=request_time,
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
            printlog(f"Exception when creating SparkApplication: {e}")

def collect_spark_application_metrics(environment):
    """Background thread to collect real-time Spark application metrics from EKS"""
    # Initialize Kubernetes client for background thread
    try:
        config.load_incluster_config()
        printlog("Background metrics thread: Successfully loaded in-cluster Kubernetes configuration")
    except Exception as e:
        printlog(f"Background metrics thread: Failed to load in-cluster config: {str(e)}, trying kubeconfig")
        try:
            config.load_kube_config()
            printlog("Background metrics thread: Loaded kubeconfig from default location")
        except Exception as e2:
            printlog(f"Background metrics thread: Failed to load any Kubernetes configuration: {str(e2)}")
            return
    
    api_instance = client.CustomObjectsApi()
    
    next_time = time.time() + 30
    iteration_count = 0
    consecutive_errors = 0
    max_consecutive_errors = 5
    
    printlog("Background metrics thread: Starting main collection loop")
    
    while True: 
        try:
            if exit_event.is_set():
                printlog("Background metrics thread: Exit event received, stopping")
                break
                
            current_time = time.time()
            if current_time > next_time:
                iteration_count += 1
                printlog(f"Collecting real-time Spark application metrics from EKS (iteration {iteration_count})")
                
                # Initialize counters for current state
                new_count = 0
                submitted_count = 0
                succeeding_count = 0
                running_count = 0
                completed_count = 0
                failed_count = 0
                total_apps_found = 0
                
                try:
                    printlog(f"Checking {SPARK_JOB_NS_NUM} namespaces for SparkApplications")
                    
                    # Collect metrics from all Spark job namespaces
                    for index in range(0, SPARK_JOB_NS_NUM):
                        spark_ns = f"spark-job{index}"
                        try:
                            printlog(f"Querying namespace: {spark_ns}")
                            spark_apps = api_instance.list_namespaced_custom_object(
                                group="sparkoperator.k8s.io",
                                version="v1beta2",
                                namespace=spark_ns,
                                plural="sparkapplications"
                            )
                            
                            apps_in_ns = len(spark_apps.get('items', []))
                            total_apps_found += apps_in_ns
                            printlog(f"Found {apps_in_ns} applications in namespace {spark_ns}")
                            
                            for app in spark_apps.get('items', []):
                                app_name = app.get('metadata', {}).get('name', 'unknown')
                                
                                if 'status' in app and 'applicationState' in app['status']:
                                    app_state = app['status']['applicationState']['state']
                                    printlog(f"App {app_name}: {app_state}")
                                    
                                    if app_state == 'NEW':
                                        new_count += 1
                                    elif app_state == 'SUBMITTED':
                                        submitted_count += 1
                                    elif app_state == 'SUCCEEDING':
                                        succeeding_count += 1
                                    elif app_state == 'RUNNING':
                                        running_count += 1
                                    elif app_state == 'COMPLETED':
                                        completed_count += 1
                                    elif app_state == 'FAILED':
                                        failed_count += 1
                                    else:
                                        # Handle any other states as NEW
                                        printlog(f"Unknown application state: {app_state}, treating as NEW")
                                        new_count += 1
                                else:
                                    # Applications without status are considered NEW
                                    printlog(f"App {app_name}: No status, treating as NEW")
                                    new_count += 1
                                    
                        except Exception as e:
                            printlog(f"Error collecting metrics from namespace {spark_ns}: {e}")
                            continue

                    # Update EKS status gauges (master only)
                    new_spark_application_gauge.set(new_count)
                    submitted_spark_application_gauge.set(submitted_count)
                    succeeding_spark_application_gauge.set(succeeding_count)
                    running_spark_application_gauge.set(running_count)
                    completed_spark_application_gauge.set(completed_count)
                    failed_spark_application_gauge.set(failed_count)

                    # Update last metrics update time
                    global last_metrics_update
                    last_metrics_update = time.time()
                    metrics_thread_heartbeat.set(last_metrics_update)

                    total_current_apps = new_count + submitted_count + succeeding_count + running_count + completed_count + failed_count
                    printlog(f"EKS Metrics updated - NEW: {new_count}, SUBMITTED: {submitted_count}, SUCCEEDING: {succeeding_count}, RUNNING: {running_count}, COMPLETED: {completed_count}, FAILED: {failed_count}, TOTAL: {total_current_apps}")
                    
                    # Reset error counter on successful collection
                    consecutive_errors = 0

                except Exception as e:
                    consecutive_errors += 1
                    printlog(f"Error in EKS metrics collection (iteration {iteration_count}, error #{consecutive_errors}): {e}")
                    
                    if consecutive_errors >= max_consecutive_errors:
                        printlog(f"Too many consecutive errors ({consecutive_errors}), thread will exit")
                        break
                    
                    import traceback
                    printlog(f"Full traceback: {traceback.format_exc()}")

                next_time = current_time + 30
            
            time.sleep(1)
            
        except Exception as e:
            printlog(f"Unexpected error in metrics thread main loop: {e}")
            consecutive_errors += 1
            if consecutive_errors >= max_consecutive_errors:
                printlog(f"Too many consecutive errors in main loop, thread will exit")
                break
            time.sleep(5)  # Wait a bit before retrying
    
    printlog("Background metrics thread: Exiting")

@events.test_start.add_listener
def on_test_start(environment, **kwargs):
    """Start background metrics collection thread when test starts"""
    printlog("Test started - ensuring background EKS metrics collection thread is running")
    start_metrics_thread_if_needed(environment)

@events.test_stop.add_listener
def on_test_stop(environment, **kwargs):
    """Stop background metrics collection thread when test stops"""
    printlog("Test stopped - keeping background EKS metrics collection thread running")
    # Don't set exit_event here - let the thread continue running
    # This way metrics collection continues even between tests

@events.quitting.add_listener
def on_locust_quit(environment, **kwargs):
    """Stop background metrics collection thread when Locust is quitting"""
    printlog("Locust is quitting - stopping background EKS metrics collection thread")
    exit_event.set()

@events.request.add_listener
def on_spark_request_event(request_type, name, response_time, response_length, exception, **kwargs):
    """Track SparkSubmit requests on master for Prometheus metrics and debugging"""
    # Only process events on master node where Prometheus server runs
    global locust_environment
    if locust_environment and hasattr(locust_environment, 'runner'):
        runner_class = locust_environment.runner.__class__.__name__
        if runner_class not in ["MasterRunner", "LocalRunner"]:
            return  # Skip processing on worker nodes
    
    if request_type == "SparkSubmit":
        if exception is None:
            # SUCCESS - increment success counter and update execution time
            success_counter.inc()  # ✅ Master increment, visible to Prometheus
            execution_time_gauge.set(response_time / 1000.0)  # Convert ms to seconds
            printlog(f"✅ [MASTER] Spark job submission successful: {name} - {response_time}ms")
            printlog(f"📊 [MASTER] Success counter incremented to: {success_counter._value._value}")
        else:
            # FAILURE - increment failure counter
            failed_counter.inc()  # ✅ Master increment, visible to Prometheus
            printlog(f"❌ [MASTER] Spark job submission failed: {name} - {exception}")
            printlog(f"📊 [MASTER] Failure counter incremented to: {failed_counter._value._value}")

@events.init.add_listener
def on_locust_init(environment, **kwargs):
    """Initialize Prometheus metrics server and start background thread"""
    global locust_environment
    locust_environment = environment  # Store environment reference for event listeners
    
    printlog("Initializing Locust load test environment")
    printlog(f"Using SPARK_JOB_NS_NUM: {SPARK_JOB_NS_NUM}")
    
    # Determine node type
    runner_class = environment.runner.__class__.__name__
    
    if runner_class == "MasterRunner" or runner_class == "LocalRunner":
        # MASTER NODE - Handle EKS monitoring and master metrics
        printlog("🎯 [MASTER] Initializing master node")
        
        # Start Prometheus metrics server on master
        start_http_server(8000)
        printlog("🚀 [MASTER] Prometheus metrics server started on port 8000")
        printlog("📊 [MASTER] Available EKS SparkApplication metrics:")
        printlog("   - locust_running_spark_application_gauge: Current RUNNING applications in EKS")
        printlog("   - locust_submitted_spark_application_gauge: Current SUBMITTED applications in EKS")
        printlog("   - locust_succeeding_spark_application_gauge: Current SUCCEEDING applications in EKS")
        printlog("   - locust_new_spark_application_gauge: Current NEW applications in EKS")
        printlog("   - locust_completed_spark_application_gauge: Current COMPLETED applications in EKS")
        printlog("   - locust_failed_spark_application_gauge: Current FAILED applications in EKS")
        printlog("   - locust_concurrent_user: Number of concurrent Locust users")
        
        # Start background EKS monitoring thread
        printlog("🔄 [MASTER] Starting background EKS metrics collection thread")
        start_metrics_thread_if_needed(environment)
        
    elif runner_class == "WorkerRunner":
        # WORKER NODE - Handle submission metrics
        printlog("🎯 [WORKER] Initializing worker node")
        
        # Start Prometheus metrics server on worker (different port)
        worker_port = 8001
        start_http_server(worker_port)
        printlog(f"🚀 [WORKER] Prometheus metrics server started on port {worker_port}")
        printlog("📈 [WORKER] Available submission metrics:")
        printlog("   - locust_spark_application_submit_success_total: Successful submissions from this worker")
        printlog("   - locust_spark_application_submit_fail_total: Failed submissions from this worker")
        printlog("   - locust_spark_application_submit_gauge: Execution time for submissions from this worker")
        
    else:
        printlog(f"Unknown runner type: {runner_class}")
    
    printlog(f"✅ Locust initialization complete for {runner_class}")
