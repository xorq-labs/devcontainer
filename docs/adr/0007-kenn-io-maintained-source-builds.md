# ADR-0007: kenn-io toolkit — maintained source builds, tool by tool

- Status: Proposed
- Date: 2026-08-20
- Implemented by: `nix/kenn/source-build.nix` (the `kwt-from-source` proof of
  concept, commit 4067847 on `kenn-io-toolkit`) landed before this ADR and is
  the thing it retroactively scopes. Everything this ADR actually decides —
  the `update.py --rev` mode, `source-builds.json`, the drift guard, the
  CLAUDE.md invariant line — is unimplemented follow-up.
- Related: `nix/kenn/README.md`'s "Design notes" section, which recorded
  "binaries, not source builds" as the flake's design and is the decision this
  ADR amends; ADR-0005 (guard taxonomy — the vocabulary the new guard in
  Decision 4 must use); CLAUDE.md's kenn-io toolkit invariants (the
  `TOOLS`/`toolMeta`/`sources.json`/`systems` four-encoding set this ADR adds a
  parallel, smaller one beside).

## Context

`nix/kenn` packages the seven kenn-io CLIs exclusively from upstream release
binaries — the README's opening line, and a decision the "Design notes"
section defends explicitly: kata and forge embed a bun-built frontend via
`go:embed`, so a source build means running a JS toolchain first, and two
upstream repos (roborev, msgvault) already ship their own flakes for anyone
who wants that. Building from an arbitrary commit was out of scope.

A proof of concept now shows the mechanism works for one tool: `kwt` has no
cgo dependencies and no embedded frontend, so `mkKennToolFromSource` in
`nix/kenn/source-build.nix` is a plain `buildGoModule` against a pinned Go
1.26.6 toolchain and a pinned git rev — no bun/npm vendoring, no C
cross-toolchain. It builds `kenn-io/kwt@7d8162f`, 41 commits past the `v0.4.0`
tag `sources.json` has pinned, and the binary runs correctly.

That POC is deliberately unmaintained: no `update.py` integration, no drift
guard, a `rev` that will silently go stale. That's the right shape for "prove
the mechanism," and the wrong shape for "a capability people can rely on" —
a pin nothing ever refreshes eventually just stops building as upstream's
`go.mod` moves, and nothing will say why.

Extending this to a standing capability is not uniform-cost across the other
six tools. Prior assessment, for reference:

| Tool | Extra axis beyond kwt's | Rough effort |
|---|---|---|
| roborev | none (same shape as kwt) | low |
| docbank | npm frontend + `CGO_ENABLED=1` | medium-low |
| msgvault | bun frontend (bun2nix) + `CGO_ENABLED=1` | medium |
| agentsview | npm frontend + `CGO_ENABLED=1` | medium |
| kata | bun frontend + embed/restore-stub sequencing | medium-high |
| forge | two bun frontends + a Rust component (unaudited) | highest, unscoped |

And the update mechanism itself changes character. Every existing `bump-kenn`
mode (`--pin`, `--check`, `--verify`) reads a *published checksum manifest* —
no compiler, no full checkout, no build. A revision has no such manifest:
discovering its `vendorHash`/`srcHash` requires an actual `nix build`. That's
slower, needs a working builder, and can fail for reasons that have nothing to
do with upstream (sandbox, disk, network) — a materially different reliability
profile than the tool that exists today.

## Decision

