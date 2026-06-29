"""Shared helpers for the EMR on EKS load-test MCP server.

These utilities locate the repository root, load the environment defined in
``env.sh``, and run the project's existing shell scripts / CLIs. The MCP tools
in ``server.py`` are thin wrappers around these helpers so that the server
stays in sync with the tested automation already shipped in the repo.
"""

from __future__ import annotations

import configparser
import json
import os
import shlex
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Repo location
# ---------------------------------------------------------------------------
# The server drives the automation that ships in the load-test repo
# (env.sh, infra-provision.sh, locust/, examples/, ...). Those artifacts come
# from GitHub: https://github.com/aws-samples/load-test-for-emr-on-eks
#
# Resolution order for where those artifacts live:
#   1. $LOADTEST_REPO_ROOT, if set        -- explicit local checkout
#   2. the parent of this file's dir       -- server is running from inside a
#                                             checkout (the common dev case)
#   3. $LOADTEST_CACHE_DIR/<repo name>     -- a managed clone fetched from
#                                             GitHub on demand
# In cases 1 and 3, the clone is created/updated by ``ensure_repo()`` if the
# artifacts are missing, so a fresh install needs no manual git clone.
REPO_URL = os.environ.get(
    "LOADTEST_REPO_URL", "https://github.com/aws-samples/load-test-for-emr-on-eks"
)
REPO_BRANCH = os.environ.get("LOADTEST_REPO_BRANCH", "")  # empty = default branch
_REPO_DIRNAME = REPO_URL.rstrip("/").split("/")[-1].removesuffix(".git")

CACHE_DIR = Path(
    os.environ.get("LOADTEST_CACHE_DIR", Path.home() / ".cache" / "emr-eks-loadtest-mcp")
).resolve()


def _resolve_repo_root() -> Path:
    explicit = os.environ.get("LOADTEST_REPO_ROOT")
    if explicit:
        return Path(explicit).resolve()

    # Server running from inside a checkout: parent dir holds env.sh.
    bundled = Path(__file__).resolve().parent.parent
    if (bundled / "env.sh").exists():
        return bundled

    # Otherwise fall back to a managed clone under the cache dir.
    return (CACHE_DIR / _REPO_DIRNAME).resolve()


REPO_ROOT = _resolve_repo_root()

ENV_SH = REPO_ROOT / "env.sh"
LOCUST_DIR = REPO_ROOT / "locust"
LOCUSTFILE = LOCUST_DIR / "locustfiles" / "locustfile.py"
EXAMPLES_DIR = REPO_ROOT / "examples"

# Where long-running background jobs (provision, on-EKS tests) write their logs.
RUN_DIR = Path(
    os.environ.get("LOADTEST_RUN_DIR", Path(__file__).resolve().parent / ".runs")
)


@dataclass
class CommandResult:
    """Outcome of a synchronous command run."""

    returncode: int
    stdout: str
    stderr: str
    command: str
    duration_sec: float = 0.0

    @property
    def ok(self) -> bool:
        return self.returncode == 0

    def as_text(self, max_chars: int = 12000) -> str:
        """Render a human/agent-friendly summary, truncating huge output."""
        status = "SUCCESS" if self.ok else f"FAILED (exit {self.returncode})"
        out = self.stdout or ""
        err = self.stderr or ""

        def clip(s: str) -> str:
            if len(s) > max_chars:
                return s[-max_chars:] + f"\n...[truncated to last {max_chars} chars]"
            return s

        parts = [
            f"$ {self.command}",
            f"[{status}] in {self.duration_sec:.1f}s",
        ]
        if out.strip():
            parts.append("--- stdout ---\n" + clip(out).rstrip())
        if err.strip():
            parts.append("--- stderr ---\n" + clip(err).rstrip())
        return "\n".join(parts)


def repo_is_present() -> bool:
    """True if the load-test artifacts (env.sh) are available at REPO_ROOT."""
    return ENV_SH.exists()


