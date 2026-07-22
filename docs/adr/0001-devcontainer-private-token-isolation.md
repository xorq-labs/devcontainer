# ADR-0001: Devcontainer private-token credential isolation

- Status: Accepted
- Date: 2026-07-22
- Implemented by: this PR (devcontainer)
- Related: **claude-profile ADR-0001** — per-profile `CLAUDE_CONFIG_DIR`
  isolation, in the `claude-profile` repo. (ADR numbers are per-repo; this is the
  devcontainer repo's first ADR. Cross-repo references are qualified by repo
  name.) This ADR applies the same isolation principle to containers.

## Context

The container's `~/.claude` is an isolated named volume (`claude-home`) — with
one hole: `${HOME}/.claude/credentials` is bind-mounted **read-write** from the
host, and the container's `~/.claude/.credentials.json` is an image-baked symlink
into that mount. So despite the "isolated" framing, the host and **every**
container of every worktree authenticate through a **single shared credential
inode**.

That single shared inode is the root of the recurring credential pain:

- **Concurrent refresh race.** Refresh tokens are single-use/rotating; when any
  box refreshes, the others' refresh token is invalidated and they lose auth
  mid-session. Known, unfixed upstream (anthropics/claude-code #25609, #27933,
  #48786).
- **Divergence.** Claude writes credentials by replacing the symlink with a
  regular file (rename), stranding the layout in the "diverged copies" state that
  requires `claude-profile doctor`.
- **Identity bleed.** `.claude.json`'s `oauthAccount` cache is per-container and
  frozen at build time; when the shared token is swapped underneath it,
  `auth status` reports the cached (wrong) account.

Everything else in `claude-home` is already correctly per-container; only the
credential is shared, and it is shared on purpose ("all containers + host share
one token"). Removing that sharing removes the whole class of failures.

## Decision

Give each container its **own** private token, seeded once at container setup —
the container application of claude-profile ADR-0001.

- **Remove** the `${HOME}/.claude/credentials` bind-mount from compose; **drop**
  the baked `.credentials.json` symlink from the Dockerfile.
- **Seed** a private `~/.claude/.credentials.json` (regular file on the
  `claude-home` volume) plus a matching `.claude.json` `oauthAccount`, from the
  host profile store. The store is still reachable **read-only** via the existing
  `.claude-host` mount (host `~/.claude`, which includes `credentials/`), so no
  new mount is needed. Account-scoped caches (`clientDataCacheSlots`,
  `orgModelDefaultCache`, …) are dropped so a different account refetches.
- **Profile selection:** `DEV_CLAUDE_PROFILE` (default: the host's active profile
  from `credentials/active-profile`).
- **Scenario 1 (seed-once, no save-back) is the default**, matching claude-profile ADR-0001: the
  container owns and refreshes its token independently; host re-login/rotation
  does not auto-propagate.
- **Keep the container's copy-with-cwd-rewrite for `projects/`.** The container's
  project key (`/workspaces/src`) differs from the host's, so the host-side
  symlink share of `projects/` (claude-profile ADR-0001) cannot apply; transcript bridging stays
  copy-with-rewrite.
- **Repurpose `fix-credentials`:** its old job (restore the shared-mount symlink)
  no longer exists; it now re-seeds the container from its profile.
  `set-credentials` remains the manual private-token override.

## Consequences

- Each container authenticates with its own token. The concurrent-refresh race
  and the rename/divergence state become **structurally impossible across boxes**;
  identity matches the token (bleed fixed).
- The container's credential layout **normalizes** to what a vanilla `claude`
  login produces (a private regular file it refreshes in place). Remaining
  non-vanilla bits (rebuilt `settings.json`/`.claude.json`, the `sessions`
  capture symlink, the project-key copy) are path/environment plumbing, not auth.
- Cost: a long-lived container owns its token lifecycle; if its refresh token
  dies it must be re-seeded (rebuild or `fix-credentials`), not silently
  recovered. Save-back / "linked" mode (Scenario 2) is deferred.
- **Dependency:** identity seeding relies on `claude-profile` capturing
  `credentials/<profile>.oauthAccount.json` (claude-profile ADR-0001 / claude-profile#13).
  Without a sidecar, the seeded session shows blank identity until the profile is
  re-saved; the token still works.

## Options considered

Same A/B/C as claude-profile ADR-0001, applied to containers. Keeping the shared mount with a
refresh broker/file-lock (B) was rejected: it depends on suppressing claude's own
refresh (unverified) and cannot support concurrent different accounts. Per-session
private config dir (A) deletes the shared resource instead of coordinating access
to it, and reuses primitives that already exist (`export-to`/`set-credentials`).

## Follow-ups

- Save-back / Scenario 2 (linked): flow a container's refreshed token back to the
  profile store, with a token-freshness precedence rule.
- Cooperate with claude's native `.claude.json.lock` during seed writes.
- Host-side isolation is claude-profile ADR-0001 (`claude-profile session`).
