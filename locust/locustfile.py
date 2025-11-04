
import time, json, subprocess, random, threading
from os import environ, path
from datetime import datetime, timedelta
environ["LOCUST_SKIP_MONKEY_PATCH"] = "1"

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

EKS_CLUSTER_NAME = environ["CLUSTER_NAME"]
REGION = environ["AWS_REGION"]

# Prometheus metrics
success_counter = Counter('locust_emr_job_submit_success', 'Number of successful EMR job submissions')
failed_counter = Counter('locust_emr_job_submit_fail', 'Number of failed EMR job submissions')
execution_time_gauge = Gauge('locust_emr_job_submit_gauge', 'Execution time for EMR job submission')
running_emr_jobs_gauge = Gauge('locust_running_emr_jobs_gauge', 'Number of concurrent running EMR jobs')
submitted_emr_jobs_gauge = Gauge('locust_submitted_emr_jobs_gauge', 'Number of submitted EMR jobs')
completed_emr_jobs_gauge = Gauge('locust_completed_emr_jobs_gauge', 'Number of completed EMR jobs')
failed_emr_jobs_gauge = Gauge('locust_failed_emr_jobs_gauge', 'Number of failed EMR jobs')
concurrent_user_gauge = Gauge('locust_concurrent_user', 'Number of concurrent locust users')
virtual_clusters_gauge = Gauge('locust_virtual_clusters_count', 'Number of EMR virtual clusters created')

@events.init_command_line_parser.add_listener
def on_locust_init(parser):
    JOB_SHELL_SCRIPT = environ["JOB_SCRIPT_NAME"]
    NAMESPACE_COUNT = int(environ.get("SPARK_JOB_NS_NUM", "2"))
    parser.add_argument("--emr-script-name", type=str, default=JOB_SHELL_SCRIPT, help="EMR on EKS job submission shell script file name and path")
    parser.add_argument("--job-ns-count", type=int, default=NAMESPACE_COUNT, help="Number of job namespaces or EMR Virtual Cluster")
    parser.add_argument("--job-azs", type=json.loads, default=None, help="List of AZs for task allocation")
    # parser.add_argument("--wait-time", type=int, default="20", help="Submission delay in sec per virtual cluster.")

def printlog(log):
    now = str(datetime.now())
    print(f"[{now}] {log}")

class EMRJobUser(User):
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
        printlog(f"Start the load test against EKS Cluster {EKS_CLUSTER_NAME} in region {REGION}........")
        printlog(f"Wait time is set between 20-30 seconds")
        printlog(f"EMR on EKS job submission script is set to [green]{environment.parsed_options.emr_script_name}")
        printlog(
            f"Monitor the test:[green on grey19]python3[/][white on grey19] python monitor.py {unique_id}[/]")
        printlog("Starting EMR job monitoring thread")
        thread = threading.Thread(target=monitor_emr_jobs, args=(environment,))
        thread.start()

    @events.test_stop.add_listener
    def on_test_stop(environment, **kwargs):
        printlog(f"Test [green]{unique_id}[/green] has stopped ramping up. Jobs are still running")
        printlog(f"To stop the test: [green on grey27]python3[/][white on grey27] python stop_test.py --id {unique_id}[/]")
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
            failed_counter.inc()
            return
            
        # emr_cluster_name = f"{unique_id}-{EKS_CLUSTER_NAME}-{index}"
        virtual_cluster_id = virtual_clusters[namespace]
        job_unique_id = setup_unique_user_id()
        selected_az = random.choice(self.job_azs) if self.job_azs else None
        start_time = time.time()
        
        try:
            # Build script path and validate
            script_path = path.join(path.dirname(__file__), "resources", self.job_script)
            if not path.exists(script_path):
                printlog(f"ERROR: Script not found at {script_path}")
                failed_counter.inc()
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

            subprocess.run(['chmod', '+x', script_path], check=True)
            result = subprocess.run(['sh', script_path],env=env,
                capture_output=True,text=True,timeout=300)
            
            if result.returncode == 0:
                success_counter.inc()
                self.total_jobs_submitted += 1
                printlog(f"EMR job {job_unique_id} is submitted successfully to VC: {virtual_cluster_id}, namespace: {namespace}")
            else:
                failed_counter.inc()
                # printlog(f"EMR job submission failed: {result.stderr}")
                printlog(f"Debug info: EMR job submission failed (exit code {result.returncode}): {result.stderr}")
                
        except subprocess.TimeoutExpired:
            failed_counter.inc()
            printlog(f"ERROR: EMR job submission timed out for: {job_unique_id}")
        except Exception as e:
            failed_counter.inc()
            # printlog(f"Exception during EMR job submission: {e}")
            printlog(f"ERROR: Exception during EMR job submission: {type(e).__name__}: {e}")
        finally:
            execution_time_gauge.set(time.time() - start_time)
            elapsed_time = time.perf_counter() - test_start_time
            printlog(f"Submitted {self.total_jobs_submitted} jobs. Elapsed time: {str(timedelta(seconds=elapsed_time))}")

def monitor_emr_jobs(environment):
    """Monitor EMR job runs across all virtual clusters, emit job counts per 1 minute"""
    next_time = time.time() + 60
    
    while True:
        if exit_event.is_set():
            break
        current_time = time.time()
        if current_time > next_time:
            printlog("Collecting EMR job metrics across all virtual clusters at 1 minute interval...")
            
            running_count = 0
            submitted_count = 0
            completed_count = 0
            failed_count = 0
            
            try:
                # Monitor jobs across all virtual clusters using library
                for ns_id, vc_id in virtual_clusters.items():
                    job_runs = virtual_cluster.list_job_runs(vc_id)
                    
                    for job_run in job_runs:
                        state = job_run['state']
                        if state == 'RUNNING':
                            running_count += 1
                        elif state in ['PENDING', 'SUBMITTED']:
                            submitted_count += 1
                        elif state in ['COMPLETED']:
                            completed_count += 1
                        elif state in ['FAILED', 'CANCELLED']:
                            failed_count += 1
                
                # Update metrics
                running_emr_jobs_gauge.set(running_count)
                submitted_emr_jobs_gauge.set(submitted_count)
                completed_emr_jobs_gauge.set(completed_count)
                failed_emr_jobs_gauge.set(failed_count)
                virtual_clusters_gauge.set(len(virtual_clusters))
                
                printlog(f"EMR Jobs - Running: {running_count}, Submitted: {submitted_count}, "
                        f"Completed: {completed_count}, Failed: {failed_count}, VCs: {len(virtual_clusters)}")
                
            except Exception as e:
                printlog(f"Error monitoring EMR jobs: {e}")
            
            next_time = current_time + 60
        
        time.sleep(5)

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
    LoadTestInitializer(environment.parsed_options.job_ns_count)
    start_http_server(8000)
    printlog("EMR on EKS Locust load test with virtual_cluster.py library initialized")
