# The Nix devcontainer base

A multi-arch container base built with Nix (`dockerTools.streamLayeredImage`)
over the pinned Microsoft devcontainer Python image. It carries the shared
infra toolchain — gh, socat, just, sops, claude-code — one store path per
layer, so bumping one tool reships only that tool's layer. It is built by CI
once and pulled everywhere:

    ghcr.io/xorq-labs/devcontainer-nix-base

Non-seed project overlays build on it by default (see "Routing" below); the
classic root `Dockerfile` remains for overlays that drive their own Nix store
and as an explicit opt-out.

## Why: what the layering buys

Bumping `CLAUDE_CODE_VERSION` in the linear root `Dockerfile` invalidates
every layer after it — node reinstall, the project system layer, the setup
copies — and every machine rebuilds and re-downloads the world. On this base,
a claude-code bump changes exactly **2 of 42 layer digests** (measured): the
claude-code blob (212 MB compressed) and the ~210 KB buildEnv profile that
references it. Everything else — the 20 MS base layers, the 20 infra layers —
keeps byte-identical digests, so the registry and every `docker pull` skip
them.

Nix's content-addressed cache already makes local *rebuilds* cheap; the
layering granularity is a *distribution* optimization. It pays off because the
base is pushed once and pulled many times, and it only changes on shared-infra
events (a claude-code bump, a new base tool) — never in anyone's inner dev
loop. Project dependencies live in the overlay's `install-system.sh` (built
locally on `up`) or the workspace (`uv sync`), not here.

Costs, measured: the first pull on a machine transfers ~0.76 GB compressed
(2.0 GB on disk), roughly half of which is the MS base the classic path
downloads from mcr.microsoft.com anyway. It is cached once per machine; after
that a claude bump pulls one 212 MB layer.

## The two /nix delivery models and routing

There are two mutually exclusive ways a container gets `/nix`:

| | baked base (this directory) | seed volume (`lib/nix-seed.sh`) |
|---|---|---|
| store owner | root (read-only toolchain) | vscode (self-service) |
| delivered by | image layers, pulled from ghcr | durable `nix` volume, seeded at first run |
| for projects that | only **consume** the infra toolchain | **drive** Nix: own flake, `nix develop`, `nix build` |
| base image | `Dockerfile.nix-default` over this base | classic root `Dockerfile` |
| opt in via | default (no seed volume in the overlay) | `devcontainer init --nix` |

They are alternatives, not layers: a seed volume mounted over the baked base
would shadow `/nix/store` and orphan the infra `PATH` (`config.Env` points at
the profile under `/nix/store`).

`dev/devcontainer` routes automatically: an overlay whose
`compose.override.yml` mounts `:/nix` (short or long compose syntax) builds
on the classic `Dockerfile`, and so does one that overrides classic-only
build args (`BASE_IMAGE`, `NODE_MAJOR`, `CLAUDE_CODE_VERSION`,
`JUST_VERSION`, `SOPS_VERSION`, and their checksum companions) — this compose
file is appended last and would silently clobber them otherwise. Everything
else builds on this base. Escape hatches (`false`/`no`/`off` and
`true`/`yes`/`on` work too; anything else errors):

    DEV_NIX_BASE=0 dev/devcontainer up    # force the classic Dockerfile
    DEV_NIX_BASE=1 dev/devcontainer up    # force the Nix base (refuses seed overlays)

`devcontainer resolve` prints the routing and the reason as `BASE=...`.

**No node/npm/npx on this base.** claude-code 2.x is a native glibc binary
(verified via ldd and by running it with node off `PATH`), so the base ships
no node runtime. `npx`-based MCP servers or project tooling must install node
in the project overlay's `install-system.sh` — or run with `DEV_NIX_BASE=0`.
The classic Dockerfile still ships node because it installs claude via npm.

## Layout

- `flake.nix` — `streamLayeredImage` over the MS base (`fromImage`), one
  store path per layer, for `x86_64-linux` and `aarch64-linux`. The MS base
  is pinned by manifest-list digest (`msBaseDigest`, shared) with a per-arch
  `sha256` of Nix's flattened copy.
- `pkgs/claude-code.nix` — claude-code fetched as the prebuilt npm platform
  binary (`-linux-x64` / `-linux-arm64`), per-arch version-coupled hashes.
- `Dockerfile.nix-default` — the imperative tail over the base: UID remap,
  the project `install-system.sh` layer, setup-* copies, `HOST_USER` symlink,
  `EXTRA_PATH`. Mirrors the root Dockerfile's tail.
