# Spike: Nix `fromImage` hybrid base for the default container

Goal: prove that bumping `claude-code` reships **only** claude-code's image
layer, while node/gh/just/sops/socat stay byte-identical — the layer reuse a
linear Dockerfile can't give (today, bumping `CLAUDE_CODE_VERSION` in the root
`Dockerfile` invalidates every layer after it, including the project system
layer).

This spike adds files under `spike/nix-default/` and leaves the real *image
build* untouched — the root `Dockerfile`, `docker-compose.yml`, and all project
overlays are unchanged. The one real-tool change is that `dev/bump-claude-code`
now also syncs the spike's version pin (see "Open decisions"), so the two pins
can't silently drift; it no-ops when the spike dir is absent.

## Layout

- `flake.nix` — `streamLayeredImage` on top of the MS devcontainer base
  (`fromImage`), layering the infra binaries. Output: `devcontainer-nix-base`.
- `pkgs/claude-code.nix` — claude-code fetched from npm. Note: 2.x is a native
  binary shipped in a per-platform package (`@anthropic-ai/claude-code-linux-x64`);
  this fetches that binary directly rather than wrapping node on a `cli.js`.
- `Dockerfile.nix-default` — the invariant tail of the root Dockerfile (UID
  remap, project `install-system.sh`, setup-* copies, `HOST_USER` symlink) over
  the Nix base.

## Fill in the remaining hash

Two of the three hashes are already filled from the current pins:

- `pkgs/claude-code.nix` `src.hash` — the linux-x64 tarball for `2.1.201`.
- `flake.nix` `imageDigest` — the `3.12-bookworm` manifest-list digest.

The last one, `flake.nix` `sha256` (the hash of Nix's flattened copy of the MS
base), can only be produced by Nix — leave it as the fakeHash sentinel and let
the first build print the real value:

```bash
nix build .#defaultBase
# fails with:  error: hash mismatch ... got: sha256-...
# paste that `got:` value into `sha256` in flake.nix, then rebuild.
```

Or precompute it (requires Nix on the builder; enable `nix-command flakes`):

```bash
nix run nixpkgs#nix-prefetch-docker -- \
  --image-name mcr.microsoft.com/devcontainers/python --image-tag 3.12-bookworm
```

Refreshing the pins after a version bump:

- **claude-code** — `dev/bump-claude-code` updates both the Dockerfile `ARG` and
  the spike's `version`, and resets the spike's `src.hash` to the fakeHash
  sentinel. Then run the `nix build` above to fill in the printed hash.
- **MS base digest** — pinned by digest, so an MS repush of `3.12-bookworm` does
  *not* change this build. Refresh only to adopt a newer base (or if the
  registry GCs the old untagged digest); re-derive with the
  `nix-prefetch-docker` / `imagetools inspect` commands above.

## Build & load

```bash
cd spike/nix-default
nix build .#defaultBase        # ./result is the streamer script
./result | docker load         # -> devcontainer-nix-base:latest
# or: nix run .#loadDefaultBase

# smoke test the packaged CLI (resolved via the image's PATH — the infra
# profile lives under /nix/store, not /bin, so the base's /bin stays intact)
docker run --rm devcontainer-nix-base:latest claude --version
```

## Measure the rebuild delta (the point of the spike)

```bash
nix build .#defaultBase && ./result | docker load
docker inspect --format '{{json .RootFS.Layers}}' devcontainer-nix-base:latest \
  > /tmp/layers.before

# bump `version` in pkgs/claude-code.nix + refresh src.hash, then:
nix build .#defaultBase && ./result | docker load
docker inspect --format '{{json .RootFS.Layers}}' devcontainer-nix-base:latest \
  > /tmp/layers.after

diff <(tr ',' '\n' < /tmp/layers.before) <(tr ',' '\n' < /tmp/layers.after)
# measured (2.1.201 -> 2.1.215): TWO layer digests differ
```

Two layers change, not one: the claude-code layer (~251 -> 265 MB, the point)
and the `devcontainer-infra` buildEnv profile (~210 KB), which necessarily
rehashes because it references claude-code by store path — that reference is the
mechanism (`config.Env` PATH) that pulls the closure into the image. The other
layers (node/gh/just/sops/socat + their closures/cacert + every MS base
layer) stay byte-identical, so the reship is the new claude-code blob plus a
~210 KB profile blob. Compare against a `CLAUDE_CODE_VERSION` bump on the root
`Dockerfile`, which invalidates every layer after it, including the project
system layer.

(If a literal single changed layer is ever wanted, drop the buildEnv and list
each package's `/bin` in `config.Env` PATH directly: that moves the claude
reference out of a layer and into the image config JSON — which changes on
every bump regardless — at the cost of a longer PATH. Not worth it for 210 KB.)

### What the layering actually buys (and what it doesn't)

