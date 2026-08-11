# Generic devcontainer Dockerfile.
# Project-specific edits live in the consumer's .devcontainer/ overlay.
# The "project" build context is injected via docker compose
# additional_contexts; standalone builds can override via --build-context.
ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/python:3.12-bookworm
FROM ${BASE_IMAGE}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG USER_UID=1000
ARG USER_GID=1000
ARG HOST_USER=
ARG DEV_CONTAINER_WORKSPACE
ARG EXTRA_PATH=

RUN if [ "$USER_GID" != "1000" ]; then groupmod -g $USER_GID vscode; fi \
    && if [ "$USER_UID" != "1000" ]; then usermod -u $USER_UID vscode; fi \
    && chown -R $USER_UID:$USER_GID /home/vscode

# Generic infrastructure: Node (for claude-code), gh, socat (SSH agent bridge)
# Node 22 LTS — EOL 2027-04-30
ARG NODE_MAJOR=22
ARG NODESOURCE_SHA256=575583bbac2fccc0b5edd0dbc03e222d9f9dc8d724da996d22754d6411104fd1
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x -o /tmp/nodesource.sh \
    && echo "$NODESOURCE_SHA256  /tmp/nodesource.sh" | sha256sum -c - \
    && bash /tmp/nodesource.sh \
    && rm /tmp/nodesource.sh \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        nodejs \
        gh \
        socat \
    && rm -rf /var/lib/apt/lists/*

# just (task runner)
ARG JUST_VERSION=1.40.0
ARG JUST_SHA256=181b91d0ceebe8a57723fb648ed2ce1a44d849438ce2e658339df4f8db5f1263
RUN curl -LsSf --retry 3 --retry-connrefused \
        https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz \
        -o /tmp/just.tar.gz \
    && echo "$JUST_SHA256  /tmp/just.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/just.tar.gz -C /usr/local/bin just \
    && rm /tmp/just.tar.gz

# sops (secrets management)
ARG SOPS_VERSION=3.9.4
ARG SOPS_SHA256=5488e32bc471de7982ad895dd054bbab3ab91c417a118426134551e9626e4e85
RUN curl -LsSf --retry 3 --retry-connrefused \
        https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64 \
        -o /usr/local/bin/sops \
    && echo "$SOPS_SHA256  /usr/local/bin/sops" | sha256sum -c - \
    && chmod +x /usr/local/bin/sops

ARG CLAUDE_CODE_VERSION=2.1.220
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Shared helpers an overlay can source. Copied before install-system runs so a
# build-time install-system.sh can source it too (e.g. nix-seed.sh). Inert for
# overlays that don't use it.
COPY lib/nix-seed.sh /usr/local/lib/devcontainer/nix-seed.sh

# Project-specific system packages and language toolchain.
COPY --from=project install-system.sh /tmp/install-system.sh
RUN bash /tmp/install-system.sh && rm /tmp/install-system.sh

COPY setup-claude.py /usr/local/bin/setup-claude
COPY audit-hook /usr/local/bin/audit-hook
COPY lib/git.sh /usr/local/lib/devcontainer/git.sh
COPY lib/claude-code-token-env.sh /usr/local/lib/devcontainer/claude-code-token-env.sh
COPY --from=project setup-env.sh /usr/local/bin/setup-env
# An ABSOLUTE mode, never `+x`. COPY preserves the source's mode, and setup-env.sh
# comes from a project overlay — a contributor's working tree, where the mode is
# whatever their umask made it. `chmod +x` only ADDS execute bits, so a 0700 source
# (umask 0077) lands as 0711: root-owned, so the owner bits no longer apply to
# vscode, and bash must READ an interpreted script to run it. The failure is
# `setup-env: Permission denied` at every container entry (#129).
RUN chmod 755 /usr/local/bin/setup-claude /usr/local/bin/audit-hook /usr/local/bin/setup-env

# Inject a claude-profile setup-token as CLAUDE_CODE_OAUTH_TOKEN for every claude
# entry point (docs/adr/0002-devcontainer-setup-token-env-delivery.md). Unlike an
# OAuth .credentials.json, a setup-token is read from the environment, so it must
# be injected per launch rather than seeded to disk. Source the snippet from both
# login shells (profile.d) and interactive non-login shells (/etc/bash.bashrc);
# the `devcontainer claude` wrapper sources it explicitly since `dc exec` gets
# neither. No-op when no token profile is active.
RUN printf '. /usr/local/lib/devcontainer/claude-code-token-env.sh\n' \
        > /etc/profile.d/claude-code-token.sh \
    && printf '\n# claude-profile setup-token injection (ADR-0002)\n. /usr/local/lib/devcontainer/claude-code-token-env.sh\n' \
        >> /etc/bash.bashrc

# No baked .credentials.json symlink: setup-claude seeds a private per-container
# token into the claude-home volume from the :ro host profile store
# (docs/adr/0001-devcontainer-private-token-isolation.md). Just create the dirs.
#
# .claude/projects is here for a second reason: compose mounts the transcript
# bind at .claude/projects/<key>, so the daemon creates the parent as root if
# the image does not ship it (#106). lib/volume-perms.sh repairs that after the
# fact, but only from setup(); shipping it here covers entry paths that never
# run dev/devcontainer at all. A FRESH claude-home volume seeds from this path
# — an existing one holding a root-owned projects/ still needs the walk, a
# clean or a reset.
RUN mkdir -p /home/vscode/.cache /home/vscode/.ssh /home/vscode/.claude/projects \
    && chown -R vscode:vscode /home/vscode/.cache /home/vscode/.ssh /home/vscode/.claude \
    && chmod 700 /home/vscode/.ssh

RUN HOST_USER="$(basename "$HOST_USER")" && \
    if [ -n "$HOST_USER" ] && [ "$HOST_USER" != "vscode" ]; then \
        ln -s /home/vscode "/home/$HOST_USER"; \
    fi

ENV PATH="${EXTRA_PATH}${EXTRA_PATH:+:}${PATH}"
ENV HOME=/home/vscode
