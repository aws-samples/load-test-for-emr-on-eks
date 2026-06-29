"""MCP server that automates the EMR on EKS load-test utility.

Exposes the repo's existing automation (env.sh, infra-provision.sh,
locust-provision.sh, the Locust CLI / LocustTest CRD, stop_test.py and
clean-up.sh) as MCP tools grouped into four areas:

  * Run & monitor  -- start/stop tests, tail logs, query EMR job / VC state
  * Provisioning   -- create the EKS cluster + components and Locust operator
  * Config         -- read/update env.sh, render the LocustTest manifest, refresh
                      the locustfile ConfigMap
  * Cleanup        -- cancel jobs, delete VCs/namespaces, tear down infra

All tools shell out to the tested scripts/CLIs via helpers.py rather than
re-implementing logic, so the server tracks the repo as it evolves.
"""

from __future__ import annotations

import json
import re
import shlex
import sys
from pathlib import Path
from typing import Optional

# Ensure this server's own directory is importable regardless of the working
# directory the MCP client (e.g. AIM / Kiro) launches us from, so `import
# helpers` resolves the sibling module rather than failing or picking up an
# unrelated package.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from mcp.server.fastmcp import FastMCP

import helpers
from helpers import (
    ENV_SH,
    EXAMPLES_DIR,
    LOCUST_DIR,
    LOCUSTFILE,
    REPO_ROOT,
    REPO_URL,
    run,
)

mcp = FastMCP("emr-eks-loadtest")

LOCUST_NAMESPACE = "locust"
CONFIGMAP_NAME = "emr-loadtest-locustfile"


def _resolve_region(env: dict) -> Optional[str]:
    """Region from env.sh (which derives it from the active profile).

    Returns None when no region is configured anywhere, so callers can fail
    loudly rather than silently targeting a hardcoded default.
    """
    return env.get("AWS_REGION") or None


# ===========================================================================
# AWS profile (must be confirmed before anything else)
# ===========================================================================
@mcp.tool()
def get_aws_profile() -> str:
    """Show the active AWS profile and the identity/region it resolves to.

    Confirm this BEFORE configuring or running a load test -- the account and
    region are derived entirely from the active AWS profile (nothing is
    hardcoded). Lists the locally configured profiles too. If credentials are
    missing or expired, this reports the error so you can switch profiles with
    ``set_aws_profile``.
    """
    profiles = helpers.aws_profiles()
    ident = helpers.aws_identity()
    lines = [f"Configured profiles: {', '.join(profiles) or '(none found)'}", ""]
    if ident["ok"]:
        lines += [
            f"Active profile: {ident['profile']}",
            f"Account:        {ident['account']}",
            f"ARN:            {ident['arn']}",
            f"Region:         {ident['region'] or '<unset>'}",
            "",
            "Confirm this is the correct account/region before proceeding. "
            "To change it, call set_aws_profile.",
        ]
    else:
        lines += [
            f"Active profile: {ident['profile']}",
            f"Region:         {ident['region'] or '<unset>'}",
            f"ERROR: could not resolve AWS identity: {ident['error']}",
            "",
            "Fix credentials (e.g. aws sso login) or pick another profile with "
            "set_aws_profile before configuring the load test.",
        ]
    return "\n".join(lines)


@mcp.tool()
def set_aws_profile(profile: str) -> str:
    """Switch to a named AWS profile and sync env.sh to its account/region.

    Validates that the profile has working credentials, then writes AWS_PROFILE
    (and AWS_REGION, from the profile's configured region) into env.sh so every
    downstream tool and script targets that profile's account/region. No
    account ID or region is hardcoded -- both come from the profile. Use this
    when ``get_aws_profile`` shows the wrong account or an auth error.
    """
    available = helpers.aws_profiles()
    if available and profile not in available:
        return (
            f"ERROR: profile {profile!r} not found. Available profiles: "
            f"{', '.join(available)}. Configure it with `aws configure "
            f"--profile {profile}` (or `aws sso login`) first."
        )
    ident = helpers.aws_identity(profile=profile)
    if not ident["ok"]:
        return (
            f"ERROR: profile {profile!r} has no working credentials: "
            f"{ident['error']}\nRun `aws sso login --profile {profile}` (or "
            "refresh keys) and try again."
        )

    msgs = [
        f"Switched to AWS profile '{profile}'.",
        f"  Account: {ident['account']}",
        f"  ARN:     {ident['arn']}",
        _write_env_var("AWS_PROFILE", profile),
    ]
    region = ident.get("region")
    if region:
        msgs.append(_write_env_var("AWS_REGION", region))
    else:
        msgs.append(
            "WARNING: profile has no default region. Set one with "
            "set_env_var('AWS_REGION', '<region>') before provisioning."
        )
    return "\n".join(msgs)


