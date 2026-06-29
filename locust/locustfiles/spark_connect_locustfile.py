"""Locust load test for EMR on EKS Spark Connect endpoints.

Load model:
  * On each worker, LoadTestInitializer creates, per namespace:
      session-enabled VC (+ SecurityConfiguration)  -> lib/virtual_cluster.py
      SPARK_CONNECT ManagedEndpoint, waited to ACTIVE -> lib/managed_endpoint.py
    and mints an auth-proxy token for it.
  * Each Locust user repeatedly opens its own SparkSession.builder.remote(sc://
    <authProxyUrl>;use_ssl=true;x-aws-proxy-auth=<token>) gRPC session and runs
    a query (default: count rows of the TPC-DS dataset), measuring
    concurrent session + query throughput and latency.

This is the interactive counterpart to locustfile.py (which load tests batch
StartJobRun submission). Select it via JOB_SCRIPT-independent env:
  VC_SESSION_ENABLED=true and run with -f spark_connect_locustfile.py.

Key env vars:
  CLUSTER_NAME, AWS_REGION                     (required)
  EXECUTION_ROLE_ARN                           (required; endpoint exec role)
  SPARK_CONNECT_RELEASE_LABEL                  default emr-spark-8.100.0-latest
  SPARK_CONNECT_IMAGE_URL                      driver+executor image (optional)
  SPARK_CONNECT_QUERY                          optional override SQL/DataFrame op
  SPARK_CONNECT_DATA_PATH                      dataset to count (parquet/csv)
  SPARK_CONNECT_DATA_FORMAT                    default parquet
  TOKEN_REFRESH_MARGIN_SEC                     default 300
"""

import threading
import time
from datetime import datetime, timedelta, timezone
from os import environ

from locust import User, between, events, task
from prometheus_client import Counter, Gauge, start_http_server

from lib.shared import console, setup_unique_user_id, test_instance
from lib.virtual_cluster import virtual_cluster
from lib.managed_endpoint import managed_endpoint, build_remote_url

# ---- shared state ---------------------------------------------------------
exit_event = threading.Event()
test_start_time = time.perf_counter()
unique_id = f"{test_instance.id}"
ns_prefix = f"{unique_id}-ns"
metrics_port = int(environ.get("METRICS_PORT", "8000"))

EKS_CLUSTER_NAME = environ["CLUSTER_NAME"]
REGION = environ["AWS_REGION"]
EXECUTION_ROLE_ARN = environ["EXECUTION_ROLE_ARN"]
RELEASE_LABEL = environ.get("SPARK_CONNECT_RELEASE_LABEL", "emr-spark-8.100.0-latest")
IMAGE_URL = environ.get("SPARK_CONNECT_IMAGE_URL") or None
DATA_PATH = environ.get("SPARK_CONNECT_DATA_PATH") or None
DATA_FORMAT = environ.get("SPARK_CONNECT_DATA_FORMAT", "parquet")
QUERY = environ.get("SPARK_CONNECT_QUERY") or None
TOKEN_REFRESH_MARGIN = int(environ.get("TOKEN_REFRESH_MARGIN_SEC", "300"))

# namespace -> {"vc_id", "endpoint_id", "auth_proxy_url", "token", "expires"}
endpoints = {}
_token_lock = threading.Lock()

# ---- Prometheus metrics ---------------------------------------------------
query_success = Counter('locust_spark_connect_query_success_total',
                        'Successful Spark Connect queries')
query_fail = Counter('locust_spark_connect_query_fail_total',
                     'Failed Spark Connect queries')
session_fail = Counter('locust_spark_connect_session_fail_total',
                      'Failed Spark Connect session creations')
query_latency = Gauge('locust_spark_connect_query_latency_seconds',
                     'Most recent Spark Connect query latency (s)')
session_latency = Gauge('locust_spark_connect_session_latency_seconds',
                       'Most recent Spark Connect session-open latency (s)')
