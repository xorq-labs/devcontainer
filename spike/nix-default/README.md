# Spike: Nix `fromImage` hybrid base for the default container

Goal: prove that bumping `claude-code` reships **only** claude-code's image
layer, while node/gh/just/sops/socat stay byte-identical — the layer reuse a
linear Dockerfile can't give (today, bumping `CLAUDE_CODE_VERSION` on line 57
of the root `Dockerfile` invalidates every layer after it, including the
project system layer).

This spike touches nothing in the real build path — the root `Dockerfile`,
`docker-compose.yml`, and all project overlays are untouched. It only adds
files under `spike/nix-default/`.

## Layout

- `flake.nix` — `streamLayeredImage` on top of the MS devcontainer base
  (`fromImage`), layering the infra binaries. Output: `devcontainer-nix-base`.
- `pkgs/claude-code.nix` — claude-code repackaged from its npm tarball.
- `Dockerfile.nix-default` — thin invariant layer (UID remap + script copies)
  over the Nix base.

## Fill in the three TODO hashes

Requires Nix on the builder (`nix --version`; enable `nix-command flakes`).

1. **claude-code tarball hash** — in `pkgs/claude-code.nix`:
   ```bash
   nix store prefetch-file \
     https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-2.1.201.tgz
   ```
   Paste the printed `sha256-...` into `src.hash`.

2. **MS base digest + hash** — in `flake.nix`:
   ```bash
   nix run nixpkgs#nix-prefetch-docker -- \
     --image-name mcr.microsoft.com/devcontainers/python --image-tag 3.12-bookworm
   ```
   Paste `imageDigest` (`sha256:...`) and `sha256`/`hash` into `pullImage`.

## Build & load

```bash
cd spike/nix-default
nix build .#defaultBase        # ./result is the streamer script
./result | docker load         # -> devcontainer-nix-base:latest
# or: nix run .#loadDefaultBase

# smoke test the packaged CLI
docker run --rm devcontainer-nix-base:latest /bin/claude --version
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

```bash
docker build -f Dockerfile.nix-default \
  --build-context project=../../defaults \
  --build-arg USER_UID="$(id -u)" --build-arg USER_GID="$(id -g)" \
  ../../
```

## Open decisions this spike surfaces

- **UID remap** stays in `Dockerfile.nix-default` — don't bake it into the
  shared derivation (it would defeat layer sharing).
- **MS digest pin** must be refreshed when MS repushes `3.12-bookworm`.
- **Host Nix requirement** — building this needs Nix on the builder; for the
  lowest-barrier *default* path that's an accessibility regression to weigh
  before shipping (fine for a spike).
- **arch** — x86_64 only here; wrap outputs in a systems list for arm64 parity.
- **claude-code packaging** — fetch-and-wrap assumes a self-bundled CLI; if a
  release adds unbundled deps / native postinstall, switch to `buildNpmPackage`.
