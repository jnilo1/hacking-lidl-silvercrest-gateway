# lib/hostcheck.sh — refuse to run on a host that cannot complete the job.
#
# Sourced by:
#   - lib/gwconf.sh, which every host-side flash / backup script sources
#   - 3-Main-SoC-Realtek-RTL8196E/34-Userdata/build_userdata.sh, which does not
# Intentionally not executable; this file is only meant to be sourced.
#
# Why a guard rather than a port. The flash path needs mkfs.jffs2 to build the
# JFFS2 userdata image, and mtd-utils exists only on Linux — there is no macOS
# or BSD build to install. Everything else that differs (GNU `stat -c`,
# `md5sum`, `timeout`, bash 4 associative arrays) could be written portably,
# but that work would end at the same wall, so these scripts state the
# requirement instead of pretending to meet it.
#
# Why it must be loud. Without the guard the failure is not a clean stop. On
# macOS the scripts run for a while on bash 3.2 and die mid-flow at the first
# associative array; before that, size checks written as `stat -c%s ... || echo
# 0` silently report 0 for every partition, so a backup that produced no usable
# image still looks like it ran. A wrong answer that looks like an answer is
# worse than a refusal.
#
# This file is the one piece of the tree that must stay readable by the shells
# it rejects: it runs on bash 3.2, so nothing here may use bash 4 syntax.

hostcheck_require_linux() {
    local os
    os="$(uname -s 2>/dev/null || echo unknown)"

    if [ "$os" != "Linux" ]; then
        cat >&2 <<MSG
Error: these scripts require a Linux host — this one reports "${os}".

The gateway's userdata image is built with mkfs.jffs2, from mtd-utils, which
exists on Linux only. The scripts also assume GNU tool behaviour and bash 4.
On macOS in particular they do not stop cleanly: bash 3.2 fails part-way, and
some size checks report 0 bytes instead of failing, so a broken backup can
look like a finished one.

Run them from a Linux machine instead:
  - any Linux box already on the gateway's network — a Raspberry Pi is enough;
  - a Linux virtual machine whose network adapter is in BRIDGED mode. NAT does
    not work: the bootloader is reached by ARP and TFTP on the same network
    segment, which also rules out Docker Desktop on macOS and Windows;
  - on Windows, Ubuntu under WSL2.

The serial console does not have to be on that machine. Watching the boot log
from this one while another machine runs the flash is fine.
MSG
        exit 1
    fi

    # A Linux host with a pre-4.0 bash: the tools are all there, the shell is
    # not. Reported separately because the fix is different — install a current
    # bash rather than move to another machine.
    if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
        cat >&2 <<MSG
Error: these scripts require bash 4 or later — this one is ${BASH_VERSION:-unknown}.

They use associative arrays, which bash 3 does not have. Install a current
bash and run them with it.
MSG
        exit 1
    fi
}

hostcheck_require_linux
