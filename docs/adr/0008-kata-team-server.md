# ADR-0008: kata on the team server, as the agent-side ledger

- Status: Proposed
- Date: 2026-11-14
- Implemented by: this PR (`.envrcs/.envrc.kata`, vendored from
  xorq-labs/xorq-envrcs at 37873f9; `.envrcs/.env.local.template`; the opt-in
  line in `.envrcs/.envrc.user.template`; `tests/test-envrc-kata.sh`).
- Related: ADR-0006 (where audit dispositions are recorded); ADR-0007 (the
  `nix/kenn` flake that supplies the `kata` binary); xorq-labs/xorq-kata-infra
  (the server, and how identity tokens are issued).

## Context

The 2026-08-21 kata evaluation (a session note, not in the tree) recommended
deferring kata, blocked on three undecided questions: where the daemon runs and
how the container reaches it, which credential applies, and project scope. Its
standing objection was that kata's GitHub sync is one-way — kata imports
GitHub issues and never writes to them — so a disposal recorded only as a kata
close leaves its GitHub twin open, the fixed-but-open failure CLAUDE.md
records (#53).

Since then the team has stood up one shared kata daemon (xorq-kata-infra,
on the tailnet), xorq-envrcs ships a fragment that points a
checkout at it, and this repo's issues already in a local daemon have been
migrated to it.

## Decision

1. **Daemon: the team server.** A checkout opts in with `source_env
   .envrc.kata` in its `.envrc.user`; the server address is
   `KATA_TEAM_SERVER` in `.envrcs/.env.local`, the token `KATA_TEAM_TOKEN` in
   `.envrcs/.envrc.secrets`. Only the kata fragment is adopted from
   xorq-envrcs, not its layout: this repo's `.envrc.user.kenn` builds the
   toolkit from the working tree (it owns the flake), and its `.gitignore`
   model is propagated by `dev/setup-worktree` and checked by
   `dev/check-gitignore-agents`, which xorq-envrcs' rebuild of `.gitignore`
   from its template would compete with (at 37873f9, its root `.envrc`:
   `_from_template .gitignore 644`).
2. **Credential: one identity token per person.** An agent writes on its
   person's token and tells itself apart with `KATA_TEAMMATE`; the name is
   self-asserted (xorq-kata-infra's README, "Three credentials, not one").
3. **Project scope: one kata project, `devcontainer`, for the repo and every
   worktree.** `.kata.toml` stays untracked and ignored (`.gitignore.template`),
   as in the sibling repos: each checkout carries its own, and getting it into a new worktree is the
   per-user `.envrcs/.worktree-symlinks` list's job.
4. **GitHub remains the record of disposal.** A PR still closes its issue with
   `Closes #N`; ADR-0006's three dispositions (an issue, a PR, an `unguarded:`
   invariant line) are unchanged and none of them is a kata close. kata holds
   work in flight — review-round findings, triage, planning — and nothing
   whose only record would be a kata close once it has an owner outside the
   session. A kata `--audit-no-change` close is not ADR-0006's third
   disposition, which is a CLAUDE.md line.

## Consequences

- The vendored fragment is a cross-repo copy. Its behaviour is guarded here
  (`tests/test-envrc-kata.sh`); agreement with upstream is not: a check needs
  the network (a `ci:` shape) and none is written. The header names the
  commit, and keeps one known inaccuracy verbatim ("never to a name": kata
  also sends the token to `localhost`).
- Container use is not yet verified. direnv runs in this project's container
  and the secrets file reaches it through the bind mount, but neither image
  ships `kata` (it comes only from `.envrc.user.kenn` building the flake with
  the overlay's nix), and reaching a tailnet address from the compose network
  depends on the host's Tailscale mode. `kata federation identity --json`
  inside a container is the check. `kata health` is not a token-blind
  shortcut: kata v0.18.0 sends `KATA_AUTH_TOKEN` with it too, and the daemon
  validates an explicit bearer on `/api/v1/health` (`requireBearer` in kata's
  `internal/daemon/auth.go`), so a bad token fails it as `token_invalid`.
- An existing checkout's live `.gitignore` is untracked (CLAUDE.md, "Gitignore
  model") and does not pick up this PR's template lines. Add them before
  creating `.envrcs/.env.local`:
  `printf '%s\n' '.envrcs/.env.*' '!.envrcs/.env.*.template' .kata.toml
  .kata.local.toml >> .gitignore`; `git check-ignore .envrcs/.env.local` then
  prints the path. `dev/check-gitignore-agents` warns on every commit until
  it is done, and prints this command for whatever is missing.
- Turning on GitHub sync for this repo is server configuration in
  xorq-kata-infra, and a separate decision.
