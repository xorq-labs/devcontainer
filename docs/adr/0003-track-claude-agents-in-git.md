# ADR-0003: Track `.claude/agents/` in git; per-subdir state symlinks

- Status: Proposed
- Date: 2026-08-01
- Implemented by: this PR (devcontainer)
- Related: **devcontainer ADR-0001 / ADR-0002** — the container's Claude state
  model this ADR must not disturb (audit logs and session stubs aggregating in
  the main checkout). Upstream Claude Code convention (sub-agents /
  claude-directory docs): project subagents in `.claude/agents/` are checked
  into version control; only `settings.local.json` and local agent memory stay
  untracked.

## Context

Upstream Claude Code treats `.claude/` as a mixed directory: `agents/` (and
project `settings.json`) are shared, version-controlled content; per-developer
state (`settings.local.json`, local memory) is not. This repo deviates in two
coupled places, both in service of state aggregation:

- `.gitignore.template` ignores the **whole** `.claude` directory with a bare
  `.claude` entry.
- `dev/setup-worktree` symlinks the **whole** directory,
  `<worktree>/.claude -> <main>/.claude`, so container audit logs
  (`container-audit/`) and session stubs (`container-sessions/`) from every
  worktree aggregate in the main checkout.

We now want a tracked project subagent (`.claude/agents/pr-reviewer.md`), and
the two deviations collide with that head-on:

- Gitignore semantics: a pattern that matches the **directory itself** (bare
  `.claude`) makes git skip the directory wholesale — no negation inside it
  can re-include anything. `.claude/*` matches only the directory's entries,
  so `!.claude/agents/` works under it (verified with `git check-ignore -v`).
- Checkout semantics: once a file under `.claude/` is tracked,
  `git worktree add` materializes a real `.claude/agents/` during checkout,
  and setup-worktree's whole-directory `ln -s` then collides with it.

### How the shared state actually reaches the main checkout (investigated)

The mechanism the new layout must preserve: setup-worktree creates an
**absolute** symlink (`ln -sv "$main/$target" ...`), and `docker-compose.yml`
bind-mounts the main checkout **at its own host path** inside the container
(`- ${DEV_MAIN_TREE}:${DEV_MAIN_TREE}:cached`; the sibling
`${DEV_MAIN_GIT}` mount just above it is the one carrying the "so worktree
`.git` files' absolute `gitdir:` pointers resolve" rationale, and the main
tree is mounted at its own host path for the same reason — absolute paths
into the main checkout have to mean the same thing inside the container as
outside). So inside a worktree's
container, `/workspaces/src/.claude` dereferences to the main checkout's host
path, which is mounted, and audit writes land in the main checkout. The
current symlink does **not** dangle in-container; aggregation works through
the main-tree mount. Per-subdir absolute symlinks resolve through exactly the
same mount, so nothing about the container plumbing changes. In-container
consumers keep working unmodified: `setup-claude.py` does
`mkdir(parents=True, exist_ok=True)` on both subdirs (a no-op through a valid
link) and `audit-hook` appends through the link.

## Decision

Narrow both the ignore and the symlink from the whole `.claude` directory to
its state subdirectories, so tracked content under `.claude/` can coexist.

- **`.gitignore.template`**: replace the bare `.claude` entry with `.claude/*`
  + `!.claude/agents/`. Runtime state (`container-audit/`,
  `container-sessions/`, `settings.local.json`, `worktrees/`) stays ignored;
  `agents/` is tracked. The live `.gitignore` is untracked and per-checkout,
  so this ships as a template change plus a one-time developer migration (see
  Consequences).
- **`dev/setup-worktree`**: create a real `<worktree>/.claude/` directory
  (`mkdir -p`, tolerating one already materialized by checkout) and symlink
  only `container-audit` and `container-sessions` from the main checkout,
  creating them in main first if absent. Manifest entries stay in the
  existing `<action>\t<path>` vocabulary (`symlink\t.claude/container-audit`,
  ...), so `dev/cleanup-worktree` needs no format change: its `symlink` action
  removes the links and its existing `rmdir -p` pass removes the then-empty
  `.claude` directory (or leaves it when tracked `agents/` content remains,
  which `git worktree remove` owns).
- **`settings.local.json` is per-worktree** (not symlinked), matching the
  upstream convention: it is the developer's local, per-checkout Claude
  config, not aggregated state. This is a *change* — the whole-directory
  symlink made it shared; see Consequences.
- **`.claude/worktrees/` is not symlinked**: it is Claude Code's own worktree
  storage in the main checkout; sharing it into a worktree through a link
  from inside a worktree is recursive (a worktree containing a link to the
  directory that contains worktrees) and serves no aggregation purpose.
- **Legacy worktrees keep their whole-directory symlink.** If
  `<worktree>/.claude` is already a symlink, setup-worktree leaves it and
  re-records `symlink\t.claude` in the manifest (so cleanup-worktree still
  removes it). The subdirs already resolve through the whole-dir link, so
  aggregation is unaffected. Migration is explicit: delete the symlink and
  re-run setup-worktree. One self-healing path: checking out a branch with
  tracked `.claude/` content in a legacy worktree may make git replace the
  (ignored) symlink with a real directory; the next setup-worktree run then
  installs the per-subdir links.

