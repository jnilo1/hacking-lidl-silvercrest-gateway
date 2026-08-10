#!/bin/bash
# test_gwconf_regression.sh — non-destructive regression tests for lib/gwconf.sh
#
# Covers the two fully automatable phases of the address-resolution test plan:
#   - the resolver's own behaviour (precedence, state round-trip, derivation on
#     simulated LANs, narrow subnets, the config-file parser);
#   - the invariant that matters most: on a 192.168.1.0/24 LAN with nothing
#     configured, every script still resolves the addresses this project has
#     always used.
#
# Touches no gateway, opens no connection, needs no root, and leaves the working
# tree clean: the unit tests point GWCONF_* at temporary files, and a fake `ip`
# on PATH simulates the LANs this host is not on. The parts of the plan that
# need real hardware (a first install, an upgrade, the on-device DHCP-failure
# fallback) are deliberately out of scope — they cannot be asserted from here.
#
# Usage:  ./scripts/test_gwconf_regression.sh [-v]
# Exit:   0 all green, 1 at least one failure.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${REPO}/lib/gwconf.sh"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

[ -f "$LIB" ] || { echo "Error: $LIB not found." >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; SKIP=0

ck() { # ck <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
        [ "$VERBOSE" -eq 1 ] && printf '  ok   %-44s %s\n' "$1" "$3"
        return 0
    fi
    FAIL=$((FAIL + 1))
    printf '  FAIL %-44s got=[%s] want=[%s]\n' "$1" "$3" "$2"
}
skip() { SKIP=$((SKIP + 1)); printf '  skip %-44s %s\n' "$1" "$2"; }
section() { printf '\n%s\n' "$1"; }

# --- harness plumbing --------------------------------------------------------

# fake_ip <router> <iface> <cidr> — a stand-in for the `ip` command, so the
# derivation can be exercised against subnets this host is not attached to.
# Anything it does not answer is handed to the real binary.
REAL_IP="$(command -v ip || true)"
fake_ip() {
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/ip" <<EOF
#!/bin/bash
case "\$*" in
  "-4 route show default") echo "default via $1 dev $2 proto dhcp metric 100" ;;
  "-o -4 addr show dev $2 scope global") echo "2: $2    inet $3 brd x scope global $2" ;;
  *) [ -n "$REAL_IP" ] && exec "$REAL_IP" "\$@" || exit 1 ;;
esac
EOF
    chmod +x "$TMP/bin/ip"
}
no_ip() {                       # a host with no usable IPv4 default route
    mkdir -p "$TMP/bin"
    printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/ip"
    chmod +x "$TMP/bin/ip"
}

# lib <body> — run <body> in a fresh shell with the library sourced and the
# config paths isolated from the user's real ones.
lib() {
    env -i PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/home" \
        GWCONF_FILE="$TMP/gateway.env" \
        GWCONF_USER_FILE="$TMP/home/.config/rtl8196e-gateway/gateway.env" \
        GWCONF_STATE_FILE="$TMP/.gateway-state" \
        bash -c "set -euo pipefail; . '$LIB'; $1"
}

# addr_on_line <pattern> — read text on stdin, print the first dotted-quad found
# on the first line matching the anchored <pattern>. Anchored because a bare
# "--linux-ip" also matches the Usage line, and written in awk because
# /usr/bin/grep is ugrep on this workstation.
addr_on_line() {
    awk -v pat="$1" '
        $0 ~ pat {
            for (i = 1; i <= NF; i++) {
                tok = $i
                gsub(/[(),\[\]]/, "", tok)
                if (tok ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print tok; exit }
            }
        }'
}

# script <script-path> <args...> — run a repo script with its config isolated,
# so its resolved defaults do not depend on the user's gateway.env.
script_isolated() {
    env PATH="$TMP/bin:$PATH" \
        GWCONF_FILE="$TMP/absent.env" \
        GWCONF_USER_FILE="$TMP/absent-user.env" \
        GWCONF_STATE_FILE="$TMP/absent.state" \
        "$@"
}

# Snapshot of the working tree, so section 11 can prove the suite changed nothing
# rather than demanding a clean checkout.
TREE_BEFORE="$(cd "$REPO" && git status --porcelain --untracked-files=no 2>/dev/null)"

