# lib/ssh.sh — common SSH helpers for the flash_*.sh scripts.
#
# Sourced by:
#   - flash_efr32.sh                                   (repo root)
#   - flash_install_rtl8196e.sh                        (repo root)
#   - 3-Main-SoC-Realtek-RTL8196E/flash_remote.sh
#
# Provides hardened SSH options that prevent the "ssh hangs forever after
# the gateway reboots" failure mode observed during v3.1 testing, plus a
# retry-on-transport-failure helper. Intentionally not executable; this
# file is only meant to be sourced.
#
# Multiplexing: a per-script ControlMaster socket is created in a private
# tmpdir, so each script's N back-to-back SSH calls share one TCP/SSH
# session. Two practical wins:
#   - Password / passphrase prompted at most once per script run
#     (subsequent commands ride the existing channel — no re-auth).
#   - One TCP+SSH handshake instead of N (~500 ms-2 s saved on slow links).
# Callers MUST chain ssh_cleanup_multiplex into their EXIT trap.

# Per-script private tmpdir for the ControlMaster socket. Using $$ keeps
# concurrent script runs to the same gateway from sharing a master (each
# gets its own master, both finish independently).
SSH_CTRL_DIR="${TMPDIR:-/tmp}/.flash-ssh-cm-${UID}-$$"
mkdir -p "$SSH_CTRL_DIR"
chmod 700 "$SSH_CTRL_DIR"

# Hardened SSH options (bash array — splice into ssh invocation).
# Callers add their own scenario-specific options on top:
#   - StrictHostKeyChecking policy (post-install: accept-new; first-flash: no)
#   - port, identity file, etc.
#
# Note: BatchMode=yes is intentionally NOT set. With BatchMode, ssh
# silently fails on encrypted private keys not loaded in ssh-agent
# (issue #90) and refuses password prompts entirely — leaving users
# without a key with no path forward. ConnectTimeout + ServerAlive
# already cover the original "ssh hangs forever" concern (transport
# layer); auth-time prompts are the user's call.
SSH_HARDEN_OPTS=(
    -o ConnectTimeout=5
    -o ServerAliveInterval=3
    -o ServerAliveCountMax=2
    -o ControlMaster=auto
    -o "ControlPath=${SSH_CTRL_DIR}/sock-%C"
    -o ControlPersist=60s
)

# ssh_retry: ssh wrapper that retries on transport failures only (rc=255).
# Real remote-command exit codes pass through unchanged so callers can
# branch on them.
#
# Usage:  ssh_retry [ssh-args...] target command...
#
# Example:
#   ssh_retry "${SSH_HARDEN_OPTS[@]}" -o StrictHostKeyChecking=accept-new \
#             "root@${GW_IP}" "uptime"
ssh_retry() {
    local attempt rc
    for attempt in 1 2 3; do
        ssh "$@"
        rc=$?
        # rc=255 is SSH's "transport failed" code (cannot connect, host
        # unreachable, connection dropped mid-flight). Anything else is
        # the real remote command exit code — never retry that.
        if [ $rc -ne 255 ]; then
            return $rc
        fi
        if [ $attempt -lt 3 ]; then
            echo "Warning: SSH transport failed (attempt $attempt/3); retrying in $((attempt * 2))s..." >&2
            sleep $((attempt * 2))
        fi
    done
    echo "Error: SSH failed after 3 attempts." >&2
    return 43
}

