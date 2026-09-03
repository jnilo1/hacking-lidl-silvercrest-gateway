# lib/gwconf.sh — where the gateway lives, from this host's point of view.
#
# Sourced by:
#   - flash_install_rtl8196e.sh, build_fullflash.sh, create_fullflash.sh   (repo root)
#   - backup_gateway.sh, restore_gateway.sh, flash_efr32.sh                (repo root)
#   - 3-Main-SoC-Realtek-RTL8196E/flash_remote.sh
#   - 3-Main-SoC-Realtek-RTL8196E/3?-*/flash_*.sh
#   - 3-Main-SoC-Realtek-RTL8196E/32-Kernel/scripts/{test,bench}_*.sh
# Intentionally not executable; this file is only meant to be sourced.
#
# The problem it solves. The gateway's own address lives in /userdata/etc/eth0.conf
# ON THE DEVICE. That file is generated into a throw-away copy of the userdata
# skeleton at flash time and the copy is reaped when the script exits, so nothing
# on this machine remembers it. Every host-side script therefore carried the same
# hardcoded address, and the provisioning prompts proposed one fixed subnet no
# matter which LAN the host was actually on.
#
# Two files, both gitignored, both optional:
#   gateway.env      user-owned, hand-edited, NEVER written by these scripts.
#                    Copy gateway.env.example to create it.
#   .gateway-state   machine-owned: what was last provisioned, what was last
#                    reached. Written by the scripts, safe to delete.
#
# Resolution order for "which gateway am I talking to":
#   1. explicit CLI argument / flag        caller's business, always wins
#   2. environment variable                caller's business (LINUX_IP, ...)
#   3. GW_IP        from gateway.env, then the user config, then .gateway-state
#   4. GW_HOST      resolved through DNS — tried BEFORE 5 when the recorded mode
#                   is dhcp, because that is the case where the name is the only
#                   thing that stays valid (the device sends its hostname in the
#                   DHCP request, so the router that granted the lease usually
#                   resolves it)
#   5. GW_LAST_SEEN from .gateway-state — the last address actually reached
#   6. the historic default, last resort
#
# Every resolver records where the value came from (GWCONF_ADDR_SOURCE /
# GWCONF_BOOT_SOURCE) so callers can show it. Silently retargeting a flash
# script at a different box is the one failure mode worth being loud about.
# Reading that source means calling gwconf_resolve_gateway / gwconf_resolve_boot_ip
# directly rather than the echoing gwconf_gateway_addr / gwconf_boot_ip wrappers —
# a $(...) capture would set the source inside a subshell and throw it away.

GWCONF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GWCONF_REPO_ROOT="$(cd "${GWCONF_LIB_DIR}/.." && pwd)"

# Host requirements, checked before anything else runs. Sourced here because
# every host-side script sources this file, and because gwconf_state_set below
# is where an unsupported shell would otherwise fail — deep inside a flash,
# after the gateway has already been sent to its bootloader.
# shellcheck disable=SC1091
. "${GWCONF_LIB_DIR}/hostcheck.sh"

GWCONF_FILE="${GWCONF_FILE:-${GWCONF_REPO_ROOT}/gateway.env}"
GWCONF_USER_FILE="${GWCONF_USER_FILE:-${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/rtl8196e-gateway/gateway.env}"
GWCONF_STATE_FILE="${GWCONF_STATE_FILE:-${GWCONF_REPO_ROOT}/.gateway-state}"

# Historic defaults. Reached only when the host has no usable IPv4 LAN to derive
# from AND nothing was ever configured or installed — i.e. the values every
# version before this one used unconditionally.
GWCONF_FALLBACK_IP="192.168.1.88"
GWCONF_FALLBACK_NETMASK="255.255.255.0"
GWCONF_FALLBACK_GATEWAY="192.168.1.1"

