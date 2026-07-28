# shellcheck shell=sh
# Select a claude-profile setup-token and inject it as CLAUDE_CODE_OAUTH_TOKEN
# for `claude` launches inside the container
# (docs/adr/0002-devcontainer-setup-token-env-delivery.md).
#
# A setup-token is consumed from the ENVIRONMENT, not a file — unlike the OAuth
# `.credentials.json` a container seeds, which any launch reads off disk. So this
# snippet is sourced from every claude entry point that does NOT inherit a
# pre-set environment: login shells (/etc/profile.d), interactive non-login
# shells (/etc/bash.bashrc), and the `devcontainer claude` wrapper (which execs
# via `dc exec` and therefore sources neither). Sourcing it when no token profile
# is active is a harmless no-op — the OAuth file path is used instead.
#
# `setup-claude token-path` resolves the active token file (an explicit
# set-token override first, else the read-only host profile store); reading the
# value here (rather than baking it) keeps the raw bearer out of image metadata
# and lets a host-side delete take effect on the next shell.
#
# When a token IS selected we also neutralize every source that outranks
# CLAUDE_CODE_OAUTH_TOKEN in claude's precedence order — otherwise an ambient one
# (common in containers/CI: a baked ANTHROPIC_API_KEY, an enterprise
# Bedrock/Vertex toggle, a base-URL redirect) would SILENTLY win and route
# traffic down an unintended, possibly API-billed path with no error. Only the
# ANTHROPIC_API_KEY > ANTHROPIC_AUTH_TOKEN > CLAUDE_CODE_OAUTH_TOKEN order is
# empirically pinned (claude v2.1.215); the cloud/base-url tiers are docs-only
# and cleared defensively — RE-VERIFY this list on every claude upgrade.
#
# apiKeyHelper (a settings.json hook that also outranks the token) is handled
# out of band: setup-claude rebuilds the container settings.json from scratch and
# never copies it over, so there is nothing to strip here.

__cc_tok="$(setup-claude token-path 2>/dev/null)" || __cc_tok=""
if [ -n "$__cc_tok" ] && [ -r "$__cc_tok" ]; then
  CLAUDE_CODE_OAUTH_TOKEN="$(cat "$__cc_tok")"
  export CLAUDE_CODE_OAUTH_TOKEN
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
    CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX
fi
unset __cc_tok
