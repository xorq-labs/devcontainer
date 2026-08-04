# shellcheck shell=sh
# Ownership repair for container mount points, factored out of setup() in
# dev/devcontainer so it can be unit-tested without docker
# (tests/test-volume-chown-guard.sh). Runs INSIDE the container as root: the
# caller reads this file on the host and injects it into `dc exec ... sh -c`,
# passing the mount points as positional args (nothing COPYs it into the image,
# so it is not a build input and edits need no rebuild).
#
# A freshly created named volume comes up owned by root:root, so its mount point
# must be chowned to the container user before user-mode setup writes to it. The
# ancestor directories are chowned too: a volume mounted at a path whose parents
# don't exist in the image (e.g. /home/vscode/.cache/uv) has those parents
# created by the daemon, also root-owned.
#
# BINDS ARE IN SCOPE FOR THE ANCESTOR WALK ONLY. The daemon creates a bind
# target's missing parents as root exactly as it does a volume's, and nothing
# else ever repairs them: that is what left ~/.claude/projects root-owned and
# unwritable, since the transcript bind mounts at ~/.claude/projects/<key>
# inside the claude-home volume (#106). Everything at or below a bind mount
# point is the HOST side, so a bind is never recursed INTO and the ancestor
# walk never chowns a bind mount point — see _vp_never_chown.
#
# What that does NOT cover, and this is deliberate and recorded (#115): the
# recursive branch below is rooted at a VOLUME and `chown -R` has no mount
# awareness, so it still descends through a bind nested UNDER that volume —
# exactly the claude-home / transcript-bind topology above. That predates the
# ancestor-walk work and is latent only because the guard's precondition (a
# volume root not already user-owned) is not normally met. Do not read
# _vp_never_chown as protecting the recursion; it is consulted by
# dev_chown_ancestors alone.
#
# THE GUARD (why the recursion is conditional):
#   setup() is named "first-run" but is gated only on `is_running`, so it re-runs
#   on every cold start — after a host reboot, a `devcontainer down`, or a
#   container recreate. An unconditional `chown -R` then re-walks the whole
#   volume each time. That is not free at cache scale: a uv cache can reach tens
#   of GB across millions of inodes, and GNU chown skips the syscall when
#   ownership already matches but still has to stat every inode. Post-reboot the
#   kernel's dentry/inode cache is cold, so the walk hits disk and takes minutes.
#
#   dev_volume_chown_needed short-circuits that to a single stat: the mount point
#   itself is only root-owned on a fresh volume, so a mount point already owned
#   by the target user means a previous run finished the recursion.
#
#   "Finished" is load-bearing and depends on traversal order: `chown -R` is
#   post-order (children before parents, the top directory LAST), so a run
#   interrupted partway leaves the mount point still root-owned and the next
#   cold start redoes it. A partially-chowned tree is therefore never mistaken
#   for a completed one.
#
#   What the guard deliberately does NOT repair: root-owned files written into
#   an already-chowned volume later (e.g. by a `dc exec -u root`), and files a
#   COMPLETED walk failed to chown (chown -R continues past per-file errors —
#   immutable flags, I/O errors — still chowns the top last, and the errors are
#   suppressed below; the guard then reads the volume as done). In both cases
#   the mount point is user-owned, so the recursion is skipped. Forcing a full
#   pass is a separate, explicit operation — not something every cold start
#   should pay for. (A read-only filesystem is safe either way: the top-dir
#   chown fails too, so the guard stays open.)
#
# The ancestor chowns stay unconditional: they are O(depth) single-file chowns,
# not a walk, and a mount point can be user-owned while a parent the daemon
# created is not.

