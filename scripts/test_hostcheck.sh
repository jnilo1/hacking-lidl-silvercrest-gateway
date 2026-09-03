#!/bin/bash
# Non-destructive regression tests for lib/hostcheck.sh.
#
# The rejected platforms cannot be run here, so the operating system is faked
# with a `uname` stub placed ahead of the real one. That is the whole input the
# guard reads, which keeps the test honest: it exercises the same branch a Mac
# would take, not a special test mode built into the guard.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${REPO}/lib/hostcheck.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

fake_uname() { # <what uname -s should print>
    mkdir -p "$TMP/bin"
    printf '#!/bin/bash\ncase "$1" in -s) echo %s ;; *) echo %s ;; esac\n' "$1" "$1" \
        > "$TMP/bin/uname"
    chmod +x "$TMP/bin/uname"
}

# source_with <PATH> — source the guard in a fresh shell, echo its stderr,
# and return its exit status.
source_with() {
    PATH="$1" bash -c ". '$LIB'; echo REACHED-THE-END" 2>&1
}

# --- a rejected platform -----------------------------------------------------
for os in Darwin FreeBSD; do
    fake_uname "$os"
    out="$(source_with "$TMP/bin:$PATH")"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        bad "$os was allowed through (exit 0)"
    elif grep -q 'REACHED-THE-END' <<<"$out"; then
        bad "$os did not stop the caller"
    elif ! grep -q "require a Linux host" <<<"$out"; then
        bad "$os rejected without the expected message: $out"
    else
        ok "$os is refused, and the caller stops"
    fi
done

# The message has to be usable on its own: it must name the reason and a way
# out, since the person reading it cannot run anything in this repo.
fake_uname Darwin
out="$(source_with "$TMP/bin:$PATH")"
for needle in 'mkfs.jffs2' 'Raspberry Pi' 'BRIDGED' 'WSL2' 'Darwin'; do
    if grep -q -- "$needle" <<<"$out"; then
        ok "the refusal mentions ${needle}"
    else
        bad "the refusal never mentions ${needle}"
    fi
done

# --- this host ---------------------------------------------------------------
if [ "$(uname -s)" = "Linux" ]; then
    out="$(source_with "$PATH")"
    rc=$?
    if [ "$rc" -eq 0 ] && grep -q 'REACHED-THE-END' <<<"$out"; then
        ok "Linux passes through silently"
    else
        bad "Linux was refused: rc=$rc $out"
    fi
else
    ok "not running on Linux, pass-through check skipped"
fi

# --- the guard must run on the shells it rejects -----------------------------
# It prints the message for bash 3.2, so it may not itself use bash 4 syntax.
if grep -nE 'local -A|declare -A|\$\{[A-Za-z_]+(\^\^?|,,?)|readarray|mapfile|wait -n' "$LIB"; then
    bad "lib/hostcheck.sh uses bash 4 syntax and could not report to bash 3"
else
    ok "lib/hostcheck.sh is free of bash 4 syntax"
fi

printf '\npassed=%d failed=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
