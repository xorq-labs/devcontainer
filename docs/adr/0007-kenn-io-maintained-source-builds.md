# ADR-0007: kenn-io toolkit — maintained source builds, tool by tool

- Status: Proposed
- Date: 2026-08-20
- Implemented by: `nix/kenn/source-build.nix` (`kwt-from-source`,
  `docbank-from-source`, `agentsview-from-source`, `msgvault-from-source`,
  `roborev-from-source`, `kata-from-source`),
  `nix/kenn/source-builds.json` (Decision 3's pin
  space), `nix/kenn/bun/` (Decision 3's second pin element, added by the
  2026-08-20 amendment below), `update.py`'s
  `--source`/`--rev` mode (Decision 3: `SOURCE_BUILD_TOOLS`,
  `SOURCE_BUILD_BUN_NIX`, `commit_sha`,
  `nix_build`, `harvest_hash_mismatches`, `discover_source_hashes`,
  `degrade_git_lock_entries`, `generate_bun_nix`,
  `do_source_write`/`do_source_check`/`do_source_verify`), the shape half of
  Decision 4's guard (`tests/test-bump-kenn.sh` §6), a new `bun2nix` flake
  input (`nix-community/bun2nix`, shared infrastructure for msgvault, kata,
  and roborev, plus an `apps.bun2nix` passthrough so `update.py` can only ever
  run the pinned version), and the CLAUDE.md invariant lines. **`kwt`,
  `docbank`, `agentsview`, `msgvault`, `roborev`, and `kata` are now graduated
  under Decision 1's own
  four-part definition** — derivation, bump mode, guard, CLAUDE.md line, all
  four present for all six. What remains unimplemented: `forge`
  (its own follow-up, per Decision 1) and CI (Decision 6,
  deliberately out of scope).
- Amended 2026-08-20 (Decision 3): a source-build pin is no longer only a rev
  plus hashes. A tool whose bun frontend upstream ships no `bun.nix` for needs
  a whole generated *file* committed beside the pin, because the expression
  cannot be produced inside a sandboxed build. See "Amendment: generated
  bun2nix expressions" below.
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