# ===========================================================================
# Config management
# ===========================================================================
@mcp.tool()
def sync_repo(update: bool = False) -> str:
    """Ensure the load-test artifacts are present, fetching them from GitHub.

    The server drives the scripts that ship in
    https://github.com/aws-samples/load-test-for-emr-on-eks (env.sh,
    infra-provision.sh, locust/, examples/, ...). If a local checkout isn't
    available, this clones the repo into the cache dir; the other tools then
    operate on it. Pass ``update=True`` to ``git pull`` a managed clone to the
    latest commit. Returns where the artifacts live.
    """
    try:
        msg = helpers.ensure_repo(update=update)
    except (RuntimeError, FileNotFoundError) as e:
        return f"ERROR: {e}"
    return f"{msg}\nRepo URL: {REPO_URL}\nRepo root: {REPO_ROOT}"


@mcp.tool()
def get_env() -> str:
    """Return the resolved load-test environment by sourcing env.sh.

    Shows the effective values of the key variables (CLUSTER_NAME, AWS_REGION,
    EMR_IMAGE_VERSION, etc.) including those derived via command substitution
    such as ACCOUNT_ID. Use this to confirm what the other tools will target.
    Fetches the repo from GitHub first if no local checkout is present.
    """
    env = helpers.load_env()
    keys = [
        "AWS_PROFILE",
        "AWS_REGION",
        "EKS_VERSION",
        "ACCOUNT_ID",
        "CLUSTER_NAME",
        "BUCKET_NAME",
        "EMR_IMAGE_VERSION",
        "SPARK_JOB_NS_NUM",
        "LOCUST_EKS_ROLE",
        "JOB_SCRIPT_NAME",
        "EXECUTION_ROLE",
        "KARPENTER_VERSION",
        "USE_AMG",
    ]
    lines = [f"Repo URL: {REPO_URL}", f"Repo root: {REPO_ROOT}", f"env.sh: {ENV_SH}", ""]
    for k in keys:
        lines.append(f"{k}={env.get(k, '<unset>')}")
    return "\n".join(lines)


def _write_env_var(name: str, value: str) -> str:
    """Update (or add) an exported variable in env.sh; return a status string.

    Shared implementation behind ``set_env_var`` and the EKS cluster-selection
    tools. Edits the ``export NAME=...`` line in place, preserving any trailing
    comment.
    """
    if not ENV_SH.exists():
        return f"ERROR: env.sh not found at {ENV_SH}"
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        return f"ERROR: invalid variable name {name!r}"

    text = ENV_SH.read_text()
    # Match an existing (optionally commented) export line for this var.
    pattern = re.compile(
        rf"^(#\s*)?export\s+{re.escape(name)}=.*$", re.MULTILINE
    )
    quoted = shlex.quote(value)
    new_line = f"export {name}={quoted}"

    if pattern.search(text):
        # Preserve a trailing comment if present on the matched line.
        def _replace(m: re.Match) -> str:
            line = m.group(0)
            comment = ""
            # keep an inline comment that follows the value (after the first =)
            after_eq = line.split("=", 1)[1] if "=" in line else ""
            cm = re.search(r"(\s+#.*)$", after_eq)
            if cm:
                comment = cm.group(1)
            return new_line + comment

        text = pattern.sub(_replace, text, count=1)
        action = "updated"
    else:
        text = text.rstrip("\n") + f"\n{new_line}\n"
        action = "added"

    ENV_SH.write_text(text)
    resolved = helpers.load_env().get(name, "<unset>")
    return f"{action} {name} in env.sh. Resolved value now: {name}={resolved}"


@mcp.tool()
def set_env_var(name: str, value: str) -> str:
    """Update (or add) an exported variable in env.sh.

    Edits the ``export NAME=...`` line in place, preserving any trailing
    comment. Use this to change CLUSTER_NAME, AWS_REGION, EMR_IMAGE_VERSION,
    SPARK_JOB_NS_NUM, etc. before provisioning or running a test.
    """
    return _write_env_var(name, value)


# ===========================================================================
# EKS cluster selection (reuse existing vs. create new)
# ===========================================================================
def _describe_eks_cluster(cluster_name: str, region: str) -> Optional[dict]:
    """Return the EKS cluster description, or None if it doesn't exist.

    Raises on unexpected AWS errors so callers can surface them distinctly
    from "not found".
    """
    result = run(
        ["aws", "eks", "describe-cluster", "--name", cluster_name,
         "--region", region, "--output", "json"],
        timeout=120,
    )
    if result.ok:
        try:
            return json.loads(result.stdout)["cluster"]
        except (json.JSONDecodeError, KeyError):
            return None
    combined = (result.stderr or "") + (result.stdout or "")
    if "ResourceNotFoundException" in combined or "No cluster found" in combined:
        return None
    # Surface non-"not found" failures (e.g. auth/region issues).
    raise RuntimeError(result.as_text())


