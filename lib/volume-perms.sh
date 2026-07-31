# shellcheck shell=sh
# Ownership repair for named-volume mount points, factored out of setup() in
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

# dev_chown_volume_targets <owner> <group> <home-prefix> <mount-point>... —
# chown each mount point (recursively, guarded) and its <home-prefix>-scoped
# ancestors to <owner>:<group>. Ancestors are walked upward only while still
# strictly under <home-prefix>, so <home-prefix> itself and anything outside it
# (notably the bind-mounted host workspace) are never touched.
#
# chown failures are tolerated: the mount point may be on a read-only or
# ownership-fixed filesystem, and a hard failure here would abort a cold start
# that user-mode setup may well survive.
dev_chown_volume_targets() {
    _vp_user="$1"
    _vp_group="$2"
    _vp_home="$3"
    shift 3

    for _vp_d in "$@"; do
        [ -n "$_vp_d" ] || continue

        if dev_volume_chown_needed "$_vp_d" "$_vp_user" "$_vp_group"; then
            chown -R "$_vp_user:$_vp_group" "$_vp_d" 2>/dev/null || true
        fi

        _vp_p="$(dirname "$_vp_d")"
        while [ "$_vp_p" != "/" ] && [ "$_vp_p" != "." ]; do
            case "$_vp_p" in
                "$_vp_home"/*) ;;
                *) break ;;
            esac
            chown "$_vp_user:$_vp_group" "$_vp_p" 2>/dev/null || true
            _vp_p="$(dirname "$_vp_p")"
        done
    done
}