# The address a bootloader answers on after a cold boot, compiled into ours and
# used by the Tuya stock loader too. Load-bearing, not cosmetic: a gateway
# already sitting at a bootloader prompt cannot be told to be anywhere else, so
# on a first flash this is the only correct target no matter what LAN the host
# is on. Only the boothold path chooses the address — see gwconf_cold_boot_ip.
GWCONF_BOOTLOADER_COLD_IP="192.168.1.6"
GWCONF_FALLBACK_BOOT_IP="$GWCONF_BOOTLOADER_COLD_IP"

# Host part preferences, most wanted first. .88 and .6 keep the addresses this
# project has always used; the rest are only reached on subnets too small to
# hold them (a /26 has no .88) or when the offset collides with the host or the
# router. See gwconf_subnet_addr.
GWCONF_IP_OFFSETS="88 200 100 50"
GWCONF_BOOT_OFFSETS="6 5 4 3"
# Parking address for /userdata/etc/eth0.bak — where the gateway lands when it
# is on DHCP and no lease ever arrives (udhcpc.script, leasefail). Deliberately
# high in the subnet, clear of the address the gateway uses in static mode.
GWCONF_PARK_OFFSETS="254 253 252 251"

# Set by the resolvers, read by callers for their "Gateway: X (Y)" line.
GWCONF_ADDR_SOURCE=""
GWCONF_BOOT_SOURCE=""
# Set by gwconf_host_lan. Initialised here so a caller running under `set -u`
# can read them even when the probe found no usable LAN.
GWCONF_HOST_IFACE=""; GWCONF_HOST_IP=""; GWCONF_HOST_PREFIX=""; GWCONF_HOST_ROUTER=""

# --- config file access ------------------------------------------------------

# gwconf_read_key <file> <key> — echo the value of KEY=VALUE in <file>.
# Deliberately parsed, not sourced: these files sit in the repo root and in
# $HOME, and sourcing them would execute whatever they contain. Tolerates
# comments, blank lines, surrounding whitespace, quotes and CRLF.
# Returns 1 (echoing nothing) when the file or the key is absent.
gwconf_read_key() {
    local file="$1" key="$2" line k v
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in ''|'#'*) continue ;; esac
        k="${line%%=*}"
        [ "$k" = "$line" ] && continue          # no '=' on this line
        v="${line#*=}"
        k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
        [ "$k" = "$key" ] || continue
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        case "$v" in
            '"'*'"') v="${v#\"}"; v="${v%\"}" ;;
            "'"*"'") v="${v#\'}"; v="${v%\'}" ;;
        esac
        printf '%s\n' "$v"
        return 0
    done < "$file"
    return 1
}

# gwconf_lookup <key> — first non-empty value across the three config files, in
# precedence order. On success sets GWCONF_VALUE and GWCONF_LOOKUP_FILE and
# returns 0; returns 1 when the key is nowhere.
#
# Sets variables instead of echoing on purpose. Callers need to know WHICH file
# a value came from, and capturing the value through $(...) would run this in a
# subshell, where GWCONF_LOOKUP_FILE would be set and immediately discarded.
gwconf_lookup() {
    local key="$1" file
    GWCONF_VALUE=""; GWCONF_LOOKUP_FILE=""
    for file in "$GWCONF_FILE" "$GWCONF_USER_FILE" "$GWCONF_STATE_FILE"; do
        if GWCONF_VALUE="$(gwconf_read_key "$file" "$key")" && [ -n "$GWCONF_VALUE" ]; then
            GWCONF_LOOKUP_FILE="$file"
            return 0
        fi
    done
    GWCONF_VALUE=""
    return 1
}

# gwconf_label <path> — short, readable name for a config file in messages.
gwconf_label() {
    case "$1" in
        "$GWCONF_FILE")       echo "gateway.env" ;;
        "$GWCONF_USER_FILE")  echo "~/.config/rtl8196e-gateway/gateway.env" ;;
        "$GWCONF_STATE_FILE") echo ".gateway-state" ;;
        *)                    basename "$1" ;;
    esac
}

# --- state file (machine-owned) ----------------------------------------------