@mcp.tool()
def check_eks_cluster(cluster_name: Optional[str] = None) -> str:
    """Check whether an EKS cluster exists, to decide reuse vs. create.

    Checks only the EKS cluster (virtual clusters are created fresh by each
    load-test run, so they are not part of this decision). Defaults to the
    CLUSTER_NAME in env.sh; pass ``cluster_name`` to probe a specific cluster.
    Reports status/version if found.
    """
    env = helpers.load_env()
    region = _resolve_region(env)
    if not region:
        return "ERROR: no AWS region configured. Run get_aws_profile / set_aws_profile first."
    name = cluster_name or env.get("CLUSTER_NAME")
    if not name:
        return "ERROR: no cluster name (set CLUSTER_NAME in env.sh or pass cluster_name)"
    try:
        cluster = _describe_eks_cluster(name, region)
    except RuntimeError as e:
        return f"ERROR checking EKS cluster {name} in {region}:\n{e}"
    if cluster is None:
        return (
            f"EKS cluster '{name}' does NOT exist in {region}.\n"
            "To create it, set the desired EKS version and run provision_infra "
            "(see prepare_new_eks_cluster)."
        )
    return (
        f"EKS cluster '{name}' EXISTS in {region}.\n"
        f"  status:  {cluster.get('status')}\n"
        f"  version: {cluster.get('version')}\n"
        f"  endpoint: {cluster.get('endpoint')}\n"
        "To reuse it for a load test, run use_existing_eks_cluster."
    )


def _kubectl_json(args: list[str]) -> Optional[dict]:
    """Run a kubectl command with -o json and return parsed JSON, or None."""
    result = run(["kubectl", *args, "-o", "json"], timeout=60)
    if not result.ok:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


