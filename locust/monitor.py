import argparse
import signal
import sys
import gevent
from rich import box
from rich.live import Live
from rich.table import Table
from lib.virtual_cluster import virtual_cluster
from lib.shared import console

states = ["PENDING", "SUBMITTED", "RUNNING", "COMPLETED", "FAILED"]
colors = ["yellow", "dark_slate_gray1", "plum1", "green1", "red1"]
fg_colors = ["yellow1", "dark_slate_gray1", "plum1", "green1", "red1"]

def signal_handler(sig, frame):
    sys.exit(0)

signal.signal(signal.SIGINT, signal_handler)

vc_states_map = {}

def generate_table(scale_test_id):
    # Creating a table with no border and a specified width
    if len(vc_states_map) == 0:
        return Table(show_header=False)

    table = Table(box=box.SIMPLE, show_header=False, show_footer=False, show_edge=False, show_lines=False, caption=f"Id: {scale_test_id}")
    table.add_column("Virtual Cluster")
    table.add_column("Status", justify="left", width=25)
    table.add_column("Legend", justify="right")
    overall_total = 0
    want = 300
    # Iterating through each virtual cluster and its jobs
    for cluster_id, state_count in vc_states_map.items():
        total = sum(state_count.values())
        if total == 0:
            continue
            # •
        overall_total += total
        bars = round((total / want) * 25)
        progress_str = "".join(f"{'=' * bars}")
        table.add_row(f"[grey69]{cluster_id}[/]", f"{progress_str}>", f"[white]{round((total / want) * 100, 2)}% ({total}/{want})[/]")
    overall_totals = {state: sum(vc[state] for vc in vc_states_map.values()) for state in states}
    table.add_row(f"", f"", f"[white]({overall_total}/{want * len(vc_states_map)})")
    return table


def draw(scale_test_id):
    with Live(generate_table(scale_test_id), console=console, refresh_per_second=4) as live:
        while True:
            live.update(generate_table(scale_test_id))
            gevent.sleep(1)


def get_job_states(vc):
    job_runs = virtual_cluster.list_job_runs(vc, states)

    if len(job_runs) == 0:
        return None
    job_states = {state: sum(1 for job in job_runs if job["state"] == state) for state in states}
    vc_states_map[vc] = job_states
    return job_states


def monitor_vc(vc, current, total):
    console.log(f"Monitoring [steel_blue1]{vc}[/steel_blue1] initiated. ({current}/{total})")
    while get_job_states(vc) is not None:
        gevent.sleep(5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Monitor virtual clusters.')
    parser.add_argument('scale_test_id', type=str, help='Unique id for the scale test')
    args = parser.parse_args()
    with console.status(f"Pulling virtual clusters for [magenta]{args.scale_test_id}"):
        vcs = [vc['id'] for vc in virtual_cluster.find_vcs(args.scale_test_id, ['RUNNING'])]
    console.print(f"Found the following: vcs={vcs}, test_id=[magenta]{args.scale_test_id}[/]")
    greenlets = []
    for index, vc in enumerate(vcs):
        greenlets.append(gevent.spawn(monitor_vc, vc, index + 1, len(vcs)))
    draw(args.scale_test_id)
    # gevent.joinall(greenlets)

