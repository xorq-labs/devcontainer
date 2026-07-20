{
  description = "Nix-layered default devcontainer base (fromImage hybrid)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      # The Linux arches the base is published for. CI builds each natively
      # (amd64 + arm64 runners) and assembles a multi-arch manifest; the
      # claude-code binary and the MS base image are fetched per-arch below,
      # everything else is arch-generic nixpkgs.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;

      # Per-arch pins for the MS devcontainer base. msBaseDigest is the
      # top-level manifest-LIST digest, shared by both arches — pullImage
      # selects the per-arch sub-manifest via os/arch. sha256 is the hash of
      # Nix's flattened copy of THAT arch's image, so it is pinned per arch;
      # only `nix build`/`nix-prefetch-docker` can produce it. Pinning by
      # digest makes the build reproducible: an MS repush of the 3.12-bookworm
      # tag does NOT affect this build. Refresh only to adopt a newer base
      # (security/toolchain updates), or in the rare case the registry
      # garbage-collects this now-untagged manifest. Re-derive per arch with:
      #   nix run nixpkgs#nix-prefetch-docker -- \
      #     --image-name mcr.microsoft.com/devcontainers/python \
      #     --image-tag 3.12-bookworm --os linux --arch <amd64|arm64>
      # (when repinning, drop --image-digest so the tag resolves fresh; keep
      # the printed imageDigest identical across both arches).
      msBaseDigest = "sha256:6ef67a2f0d2f054ad60990679e15208367ff10110a0c0be7f18dbaa7b7319d1d";
      msBase = {
        x86_64-linux = {
          arch = "amd64";
          sha256 = "sha256-0RSFzHuUFkt/89yxgyNivrOlrToXjLvYqkFIpAWukks=";
        };
        aarch64-linux = {
          arch = "arm64";
          sha256 = "sha256-DqUWh9SmvmCW+4lpTb9vPOzDySuYxhQxSMfpEvsEW1c=";
        };
      };

      # Everything below is instantiated once per system.
      outputsFor = system:
        let
          pkgs = import nixpkgs { inherit system; };

          claude-code = pkgs.callPackage ./pkgs/claude-code.nix { };

          # The infra binaries, expressed as nixpkgs derivations.
          # streamLayeredImage packs the whole runtime closure (these plus
          # their transitive deps) into one-store-path-per-layer, most-shared
          # first, up to maxLayers — so claude-code sits in its own layer and
          # a bump only changes that blob while gh/just/... stay byte-identical.
          infra = [
            # No node: claude-code 2.x is a native ELF binary (glibc-only,
            # verified via ldd + running it with node off PATH), so nothing in
            # this base needs a node runtime. The linear root Dockerfile still
            # ships node because it installs claude via `npm`; this base
            # fetches the binary directly.
            pkgs.gh
            pkgs.socat
            pkgs.just
            pkgs.sops
            claude-code
            pkgs.cacert # TLS roots so gh / claude can reach the network
          ];

          # One profile dir over the infra packages, referenced from
          # config.Env's PATH below — that reference pulls the whole runtime
          # closure into the image (the same mechanism the cacert
          # SSL_CERT_FILE reference uses) WITHOUT writing anything at the
          # image root. Passing these as `contents` instead would tar a real
          # bin/ directory that replaces the merged-usr Debian base's
          # /bin -> usr/bin symlink on apply, orphaning /bin/sh and breaking
          # every RUN and shebang in the image.
          infraEnv = pkgs.buildEnv {
            name = "devcontainer-infra";
            paths = infra;
          };

          # The Microsoft devcontainer base stays underneath: vscode user,
          # apt, python toolchain. Pull it as the fromImage base, selecting
          # this system's sub-manifest from the pinned manifest list.
          base = pkgs.dockerTools.pullImage {
            imageName = "mcr.microsoft.com/devcontainers/python";
            finalImageTag = "3.12-bookworm";
            imageDigest = msBaseDigest;
            sha256 = msBase.${system}.sha256;
            os = "linux";
            arch = msBase.${system}.arch;
          };
        in
        {
          packages = {
            inherit claude-code;

            defaultBase = pkgs.dockerTools.streamLayeredImage {
              name = "devcontainer-nix-base";
              tag = "latest";

              fromImage = base;
              # streamLayeredImage splits the runtime closure into up to
              # maxLayers-1 layers (one store path each, most-shared first)
              # plus a final catch-all. The fromImage's ~20 layers and the
              # customisation layer count against the cap. The infra closure
              # (gh/socat/just/sops + claude-code + cacert and their
              # transitive deps) is ~21 paths, so 64 keeps every path in its
              # own layer (well under Docker's ~127-layer ceiling) and a
              # claude-code bump still reships only its blob. If the budget
              # ever overflows, the tail gets lumped into one fat catch-all
              # with claude-code, defeating the per-layer dedup this base
              # exists for. No `contents`: the closure enters via the
              # infraEnv/cacert references in `config`.
              maxLayers = 64;

              # The one invariant imperative bit from the Dockerfile: the
              # credentials symlink into the credentials/ bind-mount. UID
              # remap and the setup-* script copies live in
              # Dockerfile.nix-default, because they can't (UID) or shouldn't
              # (per-project scripts) be baked into this shared,
              # content-addressed base.
              enableFakechroot = true;
              fakeRootCommands = ''
                mkdir -p home/vscode/.claude home/vscode/.cache home/vscode/.ssh
                ln -sf credentials/.credentials.json home/vscode/.claude/.credentials.json
                chmod 700 home/vscode/.ssh
                # Match the root Dockerfile's chown: fakeroot records these
                # paths as uid 0 otherwise, and the layer's home/vscode dir
                # entry would reset the base's vscode-owned home to root:root
                # on apply. Numeric ids — vscode is 1000:1000 in the MS base
                # and there's no passwd in this build environment. -R skips
                # the dangling credentials symlink; the -h line fixes the
                # link itself (as in the Dockerfile).
                chown -R 1000:1000 home/vscode
                chown -h 1000:1000 home/vscode/.claude/.credentials.json
              '';

              config = {
                # No User: the MS base's Config.User is root and the root
                # Dockerfile never sets USER either — Dockerfile.nix-default's
                # RUN steps (groupmod/apt/chown) must execute as root, and the
                # runtime user is applied by compose / devcontainer metadata,
                # not baked in. HOME matches the root Dockerfile's
                # `ENV HOME=/home/vscode`.
                WorkingDir = "/workspaces/src";
                # streamLayeredImage (nixpkgs >= 26.05) MERGES the fromImage
                # config into this one per-variable, with these entries
                # winning on conflict — the MS base's Env (LANG, PYTHON_*,
                # PIPX_*, NVM_*) flows through automatically and tracks a
                # digest repin without hand-copying. (Under 24.11 `config`
                # replaced the base config wholesale; the old full hand-copy
                # dates from then.)
                #
                # PATH is the one value that must stay hand-maintained: a
                # per-var merge picks a winner, it can't concatenate — and we
                # need the infra profile prepended (so gh/claude win) with the
                # base's own components kept verbatim behind it, or
                # python/pip/pipx fall off PATH. check-env-drift.sh guards
                # both this copy and the merge behavior itself in CI; re-derive
                # the base's PATH after a repin with:
                #   docker inspect --format '{{json .Config.Env}}' \
                #     mcr.microsoft.com/devcontainers/python@<msBaseDigest>
                Env = [
                  "HOME=/home/vscode"
                  "PATH=${infraEnv}/bin:/usr/local/python/current/bin:/usr/local/py-utils/bin:/usr/local/jupyter:/usr/local/share/nvm/current/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
                  "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                ];
                Cmd = [ "sleep" "infinity" ];
              };
            };
          };

          # Convenience: `nix run .#loadDefaultBase` streams straight into
          # docker. Uses the host's docker off PATH — no need to pull the
          # multi-hundred-MB pkgs.docker into the store just to call
          # `docker load`.
          apps.loadDefaultBase = {
            type = "app";
            program = toString (pkgs.writeShellScript "load-default-base" ''
              exec ${self.packages.${system}.defaultBase} | docker load
            '');
          };
        };
    in
    {
      packages = forAllSystems (system: (outputsFor system).packages);
      apps = forAllSystems (system: (outputsFor system).apps);
    };
}
