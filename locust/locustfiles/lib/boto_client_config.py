import boto3
from os import environ

REGION=environ.get("AWS_REGION","us-west-2")

class BotoClient:
    def __init__(self, console):
        # default session is limit to the profile or instance profile used,
        # We need to use the custom session to override the default session configuration
        boto_session = boto3.session.Session(region_name=REGION)
        self.emr_containers_client = boto_session.client('emr-containers')
        console.log("Boto EMR containers client instantiated")

    def get_emr_containers_client(self):
        return self.emr_containers_client