# wait_for_port: poll a TCP port until it accepts a connection or timeout.
# Useful after a kernel-bridge baud change (port closes briefly) or after
# a gateway reboot.
wait_for_port() {
    local host="$1" port="$2" timeout="${3:-5}"
    local deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        if timeout 1 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# ssh_cleanup_multiplex: tell every live ControlMaster to exit, then drop
# the tmpdir. Idempotent and silent on failure (best-effort cleanup).
# Callers MUST invoke this at script end — typically chained into their
# existing EXIT trap, e.g.:
#
#     trap 'rm -rf "$WORK_DIR"; ssh_cleanup_multiplex' EXIT
#
# Safe to call when no master was ever started — nothing to do, no error.
ssh_cleanup_multiplex() {
    local sock
    [ -d "$SSH_CTRL_DIR" ] || return 0
    for sock in "$SSH_CTRL_DIR"/sock-*; do
        [ -S "$sock" ] || continue
        ssh -o "ControlPath=$sock" -O exit _ 2>/dev/null || true
    done
    rm -rf "$SSH_CTRL_DIR" 2>/dev/null || true
}

# ssh_prime_with_password: open the ControlMaster session non-interactively
# using the password in $SSH_PASSWORD. No-op when SSH_PASSWORD is unset
# (interactive runs use ssh's built-in tty prompt instead). Errors out if
# SSH_PASSWORD is set but sshpass is not installed.
#
# Usage: ssh_prime_with_password [extra-ssh-opts...] target
#
# Pass the same opts the caller will use for subsequent ssh_retry calls
# (StrictHostKeyChecking policy, port, etc.) so the master's options match.
# After this returns 0, plain `ssh` / `ssh_retry` to the same target reuses
# the open master without re-auth.
ssh_prime_with_password() {
    [ -z "${SSH_PASSWORD:-}" ] && return 0
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "Error: SSH_PASSWORD is set but sshpass is not installed." >&2
        echo "Install with:  sudo apt install sshpass" >&2
        return 1
    fi
    SSHPASS="$SSH_PASSWORD" sshpass -e ssh "$@" "true" 2>/dev/null
}

# valid_ipv4 — return 0 if $1 is a dotted-quad IPv4 (each octet 0-255).
# Shared by flash_*.sh to validate the --boot-ip flag / BOOT_IP env value.
# Rejects empty, non-digit/dot chars, leading/trailing/double dots, and any
# octet > 255.
valid_ipv4() {
    case "$1" in
        ""|*[!0-9.]*|.*|*.|*..*) return 1 ;;
    esac
    local IFS=. part count=0
    for part in $1; do
        [ "$part" -le 255 ] 2>/dev/null || return 1
        count=$((count + 1))
    done
    [ "$count" -eq 4 ]
}

# resolve_ipv4 — echo a dotted-quad IPv4 for $1, resolving a hostname if needed.
# If $1 is already a valid IPv4 it is echoed unchanged; otherwise it is treated
# as a hostname and resolved host-side via getent (the on-device boothold and the
# bootloader cannot resolve names — boothold parses sscanf("%d.%d.%d.%d") and the
# host-side ip route / ip neigh / tftp / ping all need a literal, so resolution
# must happen here). Returns 1 (echoing nothing) if $1 is neither a valid IPv4
# nor a name that resolves to one.
resolve_ipv4() {
    if valid_ipv4 "$1"; then
        printf '%s\n' "$1"
        return 0
    fi
    local ip
    ip=$(getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}')
    if [ -n "$ip" ] && valid_ipv4 "$ip"; then
        printf '%s\n' "$ip"
        return 0
    fi
    return 1
}