- `compose.nix-base.yml` — the compose override `dev/devcontainer` appends
  when routing selects this base. **Pins the published image digest** in its
  `BASE_IMAGE` default — the one consumers actually build on.
- `check-env-drift.sh` — verifies the built image keeps every Env entry the
  pinned MS base sets (PATH compared per component). Guards the
  hand-maintained PATH in `flake.nix` and the `fromImage` config merge; runs
  in CI on every base build.

## CI: build and publish

`.github/workflows/nix-base.yml` builds natively on amd64 + arm64 runners
(`ubuntu-latest`, `ubuntu-24.04-arm` — free for public repos): `nix build` →
`docker load` → smoke test → `check-env-drift.sh` → build the
`Dockerfile.nix-default` tail with the defaults overlay → push per-arch
`sha-<short>-{amd64,arm64}` tags → assemble a `sha-<short>` multi-arch
manifest. On `main` the manifest is also tagged `latest` and
`claude-<version>`. PRs build and verify without pushing.

The build is reproducible: independent CI runs from different commits produce
byte-identical layer and manifest digests, so the pinned digest is stable
across republishes of the same content.

**After a publish that should reach consumers**, copy the manifest digest
from the workflow's job summary into `compose.nix-base.yml`'s `BASE_IMAGE`
default. The pin is deliberate — an upstream retag never silently changes
what anyone builds on. `dev/devcontainer`'s staleness check picks the change
up and prompts a rebuild.

## Building locally (fallback)

Pull is the primary path; any Linux host with Nix can build instead:

    cd nix/base
    nix build .#defaultBase          # ./result is the streamer script
    ./result | docker load           # -> devcontainer-nix-base:latest
    DEV_NIX_BASE_IMAGE=devcontainer-nix-base:latest dev/devcontainer up

Caveat: a build under `sandbox = false` (e.g. inside a devcontainer) captures
a stray empty `/tmp` entry in the customisation layer, so its digest differs
from CI's for that one tiny layer. Harmless — the CI (sandboxed) digests are
canonical.

Building the *Linux* image on macOS requires a Linux builder and is not worth
it when the registry is reachable — pull instead. The full macOS build
assessment (nix-darwin builder vs. a `nixos/nix` container in Docker Desktop's
VM, with caveats) is preserved in the spike, PR #38.

## Refreshing the pins

**claude-code** (the common case):

    dev/bump-claude-code             # or: devcontainer bump-claude-code

updates the Dockerfile `ARG` and this flake's `version` together, and resets
both per-arch tarball hashes to the fakeHash sentinel; `nix build` per arch
prints the real hash to paste back (`nix store prefetch-file <tarball url>`
works too, without a build). The two pins stay deliberately duplicated — the
version-coupled hashes must live next to the version — and
`tests/test-claude-code-pin-sync.sh` fails CI if the committed files drift.

**MS base digest** — pinned, so an MS repush of `3.12-bookworm` changes
nothing here. To deliberately adopt a newer base, re-derive per arch:

    nix run nixpkgs#nix-prefetch-docker -- \
      --image-name mcr.microsoft.com/devcontainers/python \
      --image-tag 3.12-bookworm --os linux --arch <amd64|arm64>

Both arches must report the same `imageDigest` (→ `msBaseDigest`); each
reports its own `sha256`. After a repin, `check-env-drift.sh` fails the CI
build if the new base changed Env in a way the flake's hand-maintained PATH
doesn't reflect.

**nixpkgs input** — `nix flake update` after editing the input ref. Note that
`streamLayeredImage` (nixpkgs ≥ 26.05) merges the `fromImage` config
per-variable, which is why `flake.nix` only sets `PATH`/`HOME`/
`SSL_CERT_FILE`; the drift check guards that merge behavior too.

## Design decisions (settled — see PR #38 for the full record)

- **No `nix` CLI in this base.** `streamLayeredImage` bakes `/nix/store`
  root-owned, so an in-container `nix profile install` can't self-serve
  without a chown layer or a daemon. Projects that need Nix use the seed
  model, which is proven end-to-end. The base stays consume-only.
- **UID remap stays in `Dockerfile.nix-default`** — baking it into the shared
  derivation would defeat layer sharing.
- **Version pin duplication is intentional** — see "Refreshing the pins".
- **maxLayers = 64** keeps every store path in its own layer (~42 used). If
  the infra set grows past the budget, the overflow is lumped into one fat
  catch-all with claude-code, silently defeating the dedup — grow maxLayers
  with the closure.