# gwconf_state_set KEY=VALUE... — merge keys into .gateway-state, rewriting it
# with a generated header. An empty VALUE deletes the key. Best-effort: a
# read-only checkout just means nothing is remembered, never a failed flash.
gwconf_state_set() {
    local -A kv=()
    local line k v arg tmp
    if [ -f "$GWCONF_STATE_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            case "$line" in ''|'#'*) continue ;; esac
            k="${line%%=*}"
            [ "$k" = "$line" ] && continue
            kv["$k"]="${line#*=}"
        done < "$GWCONF_STATE_FILE"
    fi
    for arg in "$@"; do
        k="${arg%%=*}"
        [ -n "$k" ] && [ "$k" != "$arg" ] || continue
        v="${arg#*=}"
        if [ -n "$v" ]; then kv["$k"]="$v"; else unset 'kv[$k]'; fi
    done
    tmp="$(mktemp "${GWCONF_STATE_FILE}.XXXXXX" 2>/dev/null)" || return 0
    {
        echo "# Written by the flash scripts — not meant to be edited."
        echo "# Records the gateway that was last provisioned or last reached, so"
        echo "# the host-side tools know where to look. Delete this file to forget."
        echo "# Settings you want to pin belong in gateway.env, which wins over this."
        for k in $(printf '%s\n' "${!kv[@]}" | sort); do
            printf '%s=%s\n' "$k" "${kv[$k]}"
        done
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$GWCONF_STATE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    return 0
}

# gwconf_record_install <static|dhcp> [ipaddr] [netmask] [gateway]
# Called by the provisioning scripts at the exact point they generate (or delete)
# eth0.conf — the only moment the chosen configuration is known for certain.
# In DHCP mode the address is unknowable by design, so GW_IP is cleared rather
# than left pointing at whatever was installed before.
gwconf_record_install() {
    local mode="${1:-}"
    case "$mode" in
        static)
            gwconf_state_set "GW_MODE=static" "GW_IP=${2:-}" \
                             "GW_NETMASK=${3:-}" "GW_GATEWAY=${4:-}" \
                             "GW_HOST=$(gwconf_device_hostname)"
            ;;
        dhcp)
            gwconf_state_set "GW_MODE=dhcp" "GW_IP=" "GW_NETMASK=" "GW_GATEWAY=" \
                             "GW_HOST=$(gwconf_device_hostname)"
            ;;
    esac
}

# gwconf_record_seen <addr> [hostname] — remember an address we just reached.
# The fast path for the next run, and the only thing that survives a DHCP lease
# change when the router does not resolve the gateway's name.
gwconf_record_seen() {
    [ -n "${1:-}" ] || return 0
    gwconf_state_set "GW_LAST_SEEN=$1" ${2:+"GW_LAST_SEEN_HOST=$2"}
}

# gwconf_device_hostname — the hostname the gateway will answer to, read from
# the userdata skeleton so there is one source of truth for it.
gwconf_device_hostname() {
    local f="${GWCONF_REPO_ROOT}/3-Main-SoC-Realtek-RTL8196E/34-Userdata/skeleton/etc/hostname"
    local h=""
    [ -f "$f" ] && IFS= read -r h < "$f" 2>/dev/null
    printf '%s\n' "${h:-rtl8196e-gw}"
}

# --- IPv4 arithmetic ---------------------------------------------------------

gwconf_valid_ipv4() {
    case "${1:-}" in
        ""|*[!0-9.]*|.*|*.|*..*) return 1 ;;
    esac
    local IFS=. part count=0
    for part in $1; do
        [ "$part" -le 255 ] 2>/dev/null || return 1
        count=$((count + 1))
    done
    [ "$count" -eq 4 ]
}

gwconf_ip2int() {
    local IFS=. a b c d
    read -r a b c d <<EOF
$1
EOF
    printf '%s\n' $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

gwconf_int2ip() {
    local n="$1"
    printf '%d.%d.%d.%d\n' \
        $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) \
        $(( (n >> 8) & 255 )) $(( n & 255 ))
}

gwconf_prefix2mask() {
    local p="$1"
    [ "$p" -ge 0 ] 2>/dev/null && [ "$p" -le 32 ] || return 1
    if [ "$p" -eq 0 ]; then gwconf_int2ip 0; return 0; fi
    gwconf_int2ip $(( 0xFFFFFFFF ^ ((1 << (32 - p)) - 1) ))
}

