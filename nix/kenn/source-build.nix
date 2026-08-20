{
  lib,
  buildGoModule,
  fetchFromGitHub,
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
}
