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

## Building from source (proof of concept)

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
```

See ADR-0007 for the decision this graduates tools under (one at a time, kept
as a separate output surface from release binaries, host-platform only, no
CI). Two tools are wired up so far, deliberately chosen to be as different in
shape as possible:

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

Extending this to the remaining five tools is still real, uneven work — see
the effort table in ADR-0007. In short: kata/forge/msgvault embed a **bun**
frontend instead of npm (msgvault's own `nix/package.nix` already solves this
with `nix-community/bun2nix`, a portable but separate vendoring axis), and
forge additionally carries a Rust component (`rust-pty-manager`) and *two*
independent frontends — the highest-effort tool of the seven, not yet audited
past "it exists and is wired into `make build`."

Both `rev`s are point-in-time pins with no update tooling and no drift guard
yet — `dev/bump-kenn` does not touch them, and nothing re-derives their
hashes when upstream moves. That's ADR-0007's Decision 3 (a `--tool <name>
--rev <ref>` mode in `update.py`, backed by a new `source-builds.json`) and
Decision 4 (the drift guard), both still unimplemented follow-up work.

## Design notes

**Binaries, not source builds — for release-pinned packaging.** `kata` and
`forge` embed a bun-built frontend via `go:embed`, so building from source
means running the whole JS toolchain first. Two upstream repos already ship
flakes if you want source builds — `roborev` and `msgvault` — and
`numtide/llm-agents.nix` has a maintained source build of `agentsview`. Note
roborev's flake pins its own nixpkgs and overrides Go to exactly 1.26.6;
`inputs.nixpkgs.follows` will likely break it. (This is the decision ADR-0007
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
`kenn-forge` being static despite forge carrying a Rust component is down to
`modernc.org/sqlite`, the pure-Go driver — no cgo.

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
