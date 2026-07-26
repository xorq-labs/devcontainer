{
  description = "Host-side devcontainer + git-worktree tooling, packaged for Nix / home-manager";

  # Pinned to the same channel as nix/base so the two flakes agree. Consumers
  # almost always point this at their own nixpkgs with `inputs.nixpkgs.follows`.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      # Linux-only by design (matches README:33): the scripts depend on GNU
      # coreutils (`readlink -f`) and talk to a host Docker daemon. Darwin is
      # feasible later — it needs GNU coreutils to shadow the BSD userland and
      # a Docker context on the host. See nix/home-manager/README.md.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        devcontainer-tooling = pkgs.callPackage ./nix/home-manager/package.nix {
          src = self;
        };
        default = devcontainer-tooling;
      });

      # For consumers who prefer an overlay to a bare package output.
      overlays.default = _final: prev: {
        devcontainer-tooling = prev.callPackage ./nix/home-manager/package.nix {
          src = self;
        };
      };

      # The home-manager entry point. Import this module and set
      # `programs.devcontainer-tooling.enable = true;`. The package default is
      # wired to this flake's build for the evaluating system, so no overlay is
      # required — but it stays overridable.
      homeManagerModules.default = { pkgs, lib, ... }: {
        imports = [ ./nix/home-manager/module.nix ];
        programs.devcontainer-tooling.package =
          lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      };

      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);
    };
}
