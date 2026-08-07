# shellcheck shell=bash
# Host-to-container bridge functions: SSH agent forwarding, GPG agent
# forwarding, host git config, gh credentials, and Claude config setup.
#
# Sourced by dev/devcontainer. The sourcer is expected to provide:
#   - dc(...)         — `docker compose ... -p $DEV_CONTAINER_NAME` wrapper
#   - dc_exec(...)    — `dc exec` with the standard env vars
#   - is_running()    — boolean check that the app service is up
# and to set (script-locals are fine — this lib is sourced, not exec'd):
#   - DEV_CONTAINER_NAME       — used to derive per-container forward ports
#   - DEV_CONTAINER_WORKSPACE  — passed through to setup-claude
#   - DEV_WORKSPACE            — host path of the workspace, used as project key
#   - DEV_HAS_SOCAT            — set to "true" if socat is on PATH

DEV_SSH_FORWARD_PIDFILE="/tmp/devcontainer-ssh-forward-${DEV_CONTAINER_NAME}.pid"

ssh_forward_port() {
    local hash
    hash="$(echo "$DEV_CONTAINER_NAME" | cksum | cut -d' ' -f1)"
    echo $(( (hash % 8192) + 49152 ))
}

stop_ssh_forward() {
    if [ -f "$DEV_SSH_FORWARD_PIDFILE" ]; then
        local pid
        pid="$(cat "$DEV_SSH_FORWARD_PIDFILE")"
        kill "$pid" 2>/dev/null || true
        rm -f "$DEV_SSH_FORWARD_PIDFILE"
    fi
    # Catch orphans whose PID file was lost (tmpfiles cleanup, manual rm, etc.)
    # Pattern includes the full socat arg structure to avoid killing unrelated
    # socat processes that happen to use the same port.
    local port
    port="$(ssh_forward_port)"
    pkill -f "socat TCP-LISTEN:${port},bind=.+,reuseaddr,fork UNIX-CONNECT:" 2>/dev/null || true
    if is_running; then
        dc_exec bash -c 'pkill -f "socat UNIX-LISTEN:/run/ssh-agent/" 2>/dev/null' || true
    fi
}

setup_ssh_forward() {
    if [ "${DEV_HAS_SOCAT:-false}" != "true" ]; then
        echo "warning: socat not found on host — SSH agent forwarding disabled (apt install socat)" >&2
        return 0
    fi
    if [ ! -S "${SSH_AUTH_SOCK:-}" ]; then
        echo "warning: no SSH agent detected — git over SSH won't work inside the container" >&2
        return 0
    fi

    stop_ssh_forward

    local port
    port="$(ssh_forward_port)"

    # host.docker.internal inside the container reaches this host, but the
    # address socat must bind to depends on the Docker runtime:
    #   Linux-native:  host-gateway == bridge gateway (a real host IP)
    #   Docker Desktop: host.docker.internal routes to host loopback
    #   WSL2 + Desktop: same as Docker Desktop (bridge IP is VM-internal)
    local bind_addr
    if [ "$(uname -s)" = "Linux" ] && ! grep -qiF microsoft /proc/version 2>/dev/null; then
        bind_addr="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)" || true
        if [ -z "$bind_addr" ]; then
            echo "error: could not determine Docker bridge gateway IP — is the bridge network enabled?" >&2
            return 1
        fi
    else
        bind_addr="127.0.0.1"
    fi

    socat "TCP-LISTEN:${port},bind=${bind_addr},reuseaddr,fork" \
          "UNIX-CONNECT:${SSH_AUTH_SOCK}" &
    local host_pid=$!
    echo "$host_pid" > "$DEV_SSH_FORWARD_PIDFILE"

    # Wait briefly for socat to fail-fast on bad args (e.g. port in use); if
    # it's still alive after the window, treat it as healthy. Bounded retry
    # instead of a fixed sleep — flaky on slow hosts.
    for _ in $(seq 1 50); do
        sleep 0.05
        kill -0 "$host_pid" 2>/dev/null || break
    done
    if ! kill -0 "$host_pid" 2>/dev/null; then
        echo "error: host-side SSH forwarder failed to start (port $port may be in use)" >&2
        rm -f "$DEV_SSH_FORWARD_PIDFILE"
        return 1
    fi

    # -d (detached) is required: backgrounding via `bash -c "... &"` doesn't
    # survive the exec session teardown — Docker SIGTERMs the process tree
    # when the exec call returns, killing socat despite nohup.
    dc exec -d app socat \
        UNIX-LISTEN:/run/ssh-agent/agent.sock,fork,unlink-early,mode=600 \
        TCP:host.docker.internal:${port}

    # Two-phase readiness check: wait for the socket to appear (socat has
    # bound), then verify the end-to-end agent path with ssh-add.
    for _ in $(seq 1 50); do
        if dc_exec test -S /run/ssh-agent/agent.sock 2>/dev/null; then
            break
        fi
        sleep 0.05
    done

    for _ in $(seq 1 10); do
        if dc_exec ssh-add -l >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    echo "error: SSH agent bridge started but ssh-add -l never succeeded inside the container" >&2
    return 1
}

