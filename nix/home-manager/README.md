# Home-manager flake for the host-side tooling

This packages the repo's **host-side** commands — `devcontainer`,
`new-worktree`, `setup-worktree`, `cleanup-worktree` — as a Nix flake so they
can be installed declaratively, e.g. from a home-manager configuration. It is
unrelated to `nix/base/`, which builds the *container* base image.

## What it produces

- `packages.<system>.default` — the tooling as a single package. The whole repo
  tree is installed under `$out/share/devcontainer/` (the scripts self-locate
  and reach sibling paths), and wrapped entry points land in `$out/bin/`.
- `homeManagerModules.default` — a module exposing
  `programs.devcontainer-tooling.*`.
- `overlays.default` — the same package as an overlay.

## Use it from a home-manager flake

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    devcontainer.url = "github:xorq-labs/devcontainer";
    devcontainer.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, home-manager, devcontainer, ... }: {
    homeConfigurations."you" = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [
        devcontainer.homeManagerModules.default
        {
          programs.devcontainer-tooling.enable = true;

          # Optional: pin docker/direnv with Nix instead of the host PATH.
          # programs.devcontainer-tooling.extraRuntimeInputs =
          #   [ pkgs.docker-client pkgs.direnv ];
        }
      ];
    };
  };
}
```

Or, without the module, just add the package:

```nix
home.packages = [ devcontainer.packages.x86_64-linux.default ];
```

## Design decisions

- **Docker (and direnv) come from the host, not Nix.** The wrapper *prepends*
  a curated Nix closure (git, gh, coreutils, socat, flock, curl, sed/grep/awk,
  openssh, python3) but leaves your ambient PATH intact behind it, so the host's
  `docker` / `docker compose` — which must match the running daemon — win. Pin
  them with Nix via `extraRuntimeInputs` if you prefer.
- **Self-location is preserved.** Every entry script resolves its own directory
  with `readlink -f "$0"` and sources `../lib/*.sh`. The wrapper sets `--argv0`
  to the real script in the store so that resolution still points into
  `$out/share/devcontainer/`, rather than at the `bin/` shim.
- **Linux-only.** The scripts assume GNU coreutils and a host Docker daemon
  (README:33). Darwin support would need GNU `readlink -f` on PATH and a Docker
  context; not wired up yet.

## Caveats

- **`bump-claude-code` / `bump-nix` are not exposed.** They rewrite files in the
  repo tree with `sed -i` and can only run against a writable checkout, not the
  read-only Nix store. Run them from a clone when maintaining this repo.
- **`init` has no bare `bin/` entry.** Use `devcontainer init` (a bare `init` on
  PATH would be too generic).
- The Python helpers (`setup-claude.py`, `audit-report.py`) are standard-library
  only; `python3` is on the wrapped PATH and their shebangs are patched.
