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
./result/bin/kwt version    # reports "dev" — this is not a release
```

Only **`kwt`** is wired up, and it was picked deliberately: no cgo
dependencies (no C cross-toolchain to worry about) and no embedded frontend
(no bun/npm vendoring). It is the cheapest of the seven tools to prove the
mechanism on, not a template to mechanically repeat for the rest — extending
this to the other six is real, uneven work:

- **kata, forge, msgvault** embed a bun-built frontend. msgvault's own
  `nix/package.nix` already solved this with `nix-community/bun2nix`
  (a pinned bun binary plus a generated `web/bun.nix` lockfile-equivalent that
  needs regenerating on every `bun.lock` change) — that recipe is portable,
  but it's a second vendoring axis per tool, not a one-line addition.
- **msgvault, docbank, agentsview** build with `CGO_ENABLED=1` (mattn/go-sqlite3,
  duckdb-go, sqlite-vec-go-bindings all link C). Cross-compiling cgo in Nix,
  especially to darwin, is materially harder than the static `CGO_ENABLED=0`
  builds this flake already ships as release binaries.
- **docbank, agentsview** use plain npm instead of bun — less exotic
  (`buildNpmPackage`/`fetchNpmDeps` is native nixpkgs), but still a frontend
  build step to reproduce exactly.
- **forge** additionally carries a Rust component (`rust-pty-manager`) and
  *two* independent frontends (`frontend/`, `packages/github-app-ui/`) — the
  highest-effort tool of the seven, and not yet even audited past "it exists
  and is wired into `make build`."

`kwt-from-source`'s `rev` is a point-in-time pin (HEAD of `main` when this was
written, 41 commits past the `v0.4.0` tag in `sources.json`) with no update
tooling and no drift guard — `dev/bump-kenn` does not touch it, and nothing
re-derives its `vendorHash` when upstream moves. That's deliberate: this is a
proof that the mechanism works, not a maintained second pin. Wiring a real
`--tool kwt --rev <rev>` mode into `update.py`, and deciding whether the other
six tools are worth the vendoring cost above, is unstarted follow-up work.

## Design notes

**Binaries, not source builds.** `kata` and `forge` embed a bun-built frontend
via `go:embed`, so building from source means running the whole JS toolchain
first. Two upstream repos already ship flakes if you want source builds —
`roborev` and `msgvault` — and `numtide/llm-agents.nix` has a maintained
source build of `agentsview`. Note roborev's flake pins its own nixpkgs and
overrides Go to exactly 1.26.6; `inputs.nixpkgs.follows` will likely break it.

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
