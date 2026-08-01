# ADR-0004: Durable Claude memory carve-outs (bind, don't copy)

- Status: Proposed
- Date: 2026-08-01
- Implemented by: this PR (devcontainer)
- Related: **devcontainer ADR-0001** — the credential isolation model this ADR
  deliberately does NOT extend to memory (memory is inert facts, not auth
  material); **devcontainer ADR-0003** — the tracked-content tier
  (`.claude/agents/`) that remains the sanctioned path for shareable
  *executable* instructions.

## Context

Claude Code keeps two memory stores under `~/.claude`: a global one
(`~/.claude/memory/`) and a per-project one
(`~/.claude/projects/<key>/memory/`). Each is a directory of
one-fact-per-file markdown plus a `MEMORY.md` index; **the index is what gets
loaded into a session's context**, so the load-bearing invariant is: *every
memory file has an index line*. A memory whose index line is lost is orphaned
— present on disk, invisible to every future session.

In the container, `~/.claude` is the per-worktree `claude-home` named volume,
destroyed by `reset`/`clean`. Memory was handled by one-way host→container
copies in `setup-claude.py`, which run on **every entry** (`setup_claude` in
`lib/host-bridge.sh`, called from the `up` path in `dev/devcontainer`
unconditionally, outside the `is_running` gate):

- `copy_global_memory()`: `copytree(HOST/memory, HOME/memory,
  dirs_exist_ok=True)`
- `setup_project_settings()`: the same `copytree` for
  `projects/<host-key>/memory`

### The index-clobber defect (observed, not hypothetical)

`copytree(..., dirs_exist_ok=True)` overwrites same-named destination files.
Individual memory files rarely collide (slugs differ); `MEMORY.md` collides
**always** — every memory dir has exactly one, at a fixed name. So a
container session's index edits were destroyed on the next entry while the
memory files they pointed at survived. Observed in a live container
(2026-08-01): `project_agent_workflow_rubric.md` written and indexed by a
container session on Aug 1; a later entry copied the host's Jul 20 `MEMORY.md`
over the index (mtimes preserved by `copy2` made this directly visible);
the memory is on disk and in no session's context.

Two more structural gaps, same root cause (copy-based, volume-resident):

- Global memory written in-container never reaches the host and dies with the
  volume on `clean`.
- The per-project store the container actually writes rides the
  `DEV_CLAUDE_LOGS` transcript bind (so it *does* survive `clean`), but under
  the per-container key `-devcontainer-<compose-project>` — invisible to host
  sessions (keyed by host cwd) and siloed per worktree.

## Decision

Treat memory like transcripts: **it cannot be rebuilt, so it lives on the
host and is bind-mounted, not copied.** Two new binds in
`docker-compose.yml`, sources pre-created by `ensure_claude_memory` in
`dev/devcontainer`:

- `${DEV_CLAUDE_GLOBAL_MEMORY}` (default `~/.claude/memory`) →
  `/home/vscode/.claude/memory`
- `${DEV_CLAUDE_MEMORY}` (default
  `~/.claude/projects/<main-checkout-key>/memory`) →
  `/home/vscode/.claude/projects/<container-key>/memory`, nested inside the
  transcript bind.

Deleting the copy removes the clobber defect class entirely — container and
host now edit the same index file, so there is nothing to reconcile. It also
makes memory survive `clean`, shares one per-project store across **all**
worktree containers and host sessions started in the main checkout, and lets
host tooling read/write container-written memories directly.

**Key choice**: the per-project store is keyed by the MAIN checkout's path
(`DEV_SHARED_PROJECT_KEY` from `DEV_MAIN_TREE`), not the worktree's. Memories
describe the project, not the checkout; keying per-worktree would preserve
today's amnesia between worktree agents. The trade-off: a *host* session
started inside a worktree directory (keyed by the worktree path) still sees
its own store — accepted, since worktree work here happens in containers.
Concurrent index appends from parallel containers can race (last-writer-wins
on `MEMORY.md`); accepted as identical to today's exposure with parallel host
sessions, and self-healing via index synthesis (below).

### Copy paths: demoted to a mountless fallback, never clobbering

`copy_global_memory` and the `setup_project_settings` memory branch are NOT
dead code: they remain the fallback for setups that run compose without
`dev/devcontainer` (no binds). Both now call `merge_memory()`, which:

- no-ops when source and destination are the same directory
  (`os.path.samefile` — i.e. the bind is present);
- unions `MEMORY.md` by link target, **container line winning** on collision.
  (Not the tempting "skip if exists": that orphans in the mirror direction —
  a new host memory would arrive with no index line.)
- copies other files only when the destination is missing or older;
- synthesizes an index line (from frontmatter `name:`/`description:`) for any
  memory file the index does not reference — restoring the every-file-indexed
  invariant, including orphans left by the old clobber.

### Migration (shadowing hazard)

The container project dir is *already* a bind (`DEV_CLAUDE_LOGS`), so the new
nested bind mounts **over** a directory that holds real pre-ADR-0004
memories; without migration they would be silently shadowed, not merged.
`migrate_project_memory` (in `lib/claude-memory.sh`, run host-side by
`ensure_claude_memory` before compose mounts) merges
`$DEV_CLAUDE_LOGS/memory` into the shared store with the same union
semantics (legacy/container index line wins), drains merged files so a
deleted memory cannot resurrect from the legacy copy, and leaves the emptied
directory as a vscode-owned mountpoint stub. Interrupted runs self-heal:
copy-before-remove means the next entry re-merges the remainder. Index
synthesis at the end also repairs previously-orphaned memories.

## Alternatives considered

- **Smarter copy (two-way sync on entry/exit)** — keeps two divergent stores
  and a reconciliation problem; loses writes on crash; strictly worse than
  sharing one directory.
- **Skip `MEMORY.md` when present container-side** — fixes one direction of
  the clobber, reproduces it mirrored (new host memories arrive unindexed).
- **Key the shared store by worktree path** — matches host-session keying for
  worktrees but keeps agents amnesiac across worktrees; rejected (see Key
  choice).

## Deferred: skills and other executable instructions

Memory is inert facts, so bidirectional host sharing is safe. User-level
**skills** (`~/.claude/skills/`, currently neither seeded nor persisted) are
executable instructions: a rw bind would let a container agent plant
instructions the host's Claude later runs, crossing the isolation instinct of
ADR-0001. Options, with a recommendation, for a future ADR/amendment:

- **A. rw bind both ways** — maximal fluidity; acceptable on a single-user
  host, but silently widens the container→host influence channel.
- **B. host→container `:ro` bind** (recommended) — containers consume host
  skills; authoring flows through the git-tracked project tier
  (`.claude/skills/` + a `!.claude/skills/` re-include mirroring ADR-0003),
  so new executable instructions reach the host via PR review, not silently.
- **C. dedicated shared dir** (`~/.claude/devcontainer-shared/`) — clean-proof
  but invisible to host sessions without symlinks; least fluid.

## Consequences

- `devcontainer clean`/`reset` no longer destroy memory; the recreate prompt
  fires once per existing container (new mounts are runtime staleness).
- The binds pair with `dev/devcontainer` exports per the `${VAR:?}` mount
  invariant; `ensure_claude_memory` must run before the first `dc up` (it
  does, beside `ensure_claude_logs` in the locked setup block).
- Drift guard: `tests/test-claude-memory.sh` pins, at both layers (bash
  migration, python fallback), that a container-written index line survives a
  reseed, that orphans get synthesized index lines, and that the samefile
  guard keeps the bind path copy-free.
