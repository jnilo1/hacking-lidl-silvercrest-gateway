# Changelog — Build Environment & Toolchain (RTL8196E Gateway)

All notable changes to the build environment and the Lexra MIPS cross-toolchain
are documented here. This covers `1-Build-Environment/` in its entirety:
`install_deps.sh`, `Dockerfile`, the `10-lexra-toolchain/` crosstool-NG driver,
the Realtek tools in `11-realtek-tools/`, and the Silabs tools installer in
`12-silabs-toolchain/`.

Toolchain component versions at each release:

| Release | crosstool-NG | binutils | GCC | musl | Linux headers |
|---------|--------------|----------|-----|------|---------------|
| v0 (2026-03-21) | — | — | — | — | — |
| v1.0.0 | 1.26.0 | 2.34 | 8.5.0 | 1.2.5 | 5.10.240 |
| v2.0.0 | 1.26.0 | 2.34 | 8.5.0 | 1.2.5 | 5.10.240 |
| v2.1.6 | 1.26.0 | 2.34 | 8.5.0 | 1.2.5 | 5.10.240 |
| **v3.0.0** | **1.28.0** | **2.45.1** | **15.2.0** | **1.2.6** | **6.16** |

v0 was a teardown-and-docs-only snapshot — no toolchain in the tree yet. The
toolchain entered the repository at v1.0.0 and was frozen on the GCC 8 /
binutils 2.34 / musl 1.2.5 line through the entire v1.x and v2.x series.

---

## [4.0.0] - 2026-08-10

_Toolchain unchanged since 3.0.0 (crosstool-NG 1.28.0, binutils 2.45.1, GCC
15.2.0, musl 1.2.6, Linux headers 6.16). One host dependency drops out._

### `xxd` dropped from the host dependencies (issue #147)

`install_deps.sh` and the `Dockerfile` no longer install `xxd`. Its only consumers were
`build_fullflash.sh` and `create_fullflash.sh`, which read the partition magic bytes back
out of the assembled image; both now use `od` (coreutils) instead, so nothing in the tree
invokes `xxd` any more. Reported by @hlyi, who hit the flip side of this on a fresh Debian
host: `xxd` is not installed by default there, and the flash scripts died on it. Details
in the RTL8196E changelog.

---

## [3.0.0] - 2026-04-16

### Toolchain — Alpine edge rebase (binutils 2.45.1, GCC 15.2.0, musl 1.2.6)

The toolchain has been rebased onto **Alpine Linux edge** for the three
generic components. The move jumps GCC across seven major releases
(8 → 15) and carries roughly eleven years of upstream work, including the
C++17/20/23 frontends, all current security hardening defaults, and Modern
MIPS codegen fixes that were never backported to GCC 8.

#### Why Alpine, not stock upstream

Two concrete reasons:

1. **musl is a first-class citizen in Alpine.** Every patch shipped by
   Alpine for GCC, binutils, and musl has been tested end-to-end on a
   musl-based system. Stock upstream patches often assume glibc and leak
   glibc-only idioms into the build (e.g. `libssp_nonshared.a`, fortify
   headers paths, static PIE relocations). Alpine has already done the
   work to make these components behave correctly on musl — reusing their
   patch set eliminates a whole class of subtle runtime bugs that don't
   surface until `ld-musl.so` actually loads a binary.

2. **Security hardening is on-by-default.** Alpine's GCC patch set turns
   on `-D_FORTIFY_SOURCE=2`, `-Wl,-z,now`, `-Wformat -Wformat-security`,
   `-Wtrampolines`, and static-PIE support **out of the box**. These are
   the same defaults Alpine ships to production, curated by a team that
   runs them under attack every day. Replicating them from stock GCC
   would require porting ~15 patches individually; inheriting Alpine's
   tree gives them for free, with the same review trail.

The Lexra / RTL8196E delta stays a **small local patch** on top of the
Alpine-patched source, so upstream security fixes can be pulled in by
bumping Alpine without re-auditing the local patches.

#### Component details

