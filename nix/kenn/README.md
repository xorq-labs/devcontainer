# kenn-io toolkit flake

Packages the seven kenn-io CLIs from their **upstream release binaries**:

| Attr | Repo | License |
|---|---|---|
| `kata` | kenn-io/kata | MIT |
| `kenn-forge` | kenn-io/**forge** | Elastic-2.0 (unfree in nixpkgs) |
| `roborev` | kenn-io/roborev | MIT |
| `msgvault` | kenn-io/msgvault | MIT |
| `docbank` | kenn-io/docbank | Apache-2.0 |
| `kwt` | kenn-io/kwt | Apache-2.0 |
| `agentsview` | kenn-io/agentsview | MIT |

`kenn-io/kit` is a Go library with no binary, so there is nothing to package.

## Usage

```sh
nix run .#kata -- version
nix profile install .#kenn-io-toolkit      # the six freely-licensed tools
nix profile install .#kenn-io-toolkit-all  # ...plus kenn-forge
nix develop                                # shell with everything + the updater
```

`packages.default` is `kenn-io-toolkit` — deliberately **without** `kenn-forge`.
The flake already scopes an `allowUnfreePredicate` so forge builds without any
config from you, but shipping an Elastic-licensed binary in the default target
is a policy call you should make explicitly.

### Using the overlay

```nix
nixpkgs.overlays = [ inputs.kenn-io.overlays.default ];
```

The overlay builds against *your* pkgs, so the flake's internal unfree
predicate does not apply. If you want `kenn-forge` through the overlay, add:

```nix
nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "kenn-forge";
```

ELv2 only forbids offering the software as a hosted service to third parties,
circumventing license keys, and removing notices. It explicitly permits use,
copying and distribution. nixpkgs marks it `free = false`, and because
`redistributable` defaults to `free`, it inherits `redistributable = false`
too — that is nixpkgs being conservative about an unset attribute, not a
statement about ELv2.

## Updating

```sh
./update.py                    # bump everything to latest
./update.py --tool kata forge  # only these
./update.py --pin kata=0.14.3  # hold one back
./update.py --check            # report committed vs latest, never edit
./update.py --verify           # gate the committed pins (for CI)
```

Or `devcontainer bump-kenn <same args>` — `dev/bump-kenn` is a thin wrapper
that finds this script from anywhere.

`--check` and `--verify` are not interchangeable, and follow the same split as
`dev/bump-hadolint` and `dev/bump-nix-base`:

- **`--check` is a report.** Drift is news, not a failure — it exits 0 whether
  or not a newer release exists, and non-zero only when it has no report to
  give (a version it could not resolve at all).
- **`--verify` is the gate.** It ignores latest-ness entirely and re-derives
  every *committed* version's entry from that release's published manifest,
  failing on a wrong hash, a vanished asset, an unresolvable release, or an
  entry for a tool `TOOLS` no longer lists. An unreachable upstream fails
  rather than passing unchecked.

`TOOLS` in `update.py`, `toolMeta` in `packages.nix`, `sources.json`'s keys and
`flake.nix`'s `systems` are four encodings of one tool set, and nothing here
evaluates the flake in CI — `tests/test-bump-kenn.sh` is the drift guard, and
also pins the exit contract above.

`update.py` is both the bootstrap and the update path — generating the first 28
hashes and refreshing them are the same operation, so there was never a
hand-pinning step.

It never downloads a tarball. Every release publishes a checksum manifest, so
28 SRI hashes come from 7 small text files instead of ~500MB of binaries
(hex → SRI is just base64 of the raw digest).

### Upstream quirks it handles

These are all real and all cost a debugging round if ignored:

- **`kwt` publishes `checksums.txt`**; every other repo publishes `SHA256SUMS`.
- **`forge` prefixes every checksum entry with `./`**; the others use a bare
  filename. A naive `sha256sum -c` pipeline fails on forge and only forge.
- **`kata` publishes decoys.** `kata_X_homebrew_linux_amd64.tar.gz` sits beside
  `kata_X_linux_amd64.tar.gz`; `agentsview` ships `.AppImage`/`.dmg` desktop
  artifacts in the same release. Asset names are therefore constructed exactly,
  never globbed.

Releases move fast (roborev was at v0.64.0, agentsview v0.40.1 when this was
written). Wire `--verify` into CI to gate the pins, and `--check` into a
scheduled job if you want to be told about drift without failing on it.

## Building from source

Everything above fetches a **tagged release** asset. `source-build.nix` is a
separate, narrower path that builds a tool directly from a git revision —
useful for testing an unreleased fix or a commit with no published binary at
all. It is intentionally not integrated into `mkKennTool`: a source build is a
different reproducibility contract (pinned to a commit + a Go module graph,
not to a checksum-verified published artifact), and mixing the two modes into
one derivation function would make both harder to read.

```sh
nix build .#kwt-from-source
./result/bin/kwt version        # reports "dev" — this is not a release

nix build .#docbank-from-source
./result/bin/docbank version    # same

nix build .#agentsview-from-source
./result/bin/agentsview version # same

nix build .#msgvault-from-source
./result/bin/msgvault version    # same

nix build .#roborev-from-source
./result/bin/roborev version           # same
./result/bin/roborev verify-web-assets # upstream's own "not a stub" gate

nix build .#kata-from-source
./result/bin/kata version              # same
./result/bin/kata _web-assets-check    # kata's equivalent gate (hidden, like roborev's)
```

See ADR-0007 for the decision this graduates tools under (one at a time, kept
as a separate output surface from release binaries, host-platform only, no
CI). Six tools are wired up so far:

- **`kwt`** — no cgo dependencies, no embedded frontend. `buildGoModule`
  against a pinned Go 1.26.6 toolchain and a pinned rev, nothing else.
- **`docbank`** — `CGO_ENABLED=1` (mattn/go-sqlite3; no external sqlite header
  needed, unlike msgvault's `sqlite-vec-go-bindings`) plus an npm-built Svelte
  frontend embedded via `go:embed`, matching its `Makefile`'s `frontend` target
  exactly (empty `internal/web/dist` except the `.keep` stub, copy the built
  SPA in, then build). Three quirks worth knowing before touching this one:
  - `frontend/package-lock.json` pulls `@kenn-io/kit-ui` straight from a git
    commit rather than the npm registry. `fetchNpmDeps` refuses that by
    default (a git dependency with install scripts and no lockfile of its
    own) — needs `forceGitDeps = true`.
  - That same git fetch leaves root-owned files in the prefetched npm cache —
    the "unsandboxed builder as fake root" surprise this README already
    documents for kwt's config directory, recurring for a different reason.
    Needs `makeCacheWritable = true`.
  - The frontend's build tool is `vite-plus` (a Rust-implemented Vite,
    installed as an ordinary npm devDependency — not a fork, despite the
    name), which initialises an HTTP client unconditionally, even for a fully
    offline build, and panics with no CA bundle found. Nixpkgs' sandbox
    doesn't set one by default; point `SSL_CERT_FILE` at `cacert`'s.
- **`agentsview`** — same docbank shape (`CGO_ENABLED=1` + npm/Svelte
  frontend, same `@kenn-io/kit-ui`/`makeCacheWritable`/`vite-plus` quirks
  above) plus three more real ones:
  - Its cgo sqlite header must come from the **vendored** mattn/go-sqlite3
    module's own amalgamation header (`go mod download` it, then
    `go list -m -f '{{.Dir}}'` to find it), not a system `sqlite` package —
    upstream's own Makefile warns a system header would drift from what the
    pinned go-sqlite3 version ships, and restates `CGO_CFLAGS="-O2 -g ..."`
    explicitly because setting it at all overrides Go's own default,
    unoptimized otherwise.
  - `buildGoModule`'s own `go mod vendor` step disagrees with itself on
    agentsview's dependency graph ("explicitly required in go.mod, but not
    marked as explicit in vendor/modules.txt") — fixed the same way
    msgvault's own `nix/package.nix` fixes the identical error:
    `proxyVendor = true;`.
  - `make build` depends on a network fetch (a pinned, hash-verified LiteLLM
    pricing snapshot) with no place in a sandboxed build — fetched instead as
    its own `fetchurl` derivation and copied into place.
  - A quieter fourth issue, general to any tool with an embed/frontend-copy
    `preBuild`: `buildGoModule`'s internal vendor-fetch derivation inherits
    `preBuild` too, by default — harmless for docbank (its `preBuild` is just
    a directory copy) but fatal here, since `go list -m` can't resolve
    anything before that derivation has finished fetching. Needs
    `overrideModAttrs = _: { preBuild = ""; };` (docbank picked this up too,
    for correctness — it never needed the frontend copy to run there either).
- **`msgvault`** — the first **bun**-frontend tool, via a new `bun2nix`
  (`nix-community/bun2nix`) flake input — shared infrastructure for this,
  kata, and roborev, not a per-tool cost. Closely adapted from msgvault's own
  working `nix/package.nix` rather than reinvented, simplified in one way:
  its own flake repins an exact bun version to protect its OWN release
  cadence against bun2nix drift, which a single source-build entry here
  doesn't need — it uses bun2nix's stock nixpkgs-bun default instead. Unlike
  `npmDepsHash`, there's no separate "bun deps hash" to discover or commit:
  bun2nix reads a `web/bun.nix` file (bun2nix's own lockfile-equivalent)
  **already committed inside the fetched source tree**, whose per-package
  hashes are covered by the ordinary `srcHash` — so `msgvault` needs no extra
  `SOURCE_BUILD_TOOLS` field at all, same as `kwt`. Its cgo sqlite header
  comes from the plain system `sqlite` package (`buildInputs = [ sqlite ]`) —
  a different, equally valid choice than agentsview's vendored-header route,
  because it's what msgvault's own upstream author chose, not a rule to
  generalize from. The one real gotcha `overrideModAttrs` has to handle here
  is two-part, not one: filter `bun2nix.hook` out of the go-modules
  derivation's `nativeBuildInputs` (it has no business running there) *and*
  clear `preBuild` (the same leak agentsview hit).
- **`roborev`** — the first **workspace**-scope bun frontend, and the tool that
  broke the "reuse msgvault's recipe" assumption twice. Its Go side is the
  simplest of any tool here with a frontend (`modernc.org/sqlite` is pure Go: no cgo, no header, no
  `CGO_CFLAGS`) — everything hard here is the frontend, which is also why
  roborev's *own* upstream flake skips it and ships a stub-only binary.
  - **The lockfile is at the repo root**, covering `web/` and
    `packages/roborev-ui/` together (`workspaces: ["web", "packages/*"]`),
    not msgvault's self-contained `web/`. So `bunRoot` is left unset — the
    hook then installs at the source root and hoists everything into ONE
    top-level `node_modules`, which is why the vite invocation reaches *up*
    out of `web/` (`bun ../node_modules/vite/bin/vite.js build`). There is no
    `web/node_modules` for it to be found in, and the failure is a flat
    `Module not found "node_modules/vite/bin/vite.js"`.
  - **Upstream ships no `bun.nix`**, so unlike msgvault there is nothing in
    the fetched tree for `fetchBunDeps` to read. `bun2nix` has no in-sandbox
    mode that could generate one (it shells out to `nix flake prefetch` for
    any dependency whose hash isn't in the lockfile), so one is **generated
    and committed** here — `nix/kenn/bun/roborev.nix`, written by
    `update.py --source`. See below, and ADR-0007's 2026-08-20 amendment for
    why that is a pin and not a build step.
  - **`bun2nix` 2.1.2 mis-parses roborev's `@kenn-io/kit-ui` dependency**, and
    silently. It dispatches on a lockfile entry's *arity*: 3 means
    tarball/git/github, 4 means an npm registry package. Bun writes a
    `github:` dependency with four elements
    (`[ident, meta, cacheKey, integrity]`), so it goes down the npm path and
    comes out as a `fetchurl` of
    `https://registry.npmjs.org/@kenn-io/kit-ui/-/kit-ui-github:kenn-io/kit-ui#97be355.tgz`
    — a URL that does not exist. `update.py` drops the cache-key element
    before running bun2nix (`degrade_git_lock_entries`), which routes it to
    bun2nix's github branch and yields a real `fetchFromGitHub` named the way
    bun's own cache layout wants. Only generation sees the patched lockfile;
    the build uses upstream's own. Note msgvault does *not* hit this — its
    kit-ui dependency is spelled as a tarball URL, which is already arity 3.
    Same dependency, two spellings, one of them broken.
  - Its `installCheckPhase` does more than the other four's: `roborev
    verify-web-assets` is upstream's own release gate (it walks the embedded
    Vite manifest and rejects the compilation stub), so it answers "did the
    real frontend actually embed?" far better than grepping the binary.

- **`kata`** — roborev's shape verbatim on the frontend side: root `bun.lock`
  with `workspaces: ["web", "packages/*"]`, the same bun 1.3.14, no committed
  `bun.nix`, and the same `@kenn-io/kit-ui` at the same rev in the same
  arity-4 `github:` spelling needing the lockfile rewrite. Everything above
  about roborev applies unchanged — which is what five tools of accumulated
  quirks is supposed to buy. It added exactly one thing, and it is a real one:
  - **`CGO_ENABLED = 0` is required, not cosmetic.** kata is the first
    graduated tool with a cgo dependency that has to be *disabled* rather than
    satisfied. `asg017/sqlite-vec-go-bindings` is reachable from `cmd/kata`
    and `#include`s a `sqlite3.h` it does not ship, so `buildGoModule`'s
    inherited default of `CGO_ENABLED=1` fails the build outright
    (`fatal error: sqlite3.h: No such file or directory`) — after the frontend
    has already built, so it costs a full round to find. Upstream never hits
    it because `.goreleaser.yaml` sets `CGO_ENABLED=0` on all four kata build
    ids, selecting the pure-Go `modernc.org/sqlite` path. That is also why
    `go.mod` requiring `mattn/go-sqlite3` *and* `sqlite-vec` *and*
    `modernc.org/sqlite` is not the contradiction it looks like: **check the
    release config, not the module graph.** No build tags either — upstream
    sets none for kata, unlike docbank's, agentsview's and msgvault's `fts5`.
  - Its "not a stub" gate is `kata _web-assets-check`, the same
    `web.ValidateEmbeddedRelease()` call roborev's `verify-web-assets` makes.
    Both are `Hidden: true` upstream; only the underscore differs.

Only `forge` is left, and it is **no longer the highest-effort tool** — see
ADR-0007's effort table. Two claims that ranked it there turned out to be
wrong when checked (2026-08-20):

- **Its Rust component is out of scope.** The released `kenn-forge` neither
  bundles, fetches, nor requires `rust/pty-manager`:
  `cmd/kenn-forge/main.go` takes the path from
  `os.Getenv("KENN_FORGE_PTY_MANAGER")` (opt-in, empty by default, falling
  back to the pure-Go `internal/ptyowner`), `.github/workflows/release.yml`
  never invokes cargo, the `Makefile`'s `rust-pty-manager` target is wired
  into nothing, and the crate is `publish = false`. A source build should
  match what the release ships: no `buildRustPackage`.
- **Its "two independent frontends" are one bun workspace — and the release
  builds only one of them.** Root `bun.lock` and `workspaces: ["frontend",
  "packages/*"]` cover `frontend/` and `packages/github-app-ui/` together, so
  it is one generated `bun.nix` and one vendoring problem. But
  `release.yml` builds `frontend/` alone and copies it to `internal/web/dist`;
  `packages/github-app-ui` is never built, and its embed dir ships the
  committed `stub.html` that `internal/githubapp/ui/embed.go` documents
  ("holds only a committed stub until `make build` copies the real Vite output
  in", with `HasBuiltApp()` reporting on it). So the released binary's
  GitHub-App setup page IS a stub, and release parity means ONE build output,
  not two. This corrected a claim stated as fact here, in ADR-0007's effort
  table and in the working notes (2026-08-21) — the same "read the release
  config" lesson kata taught, applied one level down: it is the authority on
  what gets embedded, not just on cgo. It also has **two** arity-4 `github:`
  dependencies for `degrade_git_lock_entries` to fix, not one — `kit-ui` at
  roborev's and kata's rev, plus `kata-ui`, whose resolved lockfile key drops
  its scope (`kata@github:kenn-io/kata#c668572`).

Forge has **no `.goreleaser.yaml`** (it releases from a workflow, unlike kata
and roborev), so `CGO_ENABLED` and build tags come from there — read
2026-08-21: both build jobs set `CGO_ENABLED: "0"` and no job passes `-tags`
at all, and the release builds `./cmd/kenn-forge` only, not the `Makefile`'s
second `cmd/kenn-forge-github-app` binary. Its
frontend tooling is `vite-plus`, the same Rust-implemented Vite docbank and
agentsview needed `SSL_CERT_FILE` for — expect that CA-bundle panic here too,
the first time that quirk crosses into a bun tool.

All six are **maintained pins**, not point-in-time proofs:
`nix/kenn/source-builds.json` holds the committed `rev`/`srcHash`/`vendorHash`
(and the npm tools' `npmDepsHash`), `nix/kenn/bun/<tool>.nix` holds the
generated bun2nix expression for the tools that need one, and `update.py` (or
`devcontainer bump-kenn`) has a `--source` mode that writes both, kept separate
from the release commands above since a git ref has no meaning shared across
repos the way a release version resolves uniformly:

```sh
./update.py --source --tool kwt --rev main         # bump to a branch's HEAD
./update.py --source --tool docbank --rev abc123   # pin an explicit commit
./update.py --source --check --tool kwt --rev main # report drift only
./update.py --source --verify                      # rebuild every committed pin
```

One wrinkle when **graduating a new tool** that needs a generated `bun.nix`:
nix reads only *tracked* files out of a dirty git work tree, so the very first
run writes the file, finds git doesn't know about it, and stops with the
`git add` to run before rerunning. It leaves the file in place for exactly
that. Later bumps of an already-tracked file need no such step.

Unlike the release path, `--source` cannot be as hermetically checkable:
there is no published manifest for an arbitrary commit, so discovering a hash
means actually running `nix build` and reading the real hash back out of a
deliberate mismatch (`discover_source_hashes`/`harvest_hash_mismatches` in
`update.py`), and `--verify` re-runs that same build against the committed
hashes — a clean build **is** the verification, the same way `dev/bump-nix`'s
installer checksum has no fixture to check against either. What IS
hermetically guarded is the shape agreement between `SOURCE_BUILD_TOOLS`,
`source-build.nix`'s exposed attributes, `source-builds.json`'s keys and the
`inherit (sourceBuilds)` list in `flake.nix`'s `packages` output
(`tests/test-bump-kenn.sh` §6) — see ADR-0007's Decision 3/4 for the full
reasoning behind that split. Note the package attribute is named for the
tool's BINARY, not its repo, while every key above uses the repo: the two
differ only for `forge`, whose attribute is `kenn-forge-from-source`.

## Design notes

**Binaries, not source builds — for release-pinned packaging.** `kata` and
`forge` embed a bun-built frontend via `go:embed`, so building from source
means running the whole JS toolchain first. Two upstream repos already ship
flakes if you want source builds — `roborev` and `msgvault` — and
`numtide/llm-agents.nix` has a maintained source build of `agentsview`. Note
roborev's flake pins its own nixpkgs and overrides Go to exactly 1.26.6;
`inputs.nixpkgs.follows` will likely break it, and it **skips the frontend
entirely** (see the `roborev` bullet above), so what it builds is a stub-only
binary. (This is the decision ADR-0007
partially reverses: the flake now also supports building select tools from a
non-release revision, tool by tool — see "Building from source" above. It
does not change how release binaries are packaged.)

**Linkage is not uniform**, which is why `autoPatchelfHook` is here at all:

| | |
|---|---|
| static | `kata`, `kenn-forge`, `roborev`, `kwt` |
| dynamic (libc, libm) | `docbank` |
| dynamic + libstdc++/libgcc (cgo sqlite/duckdb) | `agentsview`, `msgvault` |

The hook runs on every Linux build and no-ops on the static ones (verified).
`kenn-forge` is static because of `modernc.org/sqlite`, the pure-Go driver —
no cgo. The `rust/pty-manager` crate in forge's repo is not in the released
binary at all (see "Building from source" above), so it was never a factor.

**`git` is wrapped in** for `kenn-forge`, `roborev` and `kwt`, the three that
unambiguously shell out to it. Via `--suffix`, so your own git takes precedence.

**Shell completions** are generated at build time from each binary's own
`completion bash|zsh|fish` and land under `$out/share`. All six free tools
support it; `kenn-forge` has no `completion` subcommand upstream, so it's
excluded. `devShells.default` exports `XDG_DATA_DIRS` to point at them, since
listing the package alone doesn't; consumers building their own devShell
around `kenn-io-toolkit-all` need the same one-line export.

## Verification status

Built and verified with Nix 2.20.6 on `x86_64-linux`:

- **All 7 packages build.** Each derivation's `installCheckPhase` runs
  `<binary> version`, so a successful build is proof the binary executes.
- **`msgvault` patched correctly** — interpreter rewritten to the Nix glibc,
  RPATH pointing at `gcc-lib` for `libstdc++`/`libgcc`.
- **`kata` left static and untouched** by the hook.
- **`kenn-forge` wrapper** emitted correctly with git appended to `PATH`.
- **The scoped unfree predicate works** — `kenn-forge` evaluates and builds
  with no `allowUnfree` from the caller.
- `update.py` tested in all modes (`--check` both stale and clean, `--verify`
  clean and against a tampered hash, `--tool`, `--pin` against an older tag);
  one hash re-verified by downloading and hashing the tarball, and the `kata`
  x86_64-linux hash independently matches the one in `shntnu/nixos-config`.
  `tests/test-bump-kenn.sh` re-runs the mode and quirk coverage hermetically
  against a canned upstream on every `tests/run-all`.

Also built: `kenn-io-toolkit` (6 binaries, no `kenn-forge`),
`kenn-io-toolkit-all` (all 7), and the `update` app — whose
`writeShellApplication` runs ShellCheck at build time.

**Not verified:** anything darwin. Those hashes are correct (they come from
upstream manifests) but the derivations are untested on macOS.

### One bug the unsandboxed builder hid

`kwt` initialises a config directory under `$HOME` before it will run *any*
subcommand. The build sandbox points `HOME` at `/homeless-shelter`, which is
deliberately unwritable, so `kwt version` in `installCheckPhase` died with
`mkdir /homeless-shelter: permission denied` on a normal Nix.

It passed here because the portable runner builds unsandboxed as a fake root,
so the `mkdir` **succeeded** — and in succeeding, created `/homeless-shelter`
with a `.config/kwt/config.toml` inside it. That poisoned every subsequent
non-fixed-output build in this environment with
`home directory '/homeless-shelter' exists`, which is why the toolkit joins
originally looked unbuildable. Same root cause, two symptoms.

Fixed by exporting a throwaway `HOME` in `installCheckPhase`. Only `kwt` needs
it — the other six run fine with an unwritable `HOME`, tested directly — but it
is applied uniformly since it costs nothing.

The lesson generalises: an unsandboxed builder is weaker evidence than a
sandboxed one, and this class of bug is not exhausted by one instance.
`nix flake check` on a normal Nix remains the authority.
