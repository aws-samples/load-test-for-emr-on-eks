import boto3
from os import environ

REGION=environ.get("AWS_REGION","us-west-2")
# For internal testing, point the emr-containers client at a non-prod (gamma)
# endpoint to avoid production impact. Leave EMR_CONTAINERS_ENDPOINT_URL unset
# to use the default production endpoint. Example gamma value:
#   export EMR_CONTAINERS_ENDPOINT_URL=https://emr-containers-gamma.us-west-2.amazonaws.com
EMR_CONTAINERS_ENDPOINT_URL=environ.get("EMR_CONTAINERS_ENDPOINT_URL") or None

class BotoClient:
    def __init__(self, console):
        # default session is limit to the profile or instance profile used,
        # We need to use the custom session to override the default session configuration
        boto_session = boto3.session.Session(region_name=REGION)
        # One switch for all emr-containers calls (incl. those made via
        # virtual_cluster.py, which reuses this client): default -> prod,
        # EMR_CONTAINERS_ENDPOINT_URL set -> gamma/non-prod.
        if EMR_CONTAINERS_ENDPOINT_URL:
            self.emr_containers_client = boto_session.client(
                'emr-containers', endpoint_url=EMR_CONTAINERS_ENDPOINT_URL)
            console.log(f"Boto EMR containers client using endpoint {EMR_CONTAINERS_ENDPOINT_URL}")
        else:
            self.emr_containers_client = boto_session.client('emr-containers')
            console.log("Boto EMR containers client instantiated")

    def get_emr_containers_client(self):
        return self.emr_containers_client