A second proof — `docbank` — landed the same way, deliberately chosen for the
opposite shape: `CGO_ENABLED=1` (mattn/go-sqlite3) plus an npm-built Svelte
frontend embedded via `go:embed`. It forced three real fixes (a `git+https`
dependency in `package-lock.json` needing `forceGitDeps`, a root-owned npm
cache from that same git fetch needing `makeCacheWritable`, and `vite-plus` —
docbank's Vite replacement — panicking on a missing CA bundle in the sandbox)
that `kwt` never exercised, and is documented in `nix/kenn/README.md`.

Both tools have since been carried the rest of the way through Decision 1's
four-part definition: `source-builds.json` now holds their pins (migrated off
the inline literals `source-build.nix` originally hard-coded), `update.py`
gained the `--source`/`--rev` mode Decision 3 describes, and the shape half of
Decision 4's guard is in place.

A third proof — `agentsview` — landed the same shape as docbank (`CGO_ENABLED=1`
+ npm/Svelte frontend, same `@kenn-io/kit-ui` git dependency and `vite-plus`
CA-cert quirks) but surfaced four more real issues docbank never hit, now
documented in `nix/kenn/README.md`: its cgo sqlite header must come from the
*vendored* mattn/go-sqlite3 module's own amalgamation header rather than a
system `sqlite` package (upstream's own Makefile warns why); `buildGoModule`'s
own `go mod vendor` step disagreed with itself on its dependency graph, fixed
with `proxyVendor = true;` (the same fix msgvault's own `nix/package.nix` uses
for the identical error shape); `make build` depends on a network-fetched,
hash-pinned pricing snapshot with no place in a sandboxed build, fetched
instead as its own `fetchurl` derivation; and — a finding general to any
future tool with an embed-copying `preBuild`, not agentsview-specific —
`buildGoModule`'s internal vendor-fetch derivation inherits `preBuild` too by
default, which is harmless for a plain directory copy (docbank) but fatal
once that `preBuild` does anything that depends on the vendor fetch having
already finished (`go list -m` here); fixed with `overrideModAttrs = _: {
preBuild = ""; };`, applied to both agentsview and (for correctness, since it
never needed to run there either) docbank.

A fourth proof — `msgvault` — landed as the first **bun**-frontend tool, via a
new `bun2nix` (`nix-community/bun2nix`) flake input. Closely adapted from
msgvault's own working `nix/package.nix` rather than reinvented (simplified
by dropping its own bun-version-repinning dance, which protects ITS OWN
release cadence against bun2nix drift — not a risk a single source-build
entry here carries). Confirmed the research finding that there is no separate
"bun deps hash" to discover: bun2nix reads a `web/bun.nix` file already
committed inside the fetched tree, whose per-package hashes are covered by
the ordinary `srcHash` — `msgvault` needs no extra `SOURCE_BUILD_TOOLS` field,
same as `kwt`. Its cgo sqlite header comes from the plain system `sqlite`
package rather than agentsview's vendored-header route — a different,
equally valid choice, not a rule to generalize from. `overrideModAttrs` here
does two things, not one: filters `bun2nix.hook` out of the go-modules
derivation's `nativeBuildInputs` (it has no business running there) and
clears `preBuild` (the same leak agentsview hit).

A fifth proof — `roborev` — is the first **workspace**-scope bun frontend, and
the first tool whose difficulty was not in the shape of its build but in what
upstream does *not* ship. Its Go side is the simplest of any tool here with a
frontend
(`modernc.org/sqlite` is pure Go — no cgo, no header, no `CGO_CFLAGS`), and its
own upstream flake skips the frontend entirely, which is exactly why the
original "same shape as kwt" estimate was wrong: the tool it produces is a
stub-only binary. Three findings, documented in `nix/kenn/README.md`:

- The bun lockfile is at the **repo root** and covers `web/` plus
  `packages/roborev-ui/` together, not msgvault's self-contained `web/`. So
  `bunRoot` is left unset, the hook installs at the source root, and every
  dependency hoists into one top-level `node_modules` — which is why the vite
  invocation has to reach *up* out of `web/`. This half of the guess in the
  effort table was right and cost almost nothing.
- Upstream ships **no `bun.nix`**, and `bun2nix` cannot generate one inside a
  sandboxed build: it shells out to `nix flake prefetch` for any dependency
  whose hash the lockfile doesn't already carry, which is nix-inside-nix. This
  is the finding that needed a decision rather than a fix, and it is the
  amendment below.
- `bun2nix` 2.1.2 **mis-parses** roborev's `@kenn-io/kit-ui` dependency,
  silently: it dispatches on a lockfile entry's arity (3 = tarball/git/github,
  4 = npm registry), bun writes a `github:` dependency with four elements, and
  the result is a `fetchurl` of a registry URL that does not exist. Handled by
  dropping the cache-key element before generation
  (`degrade_git_lock_entries`), with a backstop that refuses to *write* a
  generated expression still containing a registry URL with a git specifier in
  it — the failure mode is otherwise a 404 at build time, far from its cause.
  msgvault does not hit this because its kit-ui dependency is spelled as a
  tarball URL, already arity 3. Same dependency, two spellings, one broken.

A sixth proof — `kata` — is the first that mostly confirmed the investment
rather than extending it. Its frontend side is roborev's shape verbatim (root
`bun.lock` workspace, no committed `bun.nix`, the same `@kenn-io/kit-ui` at the
same rev in the same arity-4 `github:` spelling), so the amendment's machinery
and `degrade_git_lock_entries` both applied unchanged and the derivation was a
near-copy — which is what five tools of accumulated quirks is supposed to buy.