Layering granularity does **not** speed up the local build. Nix is
content-addressed, so a claude-code bump re-realizes only the claude-code
derivation + the buildEnv + the streamer script; node/gh/... are
`/nix/store` cache hits. Layering happens *after* derivations are built — it only
decides how already-built store paths are grouped into tar blobs.

The payoff is **distribution**: on a re-push, layers with unchanged content keep
identical digests, so the registry (and every `docker pull`) skips them. With
one-path-per-layer, a bump reships only the ~265 MB claude-code blob + the
~210 KB profile; with claude-code lumped into a fat catch-all (what happens if
the `maxLayers` budget overflows — see `flake.nix`), that whole blob's digest
changes and every consumer re-pulls node/gh/... too.

So this matters when the base is **pushed once and pulled many times** (shared
team/CI base). If the image is only ever built and run locally, the granularity
is close to free insurance rather than a measurable win — nix's cache makes the
rebuild cheap and `docker load` dedups unchanged layers on local disk anyway.

## Optional: exercise the full default image

Runs the project `install-system.sh` and the setup-* / `HOST_USER` steps on top
of the Nix base — the equivalent of the root Dockerfile's tail:

```bash
docker build -f Dockerfile.nix-default \
  --build-context project=../../defaults \
  --build-arg USER_UID="$(id -u)" --build-arg USER_GID="$(id -g)" \
  ../../
```

## Optional: run the full devcontainer on the Nix base

`dev/devcontainer` has an opt-in that swaps the root Dockerfile for this base
via `compose.nix-base.yml` (appended after the project override so its
`build.dockerfile` wins). It builds+loads `devcontainer-nix-base:latest` first
(with `nix build .#defaultBase | docker load`) when the image is absent:

```bash
DEV_NIX_BASE=1 dev/devcontainer up
```

**Must run against a non-seed overlay.** An overlay that mounts a nix *seed
volume* (`:/nix`, e.g. the shipped `devcontainer` overlay) is incompatible: the
volume shadows the base's baked `/nix/store` and orphans the infra `PATH`
(`config.Env` points at `${infraEnv}/bin` under `/nix/store`). `dev/devcontainer`
refuses the combination — use e.g. the defaults overlay:

```bash
DEV_PROJECT_DIR="$PWD/defaults" DEV_NIX_BASE=1 dev/devcontainer up
```

This is the same two-strategies-are-exclusive tension as `init --nix` on the Nix
base: the seed volume and the baked base are alternative ways to deliver `/nix`,
not layers. Everything above `DEV_NIX_BASE` (build args, contexts, the
`Dockerfile.nix-default` tail) is unchanged; the flag only reroutes the base.

## Building on macOS / arm (assessment)

Two independent facts shape how a Mac (or any arm) user gets this base.

**1. The flake is `x86_64-linux`-only.** `system` is hardcoded and the claude-code
binary is fetched from the `-linux-x64` npm package. Multi-arch is mechanical but
not free: wrap outputs in a systems list (`aarch64-linux` + `x86_64-linux`), add
the `-linux-arm64` claude-code tarball + its `hash`, and re-pin the MS base
*per arch* — `pullImage` currently pins the amd64 sub-manifest (`arch = "amd64"`
plus a `sha256` of that flattened image); arm64 needs the arm64 sub-manifest
digest and its own `sha256`. Roughly a day of re-pinning.

**2. Nix cannot natively build a *Linux* image on macOS.** `nix build .#defaultBase`
emits a Linux image, but macOS Nix builds `*-darwin` by default; Linux
derivations need a **Linux builder**. Three routes:

- **nix-darwin `linux-builder`** — a NixOS VM as a remote `aarch64-linux` builder.
  The "official" answer, but requires running nix-darwin, a multi-GB VM, and
  per-machine setup.
- **Build inside Docker's existing Linux VM** *(recommended escape hatch)* —
  Docker Desktop already runs a Linux VM, so a `nixos/nix` container can do the
  build with no nix-darwin and no separate VM. Correctness risk is low (see the
  caveats below); it is *not* a one-liner.
- **Remote / CI builder** — not really "build for themselves."

### The docker-in-VM recipe and its caveats

```bash
# in Docker Desktop's Linux VM; nixstore is a persistent named volume for /nix
docker run --rm -v "$PWD:/work" -v nixstore:/nix nixos/nix \
  sh -c 'cd /work && nix build --option sandbox false \
           --extra-experimental-features "nix-command flakes" .#defaultBase \
         && ./result > /work/image.tar'
docker load < image.tar      # from the host CLI (same VM)
```

Caveats, in order of friction:

1. **No `docker load` inside the container** — no daemon/socket there. Build →
   write `./result > image.tar` to a bind mount → `docker load` from the host CLI.
   A two-step, not a single pipe.
