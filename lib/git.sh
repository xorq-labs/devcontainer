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

# Symlink all committable hooks from dev/hooks/ into .git/hooks/ so that
# every environment (host and container) uses the same hook scripts.
# Refuses to clobber a non-symlink hook.
install_hooks() {
    local main
    main="$(dev_main_tree)" || return 1

    # Unset core.hooksPath so git uses the default .git/hooks/.
    # Tools like Claude Code may set this to a linked-worktree path where
    # .git is a file (not a directory), breaking all hooks. pre-commit also
    # refuses to install when core.hooksPath is set.
    git config --unset-all core.hooksPath 2>/dev/null || true

    local hooks_dir="$main/.git/hooks"
    mkdir -p "$hooks_dir"
    local name
    for hook in "$main/dev/hooks/"*; do
        [ -f "$hook" ] || continue
        name="$(basename "$hook")"
        if ! [ -e "$hooks_dir/$name" ] || [ -L "$hooks_dir/$name" ]; then
            ln -sf "../../dev/hooks/$name" "$hooks_dir/$name"
        fi
    done
}
