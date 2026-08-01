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
(`- ${DEV_MAIN_TREE}:${DEV_MAIN_TREE}:cached` — put there so worktree
`.git` files' absolute `gitdir:` pointers resolve). So inside a worktree's
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
- **`settings.local.json` stays per-worktree** (not symlinked), matching the
  upstream convention: it is the developer's local, per-checkout Claude
  config, not aggregated state.
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
   `clean` now resolves the path (`readlink -f`), `rm -rf`s the target, and —
   when the subdir was a symlink — recreates the (empty) target directory so
   the link does not dangle. That last step matters: `setup-claude.py`'s
   `Path.mkdir(exist_ok=True)` raises `FileExistsError` on a dangling
   symlink, so leaving one would break the next container setup.
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
  in that checkout — confusing but harmless; the files are still tracked.
- Worktrees created from now on get the per-subdir layout; existing worktrees
  keep working in legacy mode until migrated. Every consumer of the layout
  (`setup-worktree`, `cleanup-worktree`, `devcontainer clean`) tolerates
  both; `tests/test-worktree-claude-layout.sh` pins that.
- `devcontainer clean` keeps its shared blast radius (audit log + session
  stubs for ALL worktrees) on both layouts, and now leaves a valid empty
  shared dir behind when run from a per-subdir worktree.
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