@mcp.tool()
def validate_cluster_components(cluster_name: Optional[str] = None) -> str:
    """Validate that an EKS cluster has all components required for the load test.

    Connects to the cluster (updates kubeconfig) and checks each required
    component, reporting PASS/FAIL per item with details. Use this on a NEW
    cluster after provisioning, or on an EXISTING cluster before reusing it, to
    confirm it is ready. Checks:
      - Karpenter (controller Running + NodePools/EC2NodeClass Ready)
      - AWS Load Balancer Controller (deployment available)
      - gp3 StorageClass (exists; default preferred)
      - EBS CSI driver (controller Running)
      - CoreDNS with >= 3 replicas
      - Binpacking custom scheduler (custom-scheduler-eks Running)
      - Prometheus operator + built-in Grafana (Running)
    """
    env = helpers.load_env()
    region = _resolve_region(env)
    if not region:
        return "ERROR: no AWS region configured. Run get_aws_profile / set_aws_profile first."
    name = cluster_name or env.get("CLUSTER_NAME")
    if not name:
        return "ERROR: no cluster name (set CLUSTER_NAME in env.sh or pass cluster_name)"

    # Confirm the cluster exists, then point kubeconfig at it.
    try:
        cluster = _describe_eks_cluster(name, region)
    except RuntimeError as e:
        return f"ERROR checking EKS cluster {name} in {region}:\n{e}"
    if cluster is None:
        return f"EKS cluster '{name}' does NOT exist in {region}. Create it first (provision_infra)."
    kube = run(["aws", "eks", "update-kubeconfig", "--name", name, "--region", region], timeout=120)
    if not kube.ok:
        return f"ERROR connecting kubectl to {name}:\n{kube.as_text()}"

    results: list[tuple[str, bool, str]] = []

    def add(component: str, ok: bool, detail: str) -> None:
        results.append((component, ok, detail))

    # -- Karpenter: controller pods + NodePools + EC2NodeClasses Ready --
    kp = _kubectl_json(["get", "pods", "-n", "kube-system", "-l", "app.kubernetes.io/name=karpenter"])
    kp_running = bool(kp and kp.get("items") and all(
        p.get("status", {}).get("phase") == "Running" for p in kp["items"]))
    nps = _kubectl_json(["get", "nodepools.karpenter.sh"])
    np_items = (nps or {}).get("items", [])
    np_ready = bool(np_items) and all(
        any(c.get("type") == "Ready" and c.get("status") == "True"
            for c in n.get("status", {}).get("conditions", []))
        for n in np_items)
    ncs = _kubectl_json(["get", "ec2nodeclasses.karpenter.k8s.aws"])
    nc_items = (ncs or {}).get("items", [])
    nc_ready = bool(nc_items) and all(
        any(c.get("type") == "Ready" and c.get("status") == "True"
            for c in c2.get("status", {}).get("conditions", []))
        for c2 in nc_items)
    if nps is None:
        add("Karpenter", False, "NodePool CRD not installed (Karpenter not deployed)")
    else:
        np_names = ", ".join(n["metadata"]["name"] for n in np_items) or "none"
        add("Karpenter", kp_running and np_ready and nc_ready,
            f"controller running={kp_running}; nodepools=[{np_names}] ready={np_ready}; "
            f"ec2nodeclasses ready={nc_ready}")

    # -- AWS Load Balancer Controller --
    lbc = _kubectl_json(["get", "deployment", "aws-load-balancer-controller", "-n", "kube-system"])
    lbc_avail = bool(lbc) and (lbc.get("status", {}).get("availableReplicas", 0) or 0) >= 1
    add("AWS Load Balancer Controller", lbc_avail,
        f"availableReplicas={(lbc or {}).get('status', {}).get('availableReplicas', 0)}"
        if lbc else "deployment not found")

    # -- gp3 StorageClass (exists; default preferred) --
    scs = _kubectl_json(["get", "storageclass"])
    gp3 = next((s for s in (scs or {}).get("items", [])
                if s["metadata"]["name"] == "gp3"), None)
    gp3_default = bool(gp3) and gp3["metadata"].get("annotations", {}).get(
        "storageclass.kubernetes.io/is-default-class") == "true"
    add("gp3 StorageClass", bool(gp3),
        f"present; default={gp3_default}" if gp3 else "gp3 StorageClass not found")

    # -- EBS CSI driver --
    ebs = _kubectl_json(["get", "pods", "-n", "kube-system", "-l", "app=ebs-csi-controller"])
    ebs_ok = bool(ebs and ebs.get("items")) and any(
        p.get("status", {}).get("phase") == "Running" for p in ebs["items"])
    add("EBS CSI driver", ebs_ok,
        f"controller pods running={sum(1 for p in (ebs or {}).get('items', []) if p.get('status',{}).get('phase')=='Running')}"
        if ebs else "ebs-csi-controller not found")

    # -- CoreDNS with >= 3 replicas --
    dns = _kubectl_json(["get", "deployment", "coredns", "-n", "kube-system"])
    dns_ready = (dns or {}).get("status", {}).get("readyReplicas", 0) or 0
    add("CoreDNS (>=3 replicas)", bool(dns) and dns_ready >= 3,
        f"readyReplicas={dns_ready}" if dns else "coredns deployment not found")

    # -- Binpacking custom scheduler --
    bp = _kubectl_json(["get", "pods", "-n", "kube-system", "-l", "app=custom-scheduler-eks"])
    bp_items = (bp or {}).get("items", [])
    if not bp_items:  # fall back to a name match if the label differs
        allpods = _kubectl_json(["get", "pods", "-n", "kube-system"])
        bp_items = [p for p in (allpods or {}).get("items", [])
                    if "custom-scheduler" in p["metadata"]["name"]]
    bp_ok = bool(bp_items) and any(p.get("status", {}).get("phase") == "Running" for p in bp_items)
    add("Binpacking scheduler", bp_ok,
        "custom-scheduler-eks running" if bp_ok else "custom-scheduler-eks not found/not running")

    # -- Prometheus operator + built-in Grafana --
    promns = "prometheus"
    # kube-prometheus-stack labels the operator with component=prometheus-operator
    # (the app.kubernetes.io/name varies by chart, e.g.
    # kube-prometheus-stack-prometheus-operator), so select on component.
    prom = _kubectl_json(["get", "pods", "-n", promns, "-l",
                          "app.kubernetes.io/component=prometheus-operator"])
    prom_ok = bool(prom and prom.get("items")) and any(
        p.get("status", {}).get("phase") == "Running" for p in prom["items"])
    add("Prometheus operator", prom_ok,
        "running in ns 'prometheus'" if prom_ok else "prometheus-operator not found in ns 'prometheus'")
    graf = _kubectl_json(["get", "deployment", "prometheus-grafana", "-n", promns])
    graf_ok = bool(graf) and (graf.get("status", {}).get("availableReplicas", 0) or 0) >= 1
    add("Grafana (built-in)", graf_ok,
        f"availableReplicas={(graf or {}).get('status', {}).get('availableReplicas', 0)}"
        if graf else "prometheus-grafana deployment not found")

    passed = sum(1 for _, ok, _ in results if ok)
    total = len(results)
    lines = [f"Cluster '{name}' ({region}) component validation: {passed}/{total} passed", ""]
    for component, ok, detail in results:
        lines.append(f"  [{'PASS' if ok else 'FAIL'}] {component} — {detail}")
    if passed < total:
        lines.append("")
        lines.append("Some components are missing/not ready. For a new cluster, (re)run "
                     "provision_infra; for an existing cluster, install the missing pieces "
                     "before running the load test.")
    return "\n".join(lines)


def _valid_cluster_name(name: str) -> bool:
    """EKS cluster name rules: letters/digits/hyphens, start alnum, <=100 chars."""
    return bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,99}", name))


@mcp.tool()
def set_cluster_name(cluster_name: str) -> str:
    """Set the EKS cluster name in env.sh from user input.

    Use this to name the cluster the load test targets -- a NEW cluster to
    create, or simply to point env.sh at an existing one. Validates the name
    against EKS naming rules. Derived variables (BUCKET_NAME, LOCUST_EKS_ROLE,
    EXECUTION_ROLE, Karpenter roles, ...) follow CLUSTER_NAME automatically.
    For reuse, prefer use_existing_eks_cluster which also verifies the cluster
    exists and syncs the EKS version.
    """
    name = cluster_name.strip()
    if not _valid_cluster_name(name):
        return (
            f"ERROR: invalid cluster name {cluster_name!r}. Use letters, digits "
            "and hyphens, starting with a letter or digit (max 100 chars)."
        )
    msg = _write_env_var("CLUSTER_NAME", name)
    env = helpers.load_env()
    return (
        f"{msg}\n"
        f"Derived: BUCKET_NAME={env.get('BUCKET_NAME')}, "
        f"EXECUTION_ROLE={env.get('EXECUTION_ROLE')}"
    )


