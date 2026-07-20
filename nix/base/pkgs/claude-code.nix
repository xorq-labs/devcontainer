# Package the claude-code CLI from its published npm platform tarball.
#
# As of the 2.x line, `@anthropic-ai/claude-code` is a thin installer, not the
# CLI itself: the top-level package ships `install.cjs` (a postinstall) plus a
# set of per-platform `optionalDependencies`
# (`@anthropic-ai/claude-code-linux-x64`, `-darwin-arm64`, ...). The real CLI is
# a single prebuilt native binary inside the platform package, materialized by
# the postinstall at `npm install` time.
#
# So the old "grab the main tarball and wrap node against cli.js" approach is
# dead — the main tarball has no cli.js. We fetch the linux-x64 platform package
# directly, which matches the x86_64 glibc target (the MS devcontainer
# base is Debian).
#
# The binary is dynamically linked against the standard glibc loader
# (/lib64/ld-linux-x86-64.so.2 + libc/libm/librt/libpthread/libdl). We do NOT
# autoPatchelf it: it runs on top of the Debian `fromImage` base, which provides
# those libraries at their conventional paths. That is a deliberate coupling to
# the base image — this derivation is not meant to run on a bare Nix host.
#
# Verify after building with:  claude --version
{ lib, stdenvNoCC, fetchurl }:

stdenvNoCC.mkDerivation rec {
  pname = "claude-code";
  # Keep in sync with CLAUDE_CODE_VERSION in ../../../Dockerfile.
  # `dev/bump-claude-code` updates both pins together (and resets src.hash).
  version = "2.1.215";

  # The linux-x64 platform package: a single prebuilt `claude` binary (~78 MB).
  src = fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-${version}.tgz";
    hash = "sha256-0WDTriyQy1Sn68mh1cKA5to37mzSYk5XAdxeTav70ok=";
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
    description = "Anthropic Claude Code CLI (prebuilt linux-x64 binary from npm)";
    mainProgram = "claude";
    platforms = [ "x86_64-linux" ];
  };
}
