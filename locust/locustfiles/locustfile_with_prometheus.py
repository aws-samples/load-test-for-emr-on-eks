
import sys, time, json, subprocess, random, threading
from os import environ, path
from datetime import datetime, timedelta

from locust import User, task, between, events
from prometheus_client import start_http_server, Counter, Gauge, Histogram, Summary, Info
from lib.virtual_cluster import virtual_cluster
from lib.shared import test_instance, setup_unique_user_id

# Global variables and events
exit_event = threading.Event()
test_start_time = time.perf_counter()
virtual_clusters = {}  # Store namespace -> virtual_cluster_id mapping
unique_id = f"{test_instance.id}"
ns_prefix = f"{unique_id}-ns"
metrics_port = int(environ.get("METRICS_PORT", "8000"))

EKS_CLUSTER_NAME = environ["CLUSTER_NAME"]
REGION = environ["AWS_REGION"]

# ==============================================================================
# Enhanced Prometheus Metrics with locust_* prefix
# ==============================================================================

# Job submission metrics
locust_spark_submit_total = Counter(
    'locust_spark_submit_total',
    'Total number of Spark job submissions attempted',
    ['status', 'namespace']
)

locust_spark_submit_success_total = Counter(
    'locust_spark_submit_success_total',
    'Total number of successful Spark job submissions'
)

locust_spark_submit_failed_total = Counter(
    'locust_spark_submit_failed_total',
    'Total number of failed Spark job submissions',
    ['error_type']
)

locust_spark_submit_duration_seconds = Histogram(
    'locust_spark_submit_duration_seconds',
    'Time taken for Spark job submission in seconds',
    ['namespace'],
    buckets=[0.5, 1, 2, 5, 10, 30, 60, 120, 300]
)

locust_spark_submit_duration_summary = Summary(
    'locust_spark_submit_duration_summary_seconds',
    'Summary of Spark job submission duration'
)

# Job state metrics (Gauges for current counts)
locust_spark_jobs_running = Gauge(
    'locust_spark_jobs_running',
    'Number of currently running Spark jobs'
)

locust_spark_jobs_submitted = Gauge(
    'locust_spark_jobs_submitted',
    'Number of submitted Spark jobs'
)

locust_spark_jobs_pending = Gauge(
    'locust_spark_jobs_pending',
    'Number of pending Spark jobs'
)

locust_spark_jobs_succeeding = Gauge(
    'locust_spark_jobs_succeeding',
    'Number of succeeding Spark jobs'
)

locust_spark_jobs_new = Gauge(
    'locust_spark_jobs_new',
    'Number of new Spark jobs'
)

locust_spark_jobs_completed = Gauge(
    'locust_spark_jobs_completed',
    'Number of completed Spark jobs'
)

locust_spark_jobs_failed = Gauge(
    'locust_spark_jobs_failed',
    'Number of failed Spark jobs'
)

locust_spark_jobs_cancelled = Gauge(
    'locust_spark_jobs_cancelled',
    'Number of cancelled Spark jobs'
)

# Locust user metrics
locust_users_active = Gauge(
    'locust_users_active',
    'Number of active Locust users'
)

locust_users_spawned_total = Counter(
    'locust_users_spawned_total',
    'Total number of users spawned'
)

# Virtual cluster metrics
locust_virtual_clusters_total = Gauge(
    'locust_virtual_clusters_total',
    'Total number of EMR virtual clusters created'
)

locust_virtual_clusters_active = Gauge(
    'locust_virtual_clusters_active',
    'Number of active EMR virtual clusters'
)

# Test session info
locust_test_info = Info(
    'locust_test',
    'Information about the current Locust test session'
)

# Test uptime
locust_test_uptime_seconds = Gauge(
    'locust_test_uptime_seconds',
    'Uptime of the test session in seconds'
)

# Jobs per namespace
locust_jobs_per_namespace = Gauge(
    'locust_jobs_per_namespace',
    'Number of jobs submitted per namespace',
    ['namespace']
)

