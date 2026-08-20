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

*Amended 2026-08-04 — see "record a mutation PAIR" below.*

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

## Amendment (2026-08-04): record a mutation PAIR, one aimed at the input

**Status: Accepted.**

One mutation is not enough. "Break the invariant" aims the mutation at the thing
the author is already thinking about, so the §2 run confirms the hole they just
closed and misses the parsing assumption they did not know they had made.

The evidence is named cases, not a statistic. No fail-open in this repo has
been found by the guard's own author — every one came from a reviewer or an
auditor: a `[[ ]]` dispatch arm invisible to a strict-shape parser (#96), COPY
coverage satisfied by a comment (#97), a pin anchor restated rather than read
(#95), a workflow omitting itself from its own trigger paths (#109), and — in
the PR that existed to fix this class — five successive rounds of comment- and
spelling-blind parses (#110).

The first three predate this ADR, so their authors never ran §2 at all. That is
the weaker half of the case. The stronger half is #93's and #110's guards, which
DID carry recorded §2 runs and grew fail-opens anyway — a single mutation aimed
at the invariant is not enough even when it is performed.

A count is deliberately NOT quoted here. The first version of this amendment
claimed "12 of 19", then "16 of 24", and the command it published to reproduce
that returned 3, because a later edit dropped the branch loop it depended on.
The population spans open branches and moves hourly; the marker (`round`) is
also a floor, since records like "two mutations, both previously green" document
an externally-found hole without using the word. An ADR arguing for measurement
rigor should not publish a number that cannot be re-derived — the named cases
above are stable and checkable, and they carry the argument.

So record **two** mutations:

1. **Form-only.** Reformat the source the guard parses without changing its
   meaning: wrap a line, requote, swap YAML flow spelling for block, change
   case, add a comment that mentions the identifier. The guard must stay
   **green** *and its assertion count must not fall*. A silent drop is the
   fail-open — this is what an evaporating `mapfile` looks like.
2. **Semantic, expressed in a form you did not write.** Disable the thing by
   commenting it out rather than deleting it; set the key in block form rather
   than flow. The guard must go **red**.

**Exception — guards whose invariant IS the byte form.** Where the fact being
guarded is that a line keeps an exact shape (the `BASE_IMAGE` pin's four
encodings), a form-only mutation correctly turns the guard red: format
sensitivity is the point. Record that instead of running the form-only half,
and say which invariant makes it so.

Cost: two extra runs per new or materially-changed guard. Compare an
assertion count only against the paired run on the same machine — suites with
environment-conditional assertions (absent `zsh`/`fish`) report different
absolute totals elsewhere.

Not proposed: a new rung, and a new annotation kind for coverage or wiring.
Coverage is already rung-2-able — §3's own rung-2 example (parsing a
Dockerfile's COPYs rather than listing them) *is* set-derivation. Wiring is a
fact to state in the invariant, not a kind of guard; mixing it into
`test:`/`tool:`/`ci:`/`structural`/`unguarded` would confuse the guard-kind
axis with the fact axis.

## Amendment (2026-08-04): the rung is a property of an assertion

**Status: Accepted.**

Read the ladder per ASSERTION, not per suite. A suite can be rung 2 on the fact
and rung 3 on the call: `tests/test-volume-chown-guard.sh` derives the chown
semantics by running the real lib, while pinning the driver line as a literal.
Annotating the suite as `test:` says nothing about which of its assertions are
derived, and a single derived check will otherwise vouch for its restated
neighbours.

## Amendment (2026-08-20): a guard's prose derives too

**Status: Proposed.**

§3 ranks how a guard states its **expectation**. It says nothing about the
prose *around* the guard — the header's recorded mutation runs, the roster of
what is covered, the counts in an invariant bullet, the example name in an
assertion label. All of that is a rung-3 restatement of the same sources, and
it rots the same way, with one difference that makes it worse: **nothing ever
runs it**, so it rots silently while the suite stays green.

This ADR already discovered the pattern and fixed one instance of it locally.
The 2026-08-04 mutation-pair amendment above says, in its own text:

> A count is deliberately NOT quoted here. The first version of this amendment
> claimed "12 of 19", then "16 of 24", and the command it published to
> reproduce that returned 3, because a later edit dropped the branch loop it
> depended on.

That is this amendment's argument in miniature, applied once, by hand, to one
sentence. Generalise it.

### Named cases

All from the work that graduates the kenn-io source-build tools one at a time
into a set several guards iterate — the shape that makes restated prose rot
fastest. Cited by **file and section, not commit**: this repo squash-merges, so
a branch's commit hashes cease to exist the moment the work lands, and the
first draft of this amendment cited four that a single rebase had already
killed. Where the stale text itself is the evidence, `git log -S'<the phrase>'`
finds it; the rest is visible in the named file as it stands.

- **A named member of the set the guard iterates.**
  `tests/test-bump-kenn.sh` §4 asserted that a tool with no source-build
  derivation is refused, and named `kata` as its example. `kata` graduated;
  the assertion went red with an HTTP 404 from a repo the canned universe does
  not describe — failing loudly, but *for a reason unrelated to what it
  tests*, which is a fail-open wearing a red hat. `tests/test-bump-kenn.sh` §4
  now derives the tool from `TOOLS - SOURCE_BUILD_TOOLS` at check time, with a
  clean skip when the set is empty.
- **A mutation record naming its own subject.** The same suite's §6 semantic
  mutation was `"roborev": []`, then `"kata": []` — each stopped being a
  mutation the day that tool graduated, and the record was rewritten twice —
  its own header says so — before §4 above made the naming unnecessary.
- **A count in a mutation record, unnoticed because its pair moved.** §6's
  pair-3 form-only half read "reorder SOURCE_BUILD_TOOLS's *two* keys / Green:
  *71* passed" from when the dict had two entries. The dict reached six and
  the suite 76 while the semantic half beside it was refreshed twice. A
  recorded run whose numbers no longer reproduce is the one thing §2 exists to
  prevent.
- **A count in ordinary prose.** "the easiest of the five" appeared in
  `nix/kenn/README.md`, `nix/kenn/source-build.nix` and ADR-0007 once six tools
  were graduated. Likewise "three of the four remaining tools" in ADR-0007, and
  a `CLAUDE.md` invariant bullet whose per-tool roster had to be re-listed on
  every graduation.
- **A finding recorded where nothing governs.** A re-scope of the last tool
  landed in an untracked working note and stopped there, leaving four
  contradicting claims live in ADR-0007's effort table, `nix/kenn/README.md`
  and `source-build.nix`'s header — the docs that actually govern the next
  tool.
- **This amendment's own first draft.** It cited four commit hashes on an
  unmerged branch. A rebase an hour later rewrote all four, and the repo's
  squash-merge would have killed the replacements on landing. The rule caught
  its own author's draft, which is the most this section can say for it — and
  note that ADR-0005 contained no commit hash before that draft and cites ten
  issue and PR numbers instead. The convention was already here.

### Rules

1. **No running count in guard prose or in an invariant.** Not "the five
   graduated tools", not "three encodings", not "71 passed" where the number
   is incidental. Either omit it, phrase it count-free, or derive it at check
   time. A measured threshold is not a running count: "past git's 4096-byte
   stdout buffer" is a fact about git and stays true.
2. **Do not name a member of a set the guard iterates.** Derive the example
   from the set at check time, and make the empty case an explicit skip rather
   than an accident.
3. **Touching one half of a mutation pair means re-running the other.** The
   halves go stale independently, and the fresh one lends the stale one
   credibility.
4. **A fact recorded only in a working note is not recorded.** When a finding
   changes what a durable doc claims, change the durable doc in the same pass.
   Notes are a scratchpad, not a register.

Rule 1 is the one with teeth, because a wrong count reads as precision.

### Not proposed

**A fourth rung.** The ladder ranks how an expectation is stated; prose is not
an expectation. This is §3's principle applied to a second surface, not a new
level of it.

**A lint for numerals in comments.** It would fire on every legitimate
measurement (byte thresholds, version pins, issue numbers) and miss the
rosters and example names, which carry no digits at all. The failure here is
judgment about what can go stale, and rung-3 mechanisation of a judgment is
what this ADR spent §3 arguing against.

**Extending this to search-before-you-fix.** A closely related incident sits
one step outside: an already-open PR (#145) carried a byte-identical fix to a
hook bug that was then independently rediscovered and re-fixed. That is also
"a fact recorded in one place, restated in another", but its remedy is a
habit (look for the open PR) rather than a property of prose, and the repo
already names the disease under the `Closes #N` convention. Left out
deliberately rather than overreached into.