**1. Adopt maintained source-build support, but graduate tools one at a time,
not as a batch.** A tool is "maintained" only once it has all four of:
   - a `mkKennToolFromSource`-shaped derivation in `source-build.nix`,
   - a bump mode in `update.py`/`bump-kenn` (Decision 3),
   - the drift guard this creates (Decision 4),
   - its own line in CLAUDE.md's Invariants section.

   `kwt` is the tool this ADR commits to finishing. The other six are
   explicitly **not** decided here — each graduates (or doesn't) as its own
   follow-up, evaluated against the effort table above, not committed to en
   masse. Forge in particular stays unscoped until its Rust component is
   actually audited.

**2. Source builds are a separate output surface, never merged into
`mkKennTool`.** Each graduated tool gets a `<tool>-from-source` package
attribute, exactly as `kwt-from-source` does today. A release binary and a
source build are different reproducibility contracts — a checksum-verified
published artifact vs. a commit plus a resolved module graph — and collapsing
them into one derivation function would force every consumer of
`packages.<tool>` to reason about which contract they got.

**3. New `update.py` mode: `--tool <name> --rev <ref>`.** Resolves `<ref>`
(branch, tag, or bare sha) to a commit sha via the GitHub API, runs a real
`nix build` to discover `srcHash` and `vendorHash` (there is no manifest to
read them from), and writes the result to a **new** file,
`nix/kenn/source-builds.json`, kept separate from `sources.json` rather than
merged into it: the two have different shapes (one hash pair per host build,
vs. per-platform hashes across four platforms), and a release pin and a
source-build pin drifting independently should not look like the same kind of
row. The existing `--check`/`--verify` split carries over unchanged: `--check`
reports whether the committed rev is behind `<ref>`'s current HEAD (exit 0
regardless — drift is news, not failure); `--verify` re-derives the committed
hashes by rebuilding (non-zero on a mismatch or a failed build).

**4. The drift guard lands with the second graduated tool, not the first.**
`tests/test-bump-kenn.sh` guards facts that must agree *across* files; with
only `kwt` graduated there is nothing yet for `update.py`'s new mode to
disagree with, per this repo's own rule that a convention is guarded "when
introduced" — introduction is the second instance, not the first. Recommend
docbank as that second tool specifically because it forces the guard (and the
derivation shape) to handle `CGO_ENABLED=1` and an npm frontend, which `kwt`
never exercised.

**5. Host-platform only, for now.** A graduated tool's source build targets
the platform it's built on — matching how `--rev` actually gets used ("build
what I'm running"), not the four-platform matrix release binaries get.
Cross-compiling `CGO_ENABLED=1` tools to darwin from a non-darwin host is a
real, separate difficulty (the release-binary route already carries this as
its one unverified corner) and is out of scope until a graduated tool actually
needs it.

**6. CI stays out of scope.** Nothing evaluates `nix/kenn`'s flake in CI
today; a source-build mode existing does not by itself justify standing that
up. Revisit only if a graduated tool is seen going stale silently between
manual `--verify` runs.

## Consequences

- `nix/kenn` gains a second maintenance axis alongside the existing
  `TOOLS`/`toolMeta`/`sources.json`/`systems` four-way encoding: each
  graduated tool adds a row to `source-builds.json`, a case in the new
  `update.py` mode, and a CLAUDE.md invariant line. Smaller per tool, but real,
  and it grows with every tool that graduates.
- `update.py`'s bump tool changes character for `--rev`: it goes from a pure
  checksum-manifest reader to something that must run a real build to produce
  a trustworthy pin. A failed `--verify` on a source-build entry can mean the
  builder, not upstream — worth remembering when triaging.
- Every graduated tool is a standing per-revision item someone has to decide
  to refresh; unlike release pins, `--check` cannot tell you "there's a newer
  tagged version," only "the ref you're tracking has moved."
- Reversible per tool: un-graduating one (drop its `source-builds.json` entry,
  its guard coverage, its CLAUDE.md line) doesn't touch any other tool —
  Decision 2 is what makes that true.

## Options considered

- **A — generalize to all seven tools now.** Rejected: forge's Rust component
  is unaudited and kata's embed/restore-stub sequencing is unverified;
  committing to all seven blocks the cheap wins on the expensive, uncertain
  ones.
- **B — keep the POC exactly as-is, permanently (an escape hatch, not a
  capability).** Rejected under a "maintained capability" framing specifically:
  a `rev` pin nothing ever refreshes will eventually stop building as
  upstream's `go.mod` drifts, silently, with nobody notified.
- **C — graduate tools one at a time, each with its own bump mode and guard
  (chosen).** Matches how this repo's other ~30 CLAUDE.md invariants actually
  arrived — each with its own guard at introduction, not as a batch — and lets
  the highest-uncertainty tool (forge) be deferred indefinitely without
  blocking the rest.
