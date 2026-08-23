## EMR on EKS Load-Test MCP Server

An [MCP](https://modelcontextprotocol.io/) server that automates the EMR on EKS
load-test benchmark utility. It wraps the project's existing components and exposes them as MCP tools.

The Load Test MCP will start with AWS environment auto-detection from your active AWS profile. `env.sh` resolves `ACCOUNT_ID` & `AWS_REGION` from the profile's configuration. Follow the prompt, **confirm or change your AWS Profile first** before running a load tests.

If the artifacts in this project aren't already present, the MCP server **clones them from GitHub
automatically** (via the `sync_repo` tool). So installation does not require a manual checkout — see
[Install](#install).

See the [EMR on EKS load-test guide](./README_EMR_EKS_LOADTEST.md) for the
end-to-end load-test workflow these tools automate.

## Prerequisites

The server drives the same toolchain the repo itself requires:

- eksctl is installed in latest version (>= 0.194)
```bash
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv -v /tmp/eksctl /usr/local/bin
eksctl version
```
- Update AWS CLI to the latest (requires aws cli version >= 2.36.21) on macOS. Check out the [link](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) for Linux or Windows
```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg ./AWSCLIV2.pkg -target /
aws --version
rm AWSCLIV2.pkg
```
- Install kubectl on macOS, check out the [link](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) for Linux or Windows (>= 1.31.2)
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --short --client
```
- Helm CLI (>= 3.13.2)
```bash
curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
helm version --short
```
## Quick Start — what to ask

Just talk to the GenAI assistant at your terminal in plain language. See the following examples:

- **TPC-DS scale test by default:**
  > "Run a load test"

- **Test using an existing EKS cluster:**
  > "Load test using my existing EKS cluster"

- **Perform a test for a new feature.(create your own a job run script and drop to the project dir, update JOB_SCRIPT_NAME in env.sh with your file name):**
  > "Load test my EMR on EKS job with a new feature"

- **On a brand-new cluster:**
  > "Create a new EKS cluster and run a load test"

- **Trace Spark application log in real-time:**
  > "Show me job logs"

- **Login to Grafana via provided username and password, then watch metrics on Grafan dashboards:**
  > "Login to grafana"

- **Stop load test immididately and clean up all tests' namespaces and VCs (keep EKS cluster):**
  > "Stop the test"

- **find a test unique id before stop it (2nd part of the namespace string):**
  > "what is the test session id in the namespace emr-34518fa5-20260820-ns1"

- **Stop the load test by test session id - at VC level (keep other namespaces and VCs):**
  > "Stop the test session 34518fa5"  

- **Destroy the whole test environment (final teardown):**
  > "Destroy the load test environment."   (DESTRUCTIVE: deletes the EKS cluster and all provisioned infra)

## Install

Install the package once — this puts an `emr-eks-loadtest-mcp` command on your
`PATH`, so registration needs no file paths:

```bash
pip install "git+https://github.com/aws-samples/load-test-for-emr-on-eks@load-test-mcp#subdirectory=loadtest_mcp"
```

> [!IMPORTANT]
> **Clone the MCP artifact branch** The `@load-test-mcp` above only
> controls which branch pip installs the *server* from. At runtime the server
> clones the load-test *artifacts* (`env.sh`, `locust/`, `examples/`, …) into
> its cache, and — unless told otherwise — it clones the repo's **default
> branch**, which does not contain the MCP and carries
> unrelated configs. Set `LOADTEST_REPO_BRANCH=load-test-mcp` in the server's
> environment when you register it (shown in the command below) so the
> artifacts come from the correct branch as needed. Drop it once
> `loadtest_mcp/` is merged to the default branch.

Then register with **AIM**, **Claude Code**, or **Kiro CLI** using the following command:

### AIM

```bash
toolbox install aim   # one-time; run `mwinit` first if needed

aim mcp create generic-mcp \
  --description "EMR on EKS load test MCP server supporting feature testings, load test with industry standard test framework Locust, or performance comparision between different EMR versions or configurations" \
  --id emreks-test-mcp \
  --name EmrEksLoadtestMcp \
  --run emr-eks-loadtest-mcp \
  --env LOADTEST_REPO_BRANCH=load-test-mcp \
  --execute-directly
```

Manage with `aim mcp list --installed` / `aim mcp uninstall emreks-test-mcp`.

### Claude Code

```bash
claude mcp add emr-eks-loadtest --scope user \
  -e LOADTEST_REPO_BRANCH=load-test-mcp \
  -- emr-eks-loadtest-mcp

claude # start claude code
/mcp   # list available mcp servers -> emr-eks-loadtest: ... ✔ Connected
```

Remove with the CLI `claude mcp remove emr-eks-loadtest -s user`.

### Kiro CLI

Kiro CLI loads MCP servers installed via AIM. Install the AIM CLI and register
the server (same as the [AIM](#aim) step above):

```bash
toolbox install aim   # one-time; run `mwinit` first if needed
# register the local generic-mcp as shown in the AIM section above
```

Then use it from Kiro CLI:

```bash
kiro-cli            # start Kiro CLI
/tools              # list available tools (emr-eks-loadtest tools appear here)
```

Or configure it directly without AIM by adding the server to
`~/.kiro/settings/mcp.json` (global) and restarting Kiro CLI:

```jsonc
{
  "mcpServers": {
    "emr-eks-loadtest": {
      "command": "emr-eks-loadtest-mcp",
      "args": [],
      "env": { "LOADTEST_REPO_BRANCH": "load-test-mcp" }
    }
  }
}
```

<details>
<summary>Advanced options</summary>

- **Develop against a clone (editable install, recommended for hacking on the
  server):** install the package as an isolated tool from your clone. This puts
  a stable `emr-eks-loadtest-mcp` on your `PATH` that reads source live from the
  clone, so registration needs no in-repo `.venv` path and your `server.py` edits
  take effect immediately:
  ```bash
  uv tool install --editable /path/to/load-test-for-emr-on-eks/loadtest_mcp
  # then register the bare command (no file paths):
  claude mcp add emr-eks-loadtest --scope user -- emr-eks-loadtest-mcp
  ```
  Update with `uv tool upgrade emr-eks-loadtest-mcp`; remove with
  `uv tool uninstall emr-eks-loadtest-mcp`. (pipx works the same:
  `pipx install --editable ./loadtest_mcp`.)
- **Avoid pointing the command at an in-repo `.venv` interpreter** (e.g.
  `command: ".../load-test-for-emr-on-eks/.venv/bin/python"`). That venv is
  gitignored and absent on fresh clones, so the server fails with
  `No such file or directory: .../.venv/bin/python`. Prefer the bare
  `emr-eks-loadtest-mcp` command above.
- **No clone or artifacts needed:** the server clones the load-test artifacts
  from GitHub on first use; the bare `emr-eks-loadtest-mcp` command above already
  works standalone.
- **Manual JSON** (instead of `claude mcp add`): add to `~/.claude.json` (user) or
  `.mcp.json` (project), then run `/mcp` to load it:
  ```jsonc
  { "mcpServers": { "emr-eks-loadtest": {
      "type": "stdio", "command": "emr-eks-loadtest-mcp", "args": [],
      "env": { "LOADTEST_REPO_BRANCH": "load-test-mcp" } } } }
  ```
- **Env vars** (all optional): `LOADTEST_REPO_URL`, `LOADTEST_REPO_BRANCH`,
  `LOADTEST_REPO_ROOT`, `LOADTEST_CACHE_DIR` (default `~/.cache/emr-eks-loadtest-mcp`),
  `LOADTEST_RUN_DIR`.
  - `LOADTEST_REPO_BRANCH` selects the branch the server clones the load-test
    artifacts from (passed to `git clone --branch`). **Empty means the repo's
    default branch (`customer-ws`)**, which lacks `loadtest_mcp/` — set it to
    `load-test-mcp` (as every registration command above does) until that
    directory is merged to the default branch. If artifacts were already cloned
    to the wrong branch, delete the cache dir (`LOADTEST_CACHE_DIR`, default
    `~/.cache/emr-eks-loadtest-mcp`) so the next run re-clones.

</details>

## Automated Tools

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
| `prepare_new_eks_cluster` | **Create path.** Configure `env.sh` for a new cluster — set `EKS_VERSION` (validated `major.minor`), and optionally the cluster name and Karpenter version — then run `provision_infra` to create it. | `eks_version: str = "1.35"`, `cluster_name: str = None`, `karpenter_version: str = None` |

### Provisioning

| Tool | Description | Parameters |
| --- | --- | --- |
| `provision_infra` | Start `infra-provision.sh` (EKS cluster, EBS CSI, Karpenter, native kube-scheduler binpacking config, Prometheus/Grafana, EMR on EKS, ECR image builds) in the background. Takes 20-40+ min; follow with `get_job_log('provision-infra')`. | none |
| `provision_locust_operator` | Install the Locust Kubernetes operator via `locust-provision.sh` (creates the IRSA role and installs the Helm chart). Runs in the background; follow with `get_job_log('provision-locust')`. | none |

### Run & monitor

| Tool | Description | Parameters |
| --- | --- | --- |
| `run_local_test` | Run a load test locally with the Locust CLI (blocking, for small smoke tests). Creates namespaces/VCs and submits EMR on EKS jobs from the local machine; caller must be a cluster admin. | `users: int = 1`, `run_time: str = "5m"`, `spawn_rate: float = 0.5`, `job_ns_count: int = 1`, `job_azs: list[str] = None`, `headless: bool = True` |
| `apply_eks_test` | Start a distributed test on EKS via `kubectl apply -f examples/<manifest>`. Pass the name produced by `render_locust_manifest` for a custom run. Refuses to launch while leftover `emr-*-ns*` namespaces / RUNNING virtual clusters from a previous test exist — ask the user, then re-call with `cleanup_previous=True` (runs `stop_test` + `delete_test_namespaces` first) or `False` (start anyway). | `manifest: str = "load-test-template.yaml"`, `refresh_configmap: bool = True`, `cleanup_previous: bool = None` |
| `get_test_logs` | Tail logs from the on-EKS Locust pods in the `locust` namespace. | `component: str = "master"` (`master` or `worker`), `tail: int = 200` |
| `list_virtual_clusters` | List EMR on EKS virtual clusters for the configured EKS cluster via `aws emr-containers list-virtual-clusters`. | `state: str = "RUNNING"` |
| `get_job_runs` | List EMR on EKS job runs in a virtual cluster, summarized by state. Use `list_virtual_clusters` to find the id. | `virtual_cluster_id: str`, `states: list[str] = None` (defaults to PENDING, SUBMITTED, RUNNING, COMPLETED, FAILED) |
| `get_grafana_login` | Print the Grafana dashboard URL and admin credentials, read from the `prometheus-grafana` ingress and admin-password secret in the `prometheus` namespace. | none |

### Cleanup

| Tool | Description | Parameters |
| --- | --- | --- |
| `stop_test` | Cancel EMR jobs and delete virtual clusters via `stop_test.py`. With `test_id`, only that session's VCs are torn down; without it, all RUNNING VCs on the configured cluster are cancelled and deleted. Blocks until VCs terminate. | `test_id: str = None` |
| `delete_test_namespaces` | Delete leftover load-test namespaces matching `emr-*-ns*` (the load test's own `emr-<uuid8>-<date>-ns<N>` namespaces; unrelated ones such as `sagemaker-emr-containers-*` are left alone). Run `stop_test` first to ensure jobs/VCs are terminated. | none |
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
   - **Create:** `prepare_new_eks_cluster` (set `EKS_VERSION`, default
     `1.35`, and optionally `cluster_name`), then `provision_infra` — runs in
     the background; poll with `get_job_log('provision-infra')` until finished
     (20-40+ min).
6. `set_env_var` *(optional)* — adjust `CLUSTER_NAME`, `EMR_IMAGE_VERSION`,
   `SPARK_JOB_NS_NUM`, etc. before provisioning.
7. `provision_locust_operator` — install the Locust operator; poll with
   `get_job_log('provision-locust')`.
8. `refresh_configmap` — push the latest `emr-job-run.sh` / `locustfile.py`
   into the `emr-loadtest-locustfile` ConfigMap.
9. `render_locust_manifest` — render a customized `LocustTest` manifest.
10. `apply_eks_test` — apply the rendered manifest to start a distributed test.
    If a previous run left namespaces or virtual clusters behind, the tool stops
    and reports them: confirm with the user, then re-call with
    `cleanup_previous=True` to run `stop_test` + `delete_test_namespaces` first.
11. `get_test_logs` / `list_virtual_clusters` / `get_job_runs` — monitor
    progress and EMR job/VC state.
12. `get_grafana_login` — open the dashboards to evaluate results.
13. `stop_test` — cancel jobs and delete VCs when the run is done (do this
    before a new test to avoid stale stats).
14. `delete_test_namespaces` — remove leftover `emr-*-ns*` namespaces.
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
- **Production by default; opt in to gamma for internal testing.** Set
  `EMR_CONTAINERS_ENDPOINT_URL` (e.g. the non-prod
  `https://emr-containers-gamma.us-west-2.amazonaws.com`) to point the
  `emr-containers` API at a non-prod endpoint — one switch applies to both the
  boto3 client and the AWS CLI in `emr-job-run.sh`. Leave it unset for the
  default production endpoint. Requires a whitelisted AWS account.
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