def ensure_repo(update: bool = False) -> str:
    """Make sure the load-test artifacts are present at REPO_ROOT.

    If REPO_ROOT already contains the repo (env.sh present), this is a no-op
    unless ``update`` is set, in which case it ``git pull``s a managed clone.
    Otherwise the repo is cloned from GitHub (REPO_URL) into REPO_ROOT. We only
    create/modify a clone when REPO_ROOT lives under our cache dir or was given
    explicitly via LOADTEST_REPO_ROOT -- we never mutate a checkout the server
    happens to be bundled inside.
    """
    if repo_is_present() and not update:
        return f"Using load-test artifacts at {REPO_ROOT}"

    is_git = (REPO_ROOT / ".git").exists()
    if is_git and update:
        proc = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "pull", "--ff-only"],
            capture_output=True, text=True, timeout=300,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"git pull failed for {REPO_ROOT}: {proc.stderr.strip()}")
        return f"Updated load-test artifacts at {REPO_ROOT}\n{proc.stdout.strip()}"

    if repo_is_present():
        # present but not a git clone (e.g. bundled checkout) and update requested
        return f"Using load-test artifacts at {REPO_ROOT} (not a git clone; skip update)"

    # Not present -> clone from GitHub.
    REPO_ROOT.parent.mkdir(parents=True, exist_ok=True)
    clone_args = ["git", "clone", "--depth", "1"]
    if REPO_BRANCH:
        clone_args += ["--branch", REPO_BRANCH]
    clone_args += [REPO_URL, str(REPO_ROOT)]
    proc = subprocess.run(clone_args, capture_output=True, text=True, timeout=600)
    if proc.returncode != 0:
        raise RuntimeError(
            f"Failed to clone {REPO_URL} into {REPO_ROOT}: {proc.stderr.strip()}"
        )
    if not repo_is_present():
        raise RuntimeError(
            f"Cloned {REPO_URL} but env.sh is missing under {REPO_ROOT}"
        )
    return f"Cloned {REPO_URL} into {REPO_ROOT}"


def _ensure_repo() -> None:
    """Backward-compatible guard: fetch the repo from GitHub if missing."""
    if repo_is_present():
        return
    ensure_repo()
    if not repo_is_present():
        raise FileNotFoundError(
            f"env.sh not found at {ENV_SH}. Set LOADTEST_REPO_ROOT to a "
            "load-test-for-emr-on-eks checkout, or allow the server to clone "
            f"{REPO_URL}."
        )


def load_env() -> dict[str, str]:
    """Source ``env.sh`` in a subshell and capture the resulting environment.

    ``env.sh`` uses command substitution (e.g. ``$(aws sts ...)``) so it must be
    executed by a real shell rather than parsed. We return the full child
    environment, which the caller merges into the scripts/CLIs they invoke.
    """
    _ensure_repo()
    # Print a NUL-delimited dump of the environment after sourcing env.sh.
    script = "set -a; source ./env.sh >/dev/null 2>&1; env -0"
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=120,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"Failed to source env.sh: {proc.stderr.strip()}")

    env: dict[str, str] = {}
    for entry in proc.stdout.split("\0"):
        if not entry or "=" not in entry:
            continue
        key, _, value = entry.partition("=")
        env[key] = value
    return env


# ---------------------------------------------------------------------------
# AWS profile / identity
# ---------------------------------------------------------------------------
def _profiles_from_config_files() -> list[str]:
    """Parse profile names from ~/.aws/config and ~/.aws/credentials.

    Fallback for when ``aws configure list-profiles`` returns nothing (it can,
    e.g. on some CLI builds or when profiles use ``credential_process``). In
    ``config`` profiles are ``[profile NAME]`` (plus a bare ``[default]``); in
    ``credentials`` they are ``[NAME]``. Honors AWS_CONFIG_FILE /
    AWS_SHARED_CREDENTIALS_FILE when set.
    """
    config_path = Path(
        os.environ.get("AWS_CONFIG_FILE", Path.home() / ".aws" / "config")
    ).expanduser()
    creds_path = Path(
        os.environ.get(
            "AWS_SHARED_CREDENTIALS_FILE", Path.home() / ".aws" / "credentials"
        )
    ).expanduser()

    names: list[str] = []
    for path, is_config in ((config_path, True), (creds_path, False)):
        if not path.exists():
            continue
        try:
            parser = configparser.RawConfigParser()
            parser.read(path)
        except configparser.Error:
            continue
        for section in parser.sections():
            # config uses "[profile NAME]" (and a bare "[default]"); credentials
            # uses "[NAME]" directly.
            name = section[len("profile "):] if (
                is_config and section.startswith("profile ")) else section
            if name and name not in names:
                names.append(name)
    return names


