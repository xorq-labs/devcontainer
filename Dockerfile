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

ARG CLAUDE_CODE_VERSION=2.1.201
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Project-specific system packages and language toolchain.
COPY --from=project install-system.sh /tmp/install-system.sh
RUN bash /tmp/install-system.sh && rm /tmp/install-system.sh

COPY setup-claude.py /usr/local/bin/setup-claude
COPY audit-hook /usr/local/bin/audit-hook
COPY lib/git.sh /usr/local/lib/devcontainer/git.sh
COPY --from=project setup-env.sh /usr/local/bin/setup-env
RUN chmod +x /usr/local/bin/setup-claude /usr/local/bin/audit-hook /usr/local/bin/setup-env

# /home/vscode/.claude/.credentials.json is created here as a symlink into
# the credentials/ bind-mount (declared in compose.yml). Image-baked so it
# lands in the per-worktree claude-home named volume on first init; the
# host-side migration in lib/host-bridge.sh handles the legacy file move.
RUN mkdir -p /home/vscode/.cache /home/vscode/.ssh /home/vscode/.claude \
    && ln -s credentials/.credentials.json /home/vscode/.claude/.credentials.json \
    && chown -R vscode:vscode /home/vscode/.cache /home/vscode/.ssh /home/vscode/.claude \
    && chown -h vscode:vscode /home/vscode/.claude/.credentials.json \
    && chmod 700 /home/vscode/.ssh

RUN HOST_USER="$(basename "$HOST_USER")" && \
    if [ -n "$HOST_USER" ] && [ "$HOST_USER" != "vscode" ]; then \
        ln -s /home/vscode "/home/$HOST_USER"; \
    fi

ENV PATH="${EXTRA_PATH}${EXTRA_PATH:+:}${PATH}"
ENV HOME=/home/vscode
