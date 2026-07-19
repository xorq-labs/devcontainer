{
  description = "Nix-layered default devcontainer base (fromImage hybrid spike)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }:
    let
      # x86_64 only for the spike; wrap in a systems list for arm64 parity later.
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      claude-code = pkgs.callPackage ./pkgs/claude-code.nix { };

      # The Dockerfile infra binaries, expressed as nixpkgs derivations.
      # streamLayeredImage packs the whole runtime closure (these plus their
      # transitive deps) into one-store-path-per-layer, most-shared first, up to
      # maxLayers — so claude-code sits in its own layer and a bump only changes
      # that blob while node/gh/... stay byte-identical.
      infra = [
        # node no longer backs claude-code (2.x ships a native binary), but the
        # real Dockerfile still installs it, so keep it here for parity.
        pkgs.nodejs_22
        pkgs.gh
        pkgs.socat
        pkgs.just
        pkgs.sops
        claude-code
        pkgs.cacert # TLS roots so gh / claude can reach the network
      ];

      # The Microsoft devcontainer base stays underneath: vscode user, apt,
      # python toolchain. Pull it as the fromImage base.
      base = pkgs.dockerTools.pullImage {
        imageName = "mcr.microsoft.com/devcontainers/python";
        finalImageTag = "3.12-bookworm";
        # imageDigest is the top-level manifest-list digest; pullImage selects the
        # amd64 sub-manifest via os/arch below. It changes whenever MS repushes
        # the 3.12-bookworm tag — re-derive with:
        #   nix run nixpkgs#nix-prefetch-docker -- \
        #     --image-name mcr.microsoft.com/devcontainers/python --image-tag 3.12-bookworm
        # (or `docker buildx imagetools inspect` for the digest alone).
        imageDigest = "sha256:6ef67a2f0d2f054ad60990679e15208367ff10110a0c0be7f18dbaa7b7319d1d";
        # This is the hash of Nix's flattened copy of the pulled image, so only
        # `nix build`/`nix-prefetch-docker` can produce it — can't be computed
        # with docker alone. Left as the fakeHash sentinel; the first build fails
        # and prints the real `got: sha256-...` to paste here.
        hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        os = "linux";
        arch = "amd64";
      };
    in
    {
      packages.${system} = {
        inherit claude-code;

        defaultBase = pkgs.dockerTools.streamLayeredImage {
          name = "devcontainer-nix-base";
          tag = "latest";

          fromImage = base;
          # streamLayeredImage splits the runtime closure into up to maxLayers-1
          # layers (one store path each, most-shared first) plus a final
          # catch-all; 64 leaves ample room for the infra closure to stay
          # one-path-per-layer so blobs dedupe cleanly across bumps.
          maxLayers = 64;
          contents = infra; # merged into the image root (/bin, /lib, ...)

          # The one invariant imperative bit from the Dockerfile: the
          # credentials symlink into the credentials/ bind-mount. UID remap
          # and the setup-* script copies live in Dockerfile.nix-default,
          # because they can't (UID) or shouldn't (per-project scripts) be
          # baked into this shared, content-addressed base.
          enableFakechroot = true;
          fakeRootCommands = ''
            mkdir -p home/vscode/.claude home/vscode/.cache home/vscode/.ssh
            ln -sf credentials/.credentials.json home/vscode/.claude/.credentials.json
            chmod 700 home/vscode/.ssh
          '';

          config = {
            User = "vscode";
            WorkingDir = "/workspaces/src";
            # streamLayeredImage's `config` REPLACES the fromImage config rather
            # than merging it, so anything the MS base set in Env must be
            # reproduced here or it's lost. Most load-bearing is PATH: the base
            # puts its pyenv/py-utils/nvm dirs on PATH, and dropping them breaks
            # `python`/`pip`. We prepend /bin (where the Nix contents land, so
            # node/gh/claude win) and keep the rest of the base's PATH verbatim.
            # Re-derive the base env if MS changes it:
            #   docker inspect --format '{{json .Config.Env}}' \
            #     mcr.microsoft.com/devcontainers/python:3.12-bookworm
            Env = [
              "HOME=/home/vscode"
              "PATH=/bin:/usr/local/python/current/bin:/usr/local/py-utils/bin:/usr/local/jupyter:/usr/local/share/nvm/current/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin"
              "LANG=C.UTF-8"
              "PYTHON_PATH=/usr/local/python/current"
              "PIPX_HOME=/usr/local/py-utils"
              "PIPX_BIN_DIR=/usr/local/py-utils/bin"
              "NVM_DIR=/usr/local/share/nvm"
              "NVM_SYMLINK_CURRENT=true"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
            Cmd = [ "sleep" "infinity" ];
          };
        };
      };

      # Convenience: `nix run .#loadDefaultBase` streams straight into docker.
      # Uses the host's docker off PATH — no need to pull the multi-hundred-MB
      # pkgs.docker into the store just to call `docker load`.
      apps.${system}.loadDefaultBase = {
        type = "app";
        program = toString (pkgs.writeShellScript "load-default-base" ''
          exec ${self.packages.${system}.defaultBase} | docker load
        '');
      };
    };
}
