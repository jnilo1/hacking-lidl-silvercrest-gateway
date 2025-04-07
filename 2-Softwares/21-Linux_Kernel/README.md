## Linux Kernel

The original Lidl/Gateway device uses Linux kernel version 3.10.90. At some
point, I’m considering attempting an upgrade to kernel 5.10 LTS, built on a
Debian Bullseye distribution. This is a significant challenge, as it
requires updating and patching `binutils`, `GCC`, and `uClibc` (or `musl`)
to accommodate the very peculiar RTL8196E chip.

I cannot guarantee success — but I’d gladly welcome help from Linux kernel
aficionados!

______________________________________________________________________

### Summary: Challenges in Updating the Toolchain and Building Linux Kernel 5 for Realtek RTL8196E

Updating the toolchain and compiling a recent Linux kernel (such as 5.10)
for the Realtek RTL8196E SoC involves several technical hurdles due to its
highly specialized architecture and limited upstream support. Key
challenges include:

1. **Obsolete Toolchain (GCC and Binutils):** The RTL8196E CPU is based on
   a Lexra-derived MIPS architecture variant (`rlx4181`). Modern GNU
   toolchains (GCC and Binutils) have dropped — or never officially
   supported — these Lexra instruction set extensions. Developers must:

   - Apply unofficial patches to old versions of GCC (e.g., 4.8.x) and
     Binutils (e.g., 2.24).
   - Overcome build failures caused by incompatibilities with modern host
     environments (e.g., newer GCC/glibc versions).

2. **Lack of Official Lexra Support:** RTL8196E processors are derived from
   Lexra CPUs, which deviate notably from standard MIPS:

   - No floating-point unit (FPU); missing instructions like `LL/SC`.
   - Differences in exception handling and pipeline structures.

   These differences prevent out-of-the-box compilation with upstream
   toolchains and require extensive patching or configuration tuning.

3. **Aging and Patched uClibc Library:** RTL8196E firmware typically uses a
   lightweight C library such as `uClibc` instead of `glibc`, due to
   resource constraints. However:

   - `uClibc` is deprecated and lacks support for modern kernels
     (especially beyond 4.x).
   - Developers must apply architecture-specific patches to old versions
     (e.g., uClibc 0.9.33.2).
   - Compatibility with modern kernel headers and APIs is often
     problematic.

4. **Kernel Compatibility and Porting Effort:** Realtek SDKs historically
   use very old kernels (2.6.x or 3.x). Porting to kernel 5.x requires:

   - Migrating drivers for networking, memory controllers, and peripherals.
   - Adapting Realtek SDK platform code to the modern Linux kernel driver
     model.
   - Ensuring system stability despite differences in timing, interrupts,
     and DMA handling.

5. **Resource Constraints in Embedded Environment:** The RTL8196E is a
   resource-constrained embedded platform. Developers must:

   - Optimize the kernel and libraries for minimal memory and storage
     usage.
   - Ensure code changes do not exceed available RAM or flash size.

6. **Sparse Documentation and Community Support:** Official documentation
   is outdated or non-existent. Community knowledge is fragmented across
   forums, personal repositories, and experimental projects.

______________________________________________________________________

### Previous Attempts to Update the Kernel and/or Toolchain

Here are a few potentially useful resources (no guarantees!):

- [OpenWrt Port for RTL8196E by Alter0ne](https://github.com/Alter0ne/rtl8196e)
- [Pascal's Lexra toolchain and hacks](https://gist.github.com/hackpascal)
- [Realtek Toolchain Repository](https://sourceforge.net/projects/rtl819x/files/)
- [Lexra RLX4181 CPU and RTL8196E Linux Kernel Support (shibajee)](https://github.com/shibajee/linux-rtl8196e/)
  or [here](https://github.com/shibajee/linux-rtl8196e/releases)
