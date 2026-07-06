{
  description = "Nix-layered default devcontainer base (fromImage hybrid spike)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }:
    let
      # x86_64 only for the spike; wrap in a systems list for arm64 parity later.
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      claude-code = pkgs.callPackage ./pkgs/claude-code.nix { };

      # The Dockerfile infra layer, expressed as nixpkgs derivations.
      # Each of these becomes its own content-addressed image layer, so a
      # claude-code bump only changes claude-code's layer blob.
      infra = [
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
        # TODO: get imageDigest + hash via:
        #   nix run nixpkgs#nix-prefetch-docker -- \
        #     --image-name mcr.microsoft.com/devcontainers/python --image-tag 3.12-bookworm
        # Note: this digest changes whenever MS repushes the 3.12-bookworm tag.
        imageDigest = "sha256:TODO";
        hash = "sha256-TODO=";
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
          maxLayers = 64; # room for each infra pkg to get its own layer
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
            Env = [
              "HOME=/home/vscode"
              # Nix-provided bins first, then the MS base's apt tools.
              "PATH=/bin:/usr/local/bin:/usr/bin"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
            Cmd = [ "sleep" "infinity" ];
          };
        };
      };

      # Convenience: `nix run .#loadDefaultBase` streams straight into docker.
      apps.${system}.loadDefaultBase = {
        type = "app";
        program = toString (pkgs.writeShellScript "load-default-base" ''
          exec ${self.packages.${system}.defaultBase} | ${pkgs.docker}/bin/docker load
        '');
      };
    };
}