# Test session metrics
locust_test_start_timestamp = Gauge(
    'locust_test_start_timestamp',
    'Unix timestamp when the test started'
)

# Request rate metrics
locust_request_rate = Gauge(
    'locust_request_rate',
    'Current request rate (requests per second)'
)

# ==============================================================================
# Backward compatibility - keep original metric names
# ==============================================================================
success_counter = locust_spark_submit_success_total
failed_emr_jobs_gauge = Gauge('locust_spark_application_submit_fail_total', 'Number of failed EMR job submissions')
execution_time_gauge = Gauge('locust_spark_application_submit_gauge', 'Execution time for EMR job submission')
running_emr_jobs_gauge = locust_spark_jobs_running
submitted_emr_jobs_gauge = locust_spark_jobs_submitted
pending_emr_jobs_gauge = locust_spark_jobs_pending
new_spark_application_gauge = locust_spark_jobs_new
completed_emr_jobs_gauge = locust_spark_jobs_completed
concurrent_user_gauge = locust_users_active
virtual_clusters_gauge = locust_virtual_clusters_total

@events.init_command_line_parser.add_listener
def on_locust_init(parser):
    JOB_SHELL_SCRIPT = environ["JOB_SCRIPT_NAME"]
    NAMESPACE_COUNT = int(environ.get("SPARK_JOB_NS_NUM", "2"))
    parser.add_argument("--emr-script-name", type=str, default=JOB_SHELL_SCRIPT, help="EMR on EKS job submission shell script file name and path")
    parser.add_argument("--job-ns-count", type=int, default=NAMESPACE_COUNT, help="Number of job namespaces or EMR Virtual Cluster")
    parser.add_argument("--job-azs", type=json.loads, default=None, help="List of AZs for task allocation")

def printlog(log):
    now = str(datetime.now())
    print(f"[{now}] {log}")

