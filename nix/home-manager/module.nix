{ config, lib, pkgs, ... }:

let
  cfg = config.programs.devcontainer-tooling;

  # Apply extraRuntimeInputs by overriding the package's callPackage arg. Only
  # override when there is something to add, so a user-supplied package that
  # isn't `.override`-able still works with the default (empty) list.
  package =
    if cfg.extraRuntimeInputs == [ ]
    then cfg.package
    else cfg.package.override { extraRuntimeInputs = cfg.extraRuntimeInputs; };

  # dev/devcontainer-completions is the single source of truth for completion
  # output; generate each shell's script from the packaged copy at build time.
  completion = shell:
    pkgs.runCommand "devcontainer-completions-${shell}" { } ''
      ${package}/share/devcontainer/dev/devcontainer-completions ${shell} > "$out"
    '';
in
{
  options.programs.devcontainer-tooling = {
    enable = lib.mkEnableOption "host-side devcontainer + git-worktree tooling";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        The devcontainer-tooling package to install. Defaults to this flake's
        build for the evaluating system (wired up by homeManagerModules.default).
      '';
    };

    extraRuntimeInputs = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.docker-client pkgs.direnv ]";
      description = ''
        Extra packages placed on the tooling's PATH. Docker (incl.
        `docker compose`) and direnv are taken from your own PATH by default so
        they match the host; list them here to have Nix pin them instead.
      '';
    };

    enableBashIntegration = lib.mkEnableOption "devcontainer bash completions" // { default = true; };
    enableZshIntegration = lib.mkEnableOption "devcontainer zsh completions" // { default = true; };
    enableFishIntegration = lib.mkEnableOption "devcontainer fish completions" // { default = true; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ package ];

    # Install completions to each shell's canonical autoload dir — the same
    # locations `devcontainer install-completions` targets, but declaratively.
    xdg.dataFile."bash-completion/completions/devcontainer" =
      lib.mkIf cfg.enableBashIntegration { source = completion "bash"; };
    xdg.dataFile."zsh/site-functions/_devcontainer" =
      lib.mkIf cfg.enableZshIntegration { source = completion "zsh"; };
    xdg.configFile."fish/completions/devcontainer.fish" =
      lib.mkIf cfg.enableFishIntegration { source = completion "fish"; };
  };
}