## GPG agent forwarding ######################################################

DEV_GPG_FORWARD_PIDFILE="/tmp/devcontainer-gpg-forward-${DEV_CONTAINER_NAME}.pid"

gpg_forward_port() {
    local hash
    hash="$(echo "$DEV_CONTAINER_NAME" | cksum | cut -d' ' -f1)"
    echo $(( (hash % 8192) + 57344 ))
}

stop_gpg_forward() {
    if [ -f "$DEV_GPG_FORWARD_PIDFILE" ]; then
        local pid
        pid="$(cat "$DEV_GPG_FORWARD_PIDFILE")"
        kill "$pid" 2>/dev/null || true
        rm -f "$DEV_GPG_FORWARD_PIDFILE"
    fi
    local port
    port="$(gpg_forward_port)"
    pkill -f "socat TCP-LISTEN:${port},bind=.+,reuseaddr,fork UNIX-CONNECT:" 2>/dev/null || true
    if is_running; then
        dc_exec bash -c 'pkill -f "socat UNIX-LISTEN:/run/gpg-agent/" 2>/dev/null' || true
    fi
}

setup_gpg_forward() {
    if [ "${DEV_HAS_SOCAT:-false}" != "true" ]; then
        echo "warning: socat not found on host — GPG agent forwarding disabled (apt install socat)" >&2
        return 0
    fi

    # Use the standard socket so the forwarded agent honors the host's
    # passphrase cache.  The extra socket forces restricted mode, which
    # re-prompts via pinentry on every private-key op regardless of cache.
    local host_gpg_socket
    host_gpg_socket="$(gpgconf --list-dirs agent-socket 2>/dev/null)" || true
    if [ -z "$host_gpg_socket" ] || [ ! -S "$host_gpg_socket" ]; then
        echo "warning: no GPG agent socket detected — SOPS PGP decryption won't work inside the container" >&2
        echo "  (ensure gpg-agent is running: gpgconf --launch gpg-agent)" >&2
        return 0
    fi

    # Warm gpg-agent's internal passphrase cache. The extra socket used for
    # forwarding passes --no-allow-external-cache to pinentry, so the
    # passphrase must be in gpg-agent's own cache — an external keyring
    # (GNOME Keyring, macOS Keychain, etc.) won't be consulted.
    #
    # Two operations are needed: a sign (caches the signing key) and an
    # encrypt-to-self + decrypt (caches the encryption subkey). SOPS
    # uses decryption, so skipping the second leaves the container unable
    # to decrypt secrets.
    if ! echo | gpg -so /dev/null 2>/dev/null; then
        echo "note: could not pre-cache GPG signing passphrase — you may be prompted inside the container" >&2
    fi
    local default_key
    default_key="$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec/{print $5; exit}')"
    if [ -n "$default_key" ]; then
        if ! echo "warmup" | gpg -e -r "$default_key" 2>/dev/null | gpg -d >/dev/null 2>&1; then
            echo "note: could not pre-cache GPG decryption passphrase — SOPS may prompt inside the container" >&2
        fi
    fi

    stop_gpg_forward

    local port
    port="$(gpg_forward_port)"

    local bind_addr
    if [ "$(uname -s)" = "Linux" ] && ! grep -qiF microsoft /proc/version 2>/dev/null; then
        bind_addr="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)" || true
        if [ -z "$bind_addr" ]; then
            echo "error: could not determine Docker bridge gateway IP — is the bridge network enabled?" >&2
            return 1
        fi
    else
        bind_addr="127.0.0.1"
    fi

    socat "TCP-LISTEN:${port},bind=${bind_addr},reuseaddr,fork" \
          "UNIX-CONNECT:${host_gpg_socket}" &
    local host_pid=$!
    echo "$host_pid" > "$DEV_GPG_FORWARD_PIDFILE"

    for _ in $(seq 1 50); do
        sleep 0.05
        kill -0 "$host_pid" 2>/dev/null || break
    done
    if ! kill -0 "$host_pid" 2>/dev/null; then
        echo "error: host-side GPG forwarder failed to start (port $port may be in use)" >&2
        rm -f "$DEV_GPG_FORWARD_PIDFILE"
        return 1
    fi

    # Kill any container-local gpg-agent so it doesn't compete for the socket
    dc_exec gpgconf --kill gpg-agent 2>/dev/null || true

    dc exec -d app socat \
        UNIX-LISTEN:/run/gpg-agent/S.gpg-agent,fork,unlink-early,mode=600 \
        TCP:host.docker.internal:${port}

    for _ in $(seq 1 50); do
        if dc_exec test -S /run/gpg-agent/S.gpg-agent 2>/dev/null; then
            break
        fi
        sleep 0.05
    done

    # Point container gpg at the forwarded socket
    dc_exec bash -c 'mkdir -p ~/.gnupg && chmod 700 ~/.gnupg && ln -sf /run/gpg-agent/S.gpg-agent ~/.gnupg/S.gpg-agent'

    # GPG needs public keys in the local keyring to discover which secret
    # keys the forwarded agent holds. Without this, gpg --list-secret-keys
    # returns nothing and decryption fails with "No secret key".
    gpg --export 2>/dev/null | dc exec -T app gpg --import 2>/dev/null || true

    for _ in $(seq 1 10); do
        if dc_exec gpg --list-secret-keys 2>/dev/null | grep -q '^sec'; then
            return 0
        fi
        sleep 0.1
    done
    echo "warning: GPG agent bridge started but no secret keys visible inside the container" >&2
    echo "  (is the private key loaded on the host? check: gpg --list-secret-keys)" >&2
    return 0
}

