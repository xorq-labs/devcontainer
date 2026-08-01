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

Setup-token profiles (docs/adr/0002-devcontainer-setup-token-env-delivery.md)
are the second credential type: a raw CLAUDE_CODE_OAUTH_TOKEN bearer stored as
credentials/<profile>.token, consumed from the ENVIRONMENT rather than seeded to
disk. `seed_credentials` therefore no-ops (cleanly) for a token-only profile,
and the `token-path` subcommand resolves which token file a launch should read.

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
# A Docker/Compose file-based secret is the sanctioned mountless transport for a
# setup-token (tmpfs, 0400, absent from `docker inspect`). Overridable so the
# resolver can be exercised off-container (see tests/test-claude-token.sh).
RUN_SECRETS_TOKEN = Path(os.environ.get("CLAUDE_RUN_SECRETS_TOKEN", "/run/secrets/claude_code_oauth_token"))
# The profile this container's seed resolved, pinned for launches — which never
# inherit DEV_CLAUDE_PROFILE (it is forwarded per-exec, not baked into the
# container env). Written by `seed-credentials`, read by resolve_profile.
ACTIVE_PROFILE_RECORD = HOME / ".active-profile"

# Env sources that outrank CLAUDE_CODE_OAUTH_TOKEN in claude's precedence order
# (docs/adr/0002-devcontainer-setup-token-env-delivery.md). PAIRED with the
# unset-list in lib/claude-code-token-env.sh — the snippet drops these for the
# launches it wraps; `token-doctor` flags any that remain ambient under an active
# token profile. Keep the two lists in sync. Only the
# ANTHROPIC_API_KEY > ANTHROPIC_AUTH_TOKEN > CLAUDE_CODE_OAUTH_TOKEN order is
# empirically pinned (claude v2.1.215); the cloud/base-url tiers are docs-only,
# cleared/flagged defensively. RE-VERIFY on every claude upgrade.
HIGHER_PRECEDENCE_ENV = (
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
)

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


def resolve_profile(use_record=True):
    """Which profile to use: DEV_CLAUDE_PROFILE, else the profile this
    container's seed pinned, else the host's active profile.

    The container record tier exists because launches never inherit
    DEV_CLAUDE_PROFILE: it is forwarded per-exec (seeding, fix-credentials,
    token-doctor) but is absent from the ambient container env that shells and
    the `devcontainer claude` wrapper resolve in. Without the record, a launch
    falls through to the HOST marker and can inject a different profile's
    token than seeding installed — silently authenticating as the wrong
    identity (ADR-0002's "no silent routing" goal). Seeding writes the record
    (see `seed-credentials` in main), so every later launch resolves the same
    profile the seed used, and a re-seed with a different profile re-pins it.

    Seeding itself resolves with use_record=False: the record must not feed
    the resolution that writes it, or a stale pin would re-seed itself forever
    and a host profile switch + fix-credentials would never take.
    """
    profile = os.environ.get("DEV_CLAUDE_PROFILE", "").strip()
    if profile:
        return profile
    if use_record and ACTIVE_PROFILE_RECORD.exists():
        record = ACTIVE_PROFILE_RECORD.read_text().strip()
        if record:
            return record
    marker = HOST / "credentials" / "active-profile"
    if marker.exists():
        return marker.read_text().strip()
    return ""


def record_active_profile(profile):
    """Pin the seed-time profile for launches (they don't see DEV_CLAUDE_PROFILE).

    An empty resolution clears a stale record instead of writing one, so a
    container seeded with no profile anywhere tracks the host marker live
    rather than an obsolete pin.
    """
    if profile:
        HOME.mkdir(parents=True, exist_ok=True)
        ACTIVE_PROFILE_RECORD.write_text(profile + "\n")
    elif ACTIVE_PROFILE_RECORD.exists():
        ACTIVE_PROFILE_RECORD.unlink()


def _set_onboarding_prefs():
    """Set the onboarding flags in .claude.json without touching identity.

    Used by the setup-token path, which seeds no credential file and no
    oauthAccount (identity under env-token auth is thin and resolved
    server-side) but still needs onboarding skipped so the session runs.
    """
    prefs = {}
    if CONTAINER_PREFS.exists():
        with open(CONTAINER_PREFS) as f:
            prefs = json.load(f)
    prefs.setdefault("hasCompletedOnboarding", True)
    prefs.setdefault("installMethod", "native")
    with open(CONTAINER_PREFS, "w") as f:
        json.dump(prefs, f, indent=2)


def token_path():
    """Resolve the container-side setup-token file a launch should read, or None.

    Resolution order (docs/adr/0002-devcontainer-setup-token-env-delivery.md):

    1. An explicit `set-token` override (`~/.claude/.oauth-token`) — a manual
       "override this container now" action, so it wins even over a configured
       secret (matters when debugging a container that has one).
    2. A Docker/Compose file-based secret (`/run/secrets/...`) — the sanctioned
       mountless transport (tmpfs, 0400, absent from `docker inspect`).
    3. The read-only host store (`.claude-host/credentials/<profile>.token`) —
       read live, never seeded, so a host-side delete takes effect immediately
       (a setup-token has no CLI revoke; deletion is the only revoke).
    """
    private = HOME / ".oauth-token"
    if _usable_token(private):
        return private
    if _usable_token(RUN_SECRETS_TOKEN):
        return RUN_SECRETS_TOKEN
    profile = resolve_profile()
    if profile:
        store_token = HOST / "credentials" / f"{profile}.token"
        if _usable_token(store_token):
            return store_token
    return None