active_endpoints_gauge = Gauge('locust_spark_connect_active_endpoints',
                              'Number of ACTIVE Spark Connect endpoints')
concurrent_user_gauge = Gauge('locust_concurrent_user', 'Number of concurrent locust users')


def printlog(msg):
    print(f"[{datetime.now()}] {msg}")


@events.init_command_line_parser.add_listener
def _init_parser(parser):
    ns_count = int(environ.get("SPARK_JOB_NS_NUM", "1"))
    parser.add_argument("--job-ns-count", type=int, default=ns_count,
                        help="Number of namespaces/VCs/endpoints per Locust worker")


def _fresh_token(namespace):
    """Return a valid auth-proxy token for the namespace's endpoint, refreshing
    it (under a lock) when close to expiry. Shared across this worker's users."""
    info = endpoints[namespace]
    with _token_lock:
        if info["token"] and time.time() < info["expires"] - TOKEN_REFRESH_MARGIN:
            return info["token"]
        token, expires = managed_endpoint.get_session_token(
            info["vc_id"], info["endpoint_id"], EXECUTION_ROLE_ARN)
        if token:
            info["token"], info["expires"] = token, expires
        return token


class SparkConnectUser(User):
    # Gap between successive queries per user; lower it to intensify load.
    wait_time = between(5, 10)

    def __init__(self, environment):
        super().__init__(environment)
        self.user_id = setup_unique_user_id()
        self.ns_count = environment.parsed_options.job_ns_count
        self.queries_run = 0

    @events.test_start.add_listener
    def on_test_start(environment, **kwargs):
        printlog(f"Spark Connect load test against EKS cluster {EKS_CLUSTER_NAME} "
                 f"({REGION}); release {RELEASE_LABEL}")
        printlog("Starting endpoint-state monitoring thread")
        threading.Thread(target=_monitor_endpoints, daemon=True).start()

    @events.test_stop.add_listener
    def on_test_stop(environment, **kwargs):
        printlog(f"Test {unique_id} stopped ramping. Cleaning up endpoints/VCs...")
        exit_event.set()
        _teardown()

    @task
    def count_users(self):
        concurrent_user_gauge.set(self.environment.runner.user_count)

    @task
    def run_query(self):
        if not endpoints:
            printlog("No active Spark Connect endpoints yet; skipping query")
            return
        # Round-robin-ish: pick a namespace deterministically from user id hash.
        ns_keys = sorted(endpoints.keys())
        namespace = ns_keys[hash(self.user_id) % len(ns_keys)]
        token = _fresh_token(namespace)
        if not token:
            session_fail.inc()
            printlog(f"Could not mint token for {namespace}; skipping")
            return
        remote = build_remote_url(endpoints[namespace]["auth_proxy_url"], token)

        spark = None
        t0 = time.time()
        try:
            # Import lazily so the module loads even on the master pod (no client).
            from pyspark.sql import SparkSession
            spark = SparkSession.builder.remote(remote).create()
            session_latency.set(time.time() - t0)

            q0 = time.time()
            result = self._execute_query(spark)
            query_latency.set(time.time() - q0)
            query_success.inc()
            self.queries_run += 1
            printlog(f"[{self.user_id}] query ok on {namespace}: {result}")
        except Exception as e:
            # Session open vs query failure already split via session_latency set.
            if spark is None:
                session_fail.inc()
            else:
                query_fail.inc()
            printlog(f"[{self.user_id}] Spark Connect error on {namespace}: "
                     f"{type(e).__name__}: {e}")
        finally:
            if spark is not None:
                try:
                    spark.stop()
                except Exception:
                    pass
            elapsed = time.perf_counter() - test_start_time
            printlog(f"[{self.user_id}] ran {self.queries_run} queries. "
                     f"Elapsed {timedelta(seconds=elapsed)}")

    def _execute_query(self, spark):
        """Run the configured workload and return a small summary string."""
        if QUERY:
            return spark.sql(QUERY).collect()
        if DATA_PATH:
            reader = spark.read.format(DATA_FORMAT)
            if DATA_FORMAT == "csv":
                reader = reader.option("header", "false")
            return f"rows={reader.load(DATA_PATH).count()}"
        # Default smoke workload: a trivial range count exercising the round-trip.
        return f"range_count={spark.range(0, 1000000).count()}"


