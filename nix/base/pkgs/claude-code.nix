# Package the claude-code CLI from its published npm platform tarball.
#
# As of the 2.x line, `@anthropic-ai/claude-code` is a thin installer, not the
# CLI itself: the top-level package ships `install.cjs` (a postinstall) plus a
# set of per-platform `optionalDependencies`
# (`@anthropic-ai/claude-code-linux-x64`, `-linux-arm64`, `-darwin-arm64`,
# ...). The real CLI is a single prebuilt native binary inside the platform
# package, materialized by the postinstall at `npm install` time.
#
# So the old "grab the main tarball and wrap node against cli.js" approach is
# dead — the main tarball has no cli.js. We fetch the Linux platform package
# matching the host arch directly (the MS devcontainer base is Debian glibc
# on both arches).
#
# The binary is dynamically linked against the standard glibc loader plus
# libc/libm/librt/libpthread/libdl. We do NOT autoPatchelf it: it runs on top
# of the Debian `fromImage` base, which provides those libraries at their
# conventional paths. That is a deliberate coupling to the base image — this
# derivation is not meant to run on a bare Nix host.
#
# Verify after building with:  claude --version
{ lib, stdenvNoCC, fetchurl }:

let
  # Per-arch npm platform package. The tarball hashes are version-coupled:
  # `dev/bump-claude-code` bumps `version` and resets BOTH hashes to the
  # fakeHash sentinel; a `nix build` per arch then prints the real values.
  platform =
    {
      x86_64-linux = {
        npmArch = "x64";
        hash = "sha256-0WDTriyQy1Sn68mh1cKA5to37mzSYk5XAdxeTav70ok=";
      };
      aarch64-linux = {
        npmArch = "arm64";
        hash = "sha256-DItaVPMLCMSh+8P4hnnBXQuhCvDnUWhiq69MsUFPt6s=";
      };
    }.${stdenvNoCC.hostPlatform.system}
      or (throw "claude-code: unsupported system ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation rec {
  pname = "claude-code";
  # Keep in sync with CLAUDE_CODE_VERSION in ../../../Dockerfile.
  # `dev/bump-claude-code` updates both pins together (and resets the hashes).
  version = "2.1.215";

  # The platform package: a single prebuilt `claude` binary (~78 MB).
  src = fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code-linux-${platform.npmArch}/-/claude-code-linux-${platform.npmArch}-${version}.tgz";
    hash = platform.hash;
  };

  # The prebuilt binary keeps its Debian-base glibc interpreter; leave it alone.
  dontPatchELF = true;
  dontStrip = true;

  # The npm tarball unpacks to ./package/ (sourceRoot handled by stdenv).
  installPhase = ''
    runHook preInstall
    install -Dm755 claude "$out/bin/claude"
    runHook postInstall
  '';

  meta = {
    description = "Anthropic Claude Code CLI (prebuilt Linux binary from npm)";
    mainProgram = "claude";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
