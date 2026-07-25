#!/usr/bin/env python3
"""Set up Claude Code config inside the dev container.

Sets up Claude Code config inside the container's isolated ~/.claude volume.
Permissions, global instructions, global memory, and per-project memory are
copied from the read-only host mount.
Installs a PreToolUse audit hook and symlinks sessions for host log capture.

Credentials: this script seeds a PRIVATE token + identity into the isolated
~/.claude, copied once from the read-only host profile store
(.claude-host/credentials/<profile>.json). The container is NOT bind-mounted to
the host credential file and refreshes its own token independently — see
docs/adr/0001-devcontainer-private-token-isolation.md. `seed-credentials` is a
standalone subcommand (used by `devcontainer fix-credentials`).

Expected environment variables (set by dev/devcontainer):
    DEV_CONTAINER_WORKSPACE  — container workspace path (e.g. /workspaces/src)
    DEV_HOST_PROJECT_KEY     — mangled host workspace path (e.g. -home-dan-repos-github-xorq)
    DEV_CONTAINER_PROJECT_KEY — mangled container workspace path (e.g. -workspaces-src)
    DEV_WORKSPACE            — host workspace path; optional, used to rewrite the
                               cwd prefix in copied session transcripts
    DEV_CLAUDE_PROFILE       — profile to seed credentials from; optional,
                               defaults to the host's active profile
"""

import json
import os
import shutil
import sys
from pathlib import Path

# Paths default to the in-container layout; overridable via env so the seeding
# logic can be exercised off-container (see tests/test-claude-seed.sh).
HOST = Path(os.environ.get("CLAUDE_HOST_DIR", "/home/vscode/.claude-host"))
HOME = Path(os.environ.get("CLAUDE_HOME_DIR", "/home/vscode/.claude"))
HOST_PREFS = Path(os.environ.get("CLAUDE_HOST_PREFS", "/home/vscode/.claude-host.json"))
CONTAINER_PREFS = Path(os.environ.get("CLAUDE_CONTAINER_PREFS", "/home/vscode/.claude.json"))

REQUIRED_VARS = (
    "DEV_CONTAINER_WORKSPACE",
    "DEV_HOST_PROJECT_KEY",
    "DEV_CONTAINER_PROJECT_KEY",
)

# Caches in .claude.json that are scoped to the logged-in account; dropped when
# seeding a different profile's identity so they refetch for the new account.
ACCOUNT_SCOPED_CACHES = (
    "clientDataCacheSlots",
    "orgModelDefaultCache",
    "modelAccessCache",
    "s1mAccessCache",
)


def copy_global_instructions():
    src = HOST / "CLAUDE.md"
    if src.exists():
        shutil.copy2(src, HOME / "CLAUDE.md")


def copy_global_memory():
    src = HOST / "memory"
    if src.is_dir():
        shutil.copytree(src, HOME / "memory", dirs_exist_ok=True)


def copy_user_prefs(workspace):
    prefs = {}
    if HOST_PREFS.exists():
        with open(HOST_PREFS) as f:
            prefs = json.load(f)

    projects = prefs.setdefault("projects", {})
    ws_key = str(workspace)
    projects.setdefault(ws_key, {})
    projects[ws_key]["hasTrustDialogAccepted"] = True
    projects[ws_key]["hasClaudeMdExternalIncludesApproved"] = True

    with open(CONTAINER_PREFS, "w") as f:
        json.dump(prefs, f, indent=2)


def resolve_profile():
    """Which profile to seed: DEV_CLAUDE_PROFILE, else the host's active profile."""
    profile = os.environ.get("DEV_CLAUDE_PROFILE", "").strip()
    if profile:
        return profile
    marker = HOST / "credentials" / "active-profile"
    if marker.exists():
        return marker.read_text().strip()
    return ""


