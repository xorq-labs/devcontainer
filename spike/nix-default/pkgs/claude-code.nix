# Package the claude-code CLI from its published npm tarball.
#
# This mirrors the repo's existing "pin a version + pin a hash" model
# (see CLAUDE_CODE_VERSION in the root Dockerfile) rather than pulling in
# lockfile machinery. If a release ever ships unbundled runtime deps or a
# platform-specific postinstall (native ripgrep, etc.), switch to
# buildNpmPackage / importNpmLock and drop this fetch-and-wrap approach.
#
# Verify after building with:  claude --version
{ lib, stdenvNoCC, fetchurl, nodejs_22, makeWrapper }:

stdenvNoCC.mkDerivation rec {
  pname = "claude-code";
  version = "2.1.201"; # keep in sync with CLAUDE_CODE_VERSION in ../../../Dockerfile

  src = fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
    # TODO: nix store prefetch-file <url>   (prints the sha256-... hash)
    hash = "sha256-TODO=";
  };

  nativeBuildInputs = [ makeWrapper ];

  # The npm tarball unpacks to ./package/ (sourceRoot handled by stdenv).
  installPhase = ''
    runHook preInstall

    dest="$out/lib/node_modules/@anthropic-ai/claude-code"
    mkdir -p "$dest"
    cp -r ./* "$dest/"

    # Confirm the "bin" entry in the package's package.json before trusting
    # this — recent releases map `claude` -> cli.js.
    makeWrapper ${nodejs_22}/bin/node "$out/bin/claude" \
      --add-flags "$dest/cli.js"

    runHook postInstall
  '';

  meta = {
    description = "Anthropic Claude Code CLI (repackaged from npm)";
    mainProgram = "claude";
    platforms = lib.platforms.linux;
  };
}