### The three traps and their handling

1. **In-container resolution** — investigated above: aggregation rides the
   `DEV_MAIN_TREE`-at-host-path mount, absolute links resolve identically for
   subdirs; no container-side change needed.
2. **`rm -rf` on a symlink** — `devcontainer clean` deletes
   `<workspace>/.claude/container-{audit,sessions}`. Under the old layout the
   path resolves *through* the whole-dir symlink (a non-final path component)
   and deletes the shared state; under the new layout the subdir is itself
   the symlink, and `rm -rf` on it would remove just the link and leave the
   shared state — silently voiding the documented shared blast radius. Fixed:
   `clean` now resolves the path (`readlink -f`), `rm -rf`s the target, and
   **always** recreates the (empty) target directory. Recreating
   unconditionally rather than only when the caller's own subdir is a symlink
   is the point: `clean` run from the main checkout (or from a legacy
   worktree, where the subdir resolves *through* the whole-dir link and so is
   not itself a symlink) deletes the same shared directory that every
   new-layout sibling worktree links to, and would leave all of those
   dangling. `setup-claude.py`'s `Path.mkdir(exist_ok=True)` raises
   `FileExistsError` on a dangling symlink and `audit-hook` would append into
   nothing, so the recreate is what keeps the blast radius "shared state
   emptied" rather than "sibling worktrees broken". It costs nothing on a
   main checkout, where the target is the real directory just deleted.
   `tests/test-worktree-claude-layout.sh` exercises the block on all three
   layouts.
3. **Existing worktrees** — legacy mode, as decided above: setup-worktree
   remains idempotent on both layouts, and cleanup-worktree keeps parsing the
   legacy manifest line (`symlink\t.claude`) unchanged.

## Consequences

- `.claude/agents/pr-reviewer.md` (and future agent definitions) are ordinary
  tracked files: reviewed in PRs, materialized by checkout in every worktree,
  identical across checkouts by construction rather than by symlink.
- **One-time developer migration**: the live `.gitignore` is untracked, so
  each developer must mirror the template change into their main checkout's
  live `.gitignore` (or re-copy it from `.gitignore.template`). Until they
  do, a bare `.claude` entry keeps hiding `.claude/agents/` from git status
  in that checkout — already-tracked agent files stay tracked and their edits
  still show, but adding a **new** agent definition requires `git add -f`
  (a plain `git add .claude/agents/foo.md` fails with "ignored by one of your
  .gitignore files"), so the migration is a prerequisite for authoring
  agents, not merely cosmetic.
- **`settings.local.json` becomes per-worktree — a behavior change for
  existing developers.** Under the whole-directory symlink a worktree's
  `.claude/settings.local.json` *was* the main checkout's file, so permission
  grants were shared across every worktree by accident of the layout. Under
  the per-subdir layout each worktree gets its own (it is deliberately not
  symlinked; see the Decision). Consequence: previously-shared grants stop
  following you into worktrees, and every newly created worktree starts with
  no local permissions and re-prompts. This matches the upstream convention
  and is intentional; developers who want a grant everywhere should put it in
  the tracked project `.claude/settings.json` or in their user-level
  `~/.claude/settings.json` instead of a per-worktree local file.
- Worktrees created from now on get the per-subdir layout; existing worktrees
  keep working in legacy mode until migrated. Every consumer of the layout
  (`setup-worktree`, `cleanup-worktree`, `devcontainer clean`) tolerates
  both; `tests/test-worktree-claude-layout.sh` pins that.
- `devcontainer clean` keeps its shared blast radius (audit log + session
  stubs for ALL worktrees) on both layouts, and always leaves a valid empty
  shared directory behind, so no worktree's state symlink is left dangling by
  a clean run from anywhere.
- `cleanup-worktree`'s pre-flight now lists untracked files individually
  (`--untracked-files=all`). Because `.claude` is a real directory, git's
  default output collapses it to `?? .claude/`, which matches no manifest
  entry; in a repo whose live `.gitignore` does not ignore `.claude`, that
  collapsed entry would block removal of every worktree.
- Anything new under `.claude/` is ignored by default (`.claude/*`); tracking
  more upstream-shared content later (e.g. project `settings.json`) is a
  one-line negation added to the template, not a redesign.

## Options considered

- **A — track agents at `dev/agents/` + copy into `.claude/` at setup.**
  Keeps the blanket ignore and whole-dir symlink, but forks the truth: the
  copy goes stale, Claude Code reads the copy while reviewers read the
  source, and every worktree needs a sync step. Rejected — exactly the
  two-sources drift CLAUDE.md's conventions warn about, for content upstream
  already defines a tracked home for.
- **B — keep the whole-dir symlink; don't track agents.** Zero migration,
  but agent definitions stay invisible to review and to fresh clones, and
  the repo permanently forfeits the upstream `.claude/` convention. Rejected.
- **C — per-subdir symlinks; ignore narrowed to `.claude/*` +
  `!.claude/agents/` (chosen).** Tracked content and aggregated state
  coexist; the container mechanism is untouched (same absolute-link +
  main-tree-mount resolution); costs a `clean` fix, legacy-layout tolerance,
  and a one-time live-`.gitignore` migration.
