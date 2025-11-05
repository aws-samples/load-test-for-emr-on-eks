import subprocess
import uuid
from os import environ, path
import time
from lib.shared import console
from lib.shared import test_instance

REGION=environ.get("AWS_REGION","us-west-2")
JOB_RUNNING_STATES = ['PENDING', 'SUBMITTED', 'RUNNING', 'CANCEL_PENDING']
JOB_STATES = ["PENDING", "SUBMITTED", "RUNNING", "COMPLETED", "FAILED"]
VC_DEFAULT_STATES = ["RUNNING", "TERMINATED"]
#
# VirtualCluster class has methods that will help with virtual cluster creation
# and deletion
#
class VirtualCluster:
    def __init__(self, emr_containers_client):
        self.client = emr_containers_client

    # Create EMR on EKS Virtual Cluster
    def create_virtual_cluster(self,client_token, virtual_cluster_name,k8s_namespace,eks_cluster_name):
        try:
            response = self.client.create_virtual_cluster(
                name=virtual_cluster_name,
                containerProvider={
                    'type': 'EKS',
                    'id': eks_cluster_name,
                    'info': {
                        'eksInfo': {
                            'namespace': k8s_namespace
                        }
                    }
                },
                clientToken=client_token
            )
            console.log(f"Virtual cluster created: {response['id']}")
            return response
        except Exception as e:
            console.log(f"Failed to create virtual cluster: {e}")
            return None

    # Delete EMR on EKS virtual cluster
    def delete_virtual_cluster(self, virtualClusterId):
        try:
            response = self.client.delete_virtual_cluster(id=virtualClusterId)
            console.log(f"Virtual cluster deleted: {virtualClusterId}")
            return response
        except Exception as e:
            console.log(f"Failed to delete virtual cluster {virtualClusterId}: {e}")
            return None

    def create_namespace_and_virtual_cluster(self, vs_name, ns_id, eks_name):
        try:
            # Create namespace
            script_path = path.join(path.dirname(__file__), "..", "resources", "create_new_ns_setup_emr_eks.sh")
            if not path.exists(script_path):
                console.log(f"Script not found: {script_path}")
                return None
            
            result = subprocess.run(["sh", script_path, REGION, eks_name, ns_id],
                capture_output=True, text=True, timeout=120
            )
            
            if result.returncode != 0:
                console.log(f"Failed to create namespace: {result.stderr}")
                return None
            
            console.log(f"Namespace {ns_id} created successfully")

            # Check if virtual cluster already exists
            existing_vcs = self.find_vcs_by_name(vs_name, ["RUNNING"])
            if existing_vcs:
                console.log(f"Virtual cluster {vs_name} already exists: {existing_vcs[0]['id']}")
                return existing_vcs[0]['id']

            # Create virtual cluster
            response = self.create_virtual_cluster(
                client_token=str(uuid.uuid4()),
                virtual_cluster_name=vs_name,
                k8s_namespace=ns_id,
                eks_cluster_name=eks_name
            )
            if response:
                # Wait for virtual cluster to be active
                vc_id = response['id']
                if self.wait_for_virtual_cluster_active(vc_id):
                    return vc_id
                else:
                    console.log(f"Virtual cluster {vc_id} failed to become active")
                    return None
            
            return None
            
        except Exception as e:
            console.log(f"Error in create_namespace_and_virtual_cluster: {e}")
            return None
        
    def wait_for_virtual_cluster_active(self, vc_id, max_wait=300):
        start_time = time.time()
        while time.time() - start_time < max_wait:
            try:
                vc = self.describe_virtual_cluster(vc_id)
                if vc and vc['state'] == 'RUNNING':
                    console.log(f"Virtual cluster {vc_id} is active")
                    return True
                elif vc and vc['state'] in ['TERMINATED', 'TERMINATING']:
                    console.log(f"Virtual cluster {vc_id} failed: {vc['state']}")
                    return False
                time.sleep(10)
            except Exception as e:
                console.log(f"Error checking virtual cluster status: {e}")
                time.sleep(10)
        
        console.log(f"Timeout waiting for virtual cluster {vc_id} to become active")
        return False     

    # Describe virtual cluster
    def describe_virtual_cluster(self, virtual_cluster_id):
        response = self.client.describe_virtual_cluster(
            id=virtual_cluster_id
        )
        return response['virtualCluster']

    def find_vcs_eks(self, eks_name, states=None):
        if states is None:
            states = VC_DEFAULT_STATES

        console.log(f"Looking for {eks_name}")
        paginator = self.client.get_paginator('list_virtual_clusters')
        page_iterator = paginator.paginate(
            containerProviderType='EKS',
            containerProviderId=eks_name,
            states=states
        )
        virtual_clusters = [
            vc for page in page_iterator
            for vc in page["virtualClusters"]
        ]
        return virtual_clusters

    def find_vcs_by_name(self, vc_name, states=None):
        if states is None:
            states = VC_DEFAULT_STATES
        try:
            paginator = self.client.get_paginator('list_virtual_clusters')
            page_iterator = paginator.paginate(states=states)
            virtual_clusters = [
                vc for page in page_iterator
                for vc in page["virtualClusters"]
                if vc['name'] == vc_name
            ]
            return virtual_clusters
        except Exception as e:
            console.log(f"Error finding virtual clusters by name {vc_name}: {e}")
            return []

    def find_vcs(self, scale_test_id, states=None):
        if states is None:
            states = VC_DEFAULT_STATES

        paginator = self.client.get_paginator('list_virtual_clusters')
        page_iterator = paginator.paginate(
            states=states
        )
        virtual_clusters = [
            vc for page in page_iterator
            for vc in page["virtualClusters"]
            if vc['name'].startswith(scale_test_id)
        ]
        return virtual_clusters

    def list_job_runs(self, virtualClusterId, states=JOB_STATES):
        paginator = self.client.get_paginator('list_job_runs')
        page_iterator = paginator.paginate(
            virtualClusterId=virtualClusterId,
            states=states
        )
        job_runs = [job for page in page_iterator for job in page["jobRuns"]]
        return job_runs


virtual_cluster = VirtualCluster(test_instance.emr_containers_client)