# gwconf_mask2prefix <dotted-mask> — prefix length, or 1 for a non-contiguous
# mask (255.0.255.0 and friends are rejected rather than silently mangled).
gwconf_mask2prefix() {
    gwconf_valid_ipv4 "${1:-}" || return 1
    local n p
    n="$(gwconf_ip2int "$1")"
    for p in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 \
             17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32; do
        if [ "$p" -eq 0 ]; then
            [ "$n" -eq 0 ] && { printf '0\n'; return 0; }
            continue
        fi
        if [ "$n" -eq $(( 0xFFFFFFFF ^ ((1 << (32 - p)) - 1) )) ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

# gwconf_resolve_host <name> — dotted quad for <name>, or 1 if it does not
# resolve. A literal address passes through unchanged.
gwconf_resolve_host() {
    local ip
    if gwconf_valid_ipv4 "${1:-}"; then printf '%s\n' "$1"; return 0; fi
    [ -n "${1:-}" ] || return 1
    ip="$(getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}')"
    if [ -n "$ip" ] && gwconf_valid_ipv4 "$ip"; then printf '%s\n' "$ip"; return 0; fi
    return 1
}

# --- this host's LAN ---------------------------------------------------------

# gwconf_host_lan — probe the workstation's primary IPv4 LAN, once per run.
# Sets GWCONF_HOST_IFACE / GWCONF_HOST_IP / GWCONF_HOST_PREFIX / GWCONF_HOST_ROUTER.
# Returns 1 when there is no usable IPv4 default route to derive anything from
# (no network, IPv6-only, container with no route) — callers then fall back to
# the historic constants.
gwconf_host_lan() {
    [ -n "${GWCONF_HOST_PROBED:-}" ] && return "$GWCONF_HOST_RC"
    GWCONF_HOST_PROBED=1
    GWCONF_HOST_RC=1
    GWCONF_HOST_IFACE=""; GWCONF_HOST_IP=""; GWCONF_HOST_PREFIX=""; GWCONF_HOST_ROUTER=""

    command -v ip >/dev/null 2>&1 || return 1

    local route cidr
    route="$(ip -4 route show default 2>/dev/null | head -1)"
    [ -n "$route" ] || return 1
    GWCONF_HOST_ROUTER="$(printf '%s\n' "$route" \
        | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
    GWCONF_HOST_IFACE="$(printf '%s\n' "$route" \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [ -n "$GWCONF_HOST_IFACE" ] || return 1

    cidr="$(ip -o -4 addr show dev "$GWCONF_HOST_IFACE" scope global 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="inet"){print $(i+1); exit}}')"
    [ -n "$cidr" ] || return 1
    GWCONF_HOST_IP="${cidr%/*}"
    GWCONF_HOST_PREFIX="${cidr#*/}"
    gwconf_valid_ipv4 "$GWCONF_HOST_IP" || return 1
    [ "$GWCONF_HOST_PREFIX" -ge 1 ] 2>/dev/null || return 1

    GWCONF_HOST_RC=0
    return 0
}

# gwconf_subnet_addr <offsets...> — first address at one of the given host
# offsets inside this host's subnet that is a valid host address and is neither
# the host itself nor the router. On success sets GWCONF_SUBNET_ADDR and returns
# 0; returns 1 when nothing fits (no LAN, or a subnet too small for any offset).
#
# Sets a variable rather than echoing for the same reason as gwconf_lookup, plus
# one more: it calls gwconf_host_lan, and callers go on to name the interface it
# found. Through $(...) that probe would happen in a subshell and GWCONF_HOST_*
# would come back unset.
gwconf_subnet_addr() {
    GWCONF_SUBNET_ADDR=""
    gwconf_host_lan || return 1
    [ "$GWCONF_HOST_PREFIX" -le 30 ] || return 1     # /31 and /32 have no hosts

    local hostint netint size cand off
    hostint="$(gwconf_ip2int "$GWCONF_HOST_IP")"
    size=$(( 1 << (32 - GWCONF_HOST_PREFIX) ))
    netint=$(( hostint & (0xFFFFFFFF ^ (size - 1)) ))

    for off in "$@"; do
        [ "$off" -ge 1 ] 2>/dev/null || continue
        [ "$off" -le $(( size - 2 )) ] || continue   # keep clear of the broadcast
        cand="$(gwconf_int2ip $(( netint + off )))"
        [ "$cand" = "$GWCONF_HOST_IP" ] && continue
        [ "$cand" = "${GWCONF_HOST_ROUTER:-}" ] && continue
        GWCONF_SUBNET_ADDR="$cand"
        return 0
    done

    # None of the preferred offsets fit: a subnet too small to hold .88 or .6,
    # or every preference already taken by this host or the router. Work down
    # from the top of the usable range instead, so a /29 or /30 still gets a
    # proposal inside the right network rather than an unreachable constant.
    for off in $(( size - 2 )) $(( size - 3 )) $(( size - 4 )); do
        [ "$off" -ge 1 ] || continue
        cand="$(gwconf_int2ip $(( netint + off )))"
        [ "$cand" = "$GWCONF_HOST_IP" ] && continue
        [ "$cand" = "${GWCONF_HOST_ROUTER:-}" ] && continue
        GWCONF_SUBNET_ADDR="$cand"
        return 0
    done
    return 1
}

# gwconf_warn_if_taken <ip> <what> — one-line heads-up when a proposed address
# already answers on this LAN. Deliberately a warning and not an automatic
# shift: on a re-install the occupant IS the gateway being re-flashed, and
# quietly moving to another address would be worse than saying nothing.
gwconf_warn_if_taken() {
    local ip="${1:-}" what="${2:-address}"
    [ -n "$ip" ] || return 0
    command -v ping >/dev/null 2>&1 || return 0
    ping -c 1 -W 1 "$ip" >/dev/null 2>&1 || return 0
    echo "Note: ${ip} already answers on this LAN."
    echo "      Expected if that is the gateway you are re-flashing; otherwise pick"
    echo "      another ${what} — two hosts on one address will not both work."
    return 0
}

# --- provisioning defaults ---------------------------------------------------

# gwconf_suggest_static — what to propose at the static-IP prompts.
# Sets GWCONF_SUGGEST_IPADDR / _NETMASK / _GATEWAY, and GWCONF_SUGGEST_SOURCE
# describing where they came from. Preference order per value:
#   already-configured (gateway.env / previous install) > derived from this
#   host's LAN > the historic 192.168.1.x constants.
# Always succeeds; the values are only ever proposals the user can override.
gwconf_suggest_static() {
    local v
    GWCONF_SUGGEST_SOURCE=""

    # shellcheck disable=SC2086  # word splitting of the offset list is intended
    if gwconf_lookup GW_IP; then
        GWCONF_SUGGEST_IPADDR="$GWCONF_VALUE"
        GWCONF_SUGGEST_SOURCE="$(gwconf_label "$GWCONF_LOOKUP_FILE")"
    elif gwconf_subnet_addr $GWCONF_IP_OFFSETS; then
        GWCONF_SUGGEST_IPADDR="$GWCONF_SUBNET_ADDR"
        GWCONF_SUGGEST_SOURCE="derived from ${GWCONF_HOST_IFACE} ${GWCONF_HOST_IP}/${GWCONF_HOST_PREFIX}"
    else
        GWCONF_SUGGEST_IPADDR="$GWCONF_FALLBACK_IP"
        GWCONF_SUGGEST_SOURCE="built-in default"
    fi

    if gwconf_lookup GW_NETMASK; then
        GWCONF_SUGGEST_NETMASK="$GWCONF_VALUE"
    elif gwconf_host_lan && v="$(gwconf_prefix2mask "$GWCONF_HOST_PREFIX")"; then
        GWCONF_SUGGEST_NETMASK="$v"
    else
        GWCONF_SUGGEST_NETMASK="$GWCONF_FALLBACK_NETMASK"
    fi

    if gwconf_lookup GW_GATEWAY; then
        GWCONF_SUGGEST_GATEWAY="$GWCONF_VALUE"
    elif gwconf_host_lan && [ -n "${GWCONF_HOST_ROUTER:-}" ]; then
        GWCONF_SUGGEST_GATEWAY="$GWCONF_HOST_ROUTER"
    else
        GWCONF_SUGGEST_GATEWAY="$GWCONF_FALLBACK_GATEWAY"
    fi
    return 0
}

# gwconf_write_eth0_bak <file> [ipaddr] [netmask] [gateway]
# Write the device's DHCP-failure fallback config.
#
# /userdata/etc/eth0.bak is what udhcpc.script falls back to when no lease ever
# arrives, and it doubles as the static config to copy over eth0.conf to leave
# DHCP. It used to ship a fixed 192.168.1.x, which meant a gateway on any other
# LAN became unreachable exactly when the fallback was supposed to save it.
#
# With ipaddr/netmask/gateway (a static install) the fallback lands in the same
# subnet as the gateway, on a high host number so it does not collide with the
# address the gateway normally holds. Without them (a DHCP install) it is
# derived from this host's LAN. If neither is usable the existing file is left
# alone — better the shipped default than a wrong one.
gwconf_write_eth0_bak() {
    local file="${1:-}" ipaddr="${2:-}" netmask="${3:-}" gateway="${4:-}"
    local prefix size netint off cand park=""
    [ -n "$file" ] || return 0

    if [ -n "$ipaddr" ]; then
        # A static install. Park in the gateway's own subnet — and if the config
        # handed to us does not parse, write nothing at all rather than quietly
        # substituting this host's subnet, which may not be the gateway's.
        gwconf_valid_ipv4 "$ipaddr" || return 0
        prefix="$(gwconf_mask2prefix "$netmask")" || return 0
        [ "$prefix" -le 30 ] || return 0
        size=$(( 1 << (32 - prefix) ))
        netint=$(( $(gwconf_ip2int "$ipaddr") & (0xFFFFFFFF ^ (size - 1)) ))
        for off in $GWCONF_PARK_OFFSETS $(( size - 2 )) $(( size - 3 )); do
            [ "$off" -ge 1 ] || continue
            [ "$off" -le $(( size - 2 )) ] || continue
            cand="$(gwconf_int2ip $(( netint + off )))"
            [ "$cand" = "$ipaddr" ] && continue
            [ "$cand" = "$gateway" ] && continue
            park="$cand"
            break
        done
    else
        # A DHCP install: nothing states the gateway's subnet, so this host's is
        # the best available guess — it is the network the gateway was plugged
        # into to be flashed.
        # shellcheck disable=SC2086  # word splitting of the offset list is intended
        if gwconf_subnet_addr $GWCONF_PARK_OFFSETS; then
            park="$GWCONF_SUBNET_ADDR"
            netmask="$(gwconf_prefix2mask "$GWCONF_HOST_PREFIX")" || return 0
            gateway="${GWCONF_HOST_ROUTER:-}"
        fi
    fi

    [ -n "$park" ] && [ -n "$netmask" ] && [ -n "$gateway" ] || return 0
    printf 'IPADDR=%s\nNETMASK=%s\nGATEWAY=%s\n' "$park" "$netmask" "$gateway" \
        > "$file" 2>/dev/null || true
    return 0
}

# --- resolvers ---------------------------------------------------------------

# Each address has two entry points, for the same reason gwconf_lookup sets
# variables: a caller that wants to TELL the user where the address came from
# cannot capture it through $(...), because the source would be assigned in the
# subshell and lost.
#
#   gwconf_resolve_gateway   sets GWCONF_ADDR + GWCONF_ADDR_SOURCE, echoes nothing
#   gwconf_gateway_addr      echoes the address, for `X="${X:-$(...)}"` idioms
#
# Both always succeed — the historic constant is the floor — so the echoing form
# is safe inside an assignment under `set -e`.

# gwconf_resolve_gateway — address of an INSTALLED gateway running Linux.
gwconf_resolve_gateway() {
    local mode="" host="" ip
    GWCONF_ADDR=""; GWCONF_ADDR_SOURCE=""

    if gwconf_lookup GW_IP; then
        GWCONF_ADDR="$GWCONF_VALUE"
        GWCONF_ADDR_SOURCE="$(gwconf_label "$GWCONF_LOOKUP_FILE")"
        return 0
    fi

    gwconf_lookup GW_MODE && mode="$GWCONF_VALUE"
    gwconf_lookup GW_HOST && host="$GWCONF_VALUE"
    [ -n "$host" ] || host="$(gwconf_device_hostname)"

    # DHCP: the name is the only thing that stays true across a lease change,
    # and the device does announce it (udhcpc -x hostname: in S10network), so
    # the router that granted the lease usually resolves it. Tried first here,
    # after the last-seen address otherwise.
    if [ "$mode" = "dhcp" ] && ip="$(gwconf_resolve_host "$host")"; then
        GWCONF_ADDR="$ip"; GWCONF_ADDR_SOURCE="hostname ${host}"
        return 0
    fi

    if gwconf_lookup GW_LAST_SEEN; then
        GWCONF_ADDR="$GWCONF_VALUE"
        GWCONF_ADDR_SOURCE="last reached, $(gwconf_label "$GWCONF_LOOKUP_FILE")"
        return 0
    fi

    if ip="$(gwconf_resolve_host "$host")"; then
        GWCONF_ADDR="$ip"; GWCONF_ADDR_SOURCE="hostname ${host}"
        return 0
    fi

    # Nothing recorded, and the name does not resolve. This is a guess, not
    # knowledge — but the installer proposes host part 88 in the subnet of the
    # machine it runs on, so that is where a gateway installed from here with
    # the defaults would be. Strictly better than a constant belonging to
    # another network. "guessed" rather than "derived" in the message: for
    # BOOT_IP the derivation is prescriptive (boothold hands the address to the
    # bootloader), here it is only a hypothesis about a box we did not install.
    # shellcheck disable=SC2086  # word splitting of the offset list is intended
    if gwconf_subnet_addr $GWCONF_IP_OFFSETS; then
        GWCONF_ADDR="$GWCONF_SUBNET_ADDR"
        GWCONF_ADDR_SOURCE="guessed from ${GWCONF_HOST_IFACE} ${GWCONF_HOST_IP}/${GWCONF_HOST_PREFIX}"
        return 0
    fi

    GWCONF_ADDR="$GWCONF_FALLBACK_IP"; GWCONF_ADDR_SOURCE="built-in default"
    return 0
}

gwconf_gateway_addr() {
    gwconf_resolve_gateway
    printf '%s\n' "$GWCONF_ADDR"
}

# gwconf_resolve_boot_ip — address the gateway answers on in BOOTLOADER mode.
# Unrelated to the Linux-side address and unaffected by DHCP: the bootloader has
# no DHCP client, it is handed this address by boothold (V2.7+) or falls back to
# its compiled-in default. It must sit on this host's own L2 segment, which is
# exactly what the derivation gives.
gwconf_resolve_boot_ip() {
    GWCONF_BOOT=""; GWCONF_BOOT_SOURCE=""

    if gwconf_lookup BOOT_IP; then
        GWCONF_BOOT="$GWCONF_VALUE"
        GWCONF_BOOT_SOURCE="$(gwconf_label "$GWCONF_LOOKUP_FILE")"
        return 0
    fi
    # shellcheck disable=SC2086  # word splitting of the offset list is intended
    if gwconf_subnet_addr $GWCONF_BOOT_OFFSETS; then
        GWCONF_BOOT="$GWCONF_SUBNET_ADDR"
        GWCONF_BOOT_SOURCE="derived from ${GWCONF_HOST_IFACE} ${GWCONF_HOST_IP}/${GWCONF_HOST_PREFIX}"
        return 0
    fi
    GWCONF_BOOT="$GWCONF_FALLBACK_BOOT_IP"; GWCONF_BOOT_SOURCE="built-in default"
    return 0
}

gwconf_boot_ip() {
    gwconf_resolve_boot_ip
    printf '%s\n' "$GWCONF_BOOT"
}

# gwconf_boot_ip_is_derived — true when the last gwconf_resolve_boot_ip result
# came from the host-LAN derivation rather than from a stated value.
gwconf_boot_ip_is_derived() {
    case "${GWCONF_BOOT_SOURCE:-}" in "derived from "*) return 0 ;; *) return 1 ;; esac
}