class EMRJobUser(User):
    # Submission delay in sec per virtual cluster
    wait_time = between(20, 30)

    def __init__(self, environment):
        super().__init__(environment)
        self.user_id = setup_unique_user_id()
        self.job_script = environment.parsed_options.emr_script_name
        self.ns_count = environment.parsed_options.job_ns_count
        self.job_azs = environment.parsed_options.job_azs
        self.total_jobs_submitted = 0
        # Track per-user metrics
        locust_users_spawned_total.inc()

    @events.test_start.add_listener
    def on_test_start(environment, **kwargs):
        printlog(f"Start the load test against EKS Cluster {EKS_CLUSTER_NAME} in region {REGION} with {environment.parsed_options.job_ns_count} namespaces per Locust worker ........")
        printlog(f"Wait time is set between 20-30 seconds")
        printlog(f"EMR on EKS job submission script is set to {environment.parsed_options.emr_script_name}")
        printlog(f"Prometheus metrics server starting on port {metrics_port}")

        # Set test info
        locust_test_info.info({
            'test_id': unique_id,
            'cluster_name': EKS_CLUSTER_NAME,
            'region': REGION,
            'namespace_prefix': ns_prefix
        })
        locust_test_start_timestamp.set(test_start_time)

        printlog("Starting EMR job monitoring thread")
        thread = threading.Thread(target=count_emr_jobs)
        thread.start()

        # Start metrics update thread
        metrics_thread = threading.Thread(target=update_test_metrics)
        metrics_thread.start()

    @events.test_stop.add_listener
    def on_test_stop(environment, **kwargs):
        printlog(f"Test [green]{unique_id}[/green] has stopped ramping up. Jobs are still running")
        printlog(f"To stop jobs in a test session: python locust/locustfiles/stop_test.py --id {unique_id}")
        printlog(f"Or simply stop all jobs on the EKS cluster: python locust/locustfiles/stop_test.py")
        exit_event.set()

    @task
    def count_locust_user(self):
        user_count = self.environment.runner.user_manager.user_count
        locust_users_active.set(user_count)
        concurrent_user_gauge.set(user_count)

    @task
    def submit_emr_job(self):
        printlog(f"Submitting EMR on EKS job for the test session {unique_id} by user {self.user_id}")
        # Randomly pick up a namespace to submit the job
        index = random.randint(1, self.ns_count)
        namespace = f"{ns_prefix}{index}"

        if namespace not in virtual_clusters:
            printlog(f"No virtual cluster found in the namespace {namespace}")
            locust_spark_submit_total.labels(status='error', namespace=namespace).inc()
            return

        virtual_cluster_id = virtual_clusters[namespace]
        job_unique_id = setup_unique_user_id()
        selected_az = random.choice(self.job_azs) if self.job_azs else None
        start_time = time.time()
        error_type = None

        try:
            # Build script path and validate
            script_path = path.join(path.dirname(__file__), self.job_script)
            if not path.exists(script_path):
                error_type = 'script_not_found'
                printlog(f"ERROR: Script not found at {script_path}")
                locust_spark_submit_failed_total.labels(error_type=error_type).inc()
                locust_spark_submit_total.labels(status='failed', namespace=namespace).inc()
                return

            # Execute EMR job script with environment variables
            env = environ.copy()
            env.update({
                'CLUSTER_NAME': EKS_CLUSTER_NAME,
                'VIRTUAL_CLUSTER_ID': virtual_cluster_id,
                'AWS_REGION': REGION,
                'JOB_UNIQUE_ID': job_unique_id,
                'SELECTED_AZ': selected_az
            })

            result = subprocess.run(['sh', script_path], env=env,
                capture_output=True, text=True, timeout=300)

            duration = time.time() - start_time

            if result.returncode == 0:
                success_counter.inc()
                locust_spark_submit_success_total.inc()
                locust_spark_submit_total.labels(status='success', namespace=namespace).inc()
                locust_spark_submit_duration_seconds.labels(namespace=namespace).observe(duration)
                locust_spark_submit_duration_summary.observe(duration)
                locust_jobs_per_namespace.labels(namespace=namespace).inc()

                self.total_jobs_submitted += 1
                printlog(f"EMR job {job_unique_id} is submitted successfully to VC: {virtual_cluster_id}, namespace: {namespace}")
            else:
                error_type = 'submission_failed'
                locust_spark_submit_failed_total.labels(error_type=error_type).inc()
                locust_spark_submit_total.labels(status='failed', namespace=namespace).inc()
                printlog(f"Debug info: EMR job submission failed (exit code {result.returncode}): {result.stderr}")

        except subprocess.TimeoutExpired:
            error_type = 'timeout'
            locust_spark_submit_failed_total.labels(error_type=error_type).inc()
            locust_spark_submit_total.labels(status='timeout', namespace=namespace).inc()
            printlog(f"ERROR: EMR job submission timed out for: {job_unique_id}")
        except Exception as e:
            error_type = type(e).__name__
            locust_spark_submit_failed_total.labels(error_type=error_type).inc()
            locust_spark_submit_total.labels(status='exception', namespace=namespace).inc()
            printlog(f"ERROR: Exception during EMR job submission: {type(e).__name__}: {e}")
        finally:
            execution_time_gauge.set(time.time() - start_time)
            elapsed_time = time.perf_counter() - test_start_time
            printlog(f"Submitted {self.total_jobs_submitted} jobs. Elapsed time: {str(timedelta(seconds=elapsed_time))}")

def update_test_metrics():
    """Update test uptime and other continuous metrics"""
    while not exit_event.is_set():
        uptime = time.perf_counter() - test_start_time
        locust_test_uptime_seconds.set(uptime)
        time.sleep(10)