# dev_volume_chown_needed <mount-point> <owner> <group> — true (0) when
# <mount-point> needs the recursive chown: it exists and is not owned by
# <owner>:<group>. Both are checked because the walk establishes both — an
# owner-only probe would read a vscode:root mount point as done and never
# repair the group. An unstattable directory is treated as needing it (let
# chown report the real error); a missing mount point needs nothing.
dev_volume_chown_needed() {
    [ -d "$1" ] || return 1
    _vp_owner="$(stat -c '%U %G' "$1" 2>/dev/null)" || return 0
    [ "$_vp_owner" = "$2 $3" ] && return 1
    return 0
}

_vp_nl='
'

# Paths the ancestor walk must never chown, newline-delimited and
# newline-terminated at both ends so a `case` glob tests membership exactly
# (a path may contain spaces and glob metacharacters, so neither is usable as a
# delimiter). A path may legally contain a newline too — but such a target is
# already unrepresentable upstream, where chown_mount_points reads the compose
# query's output line by line, so nothing reaches here that this could split.
#
# dev_chown_mount_points fills this with every BIND target, because an ancestor
# can itself be a bind mount point — chowning it writes to the host side. This
# is not hypothetical: docker-compose.yml mounts DEV_MAIN_TREE and DEV_MAIN_GIT
# at their HOST paths, and DEV_MAIN_GIT (<tree>/.git) nests inside DEV_MAIN_TREE,
# so on a host whose checkout lives under the container home prefix (a host user
# named `vscode`; Codespaces) the walk up from the .git target reaches the
# worktree bind and would rewrite ownership of the user's real repo directory.
#
# Empty when dev_chown_volume_targets is driven directly — that entry point is
# unchanged, and with no bind targets declared there is nothing to protect.
_vp_never_chown=""

