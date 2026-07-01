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

import functools
import json
import os
import re
import shlex
import sys
from concurrent.futures import ThreadPoolExecutor
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

mcp = FastMCP(
    "emr-eks-loadtest",
    instructions=(
        "Automates the EMR on EKS load test. ALWAYS call start_session FIRST, "
        "before any other tool, at the beginning of a load-test conversation. "
        "It reports the active AWS identity and the locally configured profiles. "
        "Then ASK THE USER which AWS target to use -- either a profile name (call "
        "set_aws_profile) or an explicit account/region they want to test "
        "against -- and confirm it with confirm_aws_profile. Do NOT assume the "
        "currently-active profile is the intended one; the user must choose. "
        "Test-affecting tools stay locked until confirm_aws_profile succeeds."
    ),
)

LOCUST_NAMESPACE = "locust"
CONFIGMAP_NAME = "emr-loadtest-locustfile"


def _require_region(env: dict) -> tuple[Optional[str], Optional[str]]:
    """Resolve the target region, returning ``(region, error)``.

    The region comes from env.sh (which derives it from the active profile);
    nothing is hardcoded. ``error`` is a ready-to-return message when no region
    is configured (``region`` is None in that case), so every region-dependent
    tool fails loudly with one shared message instead of repeating it.
    """
    region = env.get("AWS_REGION") or None
    if not region:
        return None, ("ERROR: no AWS region configured. "
                      "Run get_aws_profile / set_aws_profile first.")
    return region, None


def _require_region_and_cluster(
    env: dict, cluster_name: Optional[str] = None
) -> tuple[Optional[str], Optional[str], Optional[str]]:
    """Resolve target region + cluster name, returning ``(region, name, error)``.

    ``cluster_name`` overrides the env.sh CLUSTER_NAME when given. ``error`` is a
    ready-to-return message if either is missing (region first), with the other
    values None in that case.
    """
    region, error = _require_region(env)
    if error:
        return None, None, error
    name = cluster_name or env.get("CLUSTER_NAME")
    if not name:
        return None, None, ("ERROR: no cluster name "
                            "(set CLUSTER_NAME in env.sh or pass cluster_name)")
    return region, name, None


def _confirmation_error() -> Optional[str]:
    """Return why test-affecting tools are locked, or None if they're unlocked.

    Tools are unlocked only when the operator has confirmed the CURRENT
    account/region via ``confirm_aws_profile`` and the live identity still
    matches -- so no provisioning/run/teardown ever targets an unconfirmed (or
    since-changed) account.
    """
    ident = helpers.aws_identity()
    if not ident["ok"]:
        return (
            "ERROR: AWS credentials are not usable "
            f"(profile {ident['profile']!r}: {ident['error']}).\n"
            "Fix them (e.g. aws sso login) or switch with set_aws_profile, then "
            "confirm with confirm_aws_profile before running this."
        )
    confirmed = helpers.read_confirmed_identity()
    if not confirmed:
        return (
            "ERROR: AWS account/region not confirmed yet. This tool acts on real "
            "AWS resources, so the target must be confirmed first.\n"
            f"  Active profile: {ident['profile']}\n"
            f"  Account:        {ident['account']}\n"
            f"  Region:         {ident['region'] or '<unset>'}\n"
            "Show this to the user and, once they approve, call "
            "confirm_aws_profile(account, region) to unlock test-affecting tools."
        )
    # The recorded confirmation must still match the live identity -- guards
    # against a profile/region change after confirming.
    if (confirmed.get("account") != ident["account"]
            or (confirmed.get("region") or "") != (ident["region"] or "")):
        return (
            "ERROR: the active AWS identity changed since it was confirmed.\n"
            f"  Confirmed: account {confirmed.get('account')}, region "
            f"{confirmed.get('region') or '<unset>'}\n"
            f"  Now:       account {ident['account']}, region "
            f"{ident['region'] or '<unset>'}\n"
            "Re-confirm with confirm_aws_profile(account, region) before "
            "proceeding."
        )
    return None


def requires_confirmed_identity(func):
    """Decorator: block a test-affecting tool until the target is confirmed.

    If the account/region hasn't been confirmed (or the live identity has
    changed since), the wrapped tool returns the gate error instead of running.
    Keeps the confirmation check in one place rather than repeating it in every
    tool body.
    """
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        gate = _confirmation_error()
        if gate:
            return gate
        return func(*args, **kwargs)

    return wrapper


