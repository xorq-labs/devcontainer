# shellcheck shell=bash
# Resolve the main worktree path. The first entry in `git worktree list
# --porcelain` is always the main checkout, regardless of where the command
# is run from. Worktrees that need main-only state (project.env, dev/ scripts)
# must use this resolver, not `git rev-parse --show-toplevel` (which returns
# the *current* worktree).

dev_main_tree() {
    local out
    if ! out=$(git worktree list --porcelain 2>/dev/null); then
        echo "error: not in a git repository (run from within a checkout)" >&2
        return 1
    fi
    printf '%s\n' "$out" | head -1 | sed 's/^worktree //'
}

# Resolve the project overlay directory. Resolution order:
#   1. workspace .devcontainer/ (project chose to override)
#   2. devcontainer repo projects/<name>/ (shipped defaults)
#   3. devcontainer repo defaults/ (generic fallback)
# Usage: resolve_project_dir <base_dir> <main_tree> [project_name]
# project_name defaults to basename of main_tree.
resolve_project_dir() {
    local base_dir="$1" main_tree="$2"
    local name="${3:-$(basename "$main_tree")}"
    if [ -d "$main_tree/.devcontainer" ]; then
        printf '%s\n' "$main_tree/.devcontainer"
    elif [ -d "$base_dir/projects/$name" ]; then
        printf '%s\n' "$base_dir/projects/$name"
    else
        printf '%s\n' "$base_dir/defaults"
    fi
}

# Human-readable label for the resolved overlay directory.
project_dir_label() {
    local dir="$1" base_dir="$2"
    case "$dir" in
        */projects/*)  printf '%s\n' "${dir#"$base_dir/"}" ;;
        */.devcontainer) printf '%s\n' ".devcontainer/" ;;
        */defaults)    printf '%s\n' "defaults/ (no project overlay matched)" ;;
        *)             printf '%s\n' "$dir" ;;
    esac
}

# Docker Compose project names and volume names must match [a-z0-9][a-z0-9_-]*
# (lowercase, leading alphanumeric). Repo and worktree basenames don't have to:
# a dotfiles checkout is literally ".dotfiles", whose leading dot maps to a
# leading "-" and makes `docker compose -p` reject the project ("must ... start
# with a letter or number"). Normalize every name that feeds a compose project,
# a Docker volume, or a projects/<name> overlay tier: map disallowed characters
# to "-" (squeezing runs), lowercase, then trim leading/trailing
# non-alphanumerics. Falls back to "project" when nothing survives (e.g. an
# all-dots name). Shared by dev/devcontainer (runtime names) and dev/init
# (scaffolded projects/<name> path), so the two always agree.
sanitize_name() {
    local s
    s="$(printf '%s' "$1" \
        | tr -cs 'a-zA-Z0-9_-' '-' \
        | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/^[^a-z0-9]*//' -e 's/[^a-z0-9]*$//')"
    printf '%s' "${s:-project}"
}

# Marker identifying a hook this repo installed into a consuming project, so a
# later run can refresh it and never clobbers a hook someone wrote themselves.
_DEVCONTAINER_HOOK_MARKER="# installed-by: xorq-labs/devcontainer dev/hooks"

hook_is_managed() {
    grep -qF "$_DEVCONTAINER_HOOK_MARKER" "$1" 2>/dev/null
}