## X11 forwarding ###########################################################

DEV_X11_FORWARD_PIDFILE="/tmp/devcontainer-x11-forward-${DEV_CONTAINER_NAME}.pid"

stop_x11_forward() {
    if [ -f "$DEV_X11_FORWARD_PIDFILE" ]; then
        local pid
        pid="$(cat "$DEV_X11_FORWARD_PIDFILE")"
        kill "$pid" 2>/dev/null || true
        rm -f "$DEV_X11_FORWARD_PIDFILE"
    fi
    # Catch orphans whose PID file was lost (tmpfiles cleanup, manual rm, etc.)
    local display_num
    display_num="$(echo "${DISPLAY:-}" | sed 's/^.*:\([0-9]*\)\(\..*\)\?$/\1/')"
    if [[ "$display_num" =~ ^[0-9]+$ ]]; then
        local x11_port=$(( 6000 + display_num ))
        pkill -f "socat TCP-LISTEN:${x11_port},bind=.+,reuseaddr,fork TCP:localhost:${x11_port}" 2>/dev/null || true
    fi
}

setup_x11_forward() {
    if [ -z "${DISPLAY:-}" ]; then
        return 0
    fi

    local display_num
    display_num="$(echo "$DISPLAY" | sed 's/^.*:\([0-9]*\)\(\..*\)\?$/\1/')"
    if ! [[ "$display_num" =~ ^[0-9]+$ ]]; then
        echo "warning: could not parse display number from DISPLAY=$DISPLAY — X11 forwarding skipped" >&2
        return 0
    fi

    local container_display
    if [ -S "/tmp/.X11-unix/X${display_num}" ]; then
        # Local display — the bind-mount of /tmp/.X11-unix handles transport.
        container_display=":${display_num}"
    else
        # TCP display (SSH X11 forwarding). The SSH daemon listens on
        # localhost:6000+N only — not reachable from the container via
        # host.docker.internal. Relay through socat on the bridge IP,
        # same pattern as SSH/GPG agent forwarding.
        if [ "${DEV_HAS_SOCAT:-false}" != "true" ]; then
            echo "warning: socat not found on host — X11 forwarding for SSH displays disabled (apt install socat)" >&2
            return 0
        fi

        stop_x11_forward

        local x11_port=$(( 6000 + display_num ))
        local bind_addr
        if [ "$(uname -s)" = "Linux" ] && ! grep -qiF microsoft /proc/version 2>/dev/null; then
            bind_addr="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)" || true
            if [ -z "$bind_addr" ]; then
                echo "error: could not determine Docker bridge gateway IP — X11 forwarding disabled" >&2
                return 0
            fi
        else
            bind_addr="127.0.0.1"
        fi

        socat "TCP-LISTEN:${x11_port},bind=${bind_addr},reuseaddr,fork" \
              "TCP:localhost:${x11_port}" &
        local host_pid=$!
        echo "$host_pid" > "$DEV_X11_FORWARD_PIDFILE"

        for _ in $(seq 1 50); do
            sleep 0.05
            kill -0 "$host_pid" 2>/dev/null || break
        done
        if ! kill -0 "$host_pid" 2>/dev/null; then
            echo "error: host-side X11 forwarder failed to start (port $x11_port may be in use)" >&2
            rm -f "$DEV_X11_FORWARD_PIDFILE"
            return 0
        fi

        container_display="host.docker.internal:${display_num}"
    fi

    # Persist DISPLAY for interactive shells. The compose environment block
    # has the host's original DISPLAY value; override it for the container.
    dc_exec bash -c "
        sed -i '/^export DISPLAY=/d' /home/vscode/.bashrc
        echo 'export DISPLAY=${container_display}' >> /home/vscode/.bashrc
    "

    # Inject xauth cookie so X clients in the container can authenticate.
    if ! dc_exec command -v xauth >/dev/null 2>&1; then
        return 0
    fi
    local host_cookie
    host_cookie="$(xauth list "${DISPLAY}" 2>/dev/null | head -1)" || true
    if [ -z "$host_cookie" ]; then
        echo "warning: no xauth cookie for DISPLAY=$DISPLAY — GUI apps may fail to authenticate" >&2
    else
        local auth_hex
        auth_hex="$(echo "$host_cookie" | awk '{print $NF}')"
        dc_exec bash -c "
            touch /home/vscode/.Xauthority
            xauth add ${container_display} MIT-MAGIC-COOKIE-1 ${auth_hex}
        "
    fi
}

