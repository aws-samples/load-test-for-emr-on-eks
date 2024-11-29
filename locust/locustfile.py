from locust import User, task, between, events
from kubernetes import client, config
from prometheus_client import start_http_server, Counter, Gauge
import uuid, yaml, time
from datetime import datetime
import subprocess, sys, random, threading, signal
import json
import os

# Global variables and events
exit_event = threading.Event()

config.load_kube_config()
api_instance = client.CustomObjectsApi()

k8s_client = client.ApiClient()
group = "sparkoperator.k8s.io"
version = "v1beta2"
plural = "sparkapplications"

ns_prefix = "spark-job"
sa_prefix = "spark-job-sa"
role_prefix = "spark-job-role"
rb_prefix = "spark-job-rb"

file_path = "./resources/spark-pi.yaml"

# Prometheus metrics
success_counter = Counter('locust_spark_application_submit_success', 'Number of successful submitted spark application')
failed_counter = Counter('locust_spark_application_submit_fail', 'Number of failed submitted spark application')
execution_time_gauge = Gauge('locust_spark_application_submit_gauge', 'Execution time for submitting spark application')
running_spark_application_gauge = Gauge('locust_running_spark_application_gauge', 'Number of concurrent running spark application calculated from locust')
submitted_spark_application_gauge = Gauge('locust_submitted_spark_application_gauge', 'Number of submitted spark application calculated from locust')
succeeding_spark_application_gauge = Gauge('locust_succeeding_spark_application_gauge', 'Number of succeeding spark application calculated from locust')
new_spark_application_gauge = Gauge('locust_new_spark_application_gauge', 'Number of new spark application calculated from locust')
completed_spark_application_gauge = Gauge('locust_completed_spark_application_gauge', 'Number of completed spark application calculated from locust')
concurrent_user_gauge = Gauge('locust_concurrent_user', 'Number of concurrent locust user')

@events.init_command_line_parser.add_listener
def on_locust_init(parser):
    parser.add_argument("--job-ns-count", type=int, default=10, help="Number of job namespaces")
    parser.add_argument("--job-azs", type=json.loads, default=None, help="List of AZs for task allocation")
    parser.add_argument("--kube-labels", type=json.loads, default=None, help="Kubernetes labels for node selection")
    parser.add_argument("--karpenter", action="store_true", help="Use Karpenter for node selection")
    parser.add_argument("--job-name", type=str, default="spark-job", help="Name for the Spark job")
    parser.add_argument("--binpacking", type=lambda x: (str(x).lower() == 'true'), default=True, help="Enable or disable binpacking")
    parser.add_argument("--karpenter_driver_not_evict", type=lambda x: (str(x).lower() == 'true'), default=False, help="Enable or disable driver not evict when using karpenter")

def printlog(log):
    now = str(datetime.now())
    print(f"[{now}] {log}")