# Resolve a repo's .git/hooks, correct in both main and linked worktrees (where
# .git is a file and --git-common-dir may come back relative).
hooks_dir_for() {
    local root="$1" hooks_dir
    hooks_dir="$(git -C "$root" rev-parse --git-common-dir)/hooks" || return 1
    if [[ "$hooks_dir" != /* ]]; then
        hooks_dir="$root/$hooks_dir"
    fi
    printf '%s\n' "$hooks_dir"
}

# Symlink hooks from dev/hooks/ into .git/hooks/ for a given repo root.
# Works in both main worktrees and linked worktrees (where .git is a file).
# Refuses to clobber a non-symlink hook — except one we installed ourselves,
# which a symlink to the repo's own copy supersedes.
symlink_hooks() {
    local root="$1"
    local hooks_dir
    hooks_dir="$(hooks_dir_for "$root")" || return 1
    mkdir -p "$hooks_dir"
    local name
    for hook in "$root/dev/hooks/"*; do
        [ -f "$hook" ] || continue
        name="$(basename "$hook")"
        if ! [ -e "$hooks_dir/$name" ] || [ -L "$hooks_dir/$name" ] \
            || hook_is_managed "$hooks_dir/$name"; then
            ln -sfn "../../dev/hooks/$name" "$hooks_dir/$name"
        fi
    done
}

# Write $1 to $2 with the marker injected after the shebang, executable, and
# only when the content actually changed so mtimes stay stable across runs.
_write_managed_hook() {
    local src="$1" target="$2" label="$3" tmp first
    tmp="$(mktemp "$target.XXXXXX")" || return 1
    if IFS= read -r first <"$src" && [ "${first#'#!'}" != "$first" ]; then
        {
            printf '%s\n' "$first"
            printf '%s (source: %s)\n' "$_DEVCONTAINER_HOOK_MARKER" "$label"
            tail -n +2 "$src"
        } >"$tmp"
    else
        {
            printf '%s (source: %s)\n' "$_DEVCONTAINER_HOOK_MARKER" "$label"
            cat "$src"
        } >"$tmp"
    fi
    chmod +x "$tmp"
    if [ -f "$target" ] && [ ! -L "$target" ] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
    else
        mv -f "$tmp" "$target"
    fi
}

# Hooks this repo may push into a CONSUMING project. An allowlist, not the
# contents of dev/hooks/, because a hook is only safe to distribute if it is
# meaningful in a project that has never heard of it:
#
#   post-checkout  generic. Locks a new worktree and re-records its paths in host
#                  form. Needs no project configuration, and does nothing at all
#                  outside a worktree creation.
#
# dev/hooks/pre-commit is deliberately EXCLUDED. It ends in
# `exec pre-commit hook-impl --config=.pre-commit-config.yaml`, so in a project
# with no such config every commit dies with `TypeError: expected str, bytes or
# os.PathLike object, not NoneType` — and with pre-commit absent entirely it
# takes its own `exit 1` path. Either way, distributing it would break committing
# in any project that has not adopted pre-commit. Adding a name here means
# asserting it is inert in a project that does not use the tool behind it.
_DEVCONTAINER_SHARED_HOOKS=(post-checkout)

# Install this repo's allowlisted hooks into a CONSUMING project that has no copy
# of its own.
#
# Copied, not symlinked, and deliberately: a symlink would point at the
# devcontainer repo, which is not mounted inside the consuming project's
# container — only that project's tree and its .git are. The link would dangle
# exactly where the hook matters most. A copy under .git/hooks/ rides along with
# the .git bind mount and works in both namespaces.
#
# Per hook name, not all-or-nothing: a project may ship its own copy of one
# allowlisted hook while still needing another. Its own copy always wins.
copy_shared_hooks() {
    local base="$1" root="$2"
    [ -n "$base" ] && [ -d "$base/dev/hooks" ] || return 0
    [ "$base" != "$root" ] || return 0
    local hooks_dir
    hooks_dir="$(hooks_dir_for "$root")" || return 1
    mkdir -p "$hooks_dir"
    local name src target
    for name in "${_DEVCONTAINER_SHARED_HOOKS[@]}"; do
        src="$base/dev/hooks/$name"
        [ -f "$src" ] || continue
        # The project's own hook wins; symlink_hooks has already linked it.
        [ -f "$root/dev/hooks/$name" ] && continue
        target="$hooks_dir/$name"
        # Leave anything the project (or a person) put there that is not ours.
        if [ -e "$target" ] && [ ! -L "$target" ] && ! hook_is_managed "$target"; then
            continue
        fi
        _write_managed_hook "$src" "$target" "${src#"$base"/}"
    done
}

# Full hook setup for devcontainer/worktree contexts: clear hooksPath, symlink
# the repo's own hooks, then fill any gaps from the devcontainer repo when a base
# dir is given. Use symlink_hooks directly when only the symlinks are needed.
#
# $1 (optional): the devcontainer repo root. Host-side callers pass it; the
# in-container caller (projects/devcontainer/setup-env.sh) does not, because only
# lib/*.sh is baked into the image — dev/hooks/ is not there to copy from. Host
# installation covers the container anyway: the copy lands in .git/hooks, which
# the container sees through the .git bind mount.
install_hooks() {
    local base="${1:-}"
    local main
    main="$(dev_main_tree)" || return 1

    # Unset core.hooksPath so git uses the default .git/hooks/.
    # Tools like Claude Code may set this to a linked-worktree path where
    # .git is a file (not a directory), breaking all hooks. pre-commit also
    # refuses to install when core.hooksPath is set.
    git config --unset-all core.hooksPath 2>/dev/null || true

    symlink_hooks "$main"
    copy_shared_hooks "$base" "$main"
}