# gwconf_cold_boot_ip — the bootloader address to use when the gateway is ALREADY
# sitting at a bootloader prompt.
#
# The distinction matters and is easy to get wrong. gwconf_boot_ip derives an
# address from this host's LAN, which is right only for the caller that then
# HANDS it to the bootloader — boothold, i.e. flash_remote.sh and the upgrade
# path of flash_install. Every other caller finds a bootloader already running,
# reached by a cold boot and a serial ESC; nothing can move it, so it is at its
# compiled default. Deriving there would send a first flash on, say, a
# 192.168.0.0/24 LAN looking for a bootloader at 192.168.0.6 that is really at
# 192.168.1.6.
#
# A stated value (flag, env, gateway.env) still wins: the user may have set the
# address by hand with IPCONFIG at the bootloader prompt.
gwconf_cold_boot_ip() {
    gwconf_resolve_boot_ip
    if gwconf_boot_ip_is_derived; then
        GWCONF_BOOT="$GWCONF_BOOTLOADER_COLD_IP"
        GWCONF_BOOT_SOURCE="bootloader's compiled default"
    fi
    printf '%s\n' "$GWCONF_BOOT"
}

# gwconf_stale_hint <source> — explain an unreachable address that this library
# chose, when it chose it from the recorded state.
#
# Changing the gateway's address by hand is a documented operation: edit
# /userdata/etc/eth0.conf, reboot, reconnect at the new address. Nothing in that
# sequence reaches back to this machine, so .gateway-state keeps pointing at the
# old address and the next argument-less command aims at a host that is no
# longer there. The failure itself is safe and already names its source, but the
# generic "cannot reach" message sends the reader looking at cables and
# bootloaders instead of at a stale record. Callers print this next to it.
gwconf_stale_hint() {
    case "${1:-}" in
        *.gateway-state|"last reached, "*) ;;
        *) return 0 ;;
    esac
    echo "  That address came from .gateway-state, written by the last install or" >&2
    echo "  the last gateway reached. If you have changed the gateway's address" >&2
    echo "  since — by editing /userdata/etc/eth0.conf, or by moving it to DHCP —" >&2
    echo "  the record is stale. Pass the address as an argument, set GW_IP in" >&2
    echo "  gateway.env, or delete .gateway-state to forget it." >&2
}

