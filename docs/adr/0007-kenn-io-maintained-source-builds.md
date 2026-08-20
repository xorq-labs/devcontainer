# ADR-0007: kenn-io toolkit — maintained source builds, tool by tool

- Status: Proposed
- Date: 2026-08-20
- Implemented by: `nix/kenn/source-build.nix` — `kwt-from-source` (commit
  4067847) and `docbank-from-source`, both landed before this revision and
  retroactively scoped by it. Everything else this ADR decides — the
  `update.py --rev` mode, `source-builds.json`, the drift guard, the CLAUDE.md
  invariant lines — is unimplemented follow-up. **Neither wired-up tool counts
  as "graduated" under Decision 1's own four-part definition yet**: both are
  still derivation-shape proofs, not maintained pins. Read literally, that
  means Decision 1 has zero completions so far, not one.
- Reviewed: an independent adversarial pass (2026-08-20) found Decision 3 never
  specified who is authoritative between `update.py` and `source-build.nix`,
  found Decision 4's "second tool" trigger was reachable regardless of whether
  the thing it depends on (Decision 3) exists, found the new `--rev` mode
  breaks `test-bump-kenn.sh`'s documented hermeticity premise, and found
  Options considered never weighed consuming upstream's own source-build
  flakes. All four are addressed below rather than in a separate amendment,
  since nothing here had shipped as relied-upon yet.
- Related: `nix/kenn/README.md`'s "Design notes" section, which recorded
  "binaries, not source builds" as the flake's design and is the decision this
  ADR partially reverses (that section now cross-references this ADR);
  ADR-0005 (guard taxonomy — the vocabulary the new guard in Decision 4 must
  use); CLAUDE.md's kenn-io toolkit invariants (the
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

A second proof — `docbank` — has since landed the same way, deliberately
chosen for the opposite shape: `CGO_ENABLED=1` (mattn/go-sqlite3) plus an
npm-built Svelte frontend embedded via `go:embed`. It forced three real fixes
(a `git+https` dependency in `package-lock.json` needing `forceGitDeps`, a
root-owned npm cache from that same git fetch needing `makeCacheWritable`,
and `vite-plus` — docbank's Vite replacement — panicking on a missing CA
bundle in the sandbox) that `kwt` never exercised, and is documented in
`nix/kenn/README.md`. It is exactly as unmaintained as `kwt`: same inline
literal pins, same absence of `update.py`/guard/CLAUDE.md coverage. Both are
proofs the derivation shape generalizes, not completions of Decision 1.

Extending this to a standing capability is not uniform-cost across the
remaining tools. Prior assessment, for reference:

| Tool | Extra axis beyond kwt's | Rough effort |
|---|---|---|
| roborev | none (same shape as kwt) | low |
| docbank | npm frontend + `CGO_ENABLED=1` | done (proof only, see above) |
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

   `kwt` and `docbank` are the tools this ADR commits to finishing (Decision 3
   is what finishes them — see the header note on why neither counts as
   graduated yet). The other five are explicitly **not** decided here — each
   graduates (or doesn't) as its own follow-up, evaluated against the effort
   table above, not committed to en masse. Forge in particular stays unscoped
   until its Rust component is actually audited.

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

`source-builds.json` is authoritative; `source-build.nix` reads its per-tool
values from it, exactly as `packages.nix` reads `sources.json` today — a
graduated tool's `rev`/`srcHash`/`vendorHash` stop being literals in the
`.nix` file the moment this lands. This is a real migration of `kwt-from-source`
and `docbank-from-source` off their current inline literals, not just new
tools joining a pattern that already existed.

This mode cannot be fully hermetic the way `--pin`/`--check`/`--verify` are
today, and the ADR should say so rather than imply otherwise: discovering a
hash requires an actual `nix build`, a second external dependency beyond
`update.py`'s current sole one (`http_get`). Split what's actually checkable:
the *shape* agreement between `source-builds.json`'s keys and
`source-build.nix`'s attributes is a pure parse, testable exactly like
`test-bump-kenn.sh` tests the four-way `TOOLS` encoding today (`test:`); the
*correctness* of a committed hash against a live rebuild is not — no fixture
stands in for "did this really build," so that half is `tool:`, in the same
family as `dev/bump-nix`'s installer checksum (a real network fetch and a real
build is the only oracle, so the tool performing it correctly is the
guarantee, not a hermetic suite).

**4. The drift guard lands in the same change as Decision 3, not gated on any
tool count.** The original text here tied the guard to "the second graduated
tool," reasoning that a single tool has nothing to disagree with. That reasoning
doesn't hold up: the coupling `test-bump-kenn.sh` would guard is between
`update.py`'s new mode and `source-build.nix`'s shape, and that coupling is
created the moment Decision 3 exists — at zero, one, or seven tools, it's the
same fact needing the same guard. Tying it to a tool count also hands Decision
1 a way to defer the guard indefinitely, since Decision 1 already allows a
tool to never graduate. Restated plainly: **there is no "unguarded, one tool"
state this ADR endorses.** Until Decision 3 lands, `kwt-from-source` and
`docbank-from-source` are proofs, explicitly not counted as graduated (see the
header note) — precisely so their current unguarded state doesn't need an
excuse.

docbank was still the right second proof to build before Decision 3, for a
different reason than the original text gave: not because it's when the guard
becomes due, but because it's cheap evidence the derivation shape (not the
update tooling) generalizes past `kwt`'s easy case — `CGO_ENABLED=1` and an
npm frontend, which `kwt` never exercised — before investing in `update.py`
machinery for a shape that might not have worked.

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
- A separate, pre-existing coupling this ADR does not fix: `flake.nix`'s
  `goPinned` (Go 1.26.6 as a version + `fetchurl` hash pair, matching every
  kenn-io `go.mod`) is exactly the shape `dev/bump-nix` exists to guard for
  the Nix installer pin, and has neither a bump tool nor a test here.
  Recorded as accepted per ADR-0005 `unguarded:` framing rather than left
  silent: **unguarded** — a wrong pin fails loudly (every graduated tool's
  build breaks immediately, not silently) and there is exactly one such pin
  shared by every graduated tool, so the blast radius of leaving it hand-edited
  is a build failure, not drift. Revisit if kenn-io tools ever disagree on a Go
  version, which would need per-tool pins instead of one shared override.

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
- **D — consume upstream's own source-build flakes as inputs, instead of
  reimplementing per-tool derivations in `source-build.nix`.** Real, and not
  weighed in the original text. `roborev` and `msgvault` already ship working
  flakes; `numtide/llm-agents.nix` maintains one for `agentsview`. Pulling
  those in as flake inputs would save real vendoring work for three of the six
  remaining tools. Rejected, for three reasons: (1) it only covers 3 of 7 —
  `kata`, `forge`, `kwt`, and `docbank` (already built) have no upstream flake
  to consume, so this can't replace `source-build.nix`, only supplement it,
  and a flake with two different mechanisms for "source build" depending on
  which tool you ask for is a worse interface than one mechanism with uneven
  tool coverage; (2) it imports someone else's pin cadence and footguns
  wholesale — the README already flags that roborev's flake pins its own
  nixpkgs and breaks under `inputs.nixpkgs.follows`, which is exactly the kind
  of external volatility Decision 3's own pins are meant to control directly;
  (3) `numtide/llm-agents.nix` for agentsview is third-party, not upstream —
  depending on it couples this flake's reliability to a maintainer with no
  relationship to kenn-io at all. Worth revisiting per-tool if a specific
  upstream flake turns out cheaper than writing that tool's own
  `source-build.nix` entry — this is a rejected default, not a rejected
  option for every tool.
