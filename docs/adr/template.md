# ADR-XXXX: <title — the decision, not the problem>

<!--
Do not copy this file by hand — run `dev/adr-new <slug>`, which saves it as
docs/adr/XXXX-<slug>.md.

XXXX is a placeholder, not a number to fill in. An ADR takes the number of the
pull request that adds it, so the number does not exist until the pull request
does. Open the pull request, then run `dev/adr-rename` to rename the file and
fix this heading. See README.md for the full rule.

To cite an ADR that has no number yet — one landing in a later pull request,
say — use its slug: ADR-guard-taxonomy rather than ADR-0005. Both forms
resolve, and `dev/adr-rename` swaps the named form for the number once one
exists. This is why you never reserve a number in advance.

The title names the decision, not the symptom.
  Good:  "Nested commands are argv rewriting, and flat names are permanent"
  Bad:   "Fix the devcontainer subcommand problem"

Delete these guidance comments before merging.
-->

- Status: Proposed
- Date: YYYY-MM-DD
- Implemented by: <this PR (what in it), or the PR that carries the code>
- Related: <!-- ADR-0005, or ADR-<slug> if it has no number yet; issues and PRs
  that are evidence for the Context; other repos' ADRs qualified by repo name -->

## Context

<!--
What situation prompted this decision? Enough background that a reader
unfamiliar with the current code understands why a decision is needed.

Cite evidence rather than asserting a tendency: the issue number, the pull
request, the commit, the measurement and when it was taken. This repo's ADRs
are read years later by someone deciding whether the reasoning still holds.

This section should make clear that reasonable people could disagree. If the
answer is obvious, it belongs in a commit message.
-->

## Decision

<!--
What was decided, and how does it work? Subsections (###) for distinct design
choices. Explain the reasoning inline — why this, not just what.

If the decision spans two files, say what guards it, typed per ADR-0005
(test:/tool:/ci:/structural/unguarded: <why>). "A comment will do" is never
sufficient. If no guard lands with the decision, say so plainly and name the
follow-up rather than leaving it implied.

Reference file:line instead of pasting implementations.
-->

## Consequences

<!--
What this costs as well as what it buys, in one list. A consequence a reviewer
would raise and you have accepted belongs here, stated as an acceptance — that
is what makes the record usable later.
-->

## Options considered

<!--
Lettered, each with what it is and why it was rejected or chosen. Include the
status quo as an option. Say "rejected" or "deferred" explicitly, so a future
reader knows whether the door is open.
-->

- **A — <name>.** <What it is.> Rejected: <why.>
- **B — <name> (chosen).** <Why this one.>
