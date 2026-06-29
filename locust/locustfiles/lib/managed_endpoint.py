"""SPARK_CONNECT managed-endpoint helpers for EMR on EKS load testing.

The EMR on EKS Spark Connect flow (see the PenTester runbook) is:

  1. SecurityConfiguration  ┐ created by lib/virtual_cluster.py when
  2. session-enabled VC     ┘ VC_SESSION_ENABLED=true
  3. SPARK_CONNECT ManagedEndpoint        <-- this module (CreateManagedEndpoint)
  4. GetManagedEndpointSessionCredentials -> PASETO auth-proxy token
  5. SparkSession.builder.remote("sc://<authProxyUrl>:443/;use_ssl=true;
        x-aws-proxy-auth=<token>")         <-- spark_connect_locustfile.py

DescribeManagedEndpoint returns ``authProxyUrl`` -- the public
``sc://<id>.emr-spark-connect[-gamma].<region>.amazonaws.com:443`` proxy the
client connects through (TLS terminated at the proxy, so the client only needs
``use_ssl=true`` and the auth token, no private CA material).
"""

import time
import uuid
from os import environ

from lib.shared import console, test_instance

# Endpoint reaches ACTIVE in ~5 min (runbook observed 4m53s); allow headroom.
ENDPOINT_ACTIVE_TIMEOUT = int(environ.get("ENDPOINT_ACTIVE_TIMEOUT", "900"))
ENDPOINT_POLL_SECONDS = 15
ENDPOINT_TERMINAL_BAD = {"TERMINATED", "TERMINATING", "TERMINATED_WITH_ERRORS"}


class ManagedEndpoint:
    """Create / describe / tear down SPARK_CONNECT endpoints and mint tokens."""

    def __init__(self, emr_containers_client):
        self.client = emr_containers_client

    # ---- create -----------------------------------------------------------
    def create_spark_connect_endpoint(self, virtual_cluster_id, name, release_label,
                                       execution_role_arn, image_url=None):
        """Create a SPARK_CONNECT managed endpoint; return its id, or None.

        ``image_url`` sets spark.kubernetes.container.image for both driver and
        executor (the same image is always used for both). Leave it unset to use
        the release's default images.
        """
        kwargs = dict(
            name=name,
            virtualClusterId=virtual_cluster_id,
            type="SPARK_CONNECT",
            releaseLabel=release_label,
            executionRoleArn=execution_role_arn,
            clientToken=str(uuid.uuid4()),
        )
        if image_url:
            kwargs["configurationOverrides"] = {
                "applicationConfiguration": [
                    {"classification": "spark-defaults",
                     "properties": {"spark.kubernetes.container.image": image_url}}
                ]
            }
        try:
            resp = self.client.create_managed_endpoint(**kwargs)
            console.log(f"SPARK_CONNECT endpoint created: {resp['id']} (vc {virtual_cluster_id})")
            return resp["id"]
        except Exception as e:
            console.log(f"Failed to create SPARK_CONNECT endpoint in {virtual_cluster_id}: {e}")
            return None

    # ---- describe ---------------------------------------------------------
    def describe_endpoint(self, virtual_cluster_id, endpoint_id):
        """Return the endpoint dict (includes state, authProxyUrl), or None."""
        try:
            resp = self.client.describe_managed_endpoint(
                id=endpoint_id, virtualClusterId=virtual_cluster_id)
            return resp["endpoint"]
        except Exception as e:
            console.log(f"Failed to describe endpoint {endpoint_id}: {e}")
            return None

    def wait_for_endpoint_active(self, virtual_cluster_id, endpoint_id,
                                 max_wait=ENDPOINT_ACTIVE_TIMEOUT):
        """Block until the endpoint is ACTIVE. Returns the endpoint dict or None."""
        deadline = time.time() + max_wait
        while time.time() < deadline:
            ep = self.describe_endpoint(virtual_cluster_id, endpoint_id)
            state = (ep or {}).get("state")
            if state == "ACTIVE":
                console.log(f"Endpoint {endpoint_id} is ACTIVE: {ep.get('authProxyUrl')}")
                return ep
            if state in ENDPOINT_TERMINAL_BAD:
                console.log(f"Endpoint {endpoint_id} failed: {state} "
                            f"({(ep or {}).get('stateDetails')})")
                return None
            time.sleep(ENDPOINT_POLL_SECONDS)
        console.log(f"Timeout waiting for endpoint {endpoint_id} to become ACTIVE")
        return None

    # ---- credentials ------------------------------------------------------
    def get_session_token(self, virtual_cluster_id, endpoint_id, execution_role_arn,
                          duration_seconds=10000):
        """Mint a Spark Connect auth-proxy token (PASETO 'v2.local...').

        Returns (token, expires_at_epoch) or (None, 0). The token is passed to
        the client via the sc:// 'x-aws-proxy-auth' parameter.
        """
        try:
            resp = self.client.get_managed_endpoint_session_credentials(
                endpointIdentifier=endpoint_id,
                virtualClusterIdentifier=virtual_cluster_id,
                executionRoleArn=execution_role_arn,
                credentialType="TOKEN",
                durationInSeconds=duration_seconds,
                clientToken=str(uuid.uuid4()),
            )
            token = resp["credentials"]["token"]
            expires = resp.get("expiresAt")
            expires_epoch = expires.timestamp() if hasattr(expires, "timestamp") else (
                time.time() + duration_seconds)
            return token, expires_epoch
        except Exception as e:
            console.log(f"Failed to get session token for endpoint {endpoint_id}: {e}")
            return None, 0

    # ---- delete -----------------------------------------------------------
    def delete_endpoint(self, virtual_cluster_id, endpoint_id):
        try:
            self.client.delete_managed_endpoint(
                id=endpoint_id, virtualClusterId=virtual_cluster_id)
            console.log(f"Endpoint deleted: {endpoint_id}")
            return True
        except Exception as e:
            console.log(f"Failed to delete endpoint {endpoint_id}: {e}")
            return False

    def list_endpoints(self, virtual_cluster_id, states=None):
        try:
            paginator = self.client.get_paginator("list_managed_endpoints")
            kwargs = {"virtualClusterId": virtual_cluster_id}
            if states:
                kwargs["states"] = states
            return [ep for page in paginator.paginate(**kwargs)
                    for ep in page["endpoints"]]
        except Exception as e:
            console.log(f"Failed to list endpoints for {virtual_cluster_id}: {e}")
            return []


def build_remote_url(auth_proxy_url, token):
    """Assemble the sc:// connection string the PySpark client connects with.

    authProxyUrl already includes the scheme/host/port (e.g.
    'sc://<id>.emr-spark-connect-gamma.us-west-2.amazonaws.com:443'); we append
    the use_ssl flag and the auth-proxy token, matching the runbook's client.
    """
    base = auth_proxy_url.rstrip("/")
    return f"{base}/;use_ssl=true;x-aws-proxy-auth={token}"


managed_endpoint = ManagedEndpoint(test_instance.emr_containers_client)
