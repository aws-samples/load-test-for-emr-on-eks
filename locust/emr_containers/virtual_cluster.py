import subprocess
import uuid

from emr_containers.shared import console
from emr_containers.shared import test_instance
from emr_containers.job_common_config import REGION

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
    def create_virtual_cluster(self,
                               client_token,
                               virtual_cluster_name,
                               k8s_namespace,
                               eks_cluster_name):
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
        return response

    # Delete EMR on EKS virtual cluster
    def delete_virtual_cluster(self, virtualClusterId):
        response = self.client.delete_virtual_cluster(
            id=virtualClusterId
        )
        return response

    def create_namespace_and_virtual_cluster(self, ns_id, eks_name, vs_name):
        # Creating namespace in EKS cluster
        subprocess.run(["sh", "../resources/create_new_ns_setup_emr_eks.sh",
                        REGION, eks_name, ns_id], capture_output=True)
        # Creating virtual cluster
        create_virtual_cluster_response = self.create_virtual_cluster(
            client_token=str(uuid.uuid4()),
            virtual_cluster_name=vs_name,
            k8s_namespace=ns_id)
        return create_virtual_cluster_response['id']

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

    def list_job_runs(self, virtualClusterId, states):
        paginator = self.client.get_paginator('list_job_runs')
        page_iterator = paginator.paginate(
            virtualClusterId=virtualClusterId,
            states=states
        )
        job_runs = [job for page in page_iterator for job in page["jobRuns"]]
        return job_runs


virtual_cluster = VirtualCluster(test_instance.emr_containers_client)

