from datetime import datetime, timezone
import uuid
from lib.boto_client_config import BotoClient
from rich.console import Console

console = Console(log_path=False)

def _setup_unique_test_id():
    return f"emr-{str(uuid.uuid4())[:8]}-{datetime.now(timezone.utc).strftime('%Y%m%d')}"

def setup_unique_user_id():
    return f"{str(uuid.uuid4())[:8]}"

class ScaleTest:
    #
    # This class initializes clients and variables that will be shared across the Users
    # We will create a singleton of this class and will be used while running test jobs.
    #
    def __init__(self):
        boto = BotoClient(console)
        self.emr_containers_client = boto.get_emr_containers_client()
        self.id = _setup_unique_test_id()


test_instance = ScaleTest()