def seed_credentials(profile):
    """Seed a PRIVATE token + identity into the container's isolated ~/.claude.

    Replaces the old shared-mount model (devcontainer ADR-0001): instead of
    bind-mounting the host credentials dir and symlinking into it, each container
    gets its own token, copied once from the read-only host profile store
    (.claude-host/credentials/<profile>.json). The container then refreshes its
    own token independently — no shared inode, so no cross-session refresh race.
    Identity comes from the profile's oauthAccount sidecar; account-scoped caches
    are dropped so a different account refetches. Idempotent; safe to re-run.
    """
    if not profile:
        print("note: no DEV_CLAUDE_PROFILE and no host active-profile — credentials left untouched")
        return

    store = HOST / "credentials"
    token_src = store / f"{profile}.json"
    if not token_src.exists():
        print(
            f"warning: profile '{profile}' not found in host store ({token_src}) — credentials not seeded",
            file=sys.stderr,
        )
        return

    # Private token: a regular file on the isolated volume — never a symlink, never
    # the shared host file. 0600.
    dest = HOME / ".credentials.json"
    if dest.is_symlink() or dest.exists():
        dest.unlink()
    shutil.copyfile(token_src, dest)
    os.chmod(dest, 0o600)

    # Identity: patch oauthAccount into .claude.json from the profile sidecar so
    # `auth status` reports the seeded account, not a stale build-time cache.
    prefs = {}
    if CONTAINER_PREFS.exists():
        with open(CONTAINER_PREFS) as f:
            prefs = json.load(f)
    oauth_src = store / f"{profile}.oauthAccount.json"
    if oauth_src.exists():
        with open(oauth_src) as f:
            prefs["oauthAccount"] = json.load(f)
        for key in ACCOUNT_SCOPED_CACHES:
            prefs.pop(key, None)
    else:
        print(
            f"note: no oauthAccount sidecar for '{profile}' — identity blank until "
            f"refetch (refresh on host with: claude-profile save {profile})"
        )
    # Load-bearing for skipping the onboarding flow (field-notes-public#10).
    prefs.setdefault("hasCompletedOnboarding", True)
    prefs.setdefault("installMethod", "native")
    with open(CONTAINER_PREFS, "w") as f:
        json.dump(prefs, f, indent=2)
    print(f"seeded private credentials for profile '{profile}'")


def setup_settings(workspace, host_project_key):
    host_settings = {}
    src = HOST / "settings.json"
    if src.exists():
        with open(src) as f:
            host_settings = json.load(f)

    skipped_hooks = 0
    for hook_list in host_settings.get("hooks", {}).values():
        for matcher_group in hook_list:
            skipped_hooks += len(matcher_group.get("hooks", []))

    host_project_dir = HOST / "projects" / host_project_key
    if host_project_dir.is_dir():
        for name in ("settings.json", "settings.local.json"):
            src = host_project_dir / name
            if not src.exists():
                continue
            with open(src) as f:
                proj = json.load(f)
            for hook_list in proj.get("hooks", {}).values():
                for matcher_group in hook_list:
                    skipped_hooks += len(matcher_group.get("hooks", []))

    if skipped_hooks:
        print(f"note: skipping {skipped_hooks} host hook(s) (reference host paths)")

    audit_log = workspace / ".claude" / "container-audit" / "audit.jsonl"

    audit_cmd = f"python3 /usr/local/bin/audit-hook {audit_log}"

    container_settings = {
        "permissions": host_settings.get("permissions", {}),
        "skipDangerousModePermissionPrompt": True,
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": "",
                    "hooks": [
                        {"type": "command", "command": audit_cmd},
                    ],
                }
            ],
        },
    }

    # Carry over the remote-control startup toggle from the host so container
    # sessions default to the same remote-control behavior as host sessions.
    if "remoteControlAtStartup" in host_settings:
        container_settings["remoteControlAtStartup"] = host_settings["remoteControlAtStartup"]

    with open(HOME / "settings.json", "w") as f:
        json.dump(container_settings, f, indent=2)