def _monitor_endpoints():
    next_t = time.time() + 60
    while not exit_event.is_set():
        if time.time() >= next_t:
            active = 0
            for ns, info in list(endpoints.items()):
                ep = managed_endpoint.describe_endpoint(info["vc_id"], info["endpoint_id"])
                if ep and ep.get("state") == "ACTIVE":
                    active += 1
            active_endpoints_gauge.set(active)
            printlog(f"Active Spark Connect endpoints: {active}/{len(endpoints)}")
            next_t = time.time() + 60
        time.sleep(1)


def _teardown():
    for ns, info in list(endpoints.items()):
        managed_endpoint.delete_endpoint(info["vc_id"], info["endpoint_id"])
    printlog(f"Requested deletion of {len(endpoints)} endpoint(s). "
             f"Delete VCs/namespaces with stop_test.py if no longer needed.")


class LoadTestInitializer:
    """Per-worker: create session-enabled VC + SPARK_CONNECT endpoint per ns."""

    def __init__(self, ns_count):
        printlog(f"Provisioning {ns_count} Spark Connect endpoint(s) for {unique_id}...")
        for i in range(1, ns_count + 1):
            namespace = f"{ns_prefix}{i}"
            vc_name = f"{unique_id}-{EKS_CLUSTER_NAME}-{i}"
            # virtual_cluster.py reads VC_SESSION_ENABLED/SECURITY_CONFIGURATION_ID
            # from env and creates a session-enabled VC (+ SecurityConfiguration).
            vc_id = virtual_cluster.create_namespace_and_virtual_cluster(
                vc_name, namespace, EKS_CLUSTER_NAME)
            if not vc_id:
                printlog(f"Failed to create session-enabled VC for {namespace}")
                continue
            endpoint_id = managed_endpoint.create_spark_connect_endpoint(
                virtual_cluster_id=vc_id,
                name=f"{vc_name}-sc",
                release_label=RELEASE_LABEL,
                execution_role_arn=EXECUTION_ROLE_ARN,
                image_url=IMAGE_URL,
            )
            if not endpoint_id:
                printlog(f"Failed to create SPARK_CONNECT endpoint for {namespace}")
                continue
            ep = managed_endpoint.wait_for_endpoint_active(vc_id, endpoint_id)
            if not ep or not ep.get("authProxyUrl"):
                printlog(f"Endpoint {endpoint_id} not ACTIVE / no authProxyUrl; skipping")
                continue
            token, expires = managed_endpoint.get_session_token(
                vc_id, endpoint_id, EXECUTION_ROLE_ARN)
            endpoints[namespace] = {
                "vc_id": vc_id,
                "endpoint_id": endpoint_id,
                "auth_proxy_url": ep["authProxyUrl"],
                "token": token,
                "expires": expires,
            }
            printlog(f"Endpoint ready for {namespace}: {endpoint_id} "
                     f"({ep['authProxyUrl']})")
        printlog(f"Provisioned {len(endpoints)} Spark Connect endpoint(s)")


@events.init.add_listener
def on_locust_init(environment, **kwargs):
    hostname = environ.get("HOSTNAME", "").lower()
    if "master" in hostname:
        printlog("EMR on EKS Spark Connect load test started ...")
    else:
        printlog(f"Starting Prometheus metrics server on port {metrics_port}")
        start_http_server(metrics_port)
        LoadTestInitializer(environment.parsed_options.job_ns_count)
