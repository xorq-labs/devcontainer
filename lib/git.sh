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
    # sed, not `| head -1 |`, same as dev/hooks/pre-commit: head closes the pipe
    # early. A builtin printf is NOT one write — it chunks, so this races under
    # pipefail too, just at a larger size (tests/test-hook-precommit.sh).
    printf '%s\n' "$out" | sed -n '1s/^worktree //p'
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

# Symlink hooks from dev/hooks/ into .git/hooks/ for a given repo root.
# Works in both main worktrees and linked worktrees (where .git is a file).
# Refuses to clobber a non-symlink hook.
symlink_hooks() {
    local root="$1"
    local hooks_dir
    hooks_dir="$(git -C "$root" rev-parse --git-common-dir)/hooks"
    if [[ "$hooks_dir" != /* ]]; then
        hooks_dir="$root/$hooks_dir"
    fi
    mkdir -p "$hooks_dir"
    local name legacy
    for hook in "$root/dev/hooks/"*; do
        [ -f "$hook" ] || continue
        name="$(basename "$hook")"
        if ! [ -e "$hooks_dir/$name" ] || [ -L "$hooks_dir/$name" ]; then
            ln -sf "../../dev/hooks/$name" "$hooks_dir/$name"
        fi
        # Drop a <name>.legacy that is OUR hook — the recursion `pre-commit
        # install` leaves behind (tests/test-hook-symlinks.sh for the incident
        # and what may not change). Identity, never content or mere existence: a
        # third-party .legacy is what migration mode is for and must survive.
        # Resolved against the relative target installed above, never
        # "$root/dev/hooks/$name" — the shared hooks dir belongs to the main
        # checkout, so under a linked-worktree $root those differ and every
        # worktree call would silently miss.
        legacy="$hooks_dir/$name.legacy"
        if [ -e "$legacy" ] &&
            [ "$(readlink -f "$legacy")" = "$(readlink -f "$hooks_dir/../../dev/hooks/$name")" ]; then
            rm -f "$legacy"
        fi
    done
}

# Full hook setup for devcontainer/worktree contexts: clear hooksPath then
# symlink hooks. Use symlink_hooks directly when only the symlinks are needed.
install_hooks() {
    local main
    main="$(dev_main_tree)" || return 1

    # Unset core.hooksPath so git uses the default .git/hooks/.
    # Tools like Claude Code may set this to a linked-worktree path where
    # .git is a file (not a directory), breaking all hooks. pre-commit also
    # refuses to install when core.hooksPath is set.
    git config --unset-all core.hooksPath 2>/dev/null || true

    symlink_hooks "$main"
}
