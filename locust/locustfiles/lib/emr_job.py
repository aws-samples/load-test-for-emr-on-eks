from botocore.exceptions import ClientError
from lib.shared import test_instance, console

JOB_TERMINAL_STATES = ['FAILED', 'CANCELLED', 'COMPLETED']
JOB_POLL_SECONDS = 60

class EmrJob:
    def __init__(self, emr_containers_client):
        self.client = emr_containers_client

    # Describe EMR on EKS job run
    def describe_job(self, job_id, virtual_cluster_id):
        try:
            response = self.client.describe_job_run(
                id=job_id,
                virtualClusterId=virtual_cluster_id
            )
            return response['jobRun']
        except ClientError as error:
            console.error(f"{error.response['Error']['Code']} occurred while describing the job")
            return None

        # Cancel EMR on EKS job run

    def cancel_job(self, job_id, virtual_cluster_id):
        try:
            response = self.client.cancel_job_run(
                id=job_id,
                virtualClusterId=virtual_cluster_id
            )
            return response
        except ClientError as error:
            console.error(f"{error.response['Error']['Code']} occurred while cancelling the job")
            return None

emr_job = EmrJob(test_instance.emr_containers_client)

