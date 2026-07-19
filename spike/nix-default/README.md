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
- **MS base digest** — changes whenever MS repushes `3.12-bookworm`; re-derive
  with the `nix-prefetch-docker` / `imagetools inspect` commands above.

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
# expect: exactly ONE layer digest differs
```

If the diff is a single line, the hypothesis holds. Compare against the cost of
a `CLAUDE_CODE_VERSION` bump on the current root `Dockerfile` (which rebuilds
the infra + project layers).

## Optional: exercise the full default image

Runs the project `install-system.sh` and the setup-* / `HOST_USER` steps on top
of the Nix base — the equivalent of the root Dockerfile's tail:

```bash
docker build -f Dockerfile.nix-default \
  --build-context project=../../defaults \
  --build-arg USER_UID="$(id -u)" --build-arg USER_GID="$(id -g)" \
  ../../
```

## Open decisions this spike surfaces

- **`config` replaces the base config** — `streamLayeredImage`'s `config` does
  not merge the `fromImage` config, so the MS base's `Env` (notably the
  pyenv/py-utils/nvm `PATH`) is reproduced by hand in `flake.nix`. Re-derive it
  with `docker inspect` if MS changes the base.
- **UID remap** stays in `Dockerfile.nix-default` — don't bake it into the
  shared derivation (it would defeat layer sharing).
- **MS digest pin** must be refreshed when MS repushes `3.12-bookworm`.
- **Host Nix requirement** — building this needs Nix on the builder; for the
  lowest-barrier *default* path that's an accessibility regression to weigh
  before shipping (fine for a spike).
- **arch** — x86_64 only here (the claude-code binary is fetched per-platform);
  wrap outputs in a systems list and select the matching platform package for
  arm64 parity.
- **node may be redundant** — claude-code 2.x is a native binary and no longer
  needs node. The spike keeps `nodejs_22` for parity with the current
  Dockerfile, but both could likely drop it if nothing else needs npm.
- **version-pin coupling** — `pkgs/claude-code.nix` duplicates the Dockerfile's
  `CLAUDE_CODE_VERSION`; `dev/bump-claude-code` keeps them in sync. If the spike
  graduates, fold the pin into a single shared source instead.