echo "========================================="
echo "  gwconf regression tests"
echo "========================================="
echo "  repo: $REPO"

# --- 1. resolution precedence ------------------------------------------------

section "1. Precedence between the three config files"
fake_ip 10.0.5.1 eth9 10.0.5.77/24
: > "$TMP/.gateway-state"
printf 'GW_IP=10.0.5.11\n' > "$TMP/gateway.env"
printf 'GW_IP=10.0.5.99\n' > "$TMP/.gateway-state"
ck "gateway.env wins"        "10.0.5.11"   "$(lib 'gwconf_resolve_gateway; echo $GWCONF_ADDR')"
ck "  source reported"       "gateway.env" "$(lib 'gwconf_resolve_gateway; echo $GWCONF_ADDR_SOURCE')"
: > "$TMP/gateway.env"
ck "falls to .gateway-state" "10.0.5.99"      "$(lib 'gwconf_resolve_gateway; echo $GWCONF_ADDR')"
ck "  source reported"       ".gateway-state" "$(lib 'gwconf_resolve_gateway; echo $GWCONF_ADDR_SOURCE')"
printf 'GW_MODE=dhcp\nGW_LAST_SEEN=10.0.5.42\nGW_HOST=nope.invalid\n' > "$TMP/.gateway-state"
ck "dhcp: last address seen" "10.0.5.42" "$(lib 'gwconf_resolve_gateway; echo $GWCONF_ADDR')"
ck "  source reported"       "last reached, .gateway-state" \
                             "$(lib 'gwconf_resolve_gateway; echo $GWCONF_ADDR_SOURCE')"

# --- 2. derivation from the host's LAN ---------------------------------------

section "2. Derivation from the host's own LAN"
: > "$TMP/.gateway-state"
ck "suggested address"  "10.0.5.88"     "$(lib 'gwconf_suggest_static; echo $GWCONF_SUGGEST_IPADDR')"
ck "suggested netmask"  "255.255.255.0" "$(lib 'gwconf_suggest_static; echo $GWCONF_SUGGEST_NETMASK')"
ck "suggested gateway"  "10.0.5.1"      "$(lib 'gwconf_suggest_static; echo $GWCONF_SUGGEST_GATEWAY')"
ck "bootloader address" "10.0.5.6"      "$(lib 'gwconf_resolve_boot_ip; echo $GWCONF_BOOT')"
ck "source names iface" "derived from eth9 10.0.5.77/24" \
                        "$(lib 'gwconf_suggest_static; echo $GWCONF_SUGGEST_SOURCE')"
ck "unknown box guessed" "guessed from eth9 10.0.5.77/24" \
                        "$(lib 'gwconf_resolve_gateway; echo $GWCONF_ADDR_SOURCE')"

fake_ip 10.0.5.1 eth9 10.0.5.88/24
ck "skips the host itself" "10.0.5.200" "$(lib 'gwconf_suggest_static; echo $GWCONF_SUGGEST_IPADDR')"
fake_ip 10.0.5.6 eth9 10.0.5.77/24
ck "skips the router"      "10.0.5.5"   "$(lib 'gwconf_resolve_boot_ip; echo $GWCONF_BOOT')"

section "3. Subnets too narrow for the preferred host parts"
fake_ip 192.168.4.65 eth9 192.168.4.70/26          # 192.168.4.64/26 -> .65-.126
ck "/26 netmask"        "255.255.255.192" "$(lib 'gwconf_suggest_static; echo $GWCONF_SUGGEST_NETMASK')"
ck "/26 stays in net"   "192.168.4.114"   "$(lib 'gwconf_suggest_static; echo $GWCONF_SUGGEST_IPADDR')"
ck "/26 boot address"   "192.168.4.69"    "$(lib 'gwconf_resolve_boot_ip; echo $GWCONF_BOOT')"
fake_ip 10.9.9.1 eth9 10.9.9.1/30                  # only .1 and .2 are usable
ck "/30 last usable"    "10.9.9.2"        "$(lib 'gwconf_suggest_static; echo $GWCONF_SUGGEST_IPADDR')"

