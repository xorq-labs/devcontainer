# ADR-XXXX: ADR numbers come from the pull request that adds them

- Status: Accepted (2026-08-15 — this pull request carries the guard that
  enforces it, `dev/check-adr`, so the rule is in force the moment it lands;
  merging an ADR is what accepts it, per the rule itself)
- Date: 2026-08-15
- Implemented by: this pull request — `dev/check-adr` and
  `tests/test-check-adr.sh`, `.github/workflows/adr.yml`, the authoring pair
  `dev/adr-new` and `dev/adr-rename`, `docs/adr/README.md`,
  `docs/adr/template.md`, the three stale status headers it corrects, and the
  deletion of the 0004 reservation from its two homes.
- Related: **ADR-0005** — the guard taxonomy this decision's enforcement is
  typed under, and whose "prove it fails" rule is why the guard is specified
  here rather than assumed. `xorq-labs/xorq ADR-2210`
  (<https://github.com/xorq-labs/xorq/blob/main/docs/adr/2210-adr-numbers-from-pull-request-numbers.md>)
  — the prior art this adopts; qualified by repo name per the cross-repo
  convention ADR-0001 established, and in backticks because this guard
  resolves a bare `ADR-NNNN` against this directory.

## Context

An ADR's number is allocated by its author, by reading the highest number in
`docs/adr/` and adding one. That read is taken against the author's branch, not
against every other branch in flight, so nothing stops two of them choosing the
same number. Git will not stop them either: two branches that each add
`0008-<different-slug>.md` touch disjoint paths, so the merge produces no
conflict and no warning. Both files land, both claim 0008, and the first person
to notice is whoever greps for it.

This repo has not had that collision. It has had the two things that precede
one.

**The number 0004 has been reserved rather than written, for two weeks.** #81
opened on 2026-08-01 carrying `docs/adr/0004-durable-claude-memory-carve-outs.md`;
it is still open on 2026-08-15. So that nobody else takes it, `CLAUDE.md` on
`main` carried the clause `ADR-0004 is reserved by #81` — and ADR-0005's
`Related:` line carried its own copy, `ADR-0004 is reserved by the in-flight
host memory bind, #81`. A reservation with no register to live in ends up
copied into whatever files are to hand, one of which every pull request edits;
this one had to exist at all only because a number is currently the only way to
refer to an ADR that has not landed. Both copies are deleted by this pull
request, which is the first thing the guard below asked for: it reads them as
citations of an ADR that does not exist.

**The one concurrency this repo has had was resolved by five minutes of luck.**
#88 (ADR-0005) and #90 (ADR-0006) were opened five minutes apart on 2026-08-02
and merged nine minutes apart, in number order. They agree because one person
wrote both in one sitting — and only for that reason. The reservation clause
itself landed *in* #88 (`dd18207`), nine minutes before #90 merged, so at the
moment #90's ADR was numbered, `main` recorded neither that 0004 was spoken for
nor that 0005 was taken. A second author reading `docs/adr/` that afternoon
would have seen 0003 as the highest and written 0004.

A constraint shapes the fix. Measured on 2026-08-15, `ADR-NNNN` appears **105
times across 32 tracked files** outside `docs/adr/`, and 142 times counting the
ADRs themselves: CLAUDE.md's invariant list, `dev/setup-worktree`,
`dev/devcontainer`, `lib/command-table.tsv`, `setup-claude.py`, the two
Dockerfiles, `.gitignore.template`, and sixteen test suites. Renumbering existing
ADRs would either break those citations or require a sweep of production code
to fix a documentation problem.

## Decision

**An ADR's number is the number of the pull request that adds it.**

| Number | Meaning |
|--------|---------|
| Below 0100 | Legacy sequential number, frozen permanently |
| 0100 and above | The number of the pull request that added the ADR |

GitHub allocates pull request numbers from a single counter, so the number is
unique and already assigned before anyone could contend for it. There is
nothing to reserve, and nothing to check against another branch.

The split at 0100 needs no registry to interpret, and the margin is permanent
rather than merely large: the legacy range stops at 0007 and **that set is
closed** — #81's 0004 is the last number that can ever join it — while this
repo's issue-and-pull-request counter passed 142 before this ADR was written.
The two ranges cannot meet. Legacy ADRs keep their numbers and all 105
citations keep resolving.

Numbers stay zero-padded to four digits (`0143-<slug>.md`, `ADR-0143`), which
is where this departs from the prior art: xorq writes the number the way the
forge writes it, unpadded, because its numbers are already four digits. Ours
will be three for years, and padding buys two things that matter more than
literalness — `ls` and every citation keep one shape, and that shape is the
`ADR-[0-9]{4}` a guard and a grep can both match. Padding stops working at
10000, as unpadded ordering does at the same point; neither is this decade's
problem.

### Why the number arrives late

The number does not exist until the pull request does, so an ADR is authored
under a placeholder and renamed once the pull request is open:

1. `dev/adr-new <slug>` copies the template to `docs/adr/XXXX-<slug>.md`.
2. Write it; open the pull request.
3. `dev/adr-rename` reads the number from `gh pr view`, renames the file, and
   rewrites the `# ADR-XXXX:` heading and any named references to it.

`XXXX` rather than `0000`, because a placeholder must not look like a number.
`0000` parses as an integer, sorts as one, and a half-finished rename leaves
behind something that reads as a real ADR; `XXXX` cannot be mistaken for a
number, cannot be cited by accident, and lets a guard tell "not renamed yet"
apart from "wrong number".

### Citing an ADR that has no number yet

A number that does not exist cannot be cited, which is the whole reason #81
reserved one. So an ADR has **two citation forms, and both resolve
permanently**:

| Form | Example | Resolves against |
|------|---------|------------------|
| Numbered | `ADR-0005` | the number, for an ADR that has one |
| Named | `ADR-nested-commands-as-argv-rewriting` | the slug, numbered or not |

The two are lexically disjoint — a number begins with a digit, a slug with a
letter — so nothing is needed to tell them apart. The slug is the ADR's
identity, fixed when the file is created; the number is an alias that arrives
later. `dev/adr-rename` rewrites named references to the ADR it numbers, so
landed prose settles on the short numeric form, and because the named form
never stops resolving, a sweep that is partial or lags behind cannot break
anything.

This is what retires reservations rather than merely discouraging them. Under
this rule #81 would have written `ADR-durable-claude-memory-carve-outs` on the
day it opened, cited it that way from `lib/claude-memory.sh`, and `CLAUDE.md`
on `main` would carry no reservation clause at all.

An unresolved **named** reference is a warning: the ADR it names may
legitimately be on a branch that has not landed — #81's, today. An unresolved
**numeric** reference stays an error, because the forge allocated that number
and a missing target is a mistake. The asymmetry is the point: a bare
`ADR-0143` pointing at nothing tells a reader nothing until it lands, while
`ADR-durable-claude-memory-carve-outs` is legible immediately and resolves by
itself the moment its file appears.

### The one legacy exemption

#81 predates this rule and already wrote `0004-durable-claude-memory-carve-outs.md`
against a number reserved before the rule existed. It lands as 0004. The guard
carries exactly one allowlist entry, keyed to **file and slug together** — not
to the bare number, which would readmit any file at 0004 — and the list only
ever shrinks.

Deleting that entry cannot be done by #81 itself. The guard reads merged code,
so a pull request that lands an allowlisted ADR *and* removes its entry fails
on the very ADR the entry was protecting. The cleanup is therefore always a
follow-up, and a follow-up nobody is reminded of does not happen — so the guard
**reports a spent entry**: once the allowlisted file is in the tree and this
run is not the one adding it, every run says so, as a warning that does not
fail. That is the same defect-and-fix xorq recorded in its #2211, and it is
cheaper to inherit than to rediscover.

### Status is the only live field in an ADR

An ADR records what was true when the decision was made, so its prose is
history and is not edited to match the present. Its **status** is the
exception: it is a claim about now, it lives in exactly one place, and it is
the one field that can go stale.

It had. `ADR-0002`, `ADR-0003` and `ADR-0006` read `Proposed` while all three
were in force — named in CLAUDE.md's invariant list, guarded by suites, and in
ADR-0006's case already amended by a landed pull request (#122). This pull
request corrects the three headers, and the guard below stops it recurring:
**merging an ADR is what accepts it**, so a numbered ADR may not read a bare
`Proposed`. A decision that genuinely lands still open says
`Proposed (decision due YYYY-MM-DD)`, which puts its own staleness on the page;
a draft still carrying `XXXX` has been through no pull request, so bare
`Proposed` is right there and only there.

Amendments keep the shape this repo already uses: a dated `## Amendment`
section carrying its own status line, with the original text left alone and the
top-level status staying `Accepted`. This is a deliberate divergence from the
prior art, which introduces a distinct `Amended` status — ADR-0005 has carried
two amendments dated 2026-08-04 under an `Accepted` header, and a fourth status
value would relabel existing files to record something their amendment sections
already say.

### Enforcement

The convention spans files, so per this repo's own rule it gets a guard at
introduction, in this pull request: `dev/check-adr`, `tests/test-check-adr.sh`,
and `.github/workflows/adr.yml`. It checks:

- filenames match `NNNN-<slug>.md`, slug lowercase words joined by hyphens;
- no filename still contains `XXXX`;
- a newly added ADR's number equals its pull request number, unless allowlisted;
- the `# ADR-NNNN:` heading agrees with the filename;
- no two ADRs share a number, and no two share a slug;
- every `ADR-NNNN` mention resolves (error) and every `ADR-<slug>` mention
  resolves or warns;
- a spent allowlist entry is reported.

**The guard is in two halves because the facts are**, and the split is the
ADR-0005 typing rather than a packaging choice. Everything derivable from
`docs/adr/` alone is hermetic, so it lives in `tests/test-check-adr.sh` and
reaches CI through the `tests/*.sh` glob in `tests/run-all` — no workflow names
it, which is what keeps `.github/workflows/test.yml` a single step. The one
fact that lives OUTSIDE the tree is the pull request number: no hermetic test
can see it, so that half needs `--base`/`--pr` from a CI event
(`.github/workflows/adr.yml`), and on the authoring side a tool that reads the
number from the forge rather than a human typing it (`dev/adr-rename`). Hence
`test:` for the first half and `tool:`/`ci:` for the second.

Two properties of the CI wiring are inherited from the prior art because
neither is guessable and both are silent when wrong:

- **No `paths:` filter on the workflow.** A path-filtered workflow reports *no
  status at all* on pull requests that miss the filter, which makes it unusable
  as a required check. The check is a sub-second no-op instead. This repo has
  been bitten three times by trigger paths that quietly stopped covering an
  input (#86, #92, #93); this is the same family, one step further along.
- **Require the job by name, not the workflow.** A branch-protection entry
  naming the workflow matches nothing and silently never blocks.

That second point is inert here today, and saying so is part of the record:
**`main` has no branch protection and no rulesets — zero required status
checks**, measured 2026-08-15. So this guard reports and nothing blocks, which
is equally true of `lint.yml` and `test.yml` and is a repo-configuration
decision well outside one ADR about numbering. What the guard does buy without
it is a red check on the pull request, which is where the author is looking.

Two things the guard deliberately does not do:

- **It does not understand cross-repo citations.** `ADR-0011` in this repo and
  `ADR-0011` in another are different documents, and the guard resolves every
  bare `ADR-NNNN` against `docs/adr/`. The convention is therefore to write a
  cross-repo citation in backticks or as a link — both of which the guard reads
  as shown rather than cited — and the alternative, teaching it which words are
  repo names, is a hand-kept list of exactly the judgement being guarded
  (`unguarded:` and recorded as such in CLAUDE.md).
- **It does not check cited repo paths or bare short SHAs**, which the prior
  art added in its #2221/#2222. Measured first: `docs/adr/` carries 28
  path-shaped citations across 19 distinct paths and **zero** bare short SHAs,
  essentially all resolving — so there is no rot here to fix yet, which is a
  different reason from "it would cost too much". Filed rather than assumed.

## Consequences

- Collisions become impossible for new ADRs, and reservations become
  unnecessary. The mechanism that produced the `CLAUDE.md` clause is removed
  rather than discouraged.
- An ADR gains a backlink to the pull request that introduced it, and usually
  to the implementing code — which in this repo is nearly always the same pull
  request ("Implemented by: this PR" appears in five of the six headers
  in the tree).
- The `Implemented by:` header line loses most of its work once the number *is*
  the pull request. It stays, because it also records the case an ADR does not
  ride with its implementation (ADR-0005's retrofit, ADR-0006's #90/#122
  split).
- Numbers become sparse and jump: `0007` is followed by something in the 140s.
  A number stops telling a reader how many decisions preceded it. Chronology
  moves to `git log docs/adr/`, which was always the better source — the
  current numbers already fail at it, since ADR-0006's decision (#90) and
  ADR-0005's (#88) were nine minutes apart and 0004 does not exist.
- Two numbering conventions coexist permanently, and two citation forms do. A
  reader meeting `ADR-0005` and `ADR-guard-taxonomy` has to know they are the
  same document. The rename sweep keeps the long form mostly confined to
  unlanded prose; it does not eliminate it.
- One ADR per pull request, because a second has no number to take. This costs
  little here: an ADR reviews fine alone, and a related decision is citable by
  slug from the moment its file exists.
- One extra step for the author (`dev/adr-rename` after opening), and a red
  check on the first push of any pull request carrying an ADR. That is the
  intent, but it is a real cost paid on every ADR forever.
- `CLAUDE.md`'s "Current records:" sentence stays as a reading aid, but stops
  being a register: the reservation clause is deleted here, as is its copy in
  ADR-0005's `Related:` line. A generated index is deliberately not added —
  see option B.
- **The nesting ADR, unlanded when this was written, is renumbered rather than
  allowlisted.** It sits on a branch as `0007-nested-commands-as-argv-rewriting.md`
  with nothing pushed, so it is not legacy in any sense that matters: when its
  pull request opens it takes that number like any other ADR, and its citations
  — two CLAUDE.md invariants and its own heading, all on the same unlanded
  branch — move with it. The allowlist stays at one entry. A second entry would
  have been the cheaper edit and the wrong one: an exemption is for a number
  already claimed on a forge, not for one an author picked yesterday.
- The guard reported three defects the first time it ran against this repo, all
  of them real: the two copies of the 0004 reservation, and — in its own
  introducing ADR — a citation the guard itself had mis-read, because a
  backtick span that wrapped across a line break was not being treated as
  shown. That last one is the kind of false positive that gets a lint deleted
  rather than fixed, and it was found by pointing the guard at prose written
  before it existed rather than only at fixtures.

## Options considered

- **A — status quo: the author reads the directory and picks the next number.**
  Rejected. It requires each author to hold state git will not show them, and
  it is what produced both symptoms above. Its failure is silent by
  construction, so it does not self-correct: nobody learns that it broke.
- **B — an index file in `docs/adr/` that reserves numbers.** Its virtue is
  real: concurrent claims collide on the same line range, so git *detects* what
  filenames hide. Rejected because it converts a rare silent failure into a
  frequent noisy one — every concurrent ADR now conflicts — and adds a second
  place the number is recorded and can drift. This repo already has that file
  informally, in `CLAUDE.md`, and it is where the 0004 reservation sits; the
  measured outcome is a two-week-old claim in the repo's most-edited file.
  Generating the index rather than writing it cures staleness, not conflicts.
  If a list is wanted, print it on demand and store nothing.
- **C — date-prefixed filenames (`2026-08-15-<slug>.md`).** Rejected: it breaks
  citation. `ADR-2026-08-15` is not a usable substitute for `ADR-0005` in a
  shell comment, and dropping to bare dates leaves no short stable identifier
  for the 105 existing references. Same-day collisions also remain possible, so
  it trades a common failure for a rarer one rather than removing it.
- **D — slugs only, no numbers.** Rejected *as the sole identifier*, for the
  same 105 citations. Its core claim is nonetheless right — a slug is a better
  identity than a number, because it exists from the moment the file does and
  carries meaning on its face — so it is adopted **alongside**: the slug
  identifies, the number abbreviates. That pairing is what allows an ADR to be
  cited before a forge has numbered it, at the cost of two forms to learn.
- **E — the pull request number, with slugs as the second form (chosen).**
  Collisions become impossible rather than detectable, no registry or allocator
  exists to drift, existing numbers and their citations are untouched, and the
  reservation mechanism disappears. The costs are the sparse numbering, the
  rename step, and one permanently frozen legacy range.

## References

- `xorq-labs/xorq ADR-2210`, and the pull requests that hardened it: #2210
  (the decision), #2211 and #2212 (the spent-allowlist warning and its first
  use), #2218 (a status that had gone stale under enforcement), #2221 and
  #2222 (cited-path and bare-SHA checking, scoped per line)
- #81 — the open pull request holding `docs/adr/0004-…`, and the reservation
  clause in `CLAUDE.md` that exists because of it
- #88 and #90 — ADR-0005 and ADR-0006, opened five minutes apart
- #86, #92, #93 — this repo's three trigger-path fail-opens, the family the
  `paths:`-filter note above belongs to
- [README.md](README.md) — the numbering rule and the authoring workflow
- [template.md](template.md)
