from locust import User, task, between, events
from prometheus_client import start_http_server, Counter, Gauge
import uuid, time, os, json, subprocess, random, threading
from datetime import datetime, timedelta
from emr_containers.job_common_config import EKS_CLUSTER_NAME,REGION,JOB_SCRIPT_NAME_PATH
from emr_containers.virtual_cluster import virtual_cluster
from emr_containers.shared import test_instance, setup_unique_test_id

# Import virtual cluster management
# sys.path.append('/Users/meloyang/Documents/sourcecode/OutlookForMac-mcp-server')

# Global variables and events
exit_event = threading.Event()
test_start_time = time.perf_counter()
virtual_clusters = {}  # Store namespace -> virtual_cluster_id mapping
ns_prefix = "emr"
# EMR job script path
# emr_script_path = "./resources/emr-eks-benchmark-oom.sh"

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
    parser.add_argument("--emr-script-path", type=str, default=JOB_SCRIPT_NAME_PATH, help="EMR on EKS job submission shell script file name and path")
    parser.add_argument("--job-ns-count", type=int, default=2, help="Number of job namespaces")
    parser.add_argument("--job-azs", type=json.loads, default=f"{REGION}a", help="List of AZs for task allocation")
    parser.add_argument("--emr-version", type=str, default=None, help="EMR release version")
    # parser.add_argument("--wait-time", type=int, default="20", help="Submission delay per virtual cluster.")

def printlog(log):
    now = str(datetime.now())
    print(f"[{now}] {log}")

class EMRJobUser(User):
    wait_time = between(20, 30)

    def __init__(self, environment):
        super().__init__(environment)
        self.job_script = environment.parsed_options.emr_script_path
        self.ns_count = environment.parsed_options.job_ns_count
        self.job_azs = environment.parsed_options.job_azs
        self.emr_version = environment.parsed_options.emr_version
        self.total_jobs_submitted = 0

    @events.test_start.add_listener
    def on_test_start(environment, **kwargs):

        printlog(f"Start the load test against EKS Cluster {EKS_CLUSTER_NAME} in region {REGION}........")
        printlog(f"Wait time is set between 20 -30 seconds")
        printlog(f"EMR on EKS job submission script is set to [green]{environment.parsed_options.emr_script_path}")
        printlog(
            f"Monitor the test:[green on grey19]python3[/][white on grey19] monitor.py {test_instance.id}[/]")
        printlog("Starting EMR job monitoring thread")
        thread = threading.Thread(target=monitor_emr_jobs, args=(environment,))
        thread.start()

    @events.test_stop.add_listener
    def on_test_stop(environment, **kwargs):
        printlog("Stopping EMR job monitoring thread")
        exit_event.set()

    @task
    def count_locust_user(self):
        concurrent_user_gauge.set(self.environment.runner.user_count)

    @task
    def submit_emr_job(self):
        printlog("Submitting EMR on EKS job")
        
        # Randomly choose a namespace and its virtual cluster
        index = random.randint(1, self.ns_count)
        namespace = f"{ns_prefix}{index}"
        
        if namespace not in virtual_clusters:
            printlog(f"No virtual cluster found in the namespace {namespace}")
            failed_counter.inc()
            return
            
        emr_cluster_name = f"emr-on-{EKS_CLUSTER_NAME}"
        virtual_cluster_id = virtual_clusters[namespace]
        job_unique_id = setup_unique_test_id()
        selected_az = random.choice(self.job_azs) if self.job_azs else None
        emr_version = self.emr_version if self.emr_version else None
        start_time = time.time()
        
        try:
            # Execute EMR job script with environment variables
            env = os.environ.copy()
            env.update({
                'EMRCLUSTER_NAME': emr_cluster_name,
                'VIRTUAL_CLUSTER_ID': virtual_cluster_id,
                'AWS_REGION': REGION,
                'JOB_UNIQUE_ID': job_unique_id,
                'SELECTED_AZ': selected_az,
                'EMR_VERSION': emr_version
            })

            # Make script executable and run it
            subprocess.run(['chmod', '+x', self.job_script], check=True)
            result = subprocess.run(
                ['bash', self.job_script],
                env=env,
                capture_output=True,
                text=True,
                timeout=300
            )
            
            if result.returncode == 0:
                success_counter.inc()
                self.total_jobs_submitted += 1
                printlog(f"EMR job submitted successfully: {job_unique_id} to VC: {virtual_cluster_id}")
            else:
                failed_counter.inc()
                printlog(f"EMR job submission failed: {result.stderr}")
                
        except subprocess.TimeoutExpired:
            failed_counter.inc()
            printlog(f"EMR job submission timed out for: {job_unique_id}")
        except Exception as e:
            failed_counter.inc()
            printlog(f"Exception during EMR job submission: {e}")
        finally:
            execution_time_gauge.set(time.time() - start_time)
            elapsed_time = time.perf_counter() - test_start_time
            printlog(f"Submitted {self.total_jobs_submitted} jobs. Elapsed time: {str(timedelta(seconds=elapsed_time))}")

def monitor_emr_jobs(environment):
    """Monitor EMR job runs across all virtual clusters"""
    next_time = time.time() + 60
    
    while True:
        if exit_event.is_set():
            break
        current_time = time.time()
        if current_time > next_time:
            printlog("Collecting EMR job metrics across all virtual clusters")
            
            running_count = 0
            submitted_count = 0
            completed_count = 0
            failed_count = 0
            
            try:
                # Monitor jobs across all virtual clusters using library
                for namespace, vc_id in virtual_clusters.items():
                    job_runs = virtual_cluster.list_job_runs(vc_id, ['PENDING', 'SUBMITTED', 'RUNNING', 'COMPLETED', 'FAILED'])
                    
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
        printlog(f"Creating No.{ns_count} virtual cluster...")
        """Create virtual cluster and namespace mapping"""
        global virtual_clusters
        for i in range(ns_count):
            namespace = f"{ns_prefix}{i}"  
            self.virtual_cluster_name = f"emr-on-{EKS_CLUSTER_NAME}-{i}"
            self.vc_id = virtual_cluster.create_namespace_and_virtual_cluster(namespace,EKS_CLUSTER_NAME,self.virtual_cluster_name)
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