def count_emr_jobs():
    next_time = time.time() + 60
    while True:
        if exit_event.is_set():
            break
        current_time = time.time()
        if current_time > next_time:
            printlog("Collecting EMR job metrics across all virtual clusters at 1 minute interval...")
            job_states = {
                "PENDING": 0, "SUBMITTED": 0, "RUNNING": 0,
                "COMPLETED": 0, "FAILED": 0, "NEW": 0,
                "CANCELLED": 0
            }
            try:
                list_virtual_clusters = [vc['id'] for vc in virtual_cluster.find_vcs_eks(EKS_CLUSTER_NAME, ['RUNNING'])]
                # Aggregate jobs counts across all active virtual clusters in an EKS
                for vc_id in list_virtual_clusters:
                    job_runs = virtual_cluster.list_job_runs(vc_id)
                    if len(job_runs) == 0:
                        printlog(f"EMR Jobs in test session {unique_id} - no job found yet.")
                        continue
                     # Count known states
                    for job in job_runs:
                        if job["state"] in job_states:
                            job_states[job["state"]] += 1
                        else:
                            # Unknown states go to NEW
                            job_states["NEW"] += 1

                # Update enhanced metrics
                locust_spark_jobs_running.set(job_states.get('RUNNING', 0))
                locust_spark_jobs_submitted.set(job_states.get('SUBMITTED', 0))
                locust_spark_jobs_pending.set(job_states.get('PENDING', 0))
                locust_spark_jobs_new.set(job_states.get('NEW', 0))
                locust_spark_jobs_completed.set(job_states.get('COMPLETED', 0))
                locust_spark_jobs_failed.set(job_states.get('FAILED', 0))
                locust_spark_jobs_cancelled.set(job_states.get('CANCELLED', 0))
                locust_virtual_clusters_active.set(len(list_virtual_clusters))

                # Update backward compatible metrics
                running_emr_jobs_gauge.set(job_states.get('RUNNING', 0))
                submitted_emr_jobs_gauge.set(job_states.get('SUBMITTED', 0))
                pending_emr_jobs_gauge.set(job_states.get('PENDING', 0))
                new_spark_application_gauge.set(job_states.get('NEW', 0))
                completed_emr_jobs_gauge.set(job_states.get('COMPLETED', 0))
                failed_emr_jobs_gauge.set(job_states.get('FAILED', 0))
                virtual_clusters_gauge.set(len(list_virtual_clusters))

                printlog(f"EMR Jobs in test session {unique_id} - job_states: {job_states}")

            except Exception as e:
                printlog(f"Error monitoring EMR jobs: {e}")

            next_time = current_time + 60
        time.sleep(1)

class LoadTestInitializer():
    def __init__(self, ns_count):
        printlog(f"Creating {ns_count} virtual cluster(s) for the test instance {unique_id}...")
        """Create virtual cluster and namespace mapping"""
        global virtual_clusters
        for i in range(1, ns_count + 1):
            namespace = f"{ns_prefix}{i}"
            self.virtual_cluster_name = f"{unique_id}-{EKS_CLUSTER_NAME}-{i}"
            self.vc_id = virtual_cluster.create_namespace_and_virtual_cluster(self.virtual_cluster_name, namespace, EKS_CLUSTER_NAME)
            if self.vc_id:
                virtual_clusters[namespace] = self.vc_id
                printlog(f"Virtual cluster {self.vc_id} mapped to namespace {namespace}")
            else:
                printlog(f"Failed to create virtual cluster for namespace {namespace}")

        locust_virtual_clusters_total.set(len(virtual_clusters))
        printlog(f"Created {len(virtual_clusters)} virtual clusters successfully")

@events.init.add_listener
def on_locust_init(environment, **kwargs):
    namespace_count = environment.parsed_options.job_ns_count
    hostname = environ.get('HOSTNAME', '').lower()
    if 'master' in hostname:
        printlog("EMR on EKS load test is started ...")
        printlog(f"Starting Prometheus metrics HTTP server on port {metrics_port}")
        start_http_server(metrics_port)
    else:
        LoadTestInitializer(namespace_count)
        printlog("Load test session is initializing ...")
        # Worker pods also expose metrics
        printlog(f"Starting Prometheus metrics HTTP server on port {metrics_port}")
        start_http_server(metrics_port)
