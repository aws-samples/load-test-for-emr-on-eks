import argparse, time, traceback
import concurrent.futures
from os import environ
from lib.shared import console
from lib.virtual_cluster import virtual_cluster, JOB_RUNNING_STATES
from lib.emr_job import emr_job
EKS_CLUSTER_NAME=environ["CLUSTER_NAME"]

def _cancel_hanging_job_runs_for_virtual_cluster_deletion(job_runs):
    i = 0
    for job in job_runs:
        i += 1
        emr_job.cancel_job(
            job_id=job['id'],
            virtual_cluster_id=job['virtualClusterId'])

def _is_virtual_cluster_ready_for_cleanup(virtual_cluster_id):
    job_runs = virtual_cluster.list_job_runs(
        virtualClusterId=virtual_cluster_id,
        states=JOB_RUNNING_STATES
    )
    if job_runs:
        running_jobs = len(job_runs)
        console.log(f"Waiting [red]30s[/] for [yellow]{running_jobs}[/] jobs to enter terminated state for [steel_blue1]{virtual_cluster_id}[/]")
        return False
    return True


def safe_delete_virtual_cluster(virtual_cluster_id):
    # Cancel all job runs still running in the virtual cluster
    job_runs = virtual_cluster.list_job_runs(
        virtualClusterId=virtual_cluster_id,
        states=JOB_RUNNING_STATES
    )
    running_jobs = len(job_runs)
    console.log(f"Cancelling [yellow]{running_jobs}[/] jobs in [steel_blue1]{virtual_cluster_id}[/]")
    _cancel_hanging_job_runs_for_virtual_cluster_deletion(job_runs)

    # Check if vc is ready for clean up
    ready_for_cleanup = _is_virtual_cluster_ready_for_cleanup(virtual_cluster_id)
    while not ready_for_cleanup:
        time.sleep(30)
        ready_for_cleanup = _is_virtual_cluster_ready_for_cleanup(virtual_cluster_id)

    console.log(f"No running jobs, [steel_blue1]{virtual_cluster_id}[/] can be now terminated")
    virtual_cluster.delete_virtual_cluster(
        virtualClusterId=virtual_cluster_id
    )
    console.log(f"Virtual cluster [steel_blue1]{virtual_cluster_id}[/] has been terminated")


def main():
    parser = argparse.ArgumentParser(description='Monitor virtual clusters.')
    parser.add_argument('--id', type=str, help='The id for the scale test')
    parser.add_argument('--cluster', type=str, default=EKS_CLUSTER_NAME, help='The name of the eks cluster')
    args = parser.parse_args()

    if not args.cluster:
        vcs = [vc['id'] for vc in virtual_cluster.find_vcs(args.id, ['RUNNING'])]
    else:
        vcs = [vc['id'] for vc in virtual_cluster.find_vcs_eks(args.cluster, ['RUNNING'])]

    console.log(f"Found the following: vcs={vcs}, test_id={args.id}")
    # for vc in vcs:
    #     safe_delete_virtual_cluster(vc)

    with concurrent.futures.ThreadPoolExecutor() as executor:
        # Schedule the safe_delete_virtual_cluster function to be called concurrently
        futures = [executor.submit(safe_delete_virtual_cluster, vc) for vc in vcs]

        # Wait for all the futures to complete
        for future in concurrent.futures.as_completed(futures):
            try:
                future.result()  # This will raise an exception if the function raised one
            except Exception as exc:
                console.log(f'Generated an exception:')
                traceback.format_exc()


if __name__ == "__main__":
    main()

