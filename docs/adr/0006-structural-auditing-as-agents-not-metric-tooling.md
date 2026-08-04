# ADR-0006: Structural auditing as prompted agents, not metric tooling

- Status: Proposed
- Date: 2026-08-02
- Implemented by: PR #90 (`.claude/agents/structural-auditor.md`, the
  `pr-reviewer` "repeat offenders" section, the audit-closure convention in
  CLAUDE.md) plus this ADR, which names the report home.
- Related: ADR-0003 (why agent definitions are tracked at all); ADR-0005
  (guard taxonomy, accepted 2026-08-02 — the vocabulary this ADR's agents now
  hold findings to; the agent prompts reference it conditionally because they
  were written while it was in flight, and that conditionality is harmless to
  keep); #92 (the first audit finding, disposed as an issue).

## Context

PR #90 gives the repo two history-aware review mechanisms: a diff-scoped
"repeat offenders" check in `pr-reviewer` (has this coupling been fixed here
before?) and a repo-scoped `structural-auditor` (what shape do our bugs keep
taking?). Both are prompt-driven agents reasoning over `git log` plus the
current tree.

There is twenty years of prior art for exactly this job, and the design should
say what it takes from it and what it deliberately does without:

- **Fix-history prediction** — BugCache/FixCache (Kim et al. 2007): files
  fixed recently get fixed again. Rahman et al. 2011 showed a naive
  most-fixed-files ranking performs about as well as the cache; Google trialed
  that ranking in code review and abandoned it because a file-level "often
  fixed" flag gave reviewers nothing actionable and read as stale blame.
- **Behavioral code analysis** — Tornhill's code-maat / CodeScene: hotspot
  scores (churn × complexity), temporal coupling, and — their core product —
  trends over time against a stored baseline. Draws the same per-PR-delta vs
  repo-dashboard line PR #90 draws.
- **Fix→cause tracing** — SZZ: map a fix commit back to the commit that
  induced the bug, via blame; high false-positive rates even with tooling.
- **LLM-era repo auditing** — RepoAudit (ICML 2025): repository-level bug
  finding via parser-backed dataflow analysis of the current tree; no history
  dimension.

## Decision

Keep the agents LLM-judged and git-native. Adopt from prior art the two
lessons that killed earlier systems; accept three capability gaps explicitly;
close one.

**Adopted (already encoded in the agent prompts):**