| Component | v2.x → v3.0 | Notes |
|-----------|-------------|-------|
| binutils | 2.34 → **2.45.1** | +11 years of MIPS/ELF work. 2 Alpine patches + 1 local (81 lines). |
| GCC | 8.5.0 → **15.2.0** | +7 major releases. 24 Alpine patches + 1 local (198 lines). |
| musl | 1.2.5 → **1.2.6** | Minor bump. 5 Alpine patches (incl. 2 CVE fixes) + 1 local (324 lines). |
| Linux headers | 5.10.240 → **6.16** | Aligns with the production kernel 6.18 on the gateway. |
| crosstool-NG | 1.26.0 → **1.28.0** | First ct-ng version to support GCC 15.x. |

#### Patch stack reorganisation

- **`CT_PATCH_ORDER="local"`** — crosstool-NG's bundled patches are now
  bypassed entirely. The patch stack is strictly Alpine → local Lexra,
  which removes an entire reconciliation axis (no more "does the ct-ng
  bundled patch conflict with the Alpine patch?" decisions on every
  version bump).
- **Alpine patches imported verbatim**, numbered `001-alpine-*` through
  `024-alpine-*`. Gateway-specific filters applied: arch-specific
  (aarch64/s390x/ppc/x86_64/riscv/loongarch) and language-specific
  (Ada/D/Go/phobos) patches were dropped since we're MIPS-only, C-only.
- **Local Lexra patches renumbered** to `600-Lexra.patch` (binutils),
  `970-Lexra.patch` (GCC), `900-Lexra.patch` (musl). All three were
  regenerated from scratch against the Alpine-patched source via
  `diff -urN`, replacing the fragile manually-edited hunks that had
  drifted across seven major GCC releases.

#### Lexra support preserved

The local patches retain everything that makes the Lexra LX4380 work:

- **binutils**: `bfd_mach_mips_lx4380/5280/5380` machine numbers,
  `PROCESSOR_LX*` entries in `bfd/cpu-mips.c`, `gas/config/tc-mips.c`,
  and `include/opcode/mips.h`.
