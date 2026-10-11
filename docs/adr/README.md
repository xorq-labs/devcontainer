# Architecture decision records

This directory records architecture decisions: choices where reasonable people
could disagree, where the reasoning outlives the diff, and where a future
reader needs to know what else was on the table. If the decision is "fix the
obvious bug", it belongs in a commit message.

Start from [template.md](template.md).

## Numbering

| Number | Meaning |
|--------|---------|
| Below 0100 | Legacy sequential number, frozen |
| 0100 and above | The number of the pull request that added the ADR |

A new ADR takes the number of the pull request that adds it, zero-padded to
four digits. GitHub allocates pull request numbers, so two branches cannot
claim the same ADR number and you never have to check which one is free.

ADR-0001 through ADR-0006 predate this rule and keep their sequential numbers
permanently: `ADR-NNNN` appears over a hundred times outside this directory —
in CLAUDE.md's invariant list, in `dev/` scripts, in `lib/command-table.tsv`,
in the Dockerfiles and in sixteen test suites — so renumbering would either
break those citations or need a risky sweep of them. The legacy set is closed
apart from one ADR still on a branch, which `dev/check-adr` names in its
`LEGACY_IN_FLIGHT` table; that list only ever shrinks, and says so out loud
once an entry has done its job. Pull request numbers are already past 140, so
the two ranges cannot meet.

Numbers are sparse and non-consecutive under this rule. That is the trade: the
number tells you which pull request introduced the decision, not how many came
before it. For chronology use `git log docs/adr/`.

See [ADR-numbers-come-from-pull-requests](XXXX-numbers-come-from-pull-requests.md)
for why — it is itself written under this rule, so it carries the placeholder
until its pull request exists.

## Citing an ADR

Two forms, and both keep working forever:

| Form | Example | Use it when |
|------|---------|-------------|
| Numbered | `ADR-0005` | the ADR has a number — the short form, preferred once one exists |
| Named | `ADR-guard-taxonomy` | the ADR has no number yet, or you are citing across branches |

The slug is an ADR's real identity: fixed when the file is created, never
changed. The number is an alias that arrives when the pull request does.

The named form is what lets you cite an ADR that is not numbered yet —
including one landing in a *later* pull request. That is why nobody has to
reserve a number in advance, and why no file records which numbers are taken.

`ADR-XXXX` is not a citation form. The placeholder names no particular ADR,
since every draft in flight carries it — cite an unnumbered ADR by slug.

The guard treats the two forms asymmetrically. A **numbered** reference that
does not resolve is an error: the forge allocated that number, so a missing
target is a mistake. A **named** reference that does not resolve is a warning,
because the ADR it names may still be on a branch that has not landed.

## Cross-repo references

ADR numbers are per-repo. A reference to another repo's ADR is qualified by
repo name — `claude-profile ADR-0001`, `xorq-labs/xorq ADR-2210` — and, for
another organisation's repo, given as a URL. ADR-0001 established this.

Write it **in backticks or as a link**. The guard resolves every bare
`ADR-NNNN` against this directory and has no idea that a repo name precedes
one, so an unquoted cross-repo citation either errors (the number is free here)
or, worse, silently resolves to a local ADR that is not the document you meant.
Backticks are already how this guard says "shown, not cited", so quoting costs
nothing and the alternative — teaching it which words are repo names — is a
hand-kept list of exactly the judgement being guarded.

## Writing one

1. `dev/adr-new my-decision` copies the template to
   `docs/adr/XXXX-my-decision.md`.
2. Write it. The `XXXX` placeholder stays in the filename until a pull request
   exists.
3. Open the pull request. An ADR usually rides along with the code that
   implements it, which is what makes the pull request number a useful
   identifier.
4. `dev/adr-rename` reads the pull request number, renames the file, updates
   the heading, and rewrites named references to it. Pass a slug —
   `dev/adr-rename my-decision` — if more than one ADR is in flight.
5. Push.

Write **one ADR per pull request**. The number comes from the pull request, so
a second ADR in the same one has no number to take. Open another pull request:
an ADR reviews fine on its own, and splitting a set of related decisions costs
nothing, because each is citable as `ADR-<slug>` from the moment it is written.

A pull request that changes an ADR-recorded decision amends the ADR in the same
pull request — doc and code land together or not at all (CLAUDE.md, "Design
decisions").

## Status

Status is the one field in an ADR that is a claim about *now*, so it is the one
field kept current. Everything else is history and is not edited to match the
present.

| Status | Meaning |
|--------|---------|
| `Proposed` | Written, not yet through a pull request. Only a draft still named `XXXX-<slug>.md` may say this |
| `Proposed (decision due YYYY-MM-DD)` | Landed while genuinely still open. The date is what stops it going quiet |
| `Accepted` | In force. Give the date and what makes it so — a landed pull request, an invariant, a guard |
| `Rejected` | Considered and declined. Kept, because the reasoning is the point |
| `Superseded by ADR-NNNN` | Reversed or replaced. The replacement says `Accepted, supersedes ADR-NNNN` |

Do not edit a decision that was reversed; supersede it. When the decision still
holds but the details changed, append a dated `## Amendment` section with its
own status line and leave the original text alone — ADR-0002, ADR-0005 and
ADR-0006 show the pattern. The top-level status stays `Accepted`; there is no
separate `Amended` status.

**Merging an ADR is what accepts it**, so a numbered ADR may not read a bare
`Proposed` — `dev/check-adr` fails the run over it. Three ADRs did read
`Proposed` while CLAUDE.md invariants named them as in force, until the pull
request that added this file. A status line the guard cannot parse is also an
error, not a pass: it must be a top-level `- Status: …` list item, so a
reformat cannot quietly exempt a file from the rule.

## Why there is no index

An index listing every ADR would be a second place recording each number, and
every concurrent pull request would append to the same line range and conflict
— reintroducing the coordination this scheme removes. Generating it rather than
writing it cures staleness, not conflicts.

Status and supersession live in each ADR's own header, which is the only place
they cannot go stale. `git log docs/adr/` and grep are the other ways in.

CLAUDE.md's "Current records:" sentence is a reading aid, not a register:
nothing derives from it, and under this rule it stops recording reservations.
Its `ADR-0004 is reserved by #81` clause is what a named reference replaces,
and goes when this rule is accepted — #81 keeps 0004 through the guard's
one allowlist entry, not through that sentence.

## What the guard checks, and what blocks

`dev/check-adr` runs two ways. On its own it checks everything derivable from
this directory: filenames, headings, statuses, duplicate numbers and slugs, and
that every `ADR-NNNN` resolves (an error) while every `ADR-<slug>` resolves or
warns. That half is hermetic, so it is driven by `tests/test-check-adr.sh` and
reaches CI through the `tests/*.sh` glob — no workflow lists it.

With `--base` and `--pr` it adds the one fact that is not in the tree: that a
newly added ADR is numbered after the pull request adding it, that only one ADR
is added, and that no `XXXX` survives. `.github/workflows/adr.yml` supplies
those from the event, and carries no path filter — a path-filtered workflow
reports no status at all on pull requests that miss it, which makes it
impossible to require.

Run it locally at any time:

```bash
dev/check-adr
```

**Nothing blocks a merge today.** `main` has no branch protection and no
rulesets, so this guard, `lint.yml` and `test.yml` all report rather than gate.
Requiring them is repository configuration, and the entry to add is the JOB
name — `adr` — not the workflow name, which matches nothing and would silently
never block.