setup_git() {
    local name email
    name="$(git config user.name 2>/dev/null || true)"
    email="$(git config user.email 2>/dev/null || true)"
    if [ -n "$name" ]; then
        dc_exec git config --global user.name "$name"
    fi
    if [ -n "$email" ]; then
        dc_exec git config --global user.email "$email"
    fi
}

# gh stores its OAuth token in the OS keyring wherever one is available, so a
# host hosts.yml routinely carries the account stanza and NO token. Copying that
# in is worse than copying nothing: gh's multi-account migration runs at CONFIG
# LOAD, goes to the keyring for the missing token, and the container has no
# dbus-launch to reach one — so the migration refuses and EVERY gh command dies
# before it starts, `gh --version` included, with GH_TOKEN never consulted. An
# absent hosts.yml leaves gh working and GH_TOKEN usable.
#
# So setup_gh materializes the host's token into the copy. The two helpers below
# are text-only, which is what makes them testable without docker or a real gh
# (tests/test-gh-hosts-token.sh).

# Print the host keys that need filling. Reads a hosts.yml on stdin.
#
# A host is already fine when it has a token gh can reach without the keyring:
# one at host level, or one under the user named by `user:`. A token belonging
# to some OTHER user does not count — the migration still goes to the keyring
# for the active one, which is the whole failure. That distinction is why this
# tracks the users stanza instead of grepping for any `oauth_token` at all.
gh_hosts_missing_token() {
    awk '
        function flush(   ok) {
            if (host == "") return
            # No `user:` key at all: any in-file token is the only candidate.
            ok = host_tok || (active != "" && (active in user_tok)) ||
                 (active == "" && any_user_tok)
            if (!ok) print host
        }
        /^[^ \t#][^:]*:[ \t]*$/ {
            flush()
            host = $0
            sub(/:[ \t]*$/, "", host)
            base = -1; host_tok = 0; active = ""
            in_users = 0; user = ""; any_user_tok = 0
            delete user_tok
            next
        }
        host == "" { next }
        /^[ \t]*$/ { next }
        /^[ \t]*#/ { next }
        {
            ind = match($0, /[^ \t]/) - 1
            if (base < 0) base = ind
            key = $0
            sub(/^[ \t]*/, "", key)
            sub(/[ \t]*:.*$/, "", key)
            if (ind <= base) {
                in_users = (key == "users")
                if (key == "oauth_token") host_tok = 1
                else if (key == "user") {
                    active = $0
                    sub(/^[ \t]*user[ \t]*:[ \t]*/, "", active)
                    sub(/[ \t]*$/, "", active)
                }
            } else if (in_users) {
                # Inside the stanza a bare key is a username; anything deeper
                # that says oauth_token belongs to the last one seen.
                if ($0 ~ /:[ \t]*$/) user = key
                else if (key == "oauth_token") {
                    user_tok[user] = 1
                    any_user_tok = 1
                }
            }
        }
        END { flush() }
    '
}

