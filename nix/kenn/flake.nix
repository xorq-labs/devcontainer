{
  description = "kenn-io toolkit — kata, kenn-forge, roborev, msgvault, docbank, kwt, agentsview";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f system);

      # kenn-forge is Elastic License 2.0, which nixpkgs marks free = false.
      # Scoping the predicate to this one package here means consumers of this
      # flake's `packages` output do not have to enable allowUnfree globally —
      # and nothing else slips through. Consumers of `overlays.default` build
      # against their own pkgs and will need their own predicate; see README.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: lib.getName pkg == "kenn-forge";
        };

      # callPackage wraps the returned attrset with makeOverridable, which adds
      # `override` and `overrideDerivation`. Those are not derivations, and
      # `nix flake show` / `nix flake check` choke on non-derivations under
      # `packages`, so strip them here rather than at every use site.
      toolsFor =
        system:
        lib.filterAttrs (_: lib.isDerivation) (
          (pkgsFor system).callPackage ./packages.nix { }
        );

      # Names of the individual tools, as they appear in sources.json.
      binaries = lib.mapAttrsToList (_: v: v.binary) (
        builtins.fromJSON (builtins.readFile ./sources.json)
      );

      # Building from a git revision instead of a release binary needs its own
      # Go toolchain (pinned to the exact patch every kenn-io go.mod requires,
      # same as kenn-io/roborev's and kenn-io/msgvault's own flakes do for
      # their source builds) rather than the fetchurl-only pkgsFor above.
      sourceBuildsFor =
        system:
        let
          pkgs = pkgsFor system;
          goPinned = pkgs.go_1_26.overrideAttrs (_: rec {
            version = "1.26.6";
            src = pkgs.fetchurl {
              url = "https://go.dev/dl/go${version}.src.tar.gz";
              hash = "sha256-oHIcVMaIkBRI13rZs+x+p8R0cwdV/4kTgukuy5P/LLE=";
            };
          });
          buildGoModule = pkgs.buildGoModule.override { go = goPinned; };
        in
        pkgs.callPackage ./source-build.nix { inherit buildGoModule; };
    in
    {
      packages = forAllSystems (
        system:
        let
          tools = toolsFor system;
          sourceBuilds = sourceBuildsFor system;
        in
        tools
        // {
          default = tools.kenn-io-toolkit;
          inherit (sourceBuilds) kwt-from-source docbank-from-source;
        }
      );

      # Individual tools only — the toolkit joins are flake-level conveniences
      # and would collide unhelpfully in a shared package set.
      overlays.default = final: _prev: lib.getAttrs binaries (
        final.callPackage ./packages.nix { }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          tools = toolsFor system;
          mkApp = name: {
            type = "app";
            program = lib.getExe tools.${name};
          };
        in
        lib.genAttrs binaries mkApp
        // {
          default = mkApp "kata";

          # nix run .#update  — regenerate sources.json from GitHub releases.
          # Deliberately runs the checkout's copy rather than a store copy:
          # update.py rewrites sources.json next to itself, and the store is
          # read-only.
          update = {
            type = "app";
            program = lib.getExe (
              pkgs.writeShellApplication {
                name = "update-kenn-sources";
                runtimeInputs = [
                  pkgs.python3
                  pkgs.gitMinimal
                ];
                text = ''
                  root="''${FLAKE_ROOT:-$PWD}"
                  if [ ! -f "$root/update.py" ]; then
                    echo "update.py not found under $root" >&2
                    echo "run this from the flake checkout, or set FLAKE_ROOT" >&2
                    exit 1
                  fi
                  exec python3 "$root/update.py" "$@"
                '';
              }
            );
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          tools = toolsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              tools.kenn-io-toolkit-all
              pkgs.python3 # for update.py
              pkgs.gitMinimal
            ];

            # packages.nix installs completions under $out/share; expose them
            # to the shell (packages alone doesn't).
            shellHook = ''
              export XDG_DATA_DIRS="${tools.kenn-io-toolkit-all}/share:''${XDG_DATA_DIRS:-}"
            '';
          };
        }
      );

      # `nix flake check` builds every tool for the current system, which also
      # exercises the `<tool> version` installCheck in each derivation.
      checks = forAllSystems (system: lib.getAttrs binaries (toolsFor system));

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
