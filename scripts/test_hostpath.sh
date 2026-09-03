#!/bin/bash
# Non-destructive regression tests for lib/hostpath.sh.
#
# Each case sources the library in a fresh shell with a hand-built PATH, so the
# result never depends on the PATH policy of the distribution running the test —
# which is the very thing the library exists to normalise.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${REPO}/lib/hostpath.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# path_from <initial PATH> [statement run after the first source] — echo PATH
# once the library has been sourced, starting from exactly <initial PATH> and
# nothing inherited from this shell.
path_from() {
    env -i PATH="$1" bash -c ". '$LIB'; ${2:-:}; printf '%s' \"\$PATH\""
}

has_dir() { # <path> <dir>
    case ":$1:" in *":$2:"*) return 0 ;; esac
    return 1
}
count_dir() { # <path> <dir>
    tr ':' '\n' <<<"$1" | grep -cx -- "$2"
}

# A Debian non-root login PATH: /etc/profile gives the sbin directories to
# uid 0 only, so an ordinary user starts without them.
DEBIAN_PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games"

result="$(path_from "$DEBIAN_PATH")"
for dir in /usr/sbin /sbin; do
    if [ ! -d "$dir" ]; then
        ok "$dir absent from this host, nothing to add"
    elif has_dir "$result" "$dir"; then
        ok "$dir added to a Debian non-root PATH"
    else
        bad "$dir missing from [$result]"
    fi
done

# The tool that motivated the library must actually resolve afterwards — but
# only assert it where mtd-utils is installed, so the test stays meaningful on
# a host that does not have it.
if [ ! -x /usr/sbin/mkfs.jffs2 ]; then
    ok "mtd-utils not installed here, resolution check skipped"
elif env -i PATH="$(path_from "$DEBIAN_PATH")" \
        bash -c "command -v mkfs.jffs2 >/dev/null"; then
    ok "mkfs.jffs2 resolves from a Debian non-root PATH"
else
    bad "mkfs.jffs2 still unresolvable after sourcing"
fi

# Appended, never prepended: whatever the user put first keeps winning.
result="$(path_from "/opt/shim/bin:$DEBIAN_PATH")"
if [ "${result%%:*}" = "/opt/shim/bin" ]; then
    ok "an earlier PATH entry keeps its precedence"
else
    bad "PATH order disturbed: [$result]"
fi

# Idempotent: a directory already on PATH is neither moved nor duplicated,
# including when the library is sourced twice — a script and a script it calls
# both source it, and the child inherits the parent's exported PATH.
result="$(path_from "/usr/sbin:/usr/bin:/bin" ". '$LIB'")"
if [ -d /usr/sbin ] && [ "$(count_dir "$result" /usr/sbin)" -ne 1 ]; then
    bad "/usr/sbin duplicated: [$result]"
elif [ "${result%%:*}" != "/usr/sbin" ]; then
    bad "/usr/sbin moved from the front: [$result]"
else
    ok "an sbin directory already on PATH is left alone"
fi

# Nothing that does not exist is ever added — checked on what the library
# appended, not on the whole PATH, which carries entries it never chose.
result="$(path_from "$DEBIAN_PATH")"
missing=""
while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    has_dir "$DEBIAN_PATH" "$dir" && continue
    [ -d "$dir" ] || missing="${missing} ${dir}"
done < <(tr ':' '\n' <<<"$result")
if [ -z "$missing" ]; then
    ok "every directory the library appended exists"
else
    bad "non-existent directories added:${missing}"
fi

printf '\npassed=%d failed=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