# _vp_is_protected <path> — true when <path> is on the host side of a bind
# recorded by dev_chown_mount_points: either a bind mount point itself, or a
# path UNDER one. The expansions in the patterns are quoted, so a path
# containing glob metacharacters is compared literally rather than matched.
#
# The under-a-bind case is not redundant. An exact-match-only test protects the
# mount point but not the directories inside it, and the ancestor walk reaches
# those whenever one bind nests two or more levels under another — e.g. binds at
# /home/vscode/data and /home/vscode/data/secrets/keys leave the walk chowning
# /home/vscode/data/secrets, which is host-side. docker-compose.yml itself only
# nests one level deep (<tree>/.git directly under <tree>), but host-mounts.txt
# accepts arbitrary <host>:<container> pairs with no depth restriction
# (lib/host-mounts.sh), so the deeper shape is reachable in a user's config.
_vp_is_protected() {
    [ -n "$_vp_never_chown" ] || return 1

    case "$_vp_never_chown" in
        *"$_vp_nl$1$_vp_nl"*) return 0 ;;
    esac

    # Walk the set entry by entry, testing whether <path> lies under any of
    # them. _vpx_-prefixed so this cannot clobber the ancestor walk's iterator.
    _vpx_rest="${_vp_never_chown#"$_vp_nl"}"
    while [ -n "$_vpx_rest" ]; do
        # Termination precondition: every entry is newline-TERMINATED. Without
        # a trailing newline the `#*nl` strip removes nothing and this loops
        # forever — confirmed under dash. Unreachable via the only writer
        # (dev_chown_mount_points always appends one), but this runs as root
        # inside `dc exec` on every cold start, so a future writer that drops
        # the terminator would turn a wrong answer into a startup HANG.
        case "$_vpx_rest" in
            *"$_vp_nl"*) ;;
            *) break ;;
        esac
        _vpx_e="${_vpx_rest%%"$_vp_nl"*}"
        _vpx_rest="${_vpx_rest#*"$_vp_nl"}"
        [ -n "$_vpx_e" ] || continue
        case "$1" in
            "$_vpx_e"/*) return 0 ;;
        esac
    done

    return 1
}

# dev_chown_ancestors <owner> <group> <home-prefix> <path>... — chown each
# path's <home-prefix>-scoped ancestors to <owner>:<group>. Ancestors are walked
# upward only while still strictly under <home-prefix>, so <home-prefix> itself
# and anything outside it (notably the bind-mounted host workspace) are never
# touched, and any ancestor that is itself a bind mount point is skipped while
# the walk continues past it — its own parents are still container-side.
#
# The paths themselves are NOT chowned and nothing recurses. That is what makes
# this safe to point at a bind mount point.
#
# chown failures are tolerated: the mount point may be on a read-only or
# ownership-fixed filesystem, and a hard failure here would abort a cold start
# that user-mode setup may well survive.
dev_chown_ancestors() {
    _vpa_user="$1"
    _vpa_group="$2"
    _vpa_home="$3"
    shift 3

    for _vpa_d in "$@"; do
        [ -n "$_vpa_d" ] || continue

        _vpa_p="$(dirname "$_vpa_d")"
        while [ "$_vpa_p" != "/" ] && [ "$_vpa_p" != "." ]; do
            case "$_vpa_p" in
                "$_vpa_home"/*) ;;
                *) break ;;
            esac
            if ! _vp_is_protected "$_vpa_p"; then
                chown "$_vpa_user:$_vpa_group" "$_vpa_p" 2>/dev/null || true
            fi
            _vpa_p="$(dirname "$_vpa_p")"
        done
    done
}

# dev_chown_volume_targets <owner> <group> <home-prefix> <mount-point>... —
# chown each mount point (recursively, guarded) and its <home-prefix>-scoped
# ancestors to <owner>:<group>.
#
# Loop variables are _vpt_-prefixed, not _vpa_: these are shell globals (POSIX
# sh has no `local`), so sharing a prefix with dev_chown_ancestors would let the
# callee clobber this loop's iterator mid-walk.
dev_chown_volume_targets() {
    _vpt_user="$1"
    _vpt_group="$2"
    _vpt_home="$3"
    shift 3

    for _vpt_d in "$@"; do
        [ -n "$_vpt_d" ] || continue

        if dev_volume_chown_needed "$_vpt_d" "$_vpt_user" "$_vpt_group"; then
            chown -R "$_vpt_user:$_vpt_group" "$_vpt_d" 2>/dev/null || true
        fi

        dev_chown_ancestors "$_vpt_user" "$_vpt_group" "$_vpt_home" "$_vpt_d"
    done
}

# dev_chown_mount_points <owner> <group> <home-prefix> <kind>:<mount-point>... —
# dispatch by compose mount type. `volume` gets the guarded recursive chown plus
# its ancestors; `bind` gets ancestors ONLY.
#
# An unknown kind is skipped rather than guessed at: the recursive branch is the
# destructive one, so a compose mount type this lib has not been taught about
# (tmpfs, npipe, cluster) must not fall into it.
dev_chown_mount_points() {
    _vpm_user="$1"
    _vpm_group="$2"
    _vpm_home="$3"
    shift 3

    # Bind targets are collected in a FIRST pass: the protection has to cover
    # every bind before any walk runs, or the order of the argument list decides
    # whether a host directory gets chowned.
    _vp_never_chown="$_vp_nl"
    for _vpm_a in "$@"; do
        case "$_vpm_a" in
            bind:?*) _vp_never_chown="$_vp_never_chown${_vpm_a#bind:}$_vp_nl" ;;
        esac
    done

    for _vpm_a in "$@"; do
        [ -n "$_vpm_a" ] || continue
        _vpm_kind="${_vpm_a%%:*}"
        _vpm_d="${_vpm_a#*:}"
        [ -n "$_vpm_d" ] || continue

        case "$_vpm_kind" in
            volume)
                dev_chown_volume_targets "$_vpm_user" "$_vpm_group" \
                    "$_vpm_home" "$_vpm_d"
                ;;
            bind)
                dev_chown_ancestors "$_vpm_user" "$_vpm_group" \
                    "$_vpm_home" "$_vpm_d"
                ;;
        esac
    done

    # Scoped to this call: a later direct dev_chown_volume_targets must not
    # inherit protections derived from a compose config it was not given.
    _vp_never_chown=""
}
