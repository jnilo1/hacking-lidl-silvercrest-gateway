# lib/hostpath.sh — make the sbin directories searchable for this process.
#
# Sourced by:
#   - flash_install_rtl8196e.sh, whose prerequisite check probes mkfs.jffs2
#   - 3-Main-SoC-Realtek-RTL8196E/34-Userdata/build_userdata.sh, which runs it
# Intentionally not executable; this file is only meant to be sourced.
#
# mkfs.jffs2 (mtd-utils) builds the JFFS2 userdata image, and the package
# installs it in /usr/sbin. Whether /usr/sbin is on a non-root user's PATH is
# distribution policy, not a property of the installed package: Ubuntu ships
# /etc/environment with a PATH carrying the sbin directories, which PAM applies
# to every user, while Debian leaves that file empty and hands the sbin
# directories to uid 0 only. An ordinary user there has mtd-utils correctly
# installed and still no mkfs.jffs2 on PATH — and the prerequisite check then
# reports a missing package, which is actionable but blames the wrong thing.
# The same gap opens on any distribution outside a login shell: cron, systemd
# units, minimal containers, `su` without `-`.
#
# So add the directories rather than assume them. Appended, never prepended: a
# tool the user deliberately put earlier on PATH must keep winning.
#
# mkfs.jffs2 is currently the only host tool this repo needs that lives solely
# in an sbin directory. `ip` is not one: iproute2 installs the real binary as
# /bin/ip and leaves /sbin/ip a compatibility symlink.

hostpath_add_sbin() {
    local dir
    for dir in /usr/local/sbin /usr/sbin /sbin; do
        [ -d "$dir" ] || continue
        case ":${PATH}:" in
            *":${dir}:"*) ;;
            *) PATH="${PATH}:${dir}" ;;
        esac
    done
    export PATH
}

hostpath_add_sbin
