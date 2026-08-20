{
  lib,
  buildGoModule,
  buildNpmPackage,
  fetchFromGitHub,
  cacert,
}:

# Proof of concept: build a kenn-io tool directly from a git revision instead
# of an upstream release binary. packages.nix's mkKennTool only ever fetches a
# tagged release asset — this is deliberately a SEPARATE, narrower path, not a
# mode bolted onto mkKennTool, because a source build is a different
# reproducibility contract (pinned to a commit + a Go module graph, not to a
# checksum-verified published artifact).
#
# Only kwt is wired up. It was picked because it is the cheapest of the seven
# tools to prove this on: no cgo dependencies (so no C cross-toolchain
# concerns) and no embedded frontend (so no bun/npm vendoring axis). Extending
# this pattern to the other six tools is real, uneven, additional work — see
# nix/kenn/README.md's "Building from source" section before assuming it
# generalizes for free. In particular kata/forge/msgvault embed a bun-built
# frontend, msgvault/docbank/agentsview build with CGO_ENABLED=1, and forge
# additionally carries a Rust component — none of that is exercised here.
let
  mkKennToolFromSource =
    {
      repo,
      binary,
      rev,
      srcHash,
      vendorHash,
      subPackage ? "cmd/${binary}",
      version ? rev,
    }:
    buildGoModule {
      pname = binary;
      inherit version vendorHash;

      src = fetchFromGitHub {
        owner = "kenn-io";
        inherit repo rev;
        hash = srcHash;
      };

      subPackages = [ subPackage ];

      # Matches the upstream release build: no ldflags-injected version string,
      # since "version" here is a commit, not a semver release.
      doCheck = false;

      # Same as mkKennTool's installCheckPhase in packages.nix: kwt needs a
      # writable $HOME to initialise its config directory before it will run
      # any subcommand, and the sandbox's $HOME is deliberately unwritable.
      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        export HOME="$(mktemp -d)"
        "$out/bin/${binary}" version
        runHook postInstallCheck
      '';

      meta = {
        description = "kenn-io/${repo}, built from ${rev} rather than a release binary";
        homepage = "https://github.com/kenn-io/${repo}";
        mainProgram = binary;
        sourceProvenance = [ lib.sourceTypes.fromSource ];
      };
    };
  # docbank: tool #2 (ADR-0007 decision 4), chosen specifically because it
  # exercises what kwt didn't — CGO_ENABLED=1 (mattn/go-sqlite3, no external
  # sqlite header needed, unlike msgvault's sqlite-vec) and an npm-built
  # Svelte frontend embedded via go:embed. The frontend also pulls
  # @kenn-io/kit-ui straight from a git commit (not the npm registry) in
  # frontend/package-lock.json — buildNpmPackage's fetchNpmDeps handles a
  # resolved git+https dependency fine, it just needs git reachable during
  # that fetch, which is worth remembering if this ever breaks.
  docbank-from-source =
    let
      rev = "11af138586a2a43b62a066e1619e4fa093196ec9";
      docbankSrc = fetchFromGitHub {
        owner = "kenn-io";
        repo = "docbank";
        inherit rev;
        hash = "sha256-sU7AIPQtUpzCn2d+Mr29Ha8DK+nIvNCvF5n61PfsPXw=";
      };
      frontend = buildNpmPackage {
        pname = "docbank-frontend";
        version = rev;
        src = "${docbankSrc}/frontend";
        npmDepsHash = "sha256-8XMNDjYcA2WUP4S2YP+TfjhI6pRRK+NqQ85jF06LvK0=";
        # frontend/package.json depends on @kenn-io/kit-ui straight from a git
        # commit rather than the npm registry. That has install scripts but no
        # lockfile of its own, which prefetch-npm-deps refuses by default.
        forceGitDeps = true;
        # The git-fetched kit-ui dependency leaves root-owned files in the
        # prefetched cache (the same "unsandboxed builder as fake root"
        # surprise documented in this flake's own README, for kwt's config
        # directory) — npm then refuses to write into it unless told the
        # cache is writable.
        makeCacheWritable = true;
        # "vp build" (vite-plus, a Rust-implemented Vite) initialises an HTTP
        # client unconditionally even for a fully offline build, and panics if
        # it can't find a CA bundle — nixpkgs' sandbox doesn't set one by
        # default. Point it at cacert's; nothing here should ever need it to
        # actually make a request.
        SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
        # "vp build" (vite-plus) — the frontend's own package.json aliases
        # vite to it. No install step: docbank's Makefile only ever runs
        # `npm ci && npm run build`, never `npm install`.
        npmBuildScript = "build";
        installPhase = ''
          runHook preInstall
          mkdir -p "$out"
          cp -R dist/. "$out/"
          runHook postInstall
        '';
      };
    in
    buildGoModule {
      pname = "docbank";
      version = rev;
      src = docbankSrc;

      vendorHash = "sha256-eBykw5tsfSQG6P81AExbqCZc2nwNu39n8kYdMC/LWNE=";

      subPackages = [ "cmd/docbank" ];
      tags = [ "fts5" ]; # SQLite FTS5, matches the upstream BUILD_TAGS
      env.CGO_ENABLED = 1; # mattn/go-sqlite3 links C; no cgo-free build exists
      doCheck = false;

      # Mirrors the Makefile's `frontend` target: empty internal/web/dist
      # (keeping the go:embed stub) and copy the built SPA in before `go build`
      # ever runs, so the binary embeds the real frontend, not the stub.
      preBuild = ''
        find internal/web/dist -mindepth 1 ! -name .keep -exec rm -rf {} +
        cp -R ${frontend}/. internal/web/dist/
      '';

      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        export HOME="$(mktemp -d)"
        "$out/bin/docbank" version
        runHook postInstallCheck
      '';

      meta = {
        description = "kenn-io/docbank, built from ${rev} rather than a release binary";
        homepage = "https://github.com/kenn-io/docbank";
        mainProgram = "docbank";
        sourceProvenance = [ lib.sourceTypes.fromSource ];
      };
    };
in
{
  inherit mkKennToolFromSource;

  kwt-from-source = mkKennToolFromSource {
    repo = "kwt";
    binary = "kwt";
    # HEAD of main at the time this was written — 41 commits ahead of the
    # v0.4.0 tag pinned in sources.json, i.e. genuinely a non-release state.
    rev = "7d8162f95f937b4936acba8ffa4913649b79fdfb";
    srcHash = "sha256-L8N+QU93uhkRZ+Zxkg8peIKVnXlKg2hiTXK2pV7Rl8Q=";
    vendorHash = "sha256-8WJCaEYuMKZkusoKJr0Yez06hgwu801Qnusi9L7AkK4=";
  };

  inherit docbank-from-source;
}