@mcp.tool()
def use_existing_eks_cluster(cluster_name: str) -> str:
    """Reuse an existing EKS cluster: validate it and sync env configs to it.

    Verifies the named cluster exists in the configured region, then updates
    env.sh so the load test targets it: pins CLUSTER_NAME to the given name and
    EKS_VERSION to the cluster's actual Kubernetes version. The derived
    variables (BUCKET_NAME, LOCUST_EKS_ROLE, EXECUTION_ROLE, ...) follow
    CLUSTER_NAME automatically. Run this after the user picks the reuse path.
    """
    env = helpers.load_env()
    region = _resolve_region(env)
    if not region:
        return "ERROR: no AWS region configured. Run get_aws_profile / set_aws_profile first."
    try:
        cluster = _describe_eks_cluster(cluster_name, region)
    except RuntimeError as e:
        return f"ERROR checking EKS cluster {cluster_name} in {region}:\n{e}"
    if cluster is None:
        return (
            f"ERROR: EKS cluster '{cluster_name}' does NOT exist in {region}. "
            "Cannot reuse a non-existent cluster. Use prepare_new_eks_cluster "
            "to create one, or check the name/region."
        )

    msgs = [f"Reusing existing EKS cluster '{cluster_name}' ({region}).",
            _write_env_var("CLUSTER_NAME", cluster_name)]
    version = cluster.get("version")
    if version:
        msgs.append(_write_env_var("EKS_VERSION", str(version)))
    msgs.append(
        "Skip provision_infra. Ensure the cluster already has the required "
        "components (Karpenter, EMR on EKS, monitoring, Locust operator) before "
        "running a test; install any missing pieces individually."
    )
    return "\n".join(msgs)


@mcp.tool()
def prepare_new_eks_cluster(
    eks_version: str = "1.35",
    cluster_name: Optional[str] = None,
    karpenter_version: Optional[str] = None,
) -> str:
    """Configure env.sh to create a NEW EKS cluster at the chosen version.

    Sets EKS_VERSION to the user's preferred Kubernetes version (defaults to
    "1.35"). Optionally sets the cluster name (``cluster_name`` -- the user's
    desired name for the new cluster) and the Karpenter version
    (``karpenter_version``, defaults to env.sh's 1.8.5 if omitted). Derived
    variables follow CLUSTER_NAME automatically. After this, call
    provision_infra to actually create the cluster and all components. Run this
    after the user picks the create path and provides their preferences.
    """
    if not re.fullmatch(r"\d+\.\d+", eks_version.strip()):
        return (
            f"ERROR: EKS version {eks_version!r} should look like '1.35'. "
            "Provide a major.minor Kubernetes version."
        )
    if cluster_name is not None and not _valid_cluster_name(cluster_name.strip()):
        return (
            f"ERROR: invalid cluster name {cluster_name!r}. Use letters, digits "
            "and hyphens, starting with a letter or digit (max 100 chars)."
        )
    if karpenter_version is not None and not re.fullmatch(r"\d+\.\d+\.\d+", karpenter_version.strip()):
        return (
            f"ERROR: Karpenter version {karpenter_version!r} should look like "
            "'1.8.5' (major.minor.patch)."
        )

    msgs = ["Configured to create a new EKS cluster.",
            _write_env_var("EKS_VERSION", eks_version.strip())]
    if cluster_name is not None:
        msgs.append(_write_env_var("CLUSTER_NAME", cluster_name.strip()))
    if karpenter_version is not None:
        msgs.append(_write_env_var("KARPENTER_VERSION", karpenter_version.strip()))
    env = helpers.load_env()
    msgs += [
        f"Target cluster name: {env.get('CLUSTER_NAME')}",
        f"Region: {env.get('AWS_REGION')}",
        f"Karpenter version: {env.get('KARPENTER_VERSION')}",
        "Next: run provision_infra to create the cluster and components "
        "(~20-40+ min, creates real AWS resources).",
    ]
    return "\n".join(msgs)