# ===========================================================================
# AWS profile (must be confirmed before anything else)
# ===========================================================================
@mcp.tool()
def start_session() -> str:
    """START HERE. First step of any load-test session: pick the AWS target.

    Reports the active AWS identity and lists the locally configured profiles,
    then instructs you (the agent) to ASK THE USER which AWS account/region to
    test against -- never silently reuse whatever profile happens to be active.
    The user can answer with either:
      * a profile name -> call set_aws_profile(profile), or
      * an explicit account + region -> switch to a profile that resolves to
        them (set_aws_profile), since the account/region come only from the
        active profile.
    Then call confirm_aws_profile(account, region) to unlock test-affecting
    tools. Nothing that touches real AWS resources runs until that confirmation
    succeeds.
    """
    profiles = helpers.aws_profiles()
    ident = helpers.aws_identity()
    lines = ["Load-test session start. Choose the AWS target before proceeding.", ""]
    if profiles:
        lines.append(f"Locally configured profiles: {', '.join(profiles)}")
    else:
        lines.append("No local AWS profiles found (check ~/.aws/config).")
    lines.append("")
    if ident["ok"]:
        lines += [
            "Currently active profile (NOT necessarily the one to use):",
            f"  Profile: {ident['profile']}",
            f"  Account: {ident['account']}",
            f"  Region:  {ident['region'] or '<unset>'}",
        ]
    else:
        lines += [
            f"Active profile {ident['profile']!r} has no usable credentials: "
            f"{ident['error']}",
        ]
    lines += [
        "",
        "ACTION REQUIRED: ask the user which AWS profile (or account/region) "
        "they want to test against. If they name a profile, call "
        "set_aws_profile(profile); if they give an account/region, select the "
        "matching profile. Then confirm with confirm_aws_profile(account, "
        "region) to unlock provisioning/run/teardown tools.",
    ]
    return "\n".join(lines)


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
def confirm_aws_profile(account: str, region: str) -> str:
    """Confirm the AWS account + region the load test will run against.

    This is the REQUIRED first step before any test-affecting tool
    (provision_infra, provision_locust_operator, run_local_test, apply_eks_test,
    use_existing_eks_cluster, prepare_new_eks_cluster, refresh_configmap,
    validate_iam_roles, stop_test, delete_test_namespaces, teardown_infra) will
    act. Those tools operate on real AWS resources, so the operator must
    explicitly approve the target first.

    Pass the ``account`` and ``region`` the user approved. This verifies they
    match the live identity of the active profile (so a typo or a stale profile
    can't slip through) and records the confirmation. The confirmation is
    invalidated automatically if the profile/region later changes (e.g. via
    set_aws_profile). Call get_aws_profile first to see the values to confirm.
    """
    ident = helpers.aws_identity()
    if not ident["ok"]:
        return (
            "ERROR: cannot confirm -- AWS credentials are not usable "
            f"(profile {ident['profile']!r}: {ident['error']}).\n"
            "Fix them or switch with set_aws_profile, then try again."
        )
    live_account = ident["account"]
    live_region = ident["region"] or ""
    account = account.strip()
    region = region.strip()
    if account != live_account or region != live_region:
        return (
            "ERROR: the account/region you confirmed does not match the active "
            "profile's live identity. Nothing was confirmed.\n"
            f"  You passed: account {account!r}, region {region!r}\n"
            f"  Profile {ident['profile']!r} resolves to: account "
            f"{live_account!r}, region {live_region or '<unset>'!r}\n"
            "Re-run get_aws_profile, then confirm the exact values shown (or "
            "switch profiles with set_aws_profile)."
        )
    helpers.record_confirmed_identity(live_account, live_region, ident["profile"])
    return (
        "Confirmed. Test-affecting tools are now unlocked for:\n"
        f"  Profile: {ident['profile']}\n"
        f"  Account: {live_account}\n"
        f"  Region:  {live_region}\n"
        "This confirmation is cleared automatically if the profile or region "
        "changes."
    )


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

    # Switching profiles invalidates any prior account/region confirmation, so
    # the operator must re-confirm the new target before acting on it.
    helpers.clear_confirmed_identity()

    msgs = [
        f"Switched to AWS profile '{profile}'.",
        f"  Account: {ident['account']}",
        f"  ARN:     {ident['arn']}",
        _write_env_var("AWS_PROFILE", profile),
        "Confirmation reset: call confirm_aws_profile(account, region) for this "
        "profile before running test-affecting tools.",
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
def _describe_eks_cluster(cluster_name: str, region: str,
                          base_env: Optional[dict] = None) -> Optional[dict]:
    """Return the EKS cluster description, or None if it doesn't exist.

    Raises on unexpected AWS errors so callers can surface them distinctly
    from "not found".
    """
    result = run(
        ["aws", "eks", "describe-cluster", "--name", cluster_name,
         "--region", region, "--output", "json"],
        timeout=120,
        base_env=base_env,
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
    region, name, error = _require_region_and_cluster(env, cluster_name)
    if error:
        return error
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


def _kubectl_json(args: list[str], base_env: Optional[dict] = None) -> Optional[dict]:
    """Run a kubectl command with -o json and return parsed JSON, or None."""
    result = run(["kubectl", *args, "-o", "json"], timeout=60, base_env=base_env)
    if not result.ok:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def _ecr_image_exists(repo: str, tag: str, region: str,
                      base_env: Optional[dict] = None) -> tuple[bool, str]:
    """Check whether <repo>:<tag> exists in the configured account's ECR.

    Goes through the ``run`` helper so the AWS CLI inherits AWS_PROFILE from
    env.sh and targets the SAME account the load test runs in -- never a proxy
    or ambient default. Returns (exists, detail).
    """
    result = run(
        ["aws", "ecr", "describe-images",
         "--repository-name", repo,
         "--image-ids", f"imageTag={tag}",
         "--region", region,
         "--query", "imageDetails[0].imageTags",
         "--output", "json"],
        timeout=120,
        base_env=base_env,
    )
    if result.ok:
        return True, f"{repo}:{tag} present"
    combined = (result.stderr or "") + (result.stdout or "")
    if "RepositoryNotFoundException" in combined:
        return False, f"ECR repository '{repo}' does not exist"
    if "ImageNotFoundException" in combined:
        return False, f"repository '{repo}' exists but tag '{tag}' is missing"
    # Auth/region or other errors -- surface so it isn't mistaken for "missing".
    return False, f"could not verify {repo}:{tag} -- {combined.strip()[:200]}"


def _iam_role_exists(role_name: str, base_env: Optional[dict] = None) -> tuple[bool, str]:
    """Check whether an IAM role exists in the load-test account.

    Goes through the ``run`` helper so the AWS CLI inherits AWS_PROFILE from
    env.sh and targets the SAME account the load test runs in -- never a proxy
    or ambient default. IAM is global, so no region is needed. Returns
    (exists, detail) where detail is the role ARN when present.
    """
    result = run(
        ["aws", "iam", "get-role", "--role-name", role_name,
         "--query", "Role.Arn", "--output", "text"],
        timeout=60,
        base_env=base_env,
    )
    if result.ok:
        return True, result.stdout.strip()
    combined = (result.stderr or "") + (result.stdout or "")
    if "NoSuchEntity" in combined:
        return False, f"role '{role_name}' does not exist"
    # Auth or other errors -- surface so it isn't mistaken for "missing".
    return False, f"could not verify role '{role_name}' -- {combined.strip()[:200]}"


# Required IAM roles, keyed by the env.sh variable that names them, with the
# provisioning script that creates each one. The Locust IRSA role comes from
# locust-provision.sh; the rest come from infra-provision.sh. ``validate_iam_roles``
# and ``validate_cluster_components`` use this to report what is missing and to
# route auto-provisioning to the right script.
_REQUIRED_IAM_ROLES = [
    ("EXECUTION_ROLE", "EMR on EKS job execution role", "infra"),
    ("KARPENTER_CONTROLLER_ROLE", "Karpenter controller role", "infra"),
    ("KARPENTER_NODE_ROLE", "Karpenter node role", "infra"),
    ("LOCUST_EKS_ROLE", "Locust IRSA role", "locust"),
]


def _check_iam_roles(env: dict, base_env: Optional[dict] = None) -> list[tuple[str, str, bool, str, str]]:
    """Check every required IAM role for the configured cluster.

    Returns a list of (env_var, role_name, exists, detail, source) tuples, where
    ``source`` is "infra" or "locust" -- the script that creates the role.
    """
    # Each get-role is an independent ~4.5s AWS CLI call, so look them up
    # concurrently; executor.map preserves _REQUIRED_IAM_ROLES order.
    def one(spec: tuple[str, str, str]) -> tuple[str, str, bool, str, str]:
        var, _label, source = spec
        role_name = env.get(var)
        if not role_name:
            return (var, "<unset>", False, f"{var} is not set in env.sh", source)
        ok, detail = _iam_role_exists(role_name, base_env=base_env)
        return (var, role_name, ok, detail, source)

    with ThreadPoolExecutor(max_workers=len(_REQUIRED_IAM_ROLES)) as pool:
        return list(pool.map(one, _REQUIRED_IAM_ROLES))


def _start_provision(job_id: str, script_name: str) -> str:
    """Kick off a provisioning script in the background; return a status line."""
    script = REPO_ROOT / script_name
    if not script.exists():
        return f"ERROR: {script} not found"
    job = helpers.start_background(["bash", str(script)], job_id=job_id)
    return (f"Started {script_name} (pid {job.pid}); log: {job.log_path}. "
            f"Follow with get_job_log('{job_id}').")


@mcp.tool()
@requires_confirmed_identity
def validate_iam_roles(
    cluster_name: Optional[str] = None,
    provision_if_missing: bool = False,
) -> str:
    """Check that the IAM roles the load test depends on exist, in the load-test account.

    Verifies (via ``aws iam get-role`` under the active AWS_PROFILE, so it checks
    the SAME account the test runs in):
      - EMR on EKS job execution role (EXECUTION_ROLE) -- jobs cannot be
        submitted without it
      - Karpenter controller + node roles (KARPENTER_CONTROLLER_ROLE,
        KARPENTER_NODE_ROLE) -- node autoscaling fails without them
      - Locust IRSA role (LOCUST_EKS_ROLE) -- the operator cannot create
        namespaces/VCs without it

    When ``provision_if_missing`` is True, this starts the right script in the
    background to create whatever is missing: infra-provision.sh for the EMR /
    Karpenter roles, locust-provision.sh for the Locust role. Both are
    idempotent (they only create absent resources). Leave it False (default) to
    just report; provisioning creates real AWS resources and takes a while.
    """
    env = helpers.load_env()
    _region, name, error = _require_region_and_cluster(env, cluster_name)
    if error:
        return error

    checks = _check_iam_roles(env)
    passed = sum(1 for c in checks if c[2])  # c[2] is the exists flag
    total = len(checks)
    lines = [f"IAM role validation for cluster '{name}' (account via profile "
             f"{env.get('AWS_PROFILE', '<default>')}): {passed}/{total} present", ""]
    for var, role_name, ok, detail, _source in checks:
        lines.append(f"  [{'PASS' if ok else 'FAIL'}] {var} ({role_name}) — {detail}")

    missing = [c for c in checks if not c[2]]
    if not missing:
        lines.append("")
        lines.append("All required IAM roles exist.")
        return "\n".join(lines)

    need_infra = any(c[4] == "infra" for c in missing)
    need_locust = any(c[4] == "locust" for c in missing)
    lines.append("")
    if provision_if_missing:
        lines.append("Missing roles found; starting provisioning to create them:")
        if need_infra:
            lines.append("  - " + _start_provision("provision-infra", "infra-provision.sh"))
        if need_locust:
            lines.append("  - " + _start_provision("provision-locust", "locust-provision.sh"))
    else:
        lines.append("Some required IAM roles are missing. To create them, run:")
        if need_infra:
            lines.append("  - provision_infra (infra-provision.sh) for the EMR / Karpenter roles")
        if need_locust:
            lines.append("  - provision_locust_operator (locust-provision.sh) for the Locust role")
        lines.append("Or re-run this tool with provision_if_missing=True to start them now.")
    return "\n".join(lines)


def _check_locust_operator_rows(kj) -> list[tuple[str, bool, str]]:
    """Check the Locust operator Deployment is available and the locustfile
    ConfigMap exists in the ``locust`` namespace.

    Both are installed by locust-provision.sh: the operator (Helm release
    ``locust-operator``) reconciles the LocustTest CR into master/worker pods,
    and ``emr-loadtest-locustfile`` supplies locustfile.py + emr-job-run.sh that
    the workers mount. Takes the bound ``_kubectl_json`` partial so it reuses the
    already-resolved env. Returns PASS/FAIL rows for each.
    """
    dep = kj(["get", "deployment", "locust-operator", "-n", LOCUST_NAMESPACE])
    dep_ok = bool(dep) and (dep.get("status", {}).get("availableReplicas", 0) or 0) >= 1
    cm = kj(["get", "configmap", CONFIGMAP_NAME, "-n", LOCUST_NAMESPACE])
    cm_ok = bool(cm)
    return [
        ("Locust operator", dep_ok,
         f"availableReplicas={(dep or {}).get('status', {}).get('availableReplicas', 0)}"
         if dep else "locust-operator deployment not found in ns 'locust'"),
        (f"Locust ConfigMap ({CONFIGMAP_NAME})", cm_ok,
         "present" if cm_ok else
         f"{CONFIGMAP_NAME} not found in ns 'locust' (run refresh_configmap)"),
    ]


@mcp.tool()
def validate_cluster_components(
    cluster_name: Optional[str] = None,
    reprovision_locust_if_missing: bool = False,
) -> str:
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
      - Locust operator pod Running in ns 'locust' + emr-loadtest-locustfile
        ConfigMap present (both installed by locust-provision.sh)
      - ECR benchmark images present in the load-test account/region
        (locust:latest and eks-spark-benchmark:emr<EMR_IMAGE_VERSION>)
      - Required IAM roles in the load-test account (EMR execution role,
        Karpenter controller/node roles, Locust IRSA role)

    By default this is read-only: it reports PASS/FAIL but never provisions. If
    IAM roles are missing, use ``validate_iam_roles(provision_if_missing=True)``,
    or run provision_infra / provision_locust_operator.

    Set ``reprovision_locust_if_missing=True`` to auto-heal the Locust pieces: if
    any component owned by locust-provision.sh is missing (operator pod, the
    locustfile ConfigMap, or the Locust IRSA role), the script is re-run
    synchronously and the Locust checks are re-evaluated, so the returned report
    reflects the post-reprovision state.
    """
    env = helpers.load_env()
    region, name, error = _require_region_and_cluster(env, cluster_name)
    if error:
        return error

    # Sourcing env.sh is expensive (it shells out to `aws sts` to derive
    # ACCOUNT_ID), so resolve it ONCE here and hand the merged environment to
    # every check below via base_env -- otherwise each of the ~14 parallel
    # probes would re-source env.sh and the per-call tax would dominate (and the
    # concurrent `aws sts` calls would contend on the CLI credential cache).
    base_env = {**os.environ, **env}
    # Local binding so the check closures reuse the resolved env (no re-source).
    kj = functools.partial(_kubectl_json, base_env=base_env)

    # Confirm the cluster exists, then point kubeconfig at it.
    try:
        cluster = _describe_eks_cluster(name, region, base_env=base_env)
    except RuntimeError as e:
        return f"ERROR checking EKS cluster {name} in {region}:\n{e}"
    if cluster is None:
        return f"EKS cluster '{name}' does NOT exist in {region}. Create it first (provision_infra)."
    kube = run(["aws", "eks", "update-kubeconfig", "--name", name, "--region", region],
               timeout=120, base_env=base_env)
    if not kube.ok:
        return f"ERROR connecting kubectl to {name}:\n{kube.as_text()}"

    # Each check below is an independent, read-only probe (kubectl / aws CLI)
    # that returns its own list of (component, ok, detail) rows. They share no
    # state, so we run them concurrently in a thread pool -- the calls are
    # subprocess/IO-bound (the GIL is released during subprocess.run), so wall
    # time collapses from "sum of all checks" to "slowest single check". Results
    # are reassembled in declaration order (executor.map preserves it), so the
    # output is identical to running them sequentially.
    img_ver = env.get("EMR_IMAGE_VERSION", "")
    promns = "prometheus"
    # The IAM check's raw rows are captured here so we can derive which
    # provisioning script to suggest, without re-running the lookups.
    iam_rows: list[tuple[str, str, bool, str, str]] = []

    def check_karpenter() -> list[tuple[str, bool, str]]:
        # controller pods + NodePools + EC2NodeClasses Ready
        kp = kj(["get", "pods", "-n", "kube-system", "-l", "app.kubernetes.io/name=karpenter"])
        kp_running = bool(kp and kp.get("items") and all(
            p.get("status", {}).get("phase") == "Running" for p in kp["items"]))
        nps = kj(["get", "nodepools.karpenter.sh"])
        np_items = (nps or {}).get("items", [])
        np_ready = bool(np_items) and all(
            any(c.get("type") == "Ready" and c.get("status") == "True"
                for c in n.get("status", {}).get("conditions", []))
            for n in np_items)
        ncs = kj(["get", "ec2nodeclasses.karpenter.k8s.aws"])
        nc_items = (ncs or {}).get("items", [])
        nc_ready = bool(nc_items) and all(
            any(c.get("type") == "Ready" and c.get("status") == "True"
                for c in c2.get("status", {}).get("conditions", []))
            for c2 in nc_items)
        if nps is None:
            return [("Karpenter", False, "NodePool CRD not installed (Karpenter not deployed)")]
        np_names = ", ".join(n["metadata"]["name"] for n in np_items) or "none"
        return [("Karpenter", kp_running and np_ready and nc_ready,
                 f"controller running={kp_running}; nodepools=[{np_names}] ready={np_ready}; "
                 f"ec2nodeclasses ready={nc_ready}")]

    def check_lbc() -> list[tuple[str, bool, str]]:
        lbc = kj(["get", "deployment", "aws-load-balancer-controller", "-n", "kube-system"])
        lbc_avail = bool(lbc) and (lbc.get("status", {}).get("availableReplicas", 0) or 0) >= 1
        return [("AWS Load Balancer Controller", lbc_avail,
                 f"availableReplicas={(lbc or {}).get('status', {}).get('availableReplicas', 0)}"
                 if lbc else "deployment not found")]

    def check_gp3() -> list[tuple[str, bool, str]]:
        scs = kj(["get", "storageclass"])
        gp3 = next((s for s in (scs or {}).get("items", [])
                    if s["metadata"]["name"] == "gp3"), None)
        gp3_default = bool(gp3) and gp3["metadata"].get("annotations", {}).get(
            "storageclass.kubernetes.io/is-default-class") == "true"
        return [("gp3 StorageClass", bool(gp3),
                 f"present; default={gp3_default}" if gp3 else "gp3 StorageClass not found")]

    def check_ebs() -> list[tuple[str, bool, str]]:
        ebs = kj(["get", "pods", "-n", "kube-system", "-l", "app=ebs-csi-controller"])
        ebs_ok = bool(ebs and ebs.get("items")) and any(
            p.get("status", {}).get("phase") == "Running" for p in ebs["items"])
        return [("EBS CSI driver", ebs_ok,
                 f"controller pods running={sum(1 for p in (ebs or {}).get('items', []) if p.get('status',{}).get('phase')=='Running')}"
                 if ebs else "ebs-csi-controller not found")]

    def check_coredns() -> list[tuple[str, bool, str]]:
        dns = kj(["get", "deployment", "coredns", "-n", "kube-system"])
        dns_ready = (dns or {}).get("status", {}).get("readyReplicas", 0) or 0
        return [("CoreDNS (>=3 replicas)", bool(dns) and dns_ready >= 3,
                 f"readyReplicas={dns_ready}" if dns else "coredns deployment not found")]

    def check_binpacking() -> list[tuple[str, bool, str]]:
        bp = kj(["get", "pods", "-n", "kube-system", "-l", "app=custom-scheduler-eks"])
        bp_items = (bp or {}).get("items", [])
        if not bp_items:  # fall back to a name match if the label differs
            allpods = kj(["get", "pods", "-n", "kube-system"])
            bp_items = [p for p in (allpods or {}).get("items", [])
                        if "custom-scheduler" in p["metadata"]["name"]]
        bp_ok = bool(bp_items) and any(p.get("status", {}).get("phase") == "Running" for p in bp_items)
        return [("Binpacking scheduler", bp_ok,
                 "custom-scheduler-eks running" if bp_ok else "custom-scheduler-eks not found/not running")]

    def check_monitoring() -> list[tuple[str, bool, str]]:
        # kube-prometheus-stack labels the operator with component=prometheus-operator
        # (the app.kubernetes.io/name varies by chart, e.g.
        # kube-prometheus-stack-prometheus-operator), so select on component.
        prom = kj(["get", "pods", "-n", promns, "-l",
                              "app.kubernetes.io/component=prometheus-operator"])
        prom_ok = bool(prom and prom.get("items")) and any(
            p.get("status", {}).get("phase") == "Running" for p in prom["items"])
        graf = kj(["get", "deployment", "prometheus-grafana", "-n", promns])
        graf_ok = bool(graf) and (graf.get("status", {}).get("availableReplicas", 0) or 0) >= 1
        return [
            ("Prometheus operator", prom_ok,
             "running in ns 'prometheus'" if prom_ok else "prometheus-operator not found in ns 'prometheus'"),
            ("Grafana (built-in)", graf_ok,
             f"availableReplicas={(graf or {}).get('status', {}).get('availableReplicas', 0)}"
             if graf else "prometheus-grafana deployment not found"),
        ]

    def check_ecr() -> list[tuple[str, bool, str]]:
        # The on-EKS run pulls the Locust worker image referenced by the manifest
        # (locust:latest) and submits Spark jobs with eks-spark-benchmark:emr<ver>
        # (see locust/locustfiles/emr-job-run.sh). Missing either means the Locust
        # pods or the Spark jobs fail to start, so verify both up front. The two
        # describe-images calls are independent, so run them concurrently.
        images = [("locust", "latest"), ("eks-spark-benchmark", f"emr{img_ver}")]
        with ThreadPoolExecutor(max_workers=len(images)) as pool:
            return list(pool.map(
                lambda it: (f"ECR image {it[0]}:{it[1]}",
                            *_ecr_image_exists(it[0], it[1], region, base_env=base_env)),
                images))

    def check_iam() -> list[tuple[str, bool, str]]:
        # The EMR execution role, Karpenter controller/node roles, and Locust
        # IRSA role are created by the provisioning scripts. A missing role means
        # jobs can't be submitted, nodes can't scale, or the Locust operator
        # can't create namespaces -- so verify them as part of readiness.
        iam_rows.extend(_check_iam_roles(env, base_env=base_env))
        return [(f"IAM role {var}", ok, f"{role_name}: {detail}")
                for var, role_name, ok, detail, _source in iam_rows]

    def check_locust() -> list[tuple[str, bool, str]]:
        # The Locust operator (installed by locust-provision.sh) is what watches
        # the LocustTest CR and spawns the master/worker pods; the
        # emr-loadtest-locustfile ConfigMap carries locustfile.py + the
        # emr-job-run.sh submit script the workers mount. Either missing means
        # apply_eks_test produces no load, so verify both up front.
        return _check_locust_operator_rows(kj)

    checks = [
        check_karpenter, check_lbc, check_gp3, check_ebs, check_coredns,
        check_binpacking, check_monitoring, check_locust, check_ecr, check_iam,
    ]
    with ThreadPoolExecutor(max_workers=len(checks)) as pool:
        results: list[tuple[str, bool, str]] = [
            row for rows in pool.map(lambda fn: fn(), checks) for row in rows
        ]

    # Names of the Locust-owned component rows (operator + ConfigMap) so we can
    # tell whether the Locust pieces are what's failing.
    locust_row_names = {r[0] for r in _check_locust_operator_rows(lambda *_a, **_k: None)}
    reprovision_note: Optional[str] = None
    if reprovision_locust_if_missing:
        locust_missing = any(
            not ok and (comp in locust_row_names or comp == "IAM role LOCUST_EKS_ROLE")
            for comp, ok, _detail in results)
        if locust_missing:
            script = REPO_ROOT / "locust-provision.sh"
            if not script.exists():
                reprovision_note = f"Locust reprovision skipped: {script} not found."
            else:
                prov = run(["bash", str(script)], timeout=900, base_env=base_env)
                # Re-evaluate only the Locust-owned rows (operator + ConfigMap +
                # IRSA role) and splice the fresh verdicts back into results, so
                # the report reflects the post-reprovision state.
                iam_rows.clear()
                fresh = {r[0]: r for r in
                         (_check_locust_operator_rows(kj) + check_iam())}
                results = [fresh.get(comp, (comp, ok, detail))
                           for comp, ok, detail in results]
                reprovision_note = (
                    "Ran locust-provision.sh to heal missing Locust components "
                    f"(exit {'0' if prov.ok else 'nonzero'}); re-checked above."
                    if prov.ok else
                    f"locust-provision.sh FAILED:\n{prov.as_text()}")

    iam_missing_infra = any(not ok and source == "infra"
                            for *_unused, ok, _detail, source in iam_rows)
    iam_missing_locust = any(not ok and source == "locust"
                             for *_unused, ok, _detail, source in iam_rows)

    passed = sum(1 for _, ok, _ in results if ok)
    total = len(results)
    lines = [f"Cluster '{name}' ({region}) component validation: {passed}/{total} passed", ""]
    for component, ok, detail in results:
        lines.append(f"  [{'PASS' if ok else 'FAIL'}] {component} — {detail}")
    if reprovision_note:
        lines.append("")
        lines.append(reprovision_note)
    if passed < total:
        lines.append("")
        lines.append("Some components are missing/not ready. For a new cluster, (re)run "
                     "provision_infra; for an existing cluster, install the missing pieces "
                     "before running the load test.")
        if iam_missing_infra or iam_missing_locust:
            scripts = []
            if iam_missing_infra:
                scripts.append("provision_infra")
            if iam_missing_locust:
                scripts.append("provision_locust_operator")
            lines.append(f"Missing IAM roles can be created with: {', '.join(scripts)} "
                         "(or validate_iam_roles(provision_if_missing=True)).")
    return "\n".join(lines)


def _valid_cluster_name(name: str) -> bool:
    """EKS cluster name rules: letters/digits/hyphens, start alnum, <=100 chars."""
    return bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,99}", name))


@mcp.tool()
@requires_confirmed_identity
def use_existing_eks_cluster(cluster_name: str) -> str:
    """Reuse an existing EKS cluster: validate it and sync env configs to it.

    Verifies the named cluster exists in the configured region, then updates
    env.sh so the load test targets it: pins CLUSTER_NAME to the given name and
    EKS_VERSION to the cluster's actual Kubernetes version. The derived
    variables (BUCKET_NAME, LOCUST_EKS_ROLE, EXECUTION_ROLE, ...) follow
    CLUSTER_NAME automatically. Run this after the user picks the reuse path.
    """
    env = helpers.load_env()
    region, error = _require_region(env)
    if error:
        return error
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
@requires_confirmed_identity
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
    region, error = _require_region(env)
    if error:
        return error
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


def _refresh_configmap() -> tuple[bool, str]:
    """Delete + recreate the locustfile ConfigMap. Returns (ok, message).

    Shared by the refresh_configmap tool and apply_eks_test's auto-refresh so
    the two never drift. Recreating (not just applying) ensures deleted files
    don't linger in the ConfigMap.
    """
    files_dir = LOCUST_DIR / "locustfiles"
    if not files_dir.exists():
        return False, f"ERROR: {files_dir} not found"

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
    return create.ok, create.as_text()


@mcp.tool()
@requires_confirmed_identity
def refresh_configmap() -> str:
    """Recreate the locustfile ConfigMap from locust/locustfiles.

    Deletes and recreates ``emr-loadtest-locustfile`` in the ``locust``
    namespace so the Locust operator picks up edits to emr-job-run.sh /
    locustfile.py. Required before re-running an on-EKS test after changing
    the job script. Note: apply_eks_test does this automatically by default.
    """
    _ok, msg = _refresh_configmap()
    return msg


# ===========================================================================
# Provisioning
# ===========================================================================
@mcp.tool()
@requires_confirmed_identity
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
@requires_confirmed_identity
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
@requires_confirmed_identity
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
@requires_confirmed_identity
def apply_eks_test(
    manifest: str = "load-test-template.yaml",
    refresh_configmap: bool = True,
) -> str:
    """Start a distributed load test on EKS by applying a LocustTest manifest.

    ``kubectl apply -f examples/<manifest>``. Two safety steps run automatically
    so the applied test is always valid and current:

    1. **Auto-render:** if the manifest still contains unsubstituted ``${...}``
       placeholders (e.g. the raw ``load-test-template.yaml``, whose
       ``metadata.name`` is ``tpcds-job-${CLUSTER_NAME}`` and fails Kubernetes'
       RFC-1123 name validation), it is rendered to
       ``load-test-rendered.yaml`` via render_locust_manifest first, and that
       rendered file is applied instead.
    2. **Auto-refresh ConfigMap:** the emr-loadtest-locustfile ConfigMap is
       recreated from locust/locustfiles so the workers always mount the current
       emr-job-run.sh / locustfile.py. Pass ``refresh_configmap=False`` to skip.

    On success this also starts a background tail of the master logs and prints
    the Grafana dashboard URL + login, so the run can be monitored immediately.
    """
    path = (EXAMPLES_DIR / manifest) if not Path(manifest).is_absolute() else Path(manifest)
    if not path.exists():
        return f"ERROR: manifest not found at {path}"

    sections: list[str] = []

    # 1. Auto-render if the manifest carries unsubstituted ${...} placeholders.
    # Applying the raw template makes kubectl reject metadata.name
    # "tpcds-job-${CLUSTER_NAME}" as an invalid RFC-1123 subdomain, so render
    # first and apply the substituted file instead.
    if re.search(r"\$\{[A-Z_]+\}", path.read_text()):
        rendered = render_locust_manifest()
        if rendered.startswith("ERROR"):
            return f"Auto-render failed: {rendered}"
        path = EXAMPLES_DIR / "load-test-rendered.yaml"
        sections.append(f"Auto-rendered template (unsubstituted placeholders) -> {path}")

    # 2. Refresh the locustfile ConfigMap so the run uses the current
    # emr-job-run.sh / locustfile.py (a stale ConfigMap silently runs old job
    # parameters). Opt out with refresh_configmap=False.
    if refresh_configmap:
        cm_ok, cm_msg = _refresh_configmap()
        sections.append(f"ConfigMap refresh: {cm_msg.strip()}")
        if not cm_ok:
            sections.append("WARNING: ConfigMap refresh failed; the run may use a "
                            "stale job script. Continuing to apply the manifest.")

    result = run(["kubectl", "apply", "-f", str(path)], timeout=120)
    sections.append(result.as_text())
    if not result.ok:
        return "\n".join(sections)
    # Begin following the master logs so progress streams without a manual step,
    # and surface where to watch metrics.
    sections.append("--- live monitoring ---")
    sections.append(_start_log_follow("master"))
    sections.append("")
    sections.append(_grafana_login_text())
    return "\n".join(sections)


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


def _follow_logs_job_id(component: str) -> str:
    return f"locust-{component}-follow"


def _start_log_follow(component: str) -> str:
    """Start (or restart) a detached `kubectl logs -f` follower for a Locust
    component, streaming into a tracked background-job log.

    Returns a status line. The follower keeps tailing while the test runs; read
    accumulated output any time with get_job_log('locust-<component>-follow').
    Using a background job (not a blocking call) means a long-running tail does
    not tie up the tool call -- the same pattern provisioning scripts use.
    """
    job_id = _follow_logs_job_id(component)
    # If a previous follower is still alive, leave it -- it's already tailing.
    try:
        status = helpers.job_status(job_id)
        if status.get("running"):
            return (f"Already following {component} logs (job '{job_id}', pid "
                    f"{status['pid']}). Read it with get_job_log('{job_id}').")
    except FileNotFoundError:
        pass
    # --tail=-1 from the current end; -f follows; --prefix tags each pod. The
    # label selector reattaches across pod restarts within the run. We wrap in
    # bash so a missing pod (test not applied yet) waits briefly rather than
    # erroring out immediately.
    follow_cmd = (
        f"for i in $(seq 1 30); do "
        f"kubectl get pods -n {LOCUST_NAMESPACE} -l locust.cloud/component={component} "
        f"-o name 2>/dev/null | grep -q . && break; sleep 2; done; "
        f"exec kubectl logs -n {LOCUST_NAMESPACE} "
        f"-l locust.cloud/component={component} -f --prefix --tail=50"
    )
    job = helpers.start_background(["bash", "-c", follow_cmd], job_id=job_id)
    return (f"Following {component} logs in the background (job '{job_id}', pid "
            f"{job.pid}). Read accumulated output with get_job_log('{job_id}'); "
            f"it keeps tailing until the test ends or you call stop_test.")


@mcp.tool()
def follow_test_logs(component: str = "master") -> str:
    """Start tailing on-EKS Locust logs in the background while the test runs.

    Unlike get_test_logs (a one-shot snapshot), this launches a detached
    `kubectl logs -f` follower tracked as a background job, so the stream keeps
    accumulating across the run without blocking. component: 'master'
    (aggregated load-test progress) or 'worker' (per-job submission status).
    Poll the accumulated output with get_job_log('locust-<component>-follow').
    """
    if component not in ("master", "worker"):
        return "ERROR: component must be 'master' or 'worker'"
    return _start_log_follow(component)


def _emr_containers_endpoint(env: dict, region: str) -> str:
    """Resolve the emr-containers API endpoint the test targets.

    Mirrors how the rendered manifest / on-EKS workers pick it (see the
    EMR_CONTAINERS_ENDPOINT_URL env they get): the value from env.sh when set
    (e.g. a gamma endpoint), else the region-derived prod endpoint. The monitor
    tools MUST use the same endpoint, or they query prod and report no VCs/jobs
    while a gamma run is actually active.
    """
    return env.get("EMR_CONTAINERS_ENDPOINT_URL") or \
        f"https://emr-containers.{region}.amazonaws.com"


@mcp.tool()
def list_virtual_clusters(state: str = "RUNNING") -> str:
    """List EMR on EKS virtual clusters for the configured EKS cluster.

    Uses ``aws emr-containers list-virtual-clusters`` filtered to the cluster in
    env.sh. state: RUNNING (default), TERMINATED, etc.
    """
    env = helpers.load_env()
    cluster = env.get("CLUSTER_NAME")
    region, error = _require_region(env)
    if error:
        return error
    if not cluster:
        return "ERROR: CLUSTER_NAME not set in env.sh"
    result = run(
        ["aws", "emr-containers", "list-virtual-clusters",
         "--container-provider-id", cluster,
         "--container-provider-type", "EKS",
         "--states", state,
         "--region", region,
         "--endpoint-url", _emr_containers_endpoint(env, region),
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
    region, error = _require_region(env)
    if error:
        return error
    state_list = states or ["PENDING", "SUBMITTED", "RUNNING", "COMPLETED", "FAILED"]
    result = run(
        ["aws", "emr-containers", "list-job-runs",
         "--virtual-cluster-id", virtual_cluster_id,
         "--states", *state_list,
         "--region", region,
         "--endpoint-url", _emr_containers_endpoint(env, region),
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


def _grafana_login_text() -> str:
    """Resolve the Grafana dashboard URL + admin credentials as display text.

    Reads the ``prometheus-grafana`` ingress hostname and the admin password
    secret from the ``prometheus`` namespace (community Prometheus stack
    installed by infra-provision.sh). Shared by get_grafana_login and the
    test-start flow so monitoring details are surfaced the moment a test runs.
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
    if not url.ok or not url.stdout.strip():
        return "Grafana: could not resolve ingress hostname:\n" + url.as_text()
    gf_secret = secret.stdout.strip() if secret.ok else "<failed to read secret>"
    bar = "=" * 34
    return (
        f"{bar}\n"
        f"Grafana Login URL: http://{url.stdout.strip()}\n"
        f"Login User: admin\n"
        f"Login secret: {gf_secret}\n"
        f"{bar}"
    )


@mcp.tool()
def get_grafana_login() -> str:
    """Print the Grafana dashboard URL and admin credentials.

    Reads the ``prometheus-grafana`` ingress hostname and the admin password
    secret from the ``prometheus`` namespace (community Prometheus stack
    installed by infra-provision.sh).
    """
    return _grafana_login_text()


# ===========================================================================
# Cleanup
# ===========================================================================
@mcp.tool()
@requires_confirmed_identity
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
@requires_confirmed_identity
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
@requires_confirmed_identity
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