def aws_profiles() -> list[str]:
    """Return the AWS profiles configured locally.

    Tries ``aws configure list-profiles`` first; if that yields nothing (it can
    on some CLI versions, or with credential_process-based profiles), falls back
    to parsing ~/.aws/config and ~/.aws/credentials directly so the agent can
    still present the user real choices.
    """
    try:
        proc = subprocess.run(
            ["aws", "configure", "list-profiles"],
            capture_output=True, text=True, timeout=60,
        )
        if proc.returncode == 0:
            profiles = [p.strip() for p in proc.stdout.splitlines() if p.strip()]
            if profiles:
                return profiles
    except (subprocess.SubprocessError, OSError):
        pass
    return _profiles_from_config_files()


def aws_identity(profile: Optional[str] = None) -> dict:
    """Resolve the active AWS identity and region for a profile.

    Returns a dict with keys: ``profile``, ``account``, ``arn``, ``user_id``,
    ``region``, and ``ok``/``error``. ``ok`` is False when credentials are
    missing/expired so callers can prompt the user to fix the profile before
    anything else runs. No account/region is hardcoded -- everything comes from
    the resolved profile.
    """
    # Resolve identity against the SAME environment the real test commands use:
    # run()/start_background() layer load_env() (which sources env.sh) on top of
    # os.environ, so set_aws_profile's AWS_PROFILE/AWS_REGION writes take effect.
    # Without this, identity checks would read a stale AWS_PROFILE exported in
    # the server's own process and never agree with what gets provisioned. An
    # explicit ``profile`` argument still wins over env.sh's AWS_PROFILE.
    sts_env = os.environ.copy()
    try:
        sts_env.update(load_env())
    except RuntimeError:
        pass
    if profile:
        sts_env["AWS_PROFILE"] = profile
    sts = subprocess.run(
        ["aws", "sts", "get-caller-identity", "--output", "json"],
        capture_output=True, text=True, timeout=60, env=sts_env,
    )
    # env.sh is the source of truth for region (the user can override it via
    # set_env_var); fall back to the profile's configured region.
    region = sts_env.get("AWS_REGION", "")
    if not region:
        region_proc = subprocess.run(
            ["aws", "configure", "get", "region"]
            + (["--profile", profile] if profile else []),
            capture_output=True, text=True, timeout=60, env=sts_env,
        )
        region = region_proc.stdout.strip()
    if sts.returncode != 0:
        return {
            "ok": False,
            "profile": profile or sts_env.get("AWS_PROFILE", "default"),
            "region": region,
            "error": (sts.stderr or sts.stdout).strip(),
        }
    try:
        ident = json.loads(sts.stdout)
    except json.JSONDecodeError:
        return {"ok": False,
                "profile": profile or sts_env.get("AWS_PROFILE", "default"),
                "region": region,
                "error": "could not parse get-caller-identity output"}
    return {
        "ok": True,
        "profile": profile or sts_env.get("AWS_PROFILE", "default"),
        "account": ident.get("Account"),
        "arn": ident.get("Arn"),
        "user_id": ident.get("UserId"),
        "region": region,
    }


# ---------------------------------------------------------------------------
# AWS profile confirmation gate
# ---------------------------------------------------------------------------
# Test-affecting tools (provision, run, teardown, ...) refuse to act until the
# operator has explicitly confirmed which account/region they target. The
# confirmation is recorded here so the gate survives across tool calls (and
# server restarts) but is invalidated whenever the active profile changes.
CONFIRMED_IDENTITY_PATH = RUN_DIR / "confirmed_identity.json"


def record_confirmed_identity(account: str, region: str, profile: str) -> None:
    """Persist the account/region/profile the operator has authorized."""
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    CONFIRMED_IDENTITY_PATH.write_text(
        json.dumps(
            {
                "account": account,
                "region": region,
                "profile": profile,
                "confirmed_at": time.time(),
            }
        )
    )