@mcp.tool()
def render_locust_manifest(
    users: int = 4,
    run_time: str = "10m",
    spawn_rate: float = 2,
    workers: int = 2,
    job_ns_count: Optional[int] = None,
    output_name: str = "load-test-rendered.yaml",
) -> str:
    """Render a LocustTest CRD manifest from examples/load-test-template.yaml.

    Substitutes env.sh values (REGION, CLUSTER_NAME, ECR_URL, EMR_IMAGE_VERSION,
    JOB_SCRIPT_NAME, SPARK_JOB_NS_NUM) and the supplied test parameters, writing
    the result to ``examples/<output_name>``. Apply it later with
    ``apply_eks_test``.
    """
    template = EXAMPLES_DIR / "load-test-template.yaml"
    if not template.exists():
        return f"ERROR: template not found at {template}"

    env = helpers.load_env()
    region = _resolve_region(env)
    if not region:
        return "ERROR: no AWS region configured. Run get_aws_profile / set_aws_profile first."
    account_id = env.get("ACCOUNT_ID", "")
    ecr_url = f"{account_id}.dkr.ecr.{region}.amazonaws.com"
    ns_count = str(job_ns_count if job_ns_count is not None else env.get("SPARK_JOB_NS_NUM", "2"))

    text = template.read_text()
    subs = {
        "REGION": region,
        "CLUSTER_NAME": env.get("CLUSTER_NAME", ""),
        "ECR_URL": ecr_url,
        "EMR_IMAGE_VERSION": env.get("EMR_IMAGE_VERSION", "7.9.0"),
        "JOB_SCRIPT_NAME": env.get("JOB_SCRIPT_NAME", "emr-job-run.sh"),
        "SPARK_JOB_NS_NUM": ns_count,
        # emr-containers endpoint (prod region-derived, or gamma when set) so the
        # on-EKS worker pods target the same endpoint as local runs.
        "EMR_CONTAINERS_ENDPOINT_URL": env.get(
            "EMR_CONTAINERS_ENDPOINT_URL", f"https://emr-containers.{region}.amazonaws.com"),
    }
    for key, val in subs.items():
        text = text.replace(f"${{{key}}}", val)

    # Override the test parameters baked into the template's args block.
    text = re.sub(r"--run-time=\S+", f"--run-time={run_time}", text)
    text = re.sub(r"--users=\S+", f"--users={users}", text)
    text = re.sub(r"--spawn-rate=\S+", f"--spawn-rate={spawn_rate}", text)
    text = re.sub(r"^(\s*)workers:\s*\d+", rf"\g<1>workers: {workers}", text, flags=re.MULTILINE)

    out_path = EXAMPLES_DIR / output_name
    out_path.write_text(text)
    return f"Rendered manifest written to {out_path}\n\n{text}"


@mcp.tool()
def refresh_configmap() -> str:
    """Recreate the locustfile ConfigMap from locust/locustfiles.

    Deletes and recreates ``emr-loadtest-locustfile`` in the ``locust``
    namespace so the Locust operator picks up edits to emr-job-run.sh /
    locustfile.py. Required before re-running an on-EKS test after changing
    the job script.
    """
    files_dir = LOCUST_DIR / "locustfiles"
    if not files_dir.exists():
        return f"ERROR: {files_dir} not found"

    run(
        ["kubectl", "delete", "configmap", CONFIGMAP_NAME, "-n", LOCUST_NAMESPACE,
         "--ignore-not-found"],
        timeout=120,
    )
    create = run(
        ["kubectl", "create", "configmap", CONFIGMAP_NAME, "-n", LOCUST_NAMESPACE,
         f"--from-file={files_dir}"],
        timeout=120,
    )
    return create.as_text()


# ===========================================================================
# Provisioning
# ===========================================================================
@mcp.tool()
def provision_infra() -> str:
    """Provision the EKS cluster and all components via infra-provision.sh.

    Starts the long-running ``infra-provision.sh`` (EKS cluster, EBS CSI,
    Karpenter, binpacking scheduler, Prometheus/Grafana, EMR on EKS, and builds
    the Spark + Locust ECR images) in the background. This can take 20-40+
    minutes. Follow progress with ``get_job_log('provision-infra')``.
    """
    script = REPO_ROOT / "infra-provision.sh"
    if not script.exists():
        return f"ERROR: {script} not found"
    job = helpers.start_background(
        ["bash", str(script)],
        job_id="provision-infra",
    )
    return (
        f"Started infra provisioning (pid {job.pid}).\n"
        f"Log: {job.log_path}\n"
        "Use get_job_log('provision-infra') to follow progress (20-40+ min)."
    )


@mcp.tool()
def provision_locust_operator() -> str:
    """Install the Locust Kubernetes operator via locust-provision.sh.

    Creates the Locust IRSA role and installs the operator Helm chart. Runs in
    the background; follow with ``get_job_log('provision-locust')``. Run this
    after the EKS cluster exists.
    """
    script = REPO_ROOT / "locust-provision.sh"
    if not script.exists():
        return f"ERROR: {script} not found"
    job = helpers.start_background(
        ["bash", str(script)],
        job_id="provision-locust",
    )
    return (
        f"Started Locust operator provisioning (pid {job.pid}).\n"
        f"Log: {job.log_path}\n"
        "Use get_job_log('provision-locust') to follow progress."
    )