# preserve_user_additions <skel_dir> <ssh_target> [ssh_opts...]
# Carry every user-added path across a userdata reflash. The flashed userdata is
# rebuilt from the skeleton, which would otherwise drop anything a user added
# under /userdata next to the shipped tree — a custom program in usr/bin, a whole
# new directory, a script, config the skeleton does not ship. This copies into
# <skel_dir> every path the gateway has under /userdata that is NOT already
# present in the working skeleton: files, symlinks AND directories/subtrees
# (including empty ones).
#
# It deliberately preserves *new paths*, not *edits to shipped files*: a path the
# skeleton ships keeps the fresh shipped version (so a newer shipped file is never
# shadowed by the gateway's old copy), and curated user config is re-injected
# separately by the caller's SAVE_FILES list. Because the caller extracts
# SAVE_FILES into <skel_dir> BEFORE calling us, that config is already "present"
# and is excluded here — so what remains are the genuine user additions. (Trade
# off: preservation is by-default under /userdata, so if an app writes state
# there it is carried too; on this platform volatile state lives on ramfs, not
# /userdata, so in practice only real user files match.)
#
# Runs only on the live-gateway (upgrade) path — the caller already has an SSH
# session. Best-effort: no SSH, no extra paths, or any error → silent no-op, so
# it never blocks a flash. Reuses ssh_retry above.
preserve_user_additions() {
    local skel_dir="$1" target="$2"; shift 2  # remaining args = ssh opts
    [ -d "$skel_dir" ] || return 0

    # Paths already in the working skeleton — the shipped tree PLUS the config the
    # caller just re-injected from SAVE_FILES. Relative, no leading ./, dirs with
    # no trailing slash. Anything the gateway has on top of this is a user add.
    local nl present
    nl=$'\n'
    present="$( cd "$skel_dir" && find . -mindepth 1 -print 2>/dev/null | sed 's|^\./||' )" || return 0
    present="${nl}${present}${nl}"

    # Every path under /userdata on the gateway, BusyBox-native: no find/tr; tar
    # enumerates the tree (dirs come back with a trailing slash, all with a
    # leading ./). Reading the contents once to list names is cheap next to the
    # 16 MiB the flash itself moves.
    local listing
    listing="$(ssh_retry "$@" "$target" \
        'tar cf - -C /userdata . 2>/dev/null | tar tf - 2>/dev/null' \
        2>/dev/null)" || return 0

    # extras = gateway paths not already present in the skeleton. Pure-bash
    # membership test — /usr/bin/grep may be ugrep here, so don't lean on it.
    local p rel extras=""
    while IFS= read -r p; do
        rel="${p#./}"; rel="${rel%/}"
        [ -n "$rel" ] || continue
        case "$present" in *"${nl}${rel}${nl}"*) continue ;; esac
        extras="${extras}${rel}${nl}"
    done <<EOF
$listing
EOF
    [ -n "$extras" ] || return 0

    # Reduce to a minimal cover: drop any extra whose parent dir is also an extra,
    # so tar pulls a new directory whole (subdirs and empty dirs included) and the
    # arg list stays short. Sort so a parent always precedes its children.
    local extras_sorted extra_set e parent top=""
    extras_sorted="$(printf '%s' "$extras" | sort)"
    extra_set="${nl}${extras_sorted}${nl}"
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        parent="${e%/*}"
        if [ "$parent" = "$e" ]; then
            top="${top}${e}${nl}"                       # top-level path, always keep
        else
            case "$extra_set" in
                *"${nl}${parent}${nl}"*) : ;;           # parent is an extra → tar covers it
                *) top="${top}${e}${nl}" ;;
            esac
        fi
    done <<EOF
$extras_sorted
EOF
    [ -n "$top" ] || return 0

    # Build the tar arg list (space-separated; same no-spaces-in-names limit as
    # the SAVE_FILES list) plus a count + names for the summary.
    local args="" names="" count=0 t
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        args="${args:+$args }$t"
        names="${names:+$names, }$t"
        count=$((count + 1))
    done <<EOF
$top
EOF
    [ "$count" -gt 0 ] || return 0

    # tar preserves mode (+x), symlinks and directory structure. Best-effort.
    local tmp; tmp="$(mktemp)"
    if ssh_retry "$@" "$target" "tar cf - -C /userdata $args 2>/dev/null" > "$tmp" 2>/dev/null \
       && [ -s "$tmp" ] && tar xf "$tmp" -C "$skel_dir" 2>/dev/null; then
        echo "Preserved $count user addition(s) in /userdata: $names"
    fi
    rm -f "$tmp"
}
