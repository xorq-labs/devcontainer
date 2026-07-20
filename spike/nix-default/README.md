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
~92 layers (node/gh/just/sops/socat/nix + their closures/cacert + every MS base
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
derivation + the buildEnv + the streamer script; node/gh/nix/... are
`/nix/store` cache hits. Layering happens *after* derivations are built — it only
decides how already-built store paths are grouped into tar blobs.

The payoff is **distribution**: on a re-push, layers with unchanged content keep
identical digests, so the registry (and every `docker pull`) skips them. With
one-path-per-layer, a bump reships only the ~265 MB claude-code blob + the
~210 KB profile; with claude-code lumped into a fat catch-all (what happens if
the `maxLayers` budget overflows — see `flake.nix`), that whole blob's digest
changes and every consumer re-pulls node/nix/aws-sdk/... too.

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
- **`nix` in the base** — the infra list includes `pkgs.nix` so the baked base
  can run `nix` in-container (not just be built by it). Its closure is large
  (aws-sdk-cpp, aws-c-*, libgit2, boehm-gc, ...): it grew the base from 34 -> 73
  store paths and forced `maxLayers` 64 -> 110 to keep claude-code in its own
  layer (~+50 MB image, still one changed blob per bump). Drop it if in-container
  `nix` isn't needed and the size/layer cost isn't worth it.
- **arch** — x86_64 only here (the claude-code binary is fetched per-platform);
  wrap outputs in a systems list and select the matching platform package for
  arm64 parity.
- **node may be redundant** — claude-code 2.x is a native binary and no longer
  needs node. The spike keeps `nodejs_22` for parity with the current
  Dockerfile, but both could likely drop it if nothing else needs npm.
- **version-pin coupling** — `pkgs/claude-code.nix` duplicates the Dockerfile's
  `CLAUDE_CODE_VERSION`; `dev/bump-claude-code` keeps them in sync. If the spike
  graduates, fold the pin into a single shared source instead.