section "4. No usable LAN at all — the historic constants"
no_ip
ck "address"  "192.168.1.88"    "$(lib 'gwconf_suggest_static; echo $GWCONF_SUGGEST_IPADDR')"
ck "netmask"  "255.255.255.0"   "$(lib 'gwconf_suggest_static; echo $GWCONF_SUGGEST_NETMASK')"
ck "gateway"  "192.168.1.1"     "$(lib 'gwconf_suggest_static; echo $GWCONF_SUGGEST_GATEWAY')"
ck "boot"     "192.168.1.6"     "$(lib 'gwconf_resolve_boot_ip; echo $GWCONF_BOOT')"
ck "source"   "built-in default" "$(lib 'gwconf_suggest_static; echo $GWCONF_SUGGEST_SOURCE')"

# --- 5. state file -----------------------------------------------------------

section "5. State written at install time, read back afterwards"
fake_ip 10.0.5.1 eth9 10.0.5.77/24
: > "$TMP/.gateway-state"
lib 'gwconf_record_install static 10.0.5.30 255.255.255.0 10.0.5.1' >/dev/null
ck "GW_IP recorded"    "10.0.5.30"   "$(lib 'gwconf_lookup GW_IP && echo $GWCONF_VALUE')"
ck "GW_MODE recorded"  "static"      "$(lib 'gwconf_lookup GW_MODE && echo $GWCONF_VALUE')"
ck "GW_HOST recorded"  "rtl8196e-gw" "$(lib 'gwconf_lookup GW_HOST && echo $GWCONF_VALUE')"
ck "resolves to it"    "10.0.5.30"   "$(lib 'gwconf_resolve_gateway; echo $GWCONF_ADDR')"
lib 'gwconf_record_install dhcp' >/dev/null
ck "dhcp clears GW_IP" ""     "$(lib 'gwconf_lookup GW_IP && echo $GWCONF_VALUE || true')"
ck "dhcp mode kept"    "dhcp" "$(lib 'gwconf_lookup GW_MODE && echo $GWCONF_VALUE')"
lib 'gwconf_record_seen 10.0.5.31 mybox' >/dev/null
ck "last seen merged"  "10.0.5.31" "$(lib 'gwconf_lookup GW_LAST_SEEN && echo $GWCONF_VALUE')"
ck "other keys kept"   "dhcp"      "$(lib 'gwconf_lookup GW_MODE && echo $GWCONF_VALUE')"
ck "identity match"    "0" "$(lib 'rc=0; gwconf_check_identity mybox    >/dev/null 2>&1 || rc=$?; echo $rc')"
ck "identity mismatch" "1" "$(lib 'rc=0; gwconf_check_identity otherbox >/dev/null 2>&1 || rc=$?; echo $rc')"

# --- 6. the device's DHCP-failure fallback -----------------------------------

section "6. eth0.bak — the fallback written for the device"
bak="$TMP/eth0.bak"
lib "gwconf_write_eth0_bak '$bak' 10.0.5.30 255.255.255.0 10.0.5.1"
ck "static: same subnet" "IPADDR=10.0.5.254 NETMASK=255.255.255.0 GATEWAY=10.0.5.1" \
                         "$(tr '\n' ' ' < "$bak" | sed 's/ $//')"
lib "gwconf_write_eth0_bak '$bak' 192.168.4.100 255.255.255.192 192.168.4.65"
ck "narrow subnet"       "IPADDR=192.168.4.126 NETMASK=255.255.255.192 GATEWAY=192.168.4.65" \
                         "$(tr '\n' ' ' < "$bak" | sed 's/ $//')"
lib "gwconf_write_eth0_bak '$bak' 10.0.5.254 255.255.255.0 10.0.5.1"
ck "avoids the gw addr"  "IPADDR=10.0.5.253 NETMASK=255.255.255.0 GATEWAY=10.0.5.1" \
                         "$(tr '\n' ' ' < "$bak" | sed 's/ $//')"
lib "gwconf_write_eth0_bak '$bak'"
ck "dhcp: from host LAN" "IPADDR=10.0.5.254 NETMASK=255.255.255.0 GATEWAY=10.0.5.1" \
                         "$(tr '\n' ' ' < "$bak" | sed 's/ $//')"
printf 'UNTOUCHED\n' > "$bak"
lib "gwconf_write_eth0_bak '$bak' 10.0.5.30 255.0.255.0 10.0.5.1"
ck "bad netmask: no write" "UNTOUCHED" "$(cat "$bak")"