# ===========================================================================
# Run & monitor
# ===========================================================================
@mcp.tool()
def run_local_test(
    users: int = 1,
    run_time: str = "5m",
    spawn_rate: float = 0.5,
    job_ns_count: int = 1,
    job_azs: Optional[list[str]] = None,
    headless: bool = True,
) -> str:
    """Run a load test locally with the Locust CLI (blocking, for small tests).

    Wraps ``locust -f locust/locustfiles/locustfile.py``. Creates the
    namespaces/virtual clusters and submits EMR on EKS jobs from the local
    machine. The caller must be a cluster admin. Suitable for short smoke tests;
    for large/long runs use ``apply_eks_test`` instead.

    job_azs: e.g. ["us-west-2a", "us-west-2b"]; if omitted, pods may span AZs.
    """
    if not LOCUSTFILE.exists():
        return f"ERROR: locustfile not found at {LOCUSTFILE}"

    # Invoke locust via the server's own interpreter (`python -m locust`) so it
    # resolves from the same venv regardless of PATH (bare `locust` may not be
    # on the MCP server process's PATH).
    args = [
        sys.executable, "-m", "locust", "-f", str(LOCUSTFILE),
        f"--run-time={run_time}",
        f"--users={users}",
        f"--spawn-rate={spawn_rate}",
        "--job-ns-count", str(job_ns_count),
        "--skip-log-setup",
    ]
    if job_azs:
        args += ["--job-azs", json.dumps(job_azs)]
    if headless:
        args.append("--headless")

    # locustfile.py imports lib.* relatively, so run from the locustfiles dir.
    result = run(
        args,
        cwd=LOCUSTFILE.parent,
        timeout=_run_time_to_seconds(run_time) + 600,
    )
    return result.as_text()


@mcp.tool()
def apply_eks_test(manifest: str = "load-test-template.yaml") -> str:
    """Start a distributed load test on EKS by applying a LocustTest manifest.

    ``kubectl apply -f examples/<manifest>``. Defaults to the template; pass the
    name produced by ``render_locust_manifest`` for a customized run. Remember
    to ``refresh_configmap`` first if the job script changed.
    """
    path = (EXAMPLES_DIR / manifest) if not Path(manifest).is_absolute() else Path(manifest)
    if not path.exists():
        return f"ERROR: manifest not found at {path}"
    result = run(["kubectl", "apply", "-f", str(path)], timeout=120)
    return result.as_text()


@mcp.tool()
def get_test_logs(component: str = "master", tail: int = 200) -> str:
    """Tail logs from the on-EKS Locust pods.

    component: 'master' for aggregated load-test metrics, 'worker' for
    per-job submission status. Reads the ``locust`` namespace.
    """
    if component not in ("master", "worker"):
        return "ERROR: component must be 'master' or 'worker'"
    result = run(
        ["kubectl", "logs", "-n", LOCUST_NAMESPACE,
         "-l", f"locust.cloud/component={component}",
         "--tail", str(tail), "--prefix"],
        timeout=120,
    )
    return result.as_text()


@mcp.tool()
def list_virtual_clusters(state: str = "RUNNING") -> str:
    """List EMR on EKS virtual clusters for the configured EKS cluster.

    Uses ``aws emr-containers list-virtual-clusters`` filtered to the cluster in
    env.sh. state: RUNNING (default), TERMINATED, etc.
    """
    env = helpers.load_env()
    cluster = env.get("CLUSTER_NAME")
    region = _resolve_region(env)
    if not region:
        return "ERROR: no AWS region configured. Run get_aws_profile / set_aws_profile first."
    if not cluster:
        return "ERROR: CLUSTER_NAME not set in env.sh"
    result = run(
        ["aws", "emr-containers", "list-virtual-clusters",
         "--container-provider-id", cluster,
         "--container-provider-type", "EKS",
         "--states", state,
         "--region", region,
         "--query", "virtualClusters[].{id:id,name:name,state:state,namespace:containerProvider.info.eksInfo.namespace}",
         "--output", "table"],
        timeout=120,
    )
    return result.as_text()


@mcp.tool()
def get_job_runs(virtual_cluster_id: str, states: Optional[list[str]] = None) -> str:
    """List EMR on EKS job runs in a virtual cluster, summarized by state.

    states: subset of PENDING, SUBMITTED, RUNNING, COMPLETED, FAILED,
    CANCELLED. Defaults to the active states. Use ``list_virtual_clusters`` to
    find the virtual_cluster_id.
    """
    env = helpers.load_env()
    region = _resolve_region(env)
    if not region:
        return "ERROR: no AWS region configured. Run get_aws_profile / set_aws_profile first."
    state_list = states or ["PENDING", "SUBMITTED", "RUNNING", "COMPLETED", "FAILED"]
    result = run(
        ["aws", "emr-containers", "list-job-runs",
         "--virtual-cluster-id", virtual_cluster_id,
         "--states", *state_list,
         "--region", region,
         "--query", "jobRuns[].state",
         "--output", "json"],
        timeout=120,
    )
    if not result.ok:
        return result.as_text()
    try:
        job_states = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        return result.as_text()
    counts: dict[str, int] = {}
    for s in job_states:
        counts[s] = counts.get(s, 0) + 1
    summary = "\n".join(f"  {k}: {v}" for k, v in sorted(counts.items())) or "  (no job runs)"
    return f"Job runs in {virtual_cluster_id} (total {len(job_states)}):\n{summary}"


