import boto3
from emr_containers.job_common_config import REGION

class BotoClient:
    def __init__(self, console):
        # default session is limit to the profile or instance profile used,
        # We need to use the custom session to override the default session configuration
        boto_session = boto3.session.Session(region_name=REGION)
        self.emr_containers_client = boto_session.client('emr-containers', endpoint_url='https://emr-containers-gamma.us-west-2.amazonaws.com')
        console.log("Boto EMR containers client instantiated")

    def get_emr_containers_client(self):
        return self.emr_containers_client