- **GCC**: `-march=lx4380/lx5280/lx5380` recognition, `TARGET_LEXRA` /
  `TARGET_LX*` macros, `__mlexra` / `__mlx4380` / `__mlx5380` builtin
  defines (consumed by musl's atomics and pthread_arch), `TUNE_MIPS3000`
  scheduling for the R3000-like core, `ISA_HAS_SYNC` / `ISA_HAS_LL_SC`
  for LX5380, `ISA_HAS_CONDMOVE` extension, soft-float defaulting for
  `march=lx*`, disabled `lwl/lwr/swl/swr` patterns for LX5280 (which
  lacks these instructions), `flag_fix_bdsl` / `-mno-bdsl` option for
  branch delay slot correctness, `can_delay` attribute adjusted to
  honour `flag_fix_bdsl`.
- **musl**: atomic operation workarounds for LX4380/LX5380, LX4380
  branch-delay-slot NOP padding in assembly, LX5380 `mflxc0`-based thread
  pointer access, VDSO disabled for LX4380, `.note.GNU-stack` markers
  added to all MIPS assembly files (required by newer linkers).

#### x-tools minimisation

The final toolchain payload has been aggressively trimmed. Each component
was kept only if it has a real consumer in the repo's build graph.

**Debug facilities — all dropped:**

| Component | Why dropped |
|-----------|-------------|
| GDB (`CT_DEBUG_GDB=n`) | Gateway debugging uses serial console, ssh, and target-side `strace`. No use for a cross-GDB. |
| DUMA (`CT_DEBUG_DUMA=n`) | Debug malloc allocator. Not used by any build in the repo. |
| strace (`CT_DEBUG_STRACE=n`) | If needed on-target, BusyBox can be rebuilt with its own strace applet — no need to ship a separate binary from the toolchain. |
| ltrace (`CT_DEBUG_LTRACE=n`) | Already off; kept off. |

**Companion libraries — unused ones dropped:**

| Component | Why dropped |
|-----------|-------------|
| expat (`CT_COMP_LIBS_EXPAT=n`) | Was only a GDB dependency. GDB is gone. |
| gettext (`CT_COMP_LIBS_GETTEXT=n`) | NLS is disabled (`CT_TOOLCHAIN_ENABLE_NLS=n`). Nothing consumes it. |
| ncurses (`CT_COMP_LIBS_NCURSES=n`) | Was only a GDB dependency. The gateway's `nano` userspace app builds its **own** ncursesw-6.6 via `34-Userdata/nano/build_ncursesw.sh`, independent of the toolchain. |

**Companion libraries — kept:**

| Component | Why kept |
|-----------|----------|
| gmp, mpfr, mpc, isl | Direct GCC build dependencies (arbitrary-precision math). |
| zlib, zstd | GCC LTO and binutils debug-compression support. |
| libiconv | Used by GCC for source-code encoding conversion and by binutils BFD for ELF string translation. On a glibc host it could fall back to system iconv, but keeping libiconv in the toolchain makes the cross-compiler more portable. |

**Language frontends — C/C++ only:**

| Frontend | Status |
|----------|--------|
| C | Always on. |
| C++ | Kept on (`CT_CC_LANG_CXX=y`). `zigbeed`, `otbr-agent`, and other target userspace apps need it. |
| Fortran, Ada, D, Objective-C, Go | Off. |

### Environment — crosstool-NG 1.28.0

- **Dockerfile** and **install_deps.sh** both updated to install
  crosstool-NG 1.28.0 (up from 1.26.0). 1.28.0 is the first ct-ng
  release with a GCC 15.x option.
- Build orchestration otherwise unchanged — same two entry points
  (native via `install_deps.sh`, Docker via `Dockerfile`), same
  `x-tools/mips-lexra-linux-musl/` output layout, same auto-detection
  from downstream build scripts.

### Documentation

- `CLAUDE.md` and `README.md` version tables refreshed to reflect the
  new toolchain components.
- `CLAUDE.md` now documents that kernel headers in ct-ng are pinned to
  6.16 (the latest in ct-ng 1.28.0), while the gateway itself runs
  Linux 6.18 — the ABI gap is immaterial for cross-compilation.
- `TOOLCHAIN_UPDATE.md`, the specification that drove the Alpine rebase,
  now lives in `10-lexra-toolchain/` next to the patches, configuration
  and build script it governs.

---

## [2.x series] — 2026 Q1 to Q2

No changes to the toolchain across the entire v2 line. The Silabs-tools
installer (`12-silabs-toolchain/`) and Realtek-tools builder
(`11-realtek-tools/`) evolved in lockstep with the EFR32 and RTL8196E
chapters, but the Lexra MIPS cross-toolchain was frozen on:

- crosstool-NG 1.26.0
- binutils 2.34
- GCC 8.5.0
- musl 1.2.5
- Linux headers 5.10.240

See the top-level repository `CHANGELOG.md` entries for the individual
v2.0, v2.0.1, v2.1.0 … v2.1.6 releases.

---

## [1.0.0] — First release

Introduced the Lexra MIPS cross-toolchain into the repository. Before
v1.0.0 (tagged as `v0`), the repo was teardown and documentation only —
no build environment, no toolchain.

Baseline toolchain components established at v1.0.0:

- **crosstool-NG 1.26.0** as the build orchestrator.
- **binutils 2.34** with a single local Lexra patch (`600-Lexra.patch`)
  adding `lx4380/lx5280/lx5380` CPU recognition and the Lexra-specific
  opcodes (`madh`, `madl`, `mazh`, `mazl`, `sllv2`, ...).
- **GCC 8.5.0** with a local Lexra patch (`970-Lexra.patch`) covering
  `-march=lx*`, `TARGET_LEXRA`, branch-delay-slot handling, and disabled
  unaligned load/store patterns for LX5280.
- **musl 1.2.5** with a local Lexra patch (`910-lexra.patch`) providing
  atomic, crt, pthread_arch, and assembly workarounds for the LX4380/5380.
- **Linux 5.10.240** kernel headers, tracking the production kernel line.

Environment entry points:
- `install_deps.sh` — native Ubuntu / WSL2 path.
- `Dockerfile` — reproducible Ubuntu 22.04 image.
- Both landed on the same `x-tools/mips-lexra-linux-musl/` layout so
  downstream scripts would not need to care which path was taken.