def _usable_token(path):
    """A token file a launch can actually consume: present, readable, non-empty.

    Skipping unusable tiers (instead of returning the first that exists) lets
    resolution fall through — an unreadable override or an empty hand-created
    file must not shadow a working lower tier, and returning a path the
    snippet's own -r/-s guards then reject would report a token as active
    without one ever being injected.
    """
    try:
        return path.is_file() and os.access(path, os.R_OK) and path.stat().st_size > 0
    except OSError:
        return False


def token_doctor():
    """Flag higher-precedence auth sources that would silently outrank an active
    setup-token (docs/adr/0002-devcontainer-setup-token-env-delivery.md).

    Selection of a setup-token is by env precedence, so the container must stay
    clean of the sources that sit above CLAUDE_CODE_OAUTH_TOKEN. The token-env
    snippet drops them for the launches it wraps, but an ambient value (a baked
    image env, a compose `environment:`, a CI secret) — or an `apiKeyHelper` a
    user adds to settings.json by hand — would win with no error and route
    traffic down an unintended, possibly API-billed path.

    Prints a report and returns the number of shadowing sources found (0 =
    clean). No-ops with 0 when no token profile is active — there is nothing the
    precedence rule applies to (the OAuth file path or ambient auth is in use).

    Intended to run at the container's ambient env baseline (a plain `dc exec`,
    which sources neither /etc/profile.d nor the snippet), so it sees the same
    env a non-wrapper launch — an MCP server, a background agent — would inherit.
    """
    path = token_path()
    if path is None:
        print("note: no setup-token profile active — precedence check skipped (OAuth file or ambient auth in use)")
        return 0

    conflicts = [name for name in HIGHER_PRECEDENCE_ENV if os.environ.get(name)]

    # apiKeyHelper is a settings.json hook that also outranks the token. It is
    # handled out of band — setup_settings rebuilds the container settings.json
    # from scratch and never copies it — but a user could add one by hand, so
    # flag it here too.
    settings = HOME / "settings.json"
    if settings.exists():
        try:
            with open(settings) as f:
                if json.load(f).get("apiKeyHelper"):
                    conflicts.append("apiKeyHelper (settings.json)")
        except (json.JSONDecodeError, OSError):
            pass

    if not conflicts:
        print(f"ok: setup-token active ({path}); no higher-precedence source shadows it")
        return 0

    print(
        f"warning: setup-token active ({path}) but these higher-precedence sources are set "
        "and will SILENTLY outrank it:",
        file=sys.stderr,
    )
    for name in conflicts:
        print(f"  - {name}", file=sys.stderr)
    print(
        "  the token-env snippet drops the env ones for launches it wraps, but a value exported "
        "after shell init (or an apiKeyHelper added by hand) still wins. Unset them for this "
        "container, or clear the ambient source.",
        file=sys.stderr,
    )
    return len(conflicts)


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
        # A setup-token profile (ADR-0002) has a <profile>.token but no
        # <profile>.json. There is nothing to seed onto disk — the token is
        # injected as CLAUDE_CODE_OAUTH_TOKEN at launch (see the token-env
        # snippet, resolved via `token-path`). Skip the file seed cleanly, but
        # still set the onboarding prefs so the session doesn't re-onboard.
        if (store / f"{profile}.token").exists():
            _set_onboarding_prefs()
            print(
                f"note: profile '{profile}' is a setup-token profile — no credential file "
                "seeded; the token is injected as CLAUDE_CODE_OAUTH_TOKEN at launch"
            )
            return
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
        # Fresh resolution (env > host marker, record excluded), then pin it
        # for launches BEFORE seeding: token-path in every later shell must
        # agree with what this seed installed (see resolve_profile).
        # fix-credentials re-runs this, re-pinning.
        profile = resolve_profile(use_record=False)
        record_active_profile(profile)
        seed_credentials(profile)
        return

    # Standalone token resolver (used by the token-env snippet and the
    # `devcontainer claude` wrapper). Prints the active setup-token file path and
    # exits 0 when one exists, else stays silent and exits 1 — so a caller can do
    # `t="$(setup-claude token-path)" && export ...`. Needs only the profile +
    # store, not the project-key vars, so it runs before the REQUIRED_VARS check.
    if sys.argv[1:] == ["token-path"]:
        path = token_path()
        if path is None:
            return 1
        print(path)
        return 0

    # Standalone precedence doctor (invoked by `devcontainer token-doctor`).
    # Warns when a source that outranks CLAUDE_CODE_OAUTH_TOKEN is present while a
    # setup-token profile is active; exits non-zero if any is found so CI can gate
    # on it. Like token-path, needs only the profile + store, so it runs before
    # the REQUIRED_VARS check.
    if sys.argv[1:] == ["token-doctor"]:
        return 1 if token_doctor() else 0

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
    sys.exit(main())
