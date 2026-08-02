# ADR-0005: Guard taxonomy — type the guard, prove it fails, derive over restate

- Status: Accepted (2026-08-02 — accepted with the baseline audit on #89 and
  the CLAUDE.md rule landing in this PR)
- Date: 2026-08-02
- Implemented by: this PR (the taxonomy, the `CLAUDE.md` rule, and the baseline
  measurement); the comment sweep is #89, and the retrofit lands as invariants
  are touched
- Related: **devcontainer ADR-0003** (introduced `.claude/agents/`, one consumer
  of the conventions this ADR formalizes; ADR-0004 is reserved by the in-flight
  host memory bind, #81). Prompted by #83 and #86, two bugs
  that shipped despite the repo's unusually dense guard coverage.

## Context

This repo guards cross-file facts better than most: `CLAUDE.md` carries 36
invariants and `tests/` carries 25 suites, and the convention is explicit —
*"Any convention that spans two files gets a drift-guard test when it is
introduced. A convention only its author knows about will drift."*

Two bugs shipped anyway, and they rhyme.

**#83** — the published Nix base reached nobody for four months. Publishing
worked; the `BASE_IMAGE` pin that consumers actually build on was never moved.
No file disagreed with another file. The missing fact was *outside the tree*: a
digest on a registry.

**#86** — `lib/claude-code-token-env.sh` was absent from `nix-base.yml`'s
trigger paths, so PRs touching it silently skipped the tail build that exists to
verify exactly that change. The file already had four guards (`.dockerignore`
allowlist, `image_config_files()` hashing, the two-Dockerfile mirror invariant,
COPY-source coverage). All four checked content agreement. None checked whether
CI observed the change.

Reviewing the fix for #86 surfaced the same shape a third time, inside the new
guard itself: its Dockerfile parser missed lowercase `copy` and line
continuations, so an uncovered source would have dropped out of the checked set
and the guard would have passed green. It failed *open*.

### What the numbers say

The counts below are the hand measurements that prompted the decision, kept as
recorded. The acceptance baseline — a per-invariant classification, re-runnable
commands for every headline number, and three mutation spot-checks — is the
structural-audit report on #89. Where the two disagree, the baseline is the
number that can be re-derived.

- 36 invariants: **21** cite a test, **5** are marked `(—)`, **10** cite
  something else in prose (a tool, "routing enforced in `dev/devcontainer`",
  "partially tested", "structural"). The 21/10 split was a judgment call with
  no recorded rule — a mechanical count of the same tree gave 26/5/5, and
  29/5/2 after #87 — which is itself a small instance of this ADR's point.
  Classified with this ADR's vocabulary, composed annotations counted once per
  invariant: `test:` in 30, `tool:` in 4, `ci:` in 1, `structural` in 1, and
  **6 unguarded — none of the six stating the reason §1 requires**.
- **58** rule-asserting comments (`must` / `never` / `in sync` / `lockstep`)
  live in non-test sources — a body of stated rules larger than the promoted
  list, never audited. The 58 was a curated hand count with no recorded
  instrument; the baseline's recorded grep returns **119** lines, of which
  **27 assert 15 distinct cross-file facts, 6 of those unguarded** — two
  existing in no invariant at all.
- **2 of 25** suites contain anything resembling a check that they would fail.
  Verified by the baseline under the strict criterion (the suite feeds its own
  detection logic a broken artifact); counting the four bump suites' tool-refusal
  negative fixtures it is 6 of 25.
- Added at acceptance: all three of the baseline's vacuous-pass spot checks
  stayed green through the full suite — a one-directional anchor check, a
  fail-open dispatch parser (the #86 shape, recurring), and a textual
  COPY-coverage match that a comment satisfies. Decision 2's rationale, live
  in the current tree.

### The root cause

The guard vocabulary covers exactly one failure mode: **two committed files
disagreeing.** That is what a hermetic `tests/run-all` can check, so that is
what got guarded — well, 21 times.

Everything else has no vocabulary, so it lands in `(—)` or in a header comment,
and the fix is reinvented each time. The clearest evidence: this repo has
independently arrived at *"no test can verify this, so the tool is the
coupling"* **twice** — for hadolint's per-arch checksums, and again for
`bump-nix-base`'s manifest-list check — without ever naming it as a category. A
pattern rediscovered is a pattern undocumented.

Three consequences follow, all visible above:

1. **Absence is invisible.** Every guard asks "is this value wrong?". None asks
   "did this run?", "is this set non-empty?", "could this assertion have
   failed?". #83 was a step nobody did; #86 was a check that never ran.
2. **Redundant guards of the same kind are not defence in depth.** Four guards
   on one file, all of one type, missed a fifth failure mode.
3. **Written down is not enforced.** #86's rule was stated in prose at the top
   of the very file that violated it.

## Decision

### 1. Type the guard

Replace the bare `(—)` with an explicit guard kind in each invariant:

| Annotation | Meaning |
|---|---|
| `(test: tests/foo.sh)` | Hermetic check in the suite. |
| `(tool: dev/bump-x)` | No hermetic test can exist — the fact lives outside the tree (a registry, a release artifact). A tool that refuses to write a bad value **is** the guard. |
| `(ci: workflow.yml#job)` | Enforced only in CI, because it needs the network, a runner, or a real build. |
| `(structural)` | Cannot drift: the second copy is generated from the first. |
| `(unguarded)` | Deliberately accepted risk. **Must** say why in the same line. |

The point is not more guarding. It is that `(—)` today cannot distinguish
*"impossible to test hermetically"* from *"we didn't get to it"*, which is
precisely why the same realization had to be reached twice. `(unguarded)`
without a reason is a bug in the invariant, not in the code.

Annotations compose. A fact is often guarded at two layers of different kinds,
and picking one would silently drop the other: the hadolint checksums are
`(tool: dev/bump-hadolint; test: tests/test-bump-hadolint.sh)` — the tool
guards the fact that lives outside the tree, the test guards the tool. Separate
the kinds with `;`, one annotation per layer, still one line.

### 2. A new guard must be shown to fail

When adding or materially changing a drift guard, break the invariant and
observe the guard go red. Record the mutation in the test's header comment —
one line, e.g. *"Verified: deleting the path from both lists turns this red."*

Rationale: a test written against a fixed tree is written to pass. On the two
occasions a reviewer hand-mutated a guard in this repo, it found real vacuous
passes **both times**. Guards that fail open are worse than no guard, because
their green is mistaken for evidence.

By this ADR's own taxonomy the recorded mutation line is `(unguarded: the
header claim goes stale as the test evolves, and nothing re-runs it)` — a
rung-3 restatement, accepted deliberately. Re-verifying it mechanically is the
CI mutation testing rejected below.

### 3. Derive over restate

Three rungs, in order of preference. Choose consciously and say which in the
guard's header:

1. **Generate** the second copy from the first. No guard needed — drift is
   impossible. (`lib/command-table.tsv` → usage + three shell completions.)
2. **Derive** the expectation at check time by parsing the source of truth. The
   guard cannot go stale as the source grows.
   (`tests/test-nix-base-trigger-paths.sh` parses the Dockerfile's COPYs rather
   than listing them.)
3. **Restate and compare.** The fallback. The guard itself is now a third copy
   that needs maintaining.

Rung 3 is currently the default by habit. It should be the exception.

## Consequences

- `CLAUDE.md`'s invariant list gains a mechanical annotation, making
  "what is actually unguarded, and deliberately?" answerable by grep instead of
  by reading 36 prose bullets.
- New guards cost slightly more to write (one mutation run) and considerably
  less to trust.
- The header-stated rules become a finite, auditable backlog rather than
  ambient folklore. That sweep is #89; its first pass already
  found a live four-copy coupling with an explicit "keep the two in sync by
  hand" admission and no guard.
- This ADR does not require retrofitting existing guards. Annotations land as
  invariants are touched; the sweep handles the rest.
- Accepting this ADR is itself a doc-and-code-land-together change: the same PR
  rewrites `CLAUDE.md`'s invariant-list header (the `—` vocabulary this
  replaces) and adds the rule to Conventions. Legacy `(—)` entries remain valid
  until touched.
- The acceptance baseline was produced by a structural-auditor run (#90) — an
  agent, which in this taxonomy is a `(tool:)`-kind guard: non-hermetic,
  occasional, and deliberate, never a CI gate. Its judgment calls are recorded
  per invariant on #89; only the grep-backed counts are mechanically
  re-derivable.

## Alternatives considered

**Guard everything, drop `(unguarded)`.** Rejected: over-guarding has real cost,
and some accepted risks are correct. The problem is that today they are
indistinguishable from oversights.

**Put the taxonomy only in `CLAUDE.md` Conventions, no ADR.** Rejected: this
changes how a recurring class of decision is made, and the reasoning (why `(—)`
was insufficient, why two rediscoveries happened) is the load-bearing part.
`CLAUDE.md` will carry the rule; this carries the why.

**Require mutation testing in CI.** Rejected as premature — it means running the
suite against deliberately broken trees, which is a meaningful harness
investment. A recorded manual mutation captures most of the value now.