def get_current_cluster_name():
    try:
        result = subprocess.run(['kubectl', 'config', 'view', '--minify', '-o', 'jsonpath={.clusters[0].name}'], 
                                capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        printlog(f"Error getting current cluster name: {e}")
        return None

cluster_name = get_current_cluster_name()
if cluster_name:
    printlog(f"Current cluster name: {cluster_name}")
else:
    printlog("Unable to get current cluster name.")

class KubernetesClientUser(User):
    wait_time = between(20, 30)

    def __init__(self, environment):
        super().__init__(environment)
        self.cluster_name = cluster_name
        self.use_karpenter = environment.parsed_options.karpenter
        self.karpenter_driver_not_evict = environment.parsed_options.karpenter_driver_not_evict
        self.job_azs = environment.parsed_options.job_azs
        self.kube_labels = environment.parsed_options.kube_labels
        self.job_name = environment.parsed_options.job_name
        self.binpacking = environment.parsed_options.binpacking
        self.ns_count = environment.parsed_options.job_ns_count

    @events.test_start.add_listener
    def on_test_start(environment, **kwargs):
        printlog("Start collecting thread")
        thread = threading.Thread(target=count_running_spark_application, args=(environment,))
        thread.start()

    @events.test_stop.add_listener
    def on_test_stop(environment, **kwargs):
        printlog("Stop collecting thread")
        exit_event.set()

    @task
    def count_locust_user(self):
        concurrent_user_gauge.set(self.environment.runner.user_count)

    @task
    def submit_spark_operator_job(self):
        printlog("Submitting spark-operator job")

        index = random.randint(0, self.ns_count-1)

        spark_sa = sa_prefix + str(index)
        spark_ns = ns_prefix + str(index)

        yaml_content = self.read_yaml_file(file_path)
        unique_id = str(uuid.uuid4())
        unique_yaml_content = self.modify_yaml_file(yaml_content, unique_id, spark_ns, spark_sa)

        start_time = time.time()

        try:
            api_response = api_instance.create_namespaced_custom_object(
                group = group,
                version = version,
                namespace = spark_ns,
                plural = plural,
                body = unique_yaml_content
            )
            success_counter.inc()
            execution_time_gauge.set(time.time() - start_time)

            print(f"Sparkapplication created successfully with name: {api_response['metadata']['name']} in namespace {api_response['metadata']['namespace']}")
        except client.exceptions.ApiException as e:
            failed_counter.inc()
            print(f"Exception when creating SparkApplication: {e}")
        finally:
            print(f"Submitting time finished in {time.time() - start_time} seconds")

    def read_yaml_file(self, file_path):
        try:
            with open(file_path, 'r') as file:
                yaml_content = yaml.safe_load(file)
            # printlog(f"Loaded YAML content: {yaml_content}")
            return yaml_content
        except Exception as e:
            printlog(f"Error reading YAML file: {e}")
            return None

    def modify_yaml_file(self, yaml_content, unique_id, spark_ns, spark_sa):
        if yaml_content is None:
            printlog("Error: YAML content is None")
            return None

        if 'metadata' in yaml_content and 'name' in yaml_content['metadata']:
            yaml_content['metadata']['name'] = f"{self.job_name}-{unique_id}"
            yaml_content['metadata']['namespace'] = spark_ns
            yaml_content['spec']['driver']['serviceAccount'] = spark_sa
        
        default_image = "895885662937.dkr.ecr.us-west-2.amazonaws.com/spark/emr-6.11.0:latest"
        yaml_content['spec']['image'] = os.environ.get('EMR_IMAGE_URL', default_image)

        if 'spec' in yaml_content:
            # Select a single AZ for both driver and executor
            selected_az = random.choice(self.job_azs) if self.job_azs else None

            for component in ['driver', 'executor']:
                if component in yaml_content['spec']:
                    # Ensure nodeSelector exists and is a dictionary
                    if 'nodeSelector' not in yaml_content['spec'][component] or yaml_content['spec'][component]['nodeSelector'] is None:
                        yaml_content['spec'][component]['nodeSelector'] = {}

                    # Common logic: AZ selection
                    if selected_az:
                        yaml_content['spec'][component]['nodeSelector']['topology.kubernetes.io/zone'] = selected_az
                    
                    # Binpacking configuration
                    if self.binpacking:
                        yaml_content['spec'][component]['schedulerName'] = "my-scheduler"

                    # Karpenter-specific logic
                    if self.use_karpenter:
                        yaml_content['spec'][component]['nodeSelector']['provisioner'] = f"spark-{component}-provisioner"
                    
                    # Driver karpenter.sh/do-not-evict: "true"
                    if self.karpenter_driver_not_evict and component == 'driver':
                        if 'annotations' not in yaml_content['spec']['driver']:
                            yaml_content['spec']['driver']['annotations'] = {}
                        yaml_content['spec']['driver']['annotations']['karpenter.sh/do-not-evict'] = "true"
                    
                    # Node group logic for multiple labels
                    if self.kube_labels:
                        # 直接合并所有标签字典
                        merged_labels = {}
                        for label_dict in self.kube_labels:
                            merged_labels.update(label_dict)
                        yaml_content['spec'][component]['nodeSelector'].update(merged_labels)

        return yaml_content

def count_running_spark_application(environment):
    next_time = time.time() + 30
    while True: 
        if exit_event.is_set():
            break
        current_time = time.time()
        if current_time > next_time:
            printlog("Collect running application count")
            running_app_count = 0
            submitted_app_count = 0
            succeeding_app_count = 0
            new_app_count = 0
            completed_app_count = 0
            for index in range(0, environment.parsed_options.job_ns_count):
                spark_ns = ns_prefix + str(index)
                spark_apps = api_instance.list_namespaced_custom_object(
                    group = group,
                    version = version,
                    namespace = spark_ns,
                    plural = plural
                )
                for app in spark_apps['items']:
                    if 'status' in app:
                        app_state = app['status']['applicationState']['state']
                        if app_state == 'RUNNING':
                            running_app_count += 1
                        elif app_state == "SUBMITTED":
                            submitted_app_count += 1
                        elif app_state == "SUCCEEDING":
                            succeeding_app_count += 1
                        elif app_state == "COMPLETED":
                            completed_app_count += 1
                    if 'status' not in app:
                            new_app_count += 1

            running_spark_application_gauge.set(running_app_count)
            submitted_spark_application_gauge.set(submitted_app_count)
            succeeding_spark_application_gauge.set(succeeding_app_count)
            new_spark_application_gauge.set(new_app_count)
            completed_spark_application_gauge.set(completed_app_count)

            next_time = current_time + 30
        time.sleep(1)

class LoadTestInitializer():
    def __init__(self, ns_count):
        self.create_namespace_and_rbac(ns_prefix=ns_prefix, sa_prefix=sa_prefix, role_prefix=role_prefix, rb_prefix=rb_prefix, ns_count=ns_count)

    def create_namespace_and_rbac(self, ns_prefix, sa_prefix, role_prefix, rb_prefix, ns_count):
        rbac_path = "./resources/ns_rbac.yaml"
        v1_api = client.CoreV1Api()
        for i in range(ns_count):
            spark_ns = ns_prefix + str(i)
            try:
                v1_api.read_namespace(spark_ns)
                print(f"Found namespace {spark_ns}")
            except client.exceptions.ApiException as e:
                if e.status == 404:
                    replacements = {
                        '{spark_ns}': ns_prefix + str(i),
                        '{spark_sa}': sa_prefix + str(i),
                        '{spark_role}': role_prefix + str(i),
                        '{spark_rb}': rb_prefix + str(i)
                    }

                    with open(rbac_path, 'r') as file:
                        data = file.read()
                    for placeholder, value in replacements.items():
                        data = data.replace(placeholder, value)

                    documents = yaml.safe_load_all(data)
                    for doc in documents:
                        updated_yaml = yaml.dump(doc)
                        print(updated_yaml)

                        p = subprocess.run(['kubectl', 'apply', '-f', '-'], input=updated_yaml.encode('utf-8'), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        print(p.stdout.decode())
                        if p.stderr:
                            print(p.stderr.decode(), file=sys.stderr)
                else:
                    print(f"Checking namespace failed: {e}")

@events.init.add_listener
def on_locust_init(environment, **kwargs):
    LoadTestInitializer(environment.parsed_options.job_ns_count)
    start_http_server(8000)