# The same conversion runs on the device, in BusyBox ash. Check it there when a
# busybox binary is available rather than trusting bash to stand in for it.
section "7. Device-side netmask conversion (BusyBox ash)"
cat > "$TMP/mask2cidr.sh" <<'EOF'
mask2cidr() {
    n=0; OIFS="$IFS"; IFS='.'
    for oct in $1; do
        while [ "$oct" -gt 0 ]; do n=$((n + (oct & 1))); oct=$((oct >> 1)); done
    done
    IFS="$OIFS"; echo "$n"
}
printf '%s %s %s ' "$(mask2cidr 255.255.255.0)" "$(mask2cidr 255.255.255.192)" "$(mask2cidr 255.0.0.0)"
echo "$(echo a b c)"
EOF
if command -v busybox >/dev/null 2>&1; then
    ck "24/26/8 + IFS restored" "24 26 8 a b c" "$(busybox ash "$TMP/mask2cidr.sh")"
else
    skip "busybox ash" "busybox not installed on this host"
fi
# And it must match what the host-side library computes for the same masks.
ck "host lib agrees on /24" "24" "$(lib 'gwconf_mask2prefix 255.255.255.0')"
ck "host lib agrees on /26" "26" "$(lib 'gwconf_mask2prefix 255.255.255.192')"
ck "non-contiguous refused" "1"  "$(lib 'rc=0; gwconf_mask2prefix 255.0.255.0 >/dev/null || rc=$?; echo $rc')"

# --- 8. config files are data, not code --------------------------------------

section "8. Config files are parsed, never sourced"
printf '# comment\n\n  GW_IP  =  "10.1.2.3"  \nJUNK\nGW_HOST=box\r\n' > "$TMP/gateway.env"
: > "$TMP/.gateway-state"
ck "quotes and spaces" "10.1.2.3" "$(lib 'gwconf_lookup GW_IP && echo $GWCONF_VALUE')"
ck "CRLF tolerated"    "box"      "$(lib 'gwconf_lookup GW_HOST && echo $GWCONF_VALUE')"
ck "absent key -> 1"   "1"        "$(lib 'rc=0; gwconf_lookup NOPE >/dev/null || rc=$?; echo $rc')"
printf 'GW_IP=10.1.2.4\nevil=$(touch %s/PWNED)\n' "$TMP" > "$TMP/gateway.env"
lib 'gwconf_resolve_gateway; echo $GWCONF_ADDR' >/dev/null
ck "no command executed" "absent" "$([ -e "$TMP/PWNED" ] && echo present || echo absent)"
: > "$TMP/gateway.env"

# --- 9. the scripts agree with the library -----------------------------------

section "9. Scripts resolve what the library resolves"
fake_ip 10.42.0.1 fake0 10.42.0.77/24
# The Linux-side address is derived; the bootloader address is a separate rule,
# checked in 9b.
out="$(script_isolated "${REPO}/backup_gateway.sh" --help 2>&1)"
ck "backup_gateway linux-ip" "10.42.0.88" \
   "$(printf '%s\n' "$out" | addr_on_line '^[[:space:]]*--linux-ip')"

# gateway.env must override every one of them.
printf 'GW_IP=172.16.9.5\nBOOT_IP=172.16.9.6\n' > "$TMP/pinned.env"
out="$(env PATH="$TMP/bin:$PATH" GWCONF_FILE="$TMP/pinned.env" \
      GWCONF_USER_FILE="$TMP/absent-user.env" GWCONF_STATE_FILE="$TMP/absent.state" \
      "${REPO}/backup_gateway.sh" --help 2>&1)"
ck "gateway.env overrides" "172.16.9.5" \
   "$(printf '%s\n' "$out" | addr_on_line '^[[:space:]]*--linux-ip')"

# --- 9b. cold bootloader vs boothold ------------------------------------------
# The subtlest invariant in the whole change. Deriving the bootloader address is
# right ONLY for the caller that then hands it over via boothold. A gateway
# already sitting at a bootloader prompt is at its compiled address, so a first
# flash from a 10.42.0.0/24 host must still look for it at 192.168.1.6.