def setup_project_settings(host_project_key, container_project_key):
    host_project_dir = HOST / "projects" / host_project_key
    container_project_dir = HOME / "projects" / container_project_key

    if container_project_dir.is_symlink():
        container_project_dir.unlink()

    container_project_dir.mkdir(parents=True, exist_ok=True)

    if not host_project_dir.is_dir():
        return

    for name in ("settings.json", "settings.local.json"):
        src = host_project_dir / name
        if not src.exists():
            continue
        with open(src) as f:
            proj = json.load(f)
        container_proj = {"permissions": proj.get("permissions", {})}
        with open(container_project_dir / name, "w") as f:
            json.dump(container_proj, f, indent=2)

    host_memory = host_project_dir / "memory"
    container_memory = container_project_dir / "memory"
    if host_memory.is_dir():
        shutil.copytree(host_memory, container_memory, dirs_exist_ok=True)


def copy_sessions(workspace, host_project_key, container_project_key):
    """Mirror host session transcripts into the container's project key.

    Resume locates a session by the cwd-derived project key, and each record
    carries an absolute cwd. The host workspace path differs from the container
    one, so rewrite the prefix as we copy. Host -> container only; existing
    container-side transcripts are left untouched so continued work is not
    clobbered.

    Returns (copied, skipped) counts for callers that want to report progress.
    """
    host_dir = HOST / "projects" / host_project_key
    if not host_dir.is_dir():
        return 0, 0

    container_dir = HOME / "projects" / container_project_key
    container_dir.mkdir(parents=True, exist_ok=True)

    host_ws = os.environ.get("DEV_WORKSPACE")
    container_ws = str(workspace)

    copied = skipped = 0
    for src in host_dir.glob("*.jsonl"):
        dst = container_dir / src.name
        if dst.exists():
            skipped += 1
            continue
        text = src.read_text()
        if host_ws:
            text = text.replace(host_ws, container_ws)
        dst.write_text(text)
        copied += 1
    return copied, skipped


def setup_sessions(workspace):
    sessions_target = workspace / ".claude" / "container-sessions"
    sessions_target.mkdir(parents=True, exist_ok=True)

    sessions_link = HOME / "sessions"
    if sessions_link.is_dir() and not sessions_link.is_symlink():
        shutil.rmtree(sessions_link)
    elif sessions_link.is_symlink() or sessions_link.exists():
        sessions_link.unlink()
    sessions_link.symlink_to(sessions_target)


def setup_audit(workspace):
    (workspace / ".claude" / "container-audit").mkdir(parents=True, exist_ok=True)


def main():
    # Standalone credential re-seed (invoked by `devcontainer fix-credentials`).
    # Needs only a profile + the host store, not the project-key vars, so it runs
    # before the REQUIRED_VARS check.
    if sys.argv[1:] == ["seed-credentials"]:
        HOME.mkdir(parents=True, exist_ok=True)
        seed_credentials(resolve_profile())
        return

    missing = [v for v in REQUIRED_VARS if v not in os.environ]
    if missing:
        print(
            f"error: missing environment variables: {', '.join(missing)}",
            file=sys.stderr,
        )
        print(
            "This script should be called via dev/devcontainer, not directly.",
            file=sys.stderr,
        )
        sys.exit(1)

    workspace = Path(os.environ["DEV_CONTAINER_WORKSPACE"])
    host_project_key = os.environ["DEV_HOST_PROJECT_KEY"]
    container_project_key = os.environ["DEV_CONTAINER_PROJECT_KEY"]

    HOME.mkdir(parents=True, exist_ok=True)

    # Standalone step: re-run just the transcript mirror on demand (invoked by
    # `devcontainer copy-host-transcripts`). Full setup already runs this on
    # every entry; the standalone form is for picking up a host session that
    # started after the container came up, without a full re-setup.
    if sys.argv[1:] == ["copy-sessions"]:
        copied, skipped = copy_sessions(workspace, host_project_key, container_project_key)
        print(f"copied {copied} host transcript(s) ({skipped} already present, left untouched)")
        return

    copy_global_instructions()
    copy_global_memory()
    copy_user_prefs(workspace)
    seed_credentials(resolve_profile())
    setup_settings(workspace, host_project_key)
    setup_project_settings(host_project_key, container_project_key)
    copy_sessions(workspace, host_project_key, container_project_key)
    setup_sessions(workspace)
    setup_audit(workspace)


if __name__ == "__main__":
    main()