# Emit a hosts.yml (stdin -> stdout) with `oauth_token: <token>` added to
# <host>'s block. Three choices worth stating:
#   - HOST level, not under users.<name> where gh's own migration would put it:
#     that form works with no users stanza at all, and still satisfies the
#     migration on a half-migrated file (checked against gh 2.x).
#   - indentation read from the block's own body, because YAML requires the keys
#     of one mapping to agree — a hard-coded width corrupts any other file.
#   - token by environment, not argv: argv is world-readable through ps, and
#     `awk -v` would interpret backslash escapes in the value.
gh_hosts_with_token() {
    GH_HOSTS_TARGET="$1" GH_HOSTS_TOKEN="$2" awk '
        BEGIN {
            target = ENVIRON["GH_HOSTS_TARGET"] ":"
            token = ENVIRON["GH_HOSTS_TOKEN"]
        }
        # Stay pending past blank lines AND comments: a blank has no indent to
        # read, a column-0 comment reads as none, and a defaulted width inside
        # a block of another width is unparseable YAML — gh dies at config
        # load either way. Only a real body line can answer the question.
        pending && /^[ \t]*(#|$)/ { print; next }
        # Deferred by one line: the block body is the only place its indent can
        # be read from, and that is the line AFTER the host key.
        pending {
            indent = "    "
            if ($0 ~ /^[ \t]+[^ \t]/) {
                indent = $0
                sub(/[^ \t].*$/, "", indent)
            }
            printf "%soauth_token: %s\n", indent, token
            pending = 0
        }
        { print }
        {
            line = $0
            sub(/[ \t]*$/, "", line)
            if (line == target) pending = 1
        }
        END { if (pending) printf "    oauth_token: %s\n", token }
    '
}

setup_gh() {
    local hosts="$HOME/.config/gh/hosts.yml"
    [ -f "$hosts" ] || return 0

    # Stage in a 0700 dir: the fill writes the token through an intermediate
    # file that a plain `>` would create at the ambient umask (0644 by default).
    local stage staged
    stage="$(mktemp -d)"
    # Baked in, not expanded at trap time: RETURN fires after the locals are
    # gone. Same idiom as dc_up in dev/devcontainer.
    # shellcheck disable=SC2064
    trap "rm -rf '$stage'" RETURN
    staged="$stage/hosts.yml"
    cat "$hosts" >"$staged"

    local host token existing
    while read -r host; do
        # stdin is the host list this loop is reading; gh must not see it — a
        # gh that reads stdin would swallow the remaining hosts.
        token="$(gh auth token -h "$host" </dev/null 2>/dev/null || true)"
        if [ -z "$token" ]; then
            # Any tokenless host is fatal to gh as a whole, not just to that
            # host, so a partial fill is not worth copying — leaving no
            # hosts.yml at all keeps gh runnable and GH_TOKEN usable.
            echo "warning: host \`gh auth token -h $host\` yielded nothing (gh not installed, not logged in, or keyring unreadable)" >&2
            echo "         skipping gh config copy — run \`gh auth login\` on the host, or set GH_TOKEN in the container" >&2
            # A stale copy already in the container — the pre-fill code shipped
            # tokenless files, and /home/vscode outlives cold starts — is
            # broken the very way this fill prevents, and absent beats broken.
            # Remove it ONLY when it is itself tokenless: a file with its
            # tokens is an in-container `gh auth login`, not ours to delete.
            existing="$(dc_exec cat /home/vscode/.config/gh/hosts.yml 2>/dev/null || true)"
            if [ -n "$existing" ] && [ -n "$(gh_hosts_missing_token <<<"$existing")" ]; then
                dc_exec rm -f /home/vscode/.config/gh/hosts.yml
                echo "         removed the container's stale tokenless hosts.yml" >&2
            fi
            return 0
        fi
        gh_hosts_with_token "$host" "$token" <"$staged" >"$stage/next"
        mv "$stage/next" "$staged"
    done < <(gh_hosts_missing_token <"$hosts")

    # The mode travels with docker cp, and the file holds a bearer token.
    chmod 600 "$staged"
    dc_exec mkdir -p /home/vscode/.config/gh
    docker cp "$staged" "$(dc ps -q app)":/home/vscode/.config/gh/hosts.yml
    # docker cp preserves host UID; explicit chown makes us robust to
    # base images that don't honor USER_UID build args.
    dc exec -u root app chown vscode:vscode /home/vscode/.config/gh/hosts.yml
}

setup_claude_credentials() {
    # Host-side maintenance of the host's own credential layout (the container no
    # longer bind-mounts this dir — it seeds a private token from it read-only;
    # see docs/adr/0001-devcontainer-private-token-isolation.md). Ensures the
    # profile store dir exists (it is the container's :ro seed source), and
    # migrates any legacy ~/.claude/.credentials.json into credentials/ with a
    # host-side symlink so host claude-code and claude-profile share one layout.
    local cred_dir="$HOME/.claude/credentials"
    local cred_file="$HOME/.claude/.credentials.json"

    mkdir -p "$cred_dir"

    if [ -f "$cred_file" ] && [ ! -L "$cred_file" ]; then
        mv "$cred_file" "$cred_dir/.credentials.json"
        ln -s credentials/.credentials.json "$cred_file"
    fi
}

setup_claude() {
    # Keys are resolved once in dev/devcontainer, which also hands the container
    # key to compose so the host log directory mounts at the right project.
    local host_project_key="$DEV_HOST_PROJECT_KEY"
    local container_project_key="$DEV_CONTAINER_PROJECT_KEY"

    # Named volume root comes up root-owned; fix so vscode can write. Top-level
    # only, deliberately: setup-claude creates the contents as vscode, and a
    # recursive chown here would cross into the transcript bind mounted at
    # .claude/projects/<key> and rewrite ownership on the host side.
    #
    # It is NOT sufficient on its own. `.claude/projects` is created by the
    # DAEMON as root to host that bind, so nothing below this line repairs it —
    # that is dev_chown_mount_points' ancestor walk (lib/volume-perms.sh),
    # which runs in setup() earlier in this same locked region (#106). setup()
    # is cold-start only, so a container already running when that fix landed
    # keeps the root-owned dir until its next recreate.
    dc exec -u root app chown vscode:vscode /home/vscode/.claude

    dc exec \
        -e DEV_WORKSPACE="$DEV_WORKSPACE" \
        -e DEV_CONTAINER_WORKSPACE="$DEV_CONTAINER_WORKSPACE" \
        -e DEV_HOST_PROJECT_KEY="$host_project_key" \
        -e DEV_CONTAINER_PROJECT_KEY="$container_project_key" \
        -e DEV_CLAUDE_PROFILE="${DEV_CLAUDE_PROFILE:-}" \
        app python3 /usr/local/bin/setup-claude
}

# On-demand re-run of just the session-transcript mirror (setup-claude's
# copy-sessions step). setup_claude already runs this on every entry, but a
# host session started after the container came up isn't visible until the
# next entry — this pulls it in without a full re-setup. Host -> container
# only; transcripts already present container-side are left untouched.
copy_host_transcripts() {
    local host_project_key="$DEV_HOST_PROJECT_KEY"
    local container_project_key="$DEV_CONTAINER_PROJECT_KEY"

    dc exec \
        -e DEV_WORKSPACE="$DEV_WORKSPACE" \
        -e DEV_CONTAINER_WORKSPACE="$DEV_CONTAINER_WORKSPACE" \
        -e DEV_HOST_PROJECT_KEY="$host_project_key" \
        -e DEV_CONTAINER_PROJECT_KEY="$container_project_key" \
        app python3 /usr/local/bin/setup-claude copy-sessions
}