section "9b. Bootloader address: derived only where boothold applies"
fake_ip 10.42.0.1 fake0 10.42.0.77/24
ck "cold boot: not derived"   "192.168.1.6" "$(lib 'gwconf_cold_boot_ip')"
ck "boothold: derived"        "10.42.0.6"   "$(lib 'gwconf_boot_ip')"
ck "restore_gateway (cold)"   "192.168.1.6" \
   "$(script_isolated "${REPO}/restore_gateway.sh" --help 2>&1 | addr_on_line '^[[:space:]]*--boot-ip')"
ck "backup_gateway (cold)"    "192.168.1.6" \
   "$(script_isolated "${REPO}/backup_gateway.sh" --help 2>&1 | addr_on_line '^[[:space:]]*--boot-ip')"
ck "flash_install (1st flash)" "192.168.1.6" \
   "$(script_isolated "${REPO}/flash_install_rtl8196e.sh" --help 2>&1 | addr_on_line '^Environment: BOOT_IP')"
ck "flash_remote (boothold)"  "10.42.0.6" \
   "$(script_isolated "${REPO}/3-Main-SoC-Realtek-RTL8196E/flash_remote.sh" --help 2>&1 \
      | addr_on_line '^Environment: BOOT_IP')"

# A stated address wins on both sides — the user may have set it with IPCONFIG.
printf 'BOOT_IP=10.42.0.9\n' > "$TMP/gateway.env"
ck "stated wins, cold"     "10.42.0.9" "$(lib 'gwconf_cold_boot_ip')"
ck "stated wins, boothold" "10.42.0.9" "$(lib 'gwconf_boot_ip')"
: > "$TMP/gateway.env"

# --- 10. the invariant: nothing changed on the historic subnet ---------------

section "10. Non-regression on this host's real LAN"
rm -f "$TMP/bin/ip"                       # back to the real `ip`
host_cidr="$(ip -o -4 addr show dev "$(ip -4 route show default 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')" scope global 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="inet"){print $(i+1); exit}}')"
if [ -z "${host_cidr:-}" ]; then
    skip "real-LAN checks" "this host has no IPv4 default route"
else
    echo "  (this host: ${host_cidr})"
    out="$(script_isolated "${REPO}/backup_gateway.sh" --help 2>&1)"
    got_linux="$(printf '%s\n' "$out" | addr_on_line '^[[:space:]]*--linux-ip')"
    got_boot="$(printf '%s\n' "$out" | addr_on_line '^[[:space:]]*--boot-ip')"
    case "$host_cidr" in
        192.168.1.*/24)
            # The case that must be byte-identical to every release before this
            # change: the addresses this project has always used.
            ck "linux-ip unchanged" "192.168.1.88" "$got_linux"
            ck "boot-ip unchanged"  "192.168.1.6"  "$got_boot"
            ;;
        *)
            # Elsewhere, assert the derivation instead: same subnet as this host.
            want_net="${host_cidr%.*}"; want_net="${want_net%/*}"
            ck "linux-ip in host subnet" "${want_net}.88" "$got_linux"
            ck "boot-ip in host subnet"  "${want_net}.6"  "$got_boot"
            echo "  note: this host is not on 192.168.1.0/24, so the historic-value"
            echo "        invariant could not be checked here."
            ;;
    esac
fi

# --- 11. the tests left the tree alone ---------------------------------------

section "11. Repository hygiene"
# Compare against the snapshot taken before the first test, not against a clean
# tree: the point is that the suite itself writes nothing into the repository,
# which must hold just as well when a developer has edits in flight.
ck "suite modified no tracked file" "$TREE_BEFORE" \
   "$(cd "$REPO" && git status --porcelain --untracked-files=no 2>/dev/null)"
for f in gateway.env .gateway-state 2-Zigbee-Radio-Silabs-EFR32/26-OT-RCP/docker/.env; do
    ck "gitignored: $f" "ignored" \
       "$(cd "$REPO" && git check-ignore -q "$f" && echo ignored || echo TRACKED)"
done

# --- summary -----------------------------------------------------------------

echo ""
echo "========================================="
printf '  passed=%d  failed=%d  skipped=%d\n' "$PASS" "$FAIL" "$SKIP"
echo "========================================="
if [ "$FAIL" -eq 0 ]; then
    echo "  Phases 0 and 5 of the test plan are green."
    echo "  Still requiring hardware: first install (profile A), upgrade"
    echo "  (profile B), and the on-device DHCP-failure fallback."
fi
[ "$FAIL" -eq 0 ]
