## EMR on EKS Load-Test MCP Server

An [MCP](https://modelcontextprotocol.io/) server that automates the EMR on EKS
load-test benchmark utility. Rather than re-implementing logic, it wraps the
project's existing, tested automation — `env.sh`, `infra-provision.sh`,
`locust-provision.sh`, the Locust CLI / `LocustTest` CRD, `stop_test.py`, and
`clean-up.sh` — plus the `aws` and `kubectl` CLIs, and exposes them as MCP
tools. Because the tools shell out to those scripts, the server tracks the
project as it evolves.

The target AWS **account and region are not hardcoded** — they are derived
entirely from the active AWS profile. `env.sh` resolves `AWS_REGION` from the
profile's configured region and `ACCOUNT_ID` via `aws sts get-caller-identity`.
**Confirm the profile first** with `get_aws_profile` (and switch it with
`set_aws_profile`) before configuring or running anything.

Those artifacts come from the
[aws-samples/load-test-for-emr-on-eks](https://github.com/aws-samples/load-test-for-emr-on-eks)
GitHub repo. The server resolves them in this order:

1. `$LOADTEST_REPO_ROOT`, if set — an explicit local checkout.
2. The parent of `loadtest_mcp/` — when the server runs from inside a checkout.
3. `$LOADTEST_CACHE_DIR/load-test-for-emr-on-eks` — a clone the server fetches
   from GitHub on demand (default cache dir: `~/.cache/emr-eks-loadtest-mcp`).

If the artifacts aren't already present, the server **clones them from GitHub
automatically** (via the `sync_repo` tool, and lazily on the first tool that
needs them). So installation does not require a manual checkout — see
[Registration](#registration).

See the main project [README](../README.md) for the end-to-end load-test
workflow these tools automate.

## Prerequisites

The server drives the same toolchain the repo itself requires:

- `git` — used to clone/update the load-test artifacts from GitHub.
- `aws` CLI (>= 2.17.45), **authenticated** — the account and region come from
  the active AWS profile: `env.sh` resolves `AWS_REGION` from the profile and
  `ACCOUNT_ID` via `aws sts get-caller-identity`, so a profile with valid
  credentials is required. Confirm it with `get_aws_profile` first.
- `kubectl` (>= 1.31.2)
- `eksctl` (>= 0.194)
- `helm` (>= 3.13.2)
- `locust` (for `run_local_test`; installed from the fetched
  `locust/requirements.txt`)
- Python **>= 3.10**
- The `mcp[cli]` Python package (the MCP SDK / FastMCP).

## Install

The recommended path is [Registration](#registration) below, which fetches the
server and its artifacts from GitHub and installs the Python dependency for you
(via AIM's `--install` step, or the one-time `git clone` + `pip install` for
manual clients).

If you already have a checkout and just want the Python dependency:

```bash
cd loadtest_mcp
pip install -r requirements.txt   # installs mcp[cli]
# or, for an editable install:
pip install -e .
```

## Registration

You can register the server with [AIM](#install-with-aim-recommended) (the
Amazon AI Integration Manager) or via a [manual `mcpServers`
block](#manual-mcpservers-block). `server.py` inserts its own directory onto
`sys.path`, so it imports `helpers.py` correctly no matter which working
directory the MCP client launches it from. Neither path requires a pre-existing
checkout: the server clones the load-test artifacts from GitHub on first use.

The server reads these optional environment variables:

- `LOADTEST_REPO_URL` — Git URL of the load-test repo. Defaults to
  `https://github.com/aws-samples/load-test-for-emr-on-eks`.
- `LOADTEST_REPO_BRANCH` — branch/tag to clone. Defaults to the repo's default
  branch.
- `LOADTEST_REPO_ROOT` — an explicit local checkout to use instead of cloning.
  Defaults to the parent of `loadtest_mcp/` when the server runs from inside a
  checkout, otherwise a managed clone under the cache dir.
- `LOADTEST_CACHE_DIR` — where the server clones the repo when no checkout is
  found. Defaults to `~/.cache/emr-eks-loadtest-mcp`.
- `LOADTEST_RUN_DIR` — where background-job logs are written. Defaults to
  `loadtest_mcp/.runs`.

### Install with AIM (recommended)

[AIM](https://docs.hub.amazon.dev/docs/aim/) (AI Integration Manager) installs
MCP servers for Kiro CLI, the default agent, and other MCP-aware tools. Install
the AIM CLI via Builder Toolbox first:

```bash
mwinit
toolbox update && toolbox install aim
```

Register this server as a **generic MCP server** with AIM. The `--install` step
clones the load-test repo from GitHub (which contains both the server code and
the automation it drives) and installs the MCP SDK; the `--run` command launches
the cloned `server.py`; AIM writes the client configuration for you. This
bootstraps entirely from GitHub — no pre-existing checkout required:

```bash
aim mcp create generic-mcp \
  --id emr-eks-loadtest-mcp \
  --name EmrEksLoadtestMcp \
  --description "Automate the EMR on EKS load-test utility" \
  --install 'git clone --depth 1 https://github.com/aws-samples/load-test-for-emr-on-eks "$HOME/.cache/emr-eks-loadtest-mcp/load-test-for-emr-on-eks" 2>/dev/null || git -C "$HOME/.cache/emr-eks-loadtest-mcp/load-test-for-emr-on-eks" pull --ff-only' \
  --install 'pip install -r "$HOME/.cache/emr-eks-loadtest-mcp/load-test-for-emr-on-eks/loadtest_mcp/requirements.txt"' \
  --run 'python3 "$HOME/.cache/emr-eks-loadtest-mcp/load-test-for-emr-on-eks/loadtest_mcp/server.py"' \
  --execute-directly
```

The server runs from the cloned checkout, so it uses that same clone for the
load-test artifacts (resolution case 2) and keeps it current via the
`sync_repo` tool.

Notes:

- The `--id` must end in `mcp` (an AIM requirement).
- `--install` can be passed multiple times; the steps run in order during setup.
- To install a specific branch/tag, add `--branch <ref>` to the `git clone` and
  set `--run '... LOADTEST_REPO_BRANCH=<ref> python3 .../server.py'`.
- If you already have a checkout, point `--run` at its `loadtest_mcp/server.py`
  and drop the `git clone` install step; the server uses that checkout directly.

Manage the server with the standard AIM commands:

```bash
aim mcp list --installed                 # confirm it registered
aim mcp start-server emr-eks-loadtest-mcp # start it (or let the client launch it)
aim mcp uninstall emr-eks-loadtest-mcp    # remove it
```

To share it with your team, publish it to a registry — see the
[AIM mcp CLI reference](https://docs.hub.amazon.dev/docs/aim/user-guide/cli-reference/aim_mcp/)
for `aim mcp publish`.

### Manual `mcpServers` block

For non-AIM clients, first fetch the artifacts from GitHub once, then point the
client at the cloned `server.py`:

```bash
git clone https://github.com/aws-samples/load-test-for-emr-on-eks \
  "$HOME/.cache/emr-eks-loadtest-mcp/load-test-for-emr-on-eks"
pip install -r \
  "$HOME/.cache/emr-eks-loadtest-mcp/load-test-for-emr-on-eks/loadtest_mcp/requirements.txt"
```

```json
{
  "mcpServers": {
    "emr-eks-loadtest": {
      "command": "python3",
      "args": ["/absolute/path/to/load-test-for-emr-on-eks/loadtest_mcp/server.py"]
    }
  }
}
```

The server uses its own checkout for the load-test artifacts, so no extra `env`
is needed. Override resolution with the variables documented
[above](#registration) if desired, e.g.:

```json
{
  "mcpServers": {
    "emr-eks-loadtest": {
      "command": "python3",
      "args": ["/absolute/path/to/loadtest_mcp/server.py"],
      "env": {
        "LOADTEST_REPO_BRANCH": "main",
        "LOADTEST_CACHE_DIR": "/absolute/path/to/cache"
      }
    }
  }
}
```

Equivalent Claude Code CLI form:

```bash
claude mcp add emr-eks-loadtest \
  -- python3 /absolute/path/to/load-test-for-emr-on-eks/loadtest_mcp/server.py
```

## Tools

### AWS profile

The account and region are derived entirely from the active AWS profile —
nothing is hardcoded. Confirm (and if needed switch) the profile **before**
anything else.

| Tool | Description | Parameters |
| --- | --- | --- |
| `get_aws_profile` | Show the active AWS profile and the identity (account, ARN) and region it resolves to; also lists the locally configured profiles. Reports an error if credentials are missing/expired so you can switch with `set_aws_profile`. | none |
| `set_aws_profile` | Validate that the named profile has working credentials, then write `AWS_PROFILE` (and `AWS_REGION` from the profile's region) into `env.sh` so all downstream tools/scripts target that account/region. | `profile: str` |

### Config management

| Tool | Description | Parameters |
| --- | --- | --- |
| `sync_repo` | Ensure the load-test artifacts are present, cloning them from the GitHub repo if no checkout is found (`update=True` to `git pull` a managed clone). | `update: bool = False` |
| `get_env` | Return the resolved load-test environment by sourcing `env.sh` (shows effective values including `ACCOUNT_ID` derived via command substitution). Clones the repo from GitHub first if needed. | none |
| `set_env_var` | Update (or add) an exported variable in `env.sh`, editing the `export NAME=...` line in place and preserving any trailing comment. | `name: str`, `value: str` |
| `render_locust_manifest` | Render a `LocustTest` CRD manifest from `examples/load-test-template.yaml`, substituting `env.sh` values and test parameters, written to `examples/<output_name>`. | `users: int = 4`, `run_time: str = "10m"`, `spawn_rate: float = 2`, `workers: int = 2`, `job_ns_count: int = None`, `output_name: str = "load-test-rendered.yaml"` |
| `refresh_configmap` | Delete and recreate the `emr-loadtest-locustfile` ConfigMap in the `locust` namespace from `locust/locustfiles` so the operator picks up edits. | none |

### EKS cluster selection

Decide whether to **reuse** an existing EKS cluster or **create** a new one.
Only the EKS cluster is checked — virtual clusters are created fresh by each
load-test run, so they are not part of this decision.

| Tool | Description | Parameters |
| --- | --- | --- |
| `check_eks_cluster` | Check whether the EKS cluster exists (to decide reuse vs. create); reports status/version if found. Defaults to `CLUSTER_NAME` in `env.sh`. | `cluster_name: str = None` |
| `use_existing_eks_cluster` | **Reuse path.** Validate the named cluster exists, then sync `env.sh` to it: pin `CLUSTER_NAME` to it and `EKS_VERSION` to the cluster's actual Kubernetes version (derived vars follow `CLUSTER_NAME`). Skip `provision_infra`; ensure the required components already exist. | `cluster_name: str` |
| `prepare_new_eks_cluster` | **Create path.** Set `EKS_VERSION` for a new cluster (validates it looks like `major.minor`), then run `provision_infra` to create it. Set `CLUSTER_NAME` with `set_env_var` first if a custom name is wanted. | `eks_version: str = "1.35"` |

### Provisioning

| Tool | Description | Parameters |
| --- | --- | --- |
| `provision_infra` | Start `infra-provision.sh` (EKS cluster, EBS CSI, Karpenter, binpacking scheduler, Prometheus/Grafana, EMR on EKS, ECR image builds) in the background. Takes 20-40+ min; follow with `get_job_log('provision-infra')`. | none |
| `provision_locust_operator` | Install the Locust Kubernetes operator via `locust-provision.sh` (creates the IRSA role and installs the Helm chart). Runs in the background; follow with `get_job_log('provision-locust')`. | none |

### Run & monitor

| Tool | Description | Parameters |
| --- | --- | --- |
| `run_local_test` | Run a load test locally with the Locust CLI (blocking, for small smoke tests). Creates namespaces/VCs and submits EMR on EKS jobs from the local machine; caller must be a cluster admin. | `users: int = 1`, `run_time: str = "5m"`, `spawn_rate: float = 0.5`, `job_ns_count: int = 1`, `job_azs: list[str] = None`, `headless: bool = True` |
| `apply_eks_test` | Start a distributed test on EKS via `kubectl apply -f examples/<manifest>`. Pass the name produced by `render_locust_manifest` for a custom run. | `manifest: str = "load-test-template.yaml"` |
| `get_test_logs` | Tail logs from the on-EKS Locust pods in the `locust` namespace. | `component: str = "master"` (`master` or `worker`), `tail: int = 200` |
| `list_virtual_clusters` | List EMR on EKS virtual clusters for the configured EKS cluster via `aws emr-containers list-virtual-clusters`. | `state: str = "RUNNING"` |
| `get_job_runs` | List EMR on EKS job runs in a virtual cluster, summarized by state. Use `list_virtual_clusters` to find the id. | `virtual_cluster_id: str`, `states: list[str] = None` (defaults to PENDING, SUBMITTED, RUNNING, COMPLETED, FAILED) |
| `get_grafana_login` | Print the Grafana dashboard URL and admin credentials, read from the `prometheus-grafana` ingress and admin-password secret in the `prometheus` namespace. | none |

### Cleanup

| Tool | Description | Parameters |
| --- | --- | --- |
| `stop_test` | Cancel EMR jobs and delete virtual clusters via `stop_test.py`. With `test_id`, only that session's VCs are torn down; without it, all RUNNING VCs on the configured cluster are cancelled and deleted. Blocks until VCs terminate. | `test_id: str = None` |
| `delete_test_namespaces` | Delete leftover load-test namespaces matching `emr`. Run `stop_test` first to ensure jobs/VCs are terminated. | none |
| `teardown_infra` | **DESTRUCTIVE.** Tear down all infra created by `infra-provision.sh` via `clean-up.sh` (EKS cluster, EMR on EKS, Karpenter, IAM roles/policies, etc.). Runs in the background; follow with `get_job_log('teardown-infra')`. | none |

### Background jobs

| Tool | Description | Parameters |
| --- | --- | --- |
| `get_job_log` | Tail the log of a background job (`provision-infra`, `provision-locust`, `teardown-infra`) and report whether it is still running. | `job_id: str`, `tail: int = 200` |
| `list_background_jobs` | List all background jobs started by this server with their run state. | none |

## Typical workflow

1. `get_aws_profile` — confirm the active profile resolves to the correct
   account and region (everything is derived from it; nothing is hardcoded).
2. `set_aws_profile` *(if wrong)* — switch to the right profile; this writes
   `AWS_PROFILE` and `AWS_REGION` into `env.sh`.
3. `sync_repo` — fetch the load-test artifacts from GitHub (auto-runs on the
   first tool that needs them; call explicitly with `update=True` to refresh).
4. `get_env` — confirm what the tools will target.
5. `check_eks_cluster` — decide reuse vs. create, then pick one path:
   - **Reuse:** `use_existing_eks_cluster` — pin `env.sh` to the existing
     cluster and skip `provision_infra` (ensure required components exist).
   - **Create:** `prepare_new_eks_cluster` (set `EKS_VERSION`, default `1.35`),
     then `provision_infra` — runs in the background; poll with
     `get_job_log('provision-infra')` until finished (20-40+ min).
6. `set_env_var` *(optional)* — adjust `CLUSTER_NAME`, `EMR_IMAGE_VERSION`,
   `SPARK_JOB_NS_NUM`, etc. before provisioning.
7. `provision_locust_operator` — install the Locust operator; poll with
   `get_job_log('provision-locust')`.
8. `refresh_configmap` — push the latest `emr-job-run.sh` / `locustfile.py`
   into the `emr-loadtest-locustfile` ConfigMap.
9. `render_locust_manifest` — render a customized `LocustTest` manifest.
10. `apply_eks_test` — apply the rendered manifest to start a distributed test.
11. `get_test_logs` / `list_virtual_clusters` / `get_job_runs` — monitor
    progress and EMR job/VC state.
12. `get_grafana_login` — open the dashboards to evaluate results.
13. `stop_test` — cancel jobs and delete VCs when the run is done (do this
    before a new test to avoid stale stats).
14. `delete_test_namespaces` — remove leftover `emr-*` namespaces.
15. `teardown_infra` — tear everything down; poll with
    `get_job_log('teardown-infra')`.

## Notes / caveats

- **Account/region come from the AWS profile.** `env.sh` begins with
  `AWS_PROFILE` (defaults to `default`), derives `AWS_REGION` from that
  profile's configured region, and resolves `ACCOUNT_ID` via
  `aws sts get-caller-identity`. All three are overridable via the environment,
  but none are hardcoded — confirm them with `get_aws_profile` / `get_env` and
  switch with `set_aws_profile` before provisioning.
- **`EKS_VERSION` defaults to `1.35`** and is overridable via the environment;
  `prepare_new_eks_cluster` sets it for a new cluster, and
  `use_existing_eks_cluster` pins it to the existing cluster's actual version.
- **Long-running scripts run in the background.** `provision_infra`,
  `provision_locust_operator`, and `teardown_infra` return immediately and
  stream output to a log file under `LOADTEST_RUN_DIR` (default
  `loadtest_mcp/.runs`). Follow them with `get_job_log` and list them with
  `list_background_jobs`.
- **Destructive operations.** `teardown_infra` deletes the EKS cluster and all
  provisioned AWS resources; `delete_test_namespaces` and `stop_test` remove
  namespaces / cancel jobs / delete virtual clusters. Use them carefully and
  confirm the target environment with `get_env` first.
- **Thin wrappers.** The server shells out to the repo's existing, tested
  scripts and CLIs rather than reimplementing their logic, so it stays in sync
  with the automation shipped in the repo.