# gwconf_source_note <source> — " (X)" for a message, empty when the value was
# explicit. The source phrases are written to read on their own inside those
# parentheses ("gateway.env", "derived from eth0 10.0.0.5/24"), so nothing is
# prefixed here — "(from guessed from eth0 ...)" is what that produced.
gwconf_source_note() {
    [ -n "${1:-}" ] || return 0
    printf ' (%s)\n' "$1"
}

# gwconf_check_identity <live_hostname> — compare the gateway we just reached
# against the one we recorded. Prints a warning on mismatch and returns 1;
# returns 0 when it matches, when nothing was recorded, or when the live name
# could not be read. Never fatal on its own: a user may legitimately have
# renamed the box. It exists because a remembered address can be handed to a
# different machine by a DHCP server between two runs, and the scripts that use
# it reboot the target into its bootloader.
gwconf_check_identity() {
    local live="${1:-}" recorded=""
    [ -n "$live" ] || return 0
    gwconf_lookup GW_LAST_SEEN_HOST && recorded="$GWCONF_VALUE"
    [ -n "$recorded" ] || return 0
    [ "$live" = "$recorded" ] && return 0
    echo "Warning: this gateway calls itself '${live}', but '${recorded}' was recorded" >&2
    echo "         at this address. Check you are targeting the box you mean." >&2
    return 1
}