2. **Sandbox must be off** — `--option sandbox false` (the same setting the
   devcontainer's nix.conf already carries); container builds fail without it.
3. **Cold `/nix` is a large first run** — a fresh container has an empty store and
   pulls the MS base + evaluates nixpkgs + builds the infra closure (GB-scale).
   Use a **persistent named volume for `/nix`** or every run re-downloads.
4. **Not independent of arch** — on Apple Silicon this only builds *natively* if
   the flake supports `aarch64-linux`; otherwise it builds `x86_64-linux` under
   QEMU (slow, occasionally flaky).

Verified along the way: the flake builds cleanly **from a bare non-git directory**,
so a plain Docker bind mount is fine — flake git-purity is a non-issue here.

### Verdict: build locally is a fallback; pull is the primary path

Local Mac build is *possible and low-risk* once the four caveats are scripted, but
it **rebuilds instead of pulls** — throwing away the dedup win that is the whole
point (see "What the layering actually buys") while keeping all the setup friction.
The high-value path is **CI builds a multi-arch base once and pushes it; every
machine `docker pull`s it** — and a claude-code bump then ships only the changed
layer, so consumers pull one blob, not the image.

This does **not** put CI in the inner dev loop, because **the base is expected to
change rarely.** It carries *shared infra only* (node/gh/socat/just/sops/claude-code)
— no project dependencies — so it only changes on a shared-infra event: a
claude-code bump (the most frequent, and the case layering optimizes) or adding a
new base tool. Neither is part of anyone's edit-run loop. Changing a project's
deps touches the local overlay (`Dockerfile.nix-default` + `install-system.sh`,
built on `up`) or the workspace (`uv sync`), never the base and never CI.

Because base changes are infrequent *and* shared, amortizing one CI build across
every consumer's `docker pull` is a clear win — and a claude-code bump ships only
the changed layer, so consumers pull one blob, not the image. And even for a base
change you are never *forced* onto CI: `ensure_nix_base()` can build it locally
(cheap on Linux via Nix's content-addressed cache). The CI-built image is a
convenience and the only sane arm/Mac path, not a gate on anyone's work.

## Open decisions this spike surfaces

- **`config` replaces the base config** — `streamLayeredImage`'s `config` does
  not merge the `fromImage` config, so the MS base's `Env` (notably the
  pyenv/py-utils/nvm `PATH`) is reproduced by hand in `flake.nix`. Re-derive it
  with `docker inspect` if MS changes the base.
- **UID remap** stays in `Dockerfile.nix-default` — don't bake it into the
  shared derivation (it would defeat layer sharing).
- **MS digest pin** insulates the build from upstream repushes (pinned by
  digest); refresh is a deliberate choice to adopt a newer base, not forced
  maintenance — see "Refreshing the pins" above.
- **Host Nix requirement** — building this needs Nix on the builder; for the
  lowest-barrier *default* path that's an accessibility regression to weigh
  before shipping (fine for a spike).
- **`nix` in the base — resolved: NOT shipped.** An earlier revision added
  `pkgs.nix` to the infra list so the baked base could run `nix` in-container;
  it was dropped (its closure — aws-sdk-cpp, aws-c-*, libgit2, boehm-gc, ... —
  grew the base 34 -> 73 store paths and forced `maxLayers` 64 -> 110). The
  deciding reason wasn't size: `streamLayeredImage` bakes `/nix/store`
  **root-owned**, so `nix profile install` as the `vscode` user hits
  permission-denied without an extra chown or a multi-user daemon — the CLI
  couldn't self-serve anyway. The seed-volume overlay (vscode-owned `/nix`)
  already provides sudo-free self-service; the baked base does not. If in-container
  `nix` is ever wanted here, it needs a store-ownership fix, not just the package.
- **arch** — x86_64 only here (the claude-code binary is fetched per-platform);
  wrap outputs in a systems list and select the matching platform package for
  arm64 parity. See "Building on macOS / arm" below for why this is really a
  *distribution* decision (publish a multi-arch base), not just a flake tweak.
- **node may be redundant** — claude-code 2.x is a native binary and no longer
  needs node. The spike keeps `nodejs_22` for parity with the current
  Dockerfile, but both could likely drop it if nothing else needs npm.
- **version-pin coupling** — `pkgs/claude-code.nix` duplicates the Dockerfile's
  `CLAUDE_CODE_VERSION`; `dev/bump-claude-code` keeps them in sync, and
  `tests/test-claude-code-pin-sync.sh` guards that the two committed files agree
  (so a hand edit that skips the bump tool fails CI). Folding the pin into a
  single shared source is tempting but a net loss: the tarball `hash` is
  version-coupled and must stay in `claude-code.nix`, so a bare version file
  would only separate the version from its own hash and strip the Dockerfile's
  self-contained default (a bare `docker build` would silently install `@latest`).
  The duplicate-plus-guard is the more defensible design.
