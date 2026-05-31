# Project overlays

Each subdirectory is a project-specific overlay applied on top of the base devcontainer image. See `defaults/` for the fallback overlay and file-by-file documentation.

## Creating a new overlay

Start from the closest existing overlay, not `defaults/`. The volume topology, toolchain pinning, and SHA256 checksums are easy to get wrong from scratch — stripping what you don't need is faster and less error-prone.

### Cargo volumes

Rust overlays use a three-volume split:

- `cargo-registry` and `cargo-git` — shared across worktrees (`external: true`). These are content-addressed and safe to share.
- `cargo-target` — per-worktree (no `external: true`). Concurrent writes to a shared target dir corrupt incremental build state.

Shared volumes must be listed in `external-volumes.txt` so `ensure_external_volumes()` pre-creates them before compose up. Missing an entry here means the first `devcontainer up` fails with a missing-volume error.

The `cargo-target` mount point must match where the crate root is. For example, `xorq-desktop` mounts it at `desktop/src-tauri/target` while `batchcorder` mounts at the repo-root `target/`. Getting this wrong means builds write to the wrong place.

### Expensive build steps

Gate expensive build steps (e.g., `maturin develop`) behind artifact presence checks so container recreation with persisted volumes doesn't pay for a redundant rebuild. Use file-presence tests (`compgen -G "path/*.so"`) rather than import probes, which can trigger the build tool and defeat the skip.
