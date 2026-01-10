
import sys, time, json, subprocess, random, threading
from os import environ, path
from datetime import datetime, timedelta

from locust import User, task, between, events
from prometheus_client import start_http_server, Counter, Gauge
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
    
# Prometheus metrics
success_counter = Counter('locust_spark_application_submit_success_total', 'Number of successful EMR job submissions at Locust')
failed_counter = Counter('locust_spark_application_submit_fail_total', 'Number of failed EMR job submissions at Locust')
submission_time_gauge = Gauge('locust_spark_application_submit_time_gauge', 'Execution time for submitting spark application')
running_emr_jobs_gauge = Gauge('locust_running_spark_application_gauge', 'Number of concurrent running spark application')
submitted_emr_jobs_gauge = Gauge('locust_submitted_spark_application_gauge', 'Number of submitted EMR jobs')
pending_emr_jobs_gauge = Gauge('locust_succeeding_spark_application_gauge', 'Number of Pending spark application waiting for compute resources provisioning')
new_emr_jobs_gauge = Gauge('locust_new_spark_application_gauge', 'Number of new spark application created but not submitted yet')
completed_emr_jobs_gauge = Gauge('locust_completed_spark_application_gauge', 'Number of spark jobs completed successfully')
failed_emr_jobs_gauge = Gauge('locust_failed_spark_application_gauge', 'Number of failed EMR job submissions')
concurrent_user_gauge = Gauge('locust_concurrent_user', 'Number of concurrent locust users')

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

    @events.test_start.add_listener
    def on_test_start(environment, **kwargs):
        printlog(f"Start the load test against EKS Cluster {EKS_CLUSTER_NAME} in region {REGION} with {environment.parsed_options.job_ns_count} namespaces per Locust worker ........")
        printlog(f"Wait time is between 20-30 seconds. Reduce the interval value to scale up your test if needed.")
        printlog(f"EMR on EKS job submission script is placed to locust/locustfiles/{environment.parsed_options.emr_script_name}")
        printlog("Starting EMR job monitoring thread")
        thread = threading.Thread(target=count_emr_jobs)
        thread.start()

    @events.test_stop.add_listener
    def on_test_stop(environment, **kwargs):
        printlog(f"Test [green]{unique_id}[/green] has stopped ramping up. Jobs are still running")
        printlog(f"To stop jobs in a test session: python locust/locustfiles/stop_test.py --id {unique_id}")
        printlog(f"Or simply stop all jobs on the EKS cluster: python locust/locustfiles/stop_test.py")
        exit_event.set()

    @task
    def count_locust_user(self):
        concurrent_user_gauge.set(self.environment.runner.user_count)

    @task
    def submit_emr_job(self):
        printlog(f"Submitting EMR on EKS job for the test session {unique_id} by user {self.user_id}")
        # Randomly pick up a namespace to submit the job
        index = random.randint(1, self.ns_count)
        namespace = f"{ns_prefix}{index}"
        
        if namespace not in virtual_clusters:
            printlog(f"No virtual cluster found in the namespace {namespace}")
            return
            
        virtual_cluster_id = virtual_clusters[namespace]
        job_unique_id = setup_unique_user_id()
        selected_az = random.choice(self.job_azs) if self.job_azs else None
        start_time = time.time()
        
        try:
            # Build script path and validate
            script_path = path.join(path.dirname(__file__), self.job_script)
            if not path.exists(script_path):
                printlog(f"ERROR: Script not found at {script_path}")
                return
            
            # Execute EMR job script with environment variables
            env = environ.copy()
            env.update({
                'CLUSTER_NAME': EKS_CLUSTER_NAME,
                'VIRTUAL_CLUSTER_ID': virtual_cluster_id,
                'METRICS_PORT': str(metrics_port),
                'AWS_REGION': REGION,
                'JOB_UNIQUE_ID': job_unique_id,
                'SELECTED_AZ': selected_az
            })

            result = subprocess.run(['sh', script_path],env=env,
                capture_output=True,text=True,timeout=300)
            if result.returncode == 0:
                success_counter.inc()
                self.total_jobs_submitted += 1
                printlog(f"EMR job {job_unique_id} is submitted successfully to VC: {virtual_cluster_id}, namespace: {namespace}")
            else:
                failed_counter.inc()
                printlog(f"Debug info: EMR job submission failed (exit code {result.returncode}): {result.stderr}")   
        except subprocess.TimeoutExpired:
            failed_counter.inc()
            printlog(f"ERROR: EMR job submission timed out for: {job_unique_id}")
        except Exception as e:
            failed_counter.inc()
            printlog(f"ERROR: Exception during EMR job submission: {type(e).__name__}: {e}")
        finally:
            submission_time_gauge.set(time.time() - start_time)
            elapsed_time = time.perf_counter() - test_start_time
            printlog(f"Submitted {self.total_jobs_submitted} jobs. Elapsed time: {str(timedelta(seconds=elapsed_time))}")

def count_emr_jobs():
    next_time = time.time() + 60
    hostname = environ.get('HOSTNAME', '').lower()
    while True:
        if exit_event.is_set():
            break
        current_time = time.time()
        if current_time > next_time:
            printlog("Collecting EMR job metrics across all virtual clusters at 1 minute interval...")
            job_states = {"PENDING": 0, "SUBMITTED": 0, "RUNNING": 0, "COMPLETED": 0, "FAILED": 0, "NEW": 0}
            try:
                if 'master' in hostname:
                    # on master Locust pod, aggregate jobs counts across the entire EKS cluster
                    list_virtual_clusters = [vc['id'] for vc in virtual_cluster.find_vcs_eks(EKS_CLUSTER_NAME, ['RUNNING'])]
                else:
                    # on worker Locust pod, aggregate jobs counts per test session
                    list_virtual_clusters = [vc['id'] for vc in virtual_cluster.find_vcs(unique_id, ['RUNNING'])]
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
                # Update metrics
                running_emr_jobs_gauge.set(job_states.get('RUNNING', 0))
                submitted_emr_jobs_gauge.set(job_states.get('SUBMITTED', 0))
                pending_emr_jobs_gauge.set(job_states.get('PENDING', 0))
                new_emr_jobs_gauge.set(job_states.get('NEW', 0))
                completed_emr_jobs_gauge.set(job_states.get('COMPLETED', 0))
                failed_emr_jobs_gauge.set(job_states.get('FAILED', 0))
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
            self.vc_id = virtual_cluster.create_namespace_and_virtual_cluster(self.virtual_cluster_name,namespace,EKS_CLUSTER_NAME)
            if self.vc_id:
                virtual_clusters[namespace] = self.vc_id
                printlog(f"Virtual cluster {self.vc_id} mapped to namespace {namespace}")
            else:
                printlog(f"Failed to create virtual cluster for namespace {namespace}")
        
        printlog(f"Created {len(virtual_clusters)} virtual clusters successfully")

@events.init.add_listener
def on_locust_init(environment, **kwargs):
    namespace_count = environment.parsed_options.job_ns_count
    hostname = environ.get('HOSTNAME', '').lower()
    if 'master' in hostname:
        printlog("EMR on EKS load test is started ...")
    else:
        printlog(f"Starting Prometheus metrics HTTP server on port {metrics_port}")
        start_http_server(metrics_port)
        LoadTestInitializer(namespace_count)