def read_confirmed_identity() -> Optional[dict]:
    """Return the recorded confirmed identity, or None if none/unreadable."""
    if not CONFIRMED_IDENTITY_PATH.exists():
        return None
    try:
        return json.loads(CONFIRMED_IDENTITY_PATH.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def clear_confirmed_identity() -> None:
    """Drop any recorded confirmation (e.g. after switching profiles)."""
    try:
        CONFIRMED_IDENTITY_PATH.unlink()
    except FileNotFoundError:
        pass


def run(
    args: list[str] | str,
    *,
    cwd: Optional[Path] = None,
    timeout: int = 600,
    with_env: bool = True,
    extra_env: Optional[dict[str, str]] = None,
    base_env: Optional[dict[str, str]] = None,
    shell: bool = False,
) -> CommandResult:
    """Run a command synchronously with the load-test environment loaded.

    ``args`` may be a list (preferred) or a string when ``shell=True``.

    Sourcing ``env.sh`` is expensive (it shells out to ``aws sts`` via command
    substitution to derive ACCOUNT_ID), so a caller that issues many commands
    can resolve it once with ``load_env()`` and pass it as ``base_env`` to skip
    the per-call re-source. When ``base_env`` is given, ``with_env`` is ignored.
    """
    if base_env is not None:
        env = dict(base_env)
    else:
        env = os.environ.copy()
        if with_env:
            env.update(load_env())
    if extra_env:
        env.update(extra_env)

    cmd_str = args if isinstance(args, str) else " ".join(shlex.quote(a) for a in args)
    start = time.monotonic()
    proc = subprocess.run(
        args,
        cwd=str(cwd or REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
        shell=shell,
    )
    return CommandResult(
        returncode=proc.returncode,
        stdout=proc.stdout,
        stderr=proc.stderr,
        command=cmd_str,
        duration_sec=time.monotonic() - start,
    )


# ---------------------------------------------------------------------------
# Background jobs (for long-running scripts like infra-provision.sh)
# ---------------------------------------------------------------------------
@dataclass
class BackgroundJob:
    job_id: str
    command: str
    log_path: Path
    pid: int
    started_at: float = field(default_factory=time.time)


def start_background(
    args: list[str],
    *,
    job_id: str,
    cwd: Optional[Path] = None,
    with_env: bool = True,
    extra_env: Optional[dict[str, str]] = None,
) -> BackgroundJob:
    """Launch a long-running command detached, streaming output to a log file.

    Returns immediately. Use ``read_job_log`` / ``job_status`` to follow along.
    """
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    log_path = RUN_DIR / f"{job_id}.log"

    env = os.environ.copy()
    if with_env:
        env.update(load_env())
    if extra_env:
        env.update(extra_env)

    cmd_str = " ".join(shlex.quote(a) for a in args)
    log_file = open(log_path, "w")
    log_file.write(f"$ {cmd_str}\n\n")
    log_file.flush()

    proc = subprocess.Popen(
        args,
        cwd=str(cwd or REPO_ROOT),
        stdout=log_file,
        stderr=subprocess.STDOUT,
        env=env,
        start_new_session=True,  # detach so it survives the tool call
    )
    # Persist a small metadata sidecar so status survives server restarts.
    meta = {"job_id": job_id, "command": cmd_str, "pid": proc.pid, "log": str(log_path)}
    (RUN_DIR / f"{job_id}.json").write_text(json.dumps(meta))
    return BackgroundJob(job_id=job_id, command=cmd_str, log_path=log_path, pid=proc.pid)


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def job_status(job_id: str) -> dict:
    meta_path = RUN_DIR / f"{job_id}.json"
    if not meta_path.exists():
        raise FileNotFoundError(f"No background job named {job_id}")
    meta = json.loads(meta_path.read_text())
    meta["running"] = _pid_alive(meta["pid"])
    return meta


def read_job_log(job_id: str, tail_lines: int = 200) -> str:
    log_path = RUN_DIR / f"{job_id}.log"
    if not log_path.exists():
        raise FileNotFoundError(f"No log for background job {job_id}")
    lines = log_path.read_text(errors="replace").splitlines()
    return "\n".join(lines[-tail_lines:])


def list_jobs() -> list[dict]:
    if not RUN_DIR.exists():
        return []
    jobs = []
    for meta_path in sorted(RUN_DIR.glob("*.json")):
        try:
            meta = json.loads(meta_path.read_text())
            meta["running"] = _pid_alive(meta.get("pid", -1))
            jobs.append(meta)
        except (json.JSONDecodeError, OSError):
            continue
    return jobs