@mcp.tool()
def get_grafana_login() -> str:
    """Print the Grafana dashboard URL and admin credentials.

    Reads the ``prometheus-grafana`` ingress hostname and the admin password
    secret from the ``prometheus`` namespace (community Prometheus stack
    installed by infra-provision.sh).
    """
    url = run(
        ["kubectl", "get", "ingress", "prometheus-grafana", "-n", "prometheus",
         "-o", "jsonpath={.status.loadBalancer.ingress[0].hostname}"],
        timeout=60,
    )
    secret = run(
        ["bash", "-c",
         "kubectl --namespace prometheus get secrets prometheus-grafana "
         "-o jsonpath='{.data.admin-password}' | base64 -d"],
        timeout=60,
    )
    if not url.ok:
        return "ERROR fetching Grafana ingress:\n" + url.as_text()
    return (
        f"Grafana URL: http://{url.stdout.strip()}\n"
        f"User: admin\n"
        f"Password: {secret.stdout.strip() if secret.ok else '<failed to read secret>'}"
    )


# ===========================================================================
# Cleanup
# ===========================================================================
@mcp.tool()
def stop_test(test_id: Optional[str] = None) -> str:
    """Cancel EMR jobs and delete virtual clusters via stop_test.py.

    With ``test_id`` (the "emr-<id>-<date>" session prefix) only that session's
    VCs are torn down; without it, all RUNNING VCs on the configured EKS cluster
    are cancelled and deleted. Run this before starting a new test to avoid
    stale stats. Blocks until VCs are terminated.
    """
    script = LOCUST_DIR / "locustfiles" / "stop_test.py"
    if not script.exists():
        return f"ERROR: {script} not found"
    args = ["python3", str(script)]
    if test_id:
        args += ["--id", test_id]
    result = run(args, cwd=script.parent, timeout=1800)
    return result.as_text()


@mcp.tool()
def delete_test_namespaces() -> str:
    """Delete leftover load-test namespaces (those matching 'emr').

    Mirrors ``kubectl get namespaces -o name | grep emr | xargs kubectl
    delete``. Run ``stop_test`` first to ensure jobs/VCs are terminated.
    """
    listing = run(["kubectl", "get", "namespaces", "-o", "name"], timeout=120)
    if not listing.ok:
        return listing.as_text()
    namespaces = [
        line.split("/", 1)[1]
        for line in listing.stdout.splitlines()
        if "/" in line and "emr" in line.split("/", 1)[1]
    ]
    if not namespaces:
        return "No 'emr' load-test namespaces found."
    result = run(["kubectl", "delete", "namespace", *namespaces], timeout=600)
    return f"Deleting namespaces: {', '.join(namespaces)}\n\n{result.as_text()}"


@mcp.tool()
def teardown_infra() -> str:
    """Tear down all infra created by infra-provision.sh via clean-up.sh.

    DESTRUCTIVE: deletes the EKS cluster, EMR on EKS resources, Karpenter, IAM
    roles/policies, and other provisioned components. Runs in the background;
    follow with ``get_job_log('teardown-infra')``.
    """
    script = REPO_ROOT / "clean-up.sh"
    if not script.exists():
        return f"ERROR: {script} not found"
    job = helpers.start_background(["bash", str(script)], job_id="teardown-infra")
    return (
        f"Started infra teardown (pid {job.pid}).\n"
        f"Log: {job.log_path}\n"
        "Use get_job_log('teardown-infra') to follow progress."
    )


# ===========================================================================
# Background job introspection (shared by provisioning / teardown)
# ===========================================================================
@mcp.tool()
def get_job_log(job_id: str, tail: int = 200) -> str:
    """Tail the log of a background job (provision-infra, provision-locust,
    teardown-infra) and report whether it is still running."""
    try:
        status = helpers.job_status(job_id)
        log = helpers.read_job_log(job_id, tail_lines=tail)
    except FileNotFoundError as e:
        return f"ERROR: {e}"
    state = "RUNNING" if status["running"] else "FINISHED"
    return f"[{job_id}] {state} (pid {status['pid']})\n--- last {tail} lines ---\n{log}"


@mcp.tool()
def list_background_jobs() -> str:
    """List all background jobs started by this server with their run state."""
    jobs = helpers.list_jobs()
    if not jobs:
        return "No background jobs recorded."
    lines = []
    for j in jobs:
        state = "RUNNING" if j.get("running") else "FINISHED"
        lines.append(f"{j['job_id']}: {state} (pid {j.get('pid')}) -> {j.get('log')}")
    return "\n".join(lines)


def _run_time_to_seconds(run_time: str) -> int:
    """Convert a Locust run-time string (e.g. '5m', '1h30m', '90s') to seconds."""
    total = 0
    for value, unit in re.findall(r"(\d+)\s*([hms])", run_time.lower()):
        total += int(value) * {"h": 3600, "m": 60, "s": 1}[unit]
    return total or 300


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
