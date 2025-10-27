from botocore.exceptions import ClientError

from emr_containers.shared import test_instance, console
from emr_containers.job_common_config import JOB_EXECUTION_ROLE_ARN, RELEASE_LABEL, S3_LOG_PATH, JOB_ENTRY_POINT, STREAMING_JOB_ENTRY_POINT

JOB_TERMINAL_STATES = ['FAILED', 'CANCELLED', 'COMPLETED']
JOB_POLL_SECONDS = 60


class EmrJob:
    def __init__(self, emr_containers_client):
        self.client = emr_containers_client

    def start_streaming_job_run(self,
                            job_name,
                            virtual_cluster_id,
                            suffix,
                            job_submit_params):
        job_response = self.submit_job(
            job_name=f"{job_name}-stream",
            client_token=job_name,
            entry_point=STREAMING_JOB_ENTRY_POINT,
            entry_point_arguments=["--suffix", f"{suffix}"],
            spark_submit_params=job_submit_params,
            virtual_cluster_id=virtual_cluster_id
        )
        # console.log(f"Started job with id: {job_response['id']}, name: {job_name}")
        return job_response


    def start_job_run(self,
                      job_name,
                      virtual_cluster_id,
                      job_duration,
                      job_submit_params):
        job_response = self.submit_job(
            job_name=f"{job_name}-{job_duration}-batch",
            client_token=job_name,
            entry_point=JOB_ENTRY_POINT,
            entry_point_arguments=["--sleep_seconds", f"{job_duration}"],
            spark_submit_params=job_submit_params,
            virtual_cluster_id=virtual_cluster_id
        )
        # console.log(f"Started job with id: {job_response['id']}, name: {job_name}")
        return job_response
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

        # Submit EMR on EKS job with required parameters

    def submit_job(self,
                   job_name, client_token,
                   entry_point, entry_point_arguments, spark_submit_params,
                   virtual_cluster_id):
        response = self.client.start_job_run(
            name=job_name,
            virtualClusterId=virtual_cluster_id,
            clientToken=client_token,
            executionRoleArn=JOB_EXECUTION_ROLE_ARN,
            releaseLabel=RELEASE_LABEL,
            jobDriver={
                "sparkSubmitJobDriver": {
                    "entryPoint": entry_point,
                    "entryPointArguments": entry_point_arguments,
                    "sparkSubmitParameters": spark_submit_params
                }
            },
            retryPolicyConfiguration={
                'maxAttempts': 2
            },
            configurationOverrides={
                "monitoringConfiguration": {
                    # "cloudWatchMonitoringConfiguration": {
                    #     "logGroupName": CLOUD_WATCH_LOG_GROUP_NAME,
                    #     "logStreamNamePrefix": job_name
                    # },
                    "s3MonitoringConfiguration": {
                        "logUri": S3_LOG_PATH
                    }
                },
                "applicationConfiguration": [
                    {
                        "classification": "emr-job-submitter",
                        "properties": {
                            "jobsubmitter.container.image.pullPolicy": "IfNotPresent"
                        }
                    }
                    # {
                    #     "classification": "emr-containers-defaults",
                    #     "properties": {
                    #         "job-start-timeout":"3600"
                    #     }
                    # }
                ]
            })

        return response

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