It did add one real thing, and the *research pass had this one backwards*: it
recorded that `CGO_ENABLED=0` "genuinely holds ... despite go.mod listing
`sqlite-vec-go-bindings`", which is true of upstream and false of a naive
derivation. `buildGoModule` inherits Go's default of `CGO_ENABLED=1`, and
`asg017/sqlite-vec-go-bindings` is reachable from `cmd/kata` and `#include`s a
`sqlite3.h` it does not ship, so the build fails outright — *after* the whole
frontend has built, so it costs a full round to discover. Upstream never sees
it because `.goreleaser.yaml` sets `CGO_ENABLED=0` on all four kata build ids,
selecting the pure-Go `modernc.org/sqlite` path. The transferable lesson for
`forge` is that the authority on a tool's cgo posture is its **release
config**, not its module graph — `go.mod` here requires two cgo sqlite drivers
and a pure-Go one simultaneously, and reading it either way in isolation gives
the wrong answer.

**`kwt`, `docbank`, `agentsview`, `msgvault`, `roborev`, and `kata` count as
graduated as of this revision.**

Extending this to a standing capability is not uniform-cost across the
remaining tools. Prior assessment, updated after researching all four
remaining tools and auditing forge's Rust component:

| Tool | Extra axis beyond kwt's | Rough effort |
|---|---|---|
| docbank | npm frontend + `CGO_ENABLED=1` | done — graduated |
| agentsview | npm frontend + `CGO_ENABLED=1` + 3 more quirks (see above) | done — graduated |
| msgvault | bun frontend (bun2nix, now in place) + `CGO_ENABLED=1` | done — graduated |
| roborev | bun **workspace** frontend (repo-root scope, not self-contained, unlike msgvault's) + no cgo, but IS embedded (its own upstream flake omits the frontend entirely, producing a stub binary — the original "same shape as kwt" guess was wrong) + no committed `bun.nix` and a bun2nix parse bug on its git dependency, neither of which the research pass predicted | done — graduated (was: medium) |
| kata | bun **workspace** frontend (repo-root scope) + embed/restore-stub sequencing (a harmless plain directory copy) + `CGO_ENABLED=0` must be set explicitly, which the research pass got backwards. Turned out to be roborev's shape verbatim otherwise | done — graduated (was: medium-high) |
| forge | **Re-scoped 2026-08-20 and it shrank.** Its Rust component is not in the released binary (opt-in `KENN_FORGE_PTY_MANAGER` env var; never built by `release.yml`), so a source build should omit it. Its "two independent frontends" share ONE bun workspace (root `bun.lock`, `workspaces: ["frontend", "packages/*"]`) — one generated `bun.nix`, two build outputs. No `.goreleaser.yaml` (releases from a workflow), and `vite-plus` needs `SSL_CERT_FILE` as docbank's did | low-medium (was: highest) |

All three of the then-remaining bun tools (roborev, msgvault, kata) needed
`bun2nix` —
shared infrastructure worth building once as a new flake input, not three
times; msgvault's own `nix/package.nix` already has a working recipe to adapt,
and can be simplified (skip its own bun-version-repinning dance, which exists
to protect its own release cadence, not something a single source-build entry
here needs). Since borne out: the input landed with msgvault and roborev
reused it unchanged. What roborev showed is that "needs `bun2nix`" is not one
shape — a tool that commits its own `bun.nix` and one that doesn't are
different amounts of work, and only the first was anticipated here.

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

   `kwt`, `docbank`, `agentsview`, `msgvault`, `roborev`, and `kata` have
   completed all four (see the header note). `forge` is explicitly **not**
   decided here —
   each graduates (or doesn't) as its own follow-up, evaluated against the
   effort table above, not committed to en masse. Forge in particular was the
   one tool this ADR held unscoped pending its Rust component's audit. That
   audit happened (tractable), and a later pass made it moot: the released
   binary does not contain that component at all, so a source build need not
   build it. Nothing about forge is unscoped now, and it is no longer the
   expensive one — see the effort table.

**2. Source builds are a separate output surface, never merged into
`mkKennTool`.** Each graduated tool gets a `<tool>-from-source` package
attribute, exactly as `kwt-from-source` does today. A release binary and a
source build are different reproducibility contracts — a checksum-verified
published artifact vs. a commit plus a resolved module graph — and collapsing
them into one derivation function would force every consumer of
`packages.<tool>` to reason about which contract they got.

**3. New `update.py` mode: `--source --tool <name> --rev <ref>`.** [Implemented.]
Resolves `<ref>`
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
values from it via a `sourceBuilds ? builtins.fromJSON (...)` default arg,
exactly as `packages.nix` reads `sources.json` — `kwt-from-source` and
`docbank-from-source`'s `rev`/`srcHash`/`vendorHash` (and docbank's
`npmDepsHash`) are no longer literals in the `.nix` file; that migration
landed with this mode, not as a separate step.

This mode cannot be fully hermetic the way `--pin`/`--check`/`--verify` are:
discovering a hash requires an actual `nix build`, a second external
dependency beyond `update.py`'s prior sole one (`http_get`). What's
implemented reflects the split this ADR draws: `do_source_write` seeds a
draft entry with placeholder hashes and repeatedly rebuilds
(`discover_source_hashes`), harvesting each real hash `nix build` reports from
a deliberate mismatch (`harvest_hash_mismatches`, keyed off nixpkgs' own
fixed-output derivation naming — `-source` for `fetchFromGitHub`,
`-go-modules` for `buildGoModule`, `-npm-deps` for `buildNpmPackage`) until the
build succeeds clean; `do_source_verify` re-runs the same build against the
committed hashes with no placeholders, and a clean build IS the verification
— there is no separate comparison, because there is no manifest to compare
against. The *shape* agreement (`SOURCE_BUILD_TOOLS` vs. `source-build.nix`'s
exposed attributes vs. `source-builds.json`'s keys) is hermetically tested
(`tests/test-bump-kenn.sh` §6, `test:`); the *correctness* of a committed hash
is not (`tool:`, same family as `dev/bump-nix`'s installer checksum) — proven
instead by actually running `nix build .#kwt-from-source` /
`.#docbank-from-source` for real when each pin was written, not by a fixture.

### Amendment: generated bun2nix expressions (2026-08-20)

Decision 3 assumed a source-build pin is a rev plus hashes: things
`discover_source_hashes` can learn from a deliberate `nix build` mismatch.
`roborev` broke that assumption. It embeds a bun frontend, upstream ships no
`bun.nix`, and `bun2nix` cannot produce one inside a sandboxed build — for any
dependency whose hash the lockfile doesn't already carry (roborev's is a
`github:` dependency, so it doesn't) bun2nix shells out to `nix flake
prefetch`, which is nix-inside-nix. The expression therefore has to be
generated **outside** the build and committed.

**Decided: a graduated tool's pin may include a generated file, kept in
`nix/kenn/bun/<tool>.nix` and written by the same `--source` run that writes
its hashes.** `update.py`'s `SOURCE_BUILD_BUN_NIX` names which tools need one
(a deliberately separate mapping from `SOURCE_BUILD_TOOLS`, because a generated
file is not a discovered hash), and generation runs *before* the first
build round rather than in the harvest loop — `source-build.nix` imports the
file, so it must exist for the first round to even evaluate.

Three consequences worth stating rather than discovering:

- **Nothing re-derives a generated file the way `--verify` re-derives a
  release hash**, so a stale one is caught only by the build failing. That is
  the same `tool:` guard family the rest of `--source` already sits in, and it
  is not vacuous here: a `bun.nix` that no longer matches the rev's lockfile
  makes the offline `bun install` fail, not silently succeed. What IS
  hermetically guarded is the shape agreement — every `SOURCE_BUILD_BUN_NIX`
  key has a committed file, every committed file has a key, and
  `source-build.nix` imports each one (`tests/test-bump-kenn.sh` §6). The
  orphan direction matters most: a committed file whose key was dropped is
  regenerated by nothing and rots against the rev sitting next to it.
- **Generating for a tool for the first time needs a `git add` before nix can
  see the file at all** (nix reads only tracked files from a dirty work tree).
  `update.py` detects this and stops with the command to run, leaving the file
  in place, rather than letting it surface as an eval error about a missing
  path.
- **The generator is pinned to this flake's own `bun2nix`** via a new
  `apps.bun2nix`, because `bun.nix` has no schema stability guarantee across
  bun2nix versions — a generator newer than the consuming `bun2nix.hook` would
  produce a file the hook cannot read.

Rejected alternatives, briefly: a fixed-output derivation running `bun install`
and committing one `bunDepsHash` (fits the existing harvest loop exactly, but
bets on `bun install`'s byte-level reproducibility, which nothing upstream
promises — whereas bun2nix's output is a deterministic function of the
lockfile); the same FOD producing `bun.nix` and importing it back (needs nix
inside the sandbox — the very thing that forced this); and building roborev
with the stub frontend as its own flake does (cheap, but delivers strictly less
than the release binary the flake already ships, which makes the source build
pointless for the one tool people would reach for it on).

**4. The drift guard lands in the same change as Decision 3, not gated on any
tool count.** [Implemented — shape half only, by design; see Decision 3.] The
original text here tied the guard to "the second graduated tool," reasoning
that a single tool has nothing to disagree with. That reasoning doesn't hold
up: the coupling `test-bump-kenn.sh` guards is between `update.py`'s
`SOURCE_BUILD_TOOLS`, `source-build.nix`'s exposed attributes, and
`source-builds.json`'s keys, and that coupling is created the moment Decision
3 exists — at zero, one, or seven tools, it's the same fact needing the same
guard. Tying it to a tool count would also have handed Decision 1 a way to
defer the guard indefinitely, since Decision 1 already allows a tool to never
graduate.

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
  `update.py` mode, and a CLAUDE.md invariant line — plus, for a tool upstream
  ships no `bun.nix` for, an entry in `SOURCE_BUILD_BUN_NIX` and a generated
  `nix/kenn/bun/<tool>.nix`. Smaller per tool, but real,
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
  weighed in the original text. `roborev` and `msgvault` already ship
  flakes (both superseded here — each graduated via its own
  `source-build.nix` entry, msgvault adapted from that flake's recipe rather
  than consumed as an input, roborev *not* adaptable from it at all: its flake
  omits the frontend, so what it builds is a stub-only binary, which is a
  concrete instance of reason (2) below rather than a reusable recipe);
  `numtide/llm-agents.nix` maintains a third-party one
  for `agentsview` (also superseded, the same way). Rejected, for three
  reasons: (1) it never covers all seven — every tool graduated so far is
  built directly rather than consumed as a flake input, so this can't replace
  `source-build.nix`, only supplement it, and a
  flake with two different mechanisms for "source build" depending on which
  tool you ask for is a worse interface than one mechanism with uneven tool
  coverage; (2) it imports someone else's pin cadence and footguns wholesale —
  the README already flags that roborev's flake pins its own nixpkgs and
  breaks under `inputs.nixpkgs.follows`, which is exactly the kind of external
  volatility Decision 3's own pins are meant to control directly; (3) a
  third-party flake (agentsview's `numtide/llm-agents.nix` case) couples this
  flake's reliability to a maintainer with no relationship to kenn-io at all.
  Worth revisiting per-tool if a specific upstream flake turns out cheaper
  than writing that tool's own
  `source-build.nix` entry — this is a rejected default, not a rejected
  option for every tool.