- *Actionability over scoring* (Google's Rahman-trial lesson): the repeat
  check reports only on a hit, and a finding must name a missing mechanism
  ("the guard is absent"), never a risk score. The disposal-draft requirement
  and the CLAUDE.md audit-closure convention exist for the same reason — an
  unactioned finding is how these systems lose credibility.
- *The per-diff / repo-scope split* (CodeScene's delta-vs-dashboard line):
  repo-level debt never blocks a PR verdict; per-PR verdicts never carry
  repo-wide scans.

**Closed by this ADR — audits get a baseline** (reversed by the 2026-08-04
amendment below: committing a report is now optional. The original text is
kept unedited so the requirement, and its reversal, both read as decisions
rather than as an absence):

CodeScene's real advantage is not its metrics but its memory: trend against a
stored baseline. The auditor's output spec promises measurements "so the next
audit can rerun and compare" — vacuous while reports die in the invoking
conversation. Therefore: **the caller commits each audit report to
`docs/audits/<date>-<scope>.md`** (the agent itself must not write files),
and the auditor reads the newest prior report there before measuring, so its
measurements become a time series and its "checked and dropped" list is not
re-litigated from scratch each run.

**Accepted gaps (recorded so they read as decisions, not oversights):**

- *No deterministic metric layer* (code-maat's hotspot/coupling scores).
  Accept, because: the repo is small enough that the rerunnable
  `git log`-based measurements in each committed report serve the purpose,
  and a metrics pipeline in CI is a standing cost with no current consumer.
  Revisit if reports show measurement drift that hand-run commands can't
  explain.
- *No SZZ-grade fix→inducing-commit tracing.* Accept, because: SZZ's
  false-positive record does not justify its machinery here; an agent reading
  the fix commit and judging "same underlying cause" is the honest version at
  this scale, and the two-instances-minimum rule bounds the damage of a wrong
  judgment.
- *No dataflow-precision analysis* (RepoAudit). Accept, because: this is a
  bash/YAML repo; shellcheck already holds the static-analysis slice, and the
  auditor's job is recurrence across history, which dataflow tools do not
  address.

## Consequences

- `docs/audits/` is the durable home for audit reports; an audit is closed
  (per the CLAUDE.md convention) when each shape is filed, landed, or
  recorded as an accepted `(—)` — committing the report is how the
  measurements and drop-list persist. *(Amended 2026-08-04: the commit is
  optional. Closure is unchanged — filed, landed, or recorded — and is now
  the only durable trace an audit is required to leave.)*
- The first audit (2026-08-02, repo-wide) predates this ADR; its one shape is
  disposed as #92 and its report ships as the first entry in `docs/audits/`
  so the baseline starts now, not at the second audit. *(Amended 2026-08-04:
  the reports already committed there are kept; see the amendment.)*
- The accepted-gaps list is the contract for future "should we adopt
  CodeScene/code-maat?" discussions: reopen by amending this ADR, not ad hoc.

## Amendment (2026-08-04): committing an audit report is optional

**Status: Accepted.** Reverses the "Closed by this ADR — audits get a
baseline" requirement in §Decision. Everything else — the two adopted lessons,
the three accepted gaps, the recorded no to a metric layer — is unchanged.

The rule was: **the caller commits each audit report to
`docs/audits/<date>-<scope>.md`.** It is now: the caller **may** commit a
report there when it is worth keeping. Closure is untouched — each surviving
shape is still filed as an issue, landed in a PR, or recorded as an accepted
`unguarded:` invariant (CLAUDE.md) — and the agent still must not write files
itself.

Why the reversal:

- **The report is the second copy, and the weaker one.** A finding's durable
  form is an issue, a landed guard, or an `unguarded:` invariant; the closure
  rule already demands one of the three, and all three live where the next
  reader is already looking. A committed report restates that record in prose
  that nothing keeps true — a snapshot of a tree that changes under it, with
  no guard and no way to write one. That is the restate-over-derive shape
  ADR-0005 rejects, and it is the auditor prompt's own warning ("a copy of a
  convention is one more thing to drift") applied to the auditor's output.
- **A mandatory artifact taxes the run that was already easiest to skip.**
  Audits here are deliberate and occasional. Requiring a committed,
  reviewable document per run prices the audit above what an average one
  returns, and the failure mode is not a missing file — it is a skipped
  audit.
- **The baseline it bought was thinner than it looked.** Of the reports filed
  so far, the part that got reused was the *commands* under §Measurements, not
  the numbers they produced; the commands are already in the agent definition
  and reproduce without a prior report.

**What this costs.** Option B's objection comes back, and this amendment does
not pretend otherwise: with no guaranteed prior report, the auditor's "rerun
and compare" promise has no guaranteed baseline. An audit that leaves no file
makes the next one re-derive its negative space, and measurements do not
accumulate into a time series. Nothing replaces that; it is accepted, in
ADR-0005's `unguarded:` form:

> `unguarded:` audit-to-audit continuity. No mechanism guarantees a prior
> report exists, so measurements may not form a time series and a
> checked-and-dropped list may be re-litigated. Accepted because the disposal
> record (issues, landed guards, `unguarded:` invariants) already carries the
> findings that matter; the measurement commands are reproducible from the
> agent definition without a prior report; and re-deriving negative space on
> an occasional audit is cheaper than a standing documentation obligation on
> every one. Revisit if two consecutive audits are seen re-filing the same
> dropped candidate, or if a measurement trend is wanted for its own sake.

**The existing reports stay.** Whatever is already in `docs/audits/` is kept as
historical record, and the directory with it: dropping the requirement is not a
reason to destroy what it produced. (Deliberately not enumerated — a list of
filenames here would be a second copy of a directory listing, going stale on
the next report committed under the now-optional rule.) The auditor still reads the newest report there
when one exists — the directory is an optional baseline now, not a guaranteed
one, and the agent definition says so.

Rejected: making the commit conditional on a surviving shape (the reports with
the most reuse value are often the ones that found nothing, which this would
suppress); keeping the requirement plus a freshness guard (a guard can check a
date, not whether the prose is still true — the vacuous-check shape ADR-0005
names).

## Options considered

- **A — adopt metric tooling (code-maat or CodeScene) in CI.** Deterministic
  and comparable, but a standing pipeline for a small repo, and Google's
  trial says the score-shaped output is the part that fails with reviewers.
  Rejected for now; reopening is an amendment here.
- **B — agents with no persistence (status quo before this ADR).** Zero
  ceremony, but the "rerun and compare" promise is unfulfillable and every
  audit re-derives the last one's negative space. Rejected. *(The 2026-08-04
  amendment accepts this cost after all, with the disposal record — not the
  report — as what persists; see the amendment for why the trade flipped.)*
- **C — agents + committed reports under `docs/audits/` (chosen).** Keeps the
  LLM-judged approach, closes the baseline gap for the cost of one `git add`
  per audit, and leaves the metric layer as a recorded, revisitable no.
  *(Amended 2026-08-04 to C′ — the same directory, the same agents, but the
  commit is optional rather than required; the cost was not one `git add`, it
  was a reviewable document per audit.)*
