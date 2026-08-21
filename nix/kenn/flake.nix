{
  description = "kenn-io toolkit — kata, kenn-forge, roborev, msgvault, docbank, kwt, agentsview";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Only for source builds (ADR-0007): msgvault, kata, and roborev embed a
    # bun-built frontend, and this is the vendoring recipe msgvault's own
    # nix/package.nix already uses. Shared infrastructure for three tools, not
    # a per-tool cost — see nix/kenn/README.md's "Building from source".
    bun2nix.url = "github:nix-community/bun2nix/2.1.2";
    bun2nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      bun2nix,
    }:
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
        pkgs.callPackage ./source-build.nix {
          inherit buildGoModule;
          bun2nix = bun2nix.packages.${system}.default;
        };
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
          inherit (sourceBuilds)
            kwt-from-source
            docbank-from-source
            agentsview-from-source
            msgvault-from-source
            roborev-from-source
            kata-from-source
            kenn-forge-from-source
            ;
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

          # nix run .#bun2nix  — the bun2nix CLI at THIS flake's pinned
          # version. update.py --source runs it through here for the tools
          # upstream ships no bun.nix for (SOURCE_BUILD_BUN_NIX): bun.nix has
          # no schema stability guarantee across bun2nix versions, so the
          # generator and the bun2nix.hook that consumes its output must not be
          # able to drift apart. Exposed as an app rather than a package so it
          # stays out of `packages` (it is a build-time tool for this repo, not
          # one of the kenn-io tools this flake exists to ship).
          bun2nix = {
            type = "app";
            program = "${bun2nix.packages.${system}.default}/bin/bun2nix";
          };

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
