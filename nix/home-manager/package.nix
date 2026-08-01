{ lib
, stdenvNoCC
, makeWrapper
  # The repo source (passed as `self` from the flake). The WHOLE tree is
  # installed, not just dev/ + lib/: the entry scripts self-locate via
  # `readlink -f "$0"` and reach out to sibling paths (lib/, the two .py
  # helpers, nix/, Dockerfile, docker-compose.yml, defaults/, projects/,
  # templates/), so they must all travel together.
, src
  # Runtime closure placed on the tooling's PATH via a wrapper. These are the
  # host-facing tools the scripts shell out to.
, bash
, coreutils # GNU `readlink -f`, used pervasively for path resolution
, git
, gnugrep
, gnused
, gawk
, gnutar
, curl
, socat # optional SSH/GPG agent bridging
, util-linux # provides `flock`
, openssh # `ssh` for agent forwarding
, gh
, python3 # setup-claude.py / audit-report.py (stdlib only)
  # Deliberately NOT bundled, so they resolve from the user's own PATH and
  # match the host: docker + `docker compose`/`docker-compose`, and direnv.
  # Pin them via Nix instead by passing them in `extraRuntimeInputs`.
, extraRuntimeInputs ? [ ]
}:

let
  runtimeInputs = [
    bash
    coreutils
    git
    gnugrep
    gnused
    gawk
    gnutar
    curl
    socat
    util-linux
    openssh
    gh
    python3
  ] ++ extraRuntimeInputs;

  # User-facing commands that get a wrapped bin/ entry. `init` is intentionally
  # omitted (it is reached as `devcontainer init`, and a bare `init` on PATH is
  # too generic). The bump-* maintenance commands are also omitted: they do
  # in-place `sed -i` on the repo tree and cannot run against the read-only
  # store (see nix/home-manager/README.md).
  binCommands = [ "devcontainer" "new-worktree" "setup-worktree" "cleanup-worktree" ];
in
stdenvNoCC.mkDerivation {
  pname = "devcontainer-tooling";
  version = "0.1.0";

  inherit src;

  nativeBuildInputs = [ makeWrapper ];

  # Pure bash + stdlib Python; nothing to configure or compile.
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    tree=$out/share/devcontainer
    mkdir -p "$tree"
    cp -R ./. "$tree"/
    chmod -R u+w "$tree"

    # Make interpreters explicit and store-pure: rewrites `#!/usr/bin/env bash`
    # and the python3 shebangs to concrete store paths, so the scripts run off
    # a read-only store and on hosts without /usr/bin/env.
    patchShebangs "$tree/dev" "$tree/lib" "$tree"/*.py

    # Ship shell completions in the standard per-shell locations so that
    # nixpkgs / home-manager pick them up automatically from the profile — no
    # `devcontainer install-completions` step needed. Generated from the same
    # single source of truth (`devcontainer-completions <shell>`) the runtime
    # command uses, so the two can never drift.
    #
    # Unlike dev/install-completions, redirecting straight into the target is
    # safe here: $out is a fresh empty build output, so there is no installed
    # file to truncate, and a generator failure fails the derivation and
    # discards $out wholesale. Do not copy this shape back into the installer.
    gen="$tree/dev/devcontainer-completions"
    mkdir -p "$out/share/bash-completion/completions" \
             "$out/share/zsh/site-functions" \
             "$out/share/fish/vendor_completions.d"
    "$gen" bash > "$out/share/bash-completion/completions/devcontainer"
    "$gen" zsh  > "$out/share/zsh/site-functions/_devcontainer"
    "$gen" fish > "$out/share/fish/vendor_completions.d/devcontainer.fish"

    # Wrap each entry point so the host toolchain is on PATH. --argv0 pins $0
    # back to the real script in the store so the scripts' own
    # `readlink -f "$0"` + "../lib" self-location keeps resolving — a plain
    # wrapper would set $0 to the bin/ shim and break sibling sourcing.
    mkdir -p "$out/bin"
    for cmd in ${lib.concatStringsSep " " binCommands}; do
      makeWrapper "$tree/dev/$cmd" "$out/bin/$cmd" \
        --argv0 "$tree/dev/$cmd" \
        --prefix PATH : ${lib.makeBinPath runtimeInputs}
    done

    runHook postInstall
  '';

  meta = {
    description = "Host-side devcontainer + git-worktree tooling (devcontainer, new-worktree, setup-worktree, cleanup-worktree)";
    longDescription = ''
      Wraps the devcontainer infra repo's host-side bash/Python tooling for
      installation via Nix or home-manager. Docker and direnv are taken from
      the host PATH by default; override with `extraRuntimeInputs`.
    '';
    platforms = lib.platforms.linux;
    mainProgram = "devcontainer";
  };
}
