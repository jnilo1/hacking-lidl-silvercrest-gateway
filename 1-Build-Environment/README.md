# Build Environment

This directory contains the unified build environment for the Lidl/Silvercrest Gateway project. It provides all tools needed to build both:

- **Main SoC (RTL8196E)** — Linux kernel, root filesystem, userdata
- **Zigbee Radio (Silabs EFR32)** — NCP/RCP firmware

## Choose Your Build Method

| | Docker | Native Ubuntu |
|---|---|---|
| **Setup time** | ~45 min (one-time) | ~45 min (one-time) |
| **Disk space** | ~8 GB (image) | ~4 GB (tools) |
| **Best for** | Any OS, reproducible builds | Ubuntu 22.04, faster I/O |
| **Windows** | Requires Docker Desktop | **Recommended:** WSL2 + native |

> **Windows users:** WSL2 with Ubuntu 22.04 is the recommended approach. Native builds in WSL2 are simpler and faster than Docker Desktop.

---

## Option 1: Docker (Any OS)

Build the Docker image once, then use it for all builds.

### Build the Image

```bash
cd 1-Build-Environment
docker build -t lidl-gateway-builder .
```

This takes ~45 minutes (downloads and compiles toolchains).

### Use the Image

From the `1-Build-Environment` directory:

```bash
# Interactive shell
docker run -it --rm -v $(pwd)/..:/workspace lidl-gateway-builder

# Build Main SoC (bootloader + kernel + rootfs + userdata)
docker run -it --rm -v $(pwd)/..:/workspace lidl-gateway-builder \
    /workspace/3-Main-SoC-Realtek-RTL8196E/build_rtl8196e.sh

# Build all EFR32 firmware (bootloader + NCP + RCP + OT-RCP + Router)
docker run -it --rm -v $(pwd)/..:/workspace lidl-gateway-builder \
    /workspace/2-Zigbee-Radio-Silabs-EFR32/build_efr32.sh
```

### Docker Options Explained

| Option | Description |
|--------|-------------|
| `-it` | Interactive mode with terminal |
| `--rm` | Remove container after exit |
| `-v $(pwd)/..:/workspace` | Mount project root to `/workspace` |

The `-v` mount is bidirectional: built files appear in your local directories.

---

## Option 2: Native Build (Ubuntu 22.04 / WSL2)

For native Ubuntu or WSL2 users. **Recommended for Windows users.**

### Quick Start (One Command)

```bash
# Clone the repository (anywhere, rename if you want)
git clone https://github.com/jnilo1/hacking-lidl-silvercrest-gateway.git
cd hacking-lidl-silvercrest-gateway/1-Build-Environment

# Install everything — takes ~45 minutes
sudo ./install_deps.sh
```

This single command installs everything:
1. Ubuntu packages (build tools, Java, etc.)
2. Lexra MIPS toolchain (for Main SoC)
3. Realtek tools (cvimg, lzma)
4. Silabs tools (slc-cli, Gecko SDK, ARM GCC, Commander)

All tools are installed inside the project directory:
- `<project>/x-tools/` — Lexra toolchain
- `<project>/silabs-tools/` — Silabs toolchain

Build scripts auto-detect these locations — no PATH configuration needed.

---

## Directory Structure

```
<project>/
├── x-tools/                    # Lexra toolchain (created by build)
│   └── mips-lexra-linux-musl/
│
├── silabs-tools/               # Silabs toolchain (created by install)
│   ├── slc_cli/
│   ├── gecko_sdk/
│   ├── arm-gnu-toolchain/
│   ├── commander/
│   ├── SimplicityStudio/       # slc workspace (kept here via JAVA_TOOL_OPTIONS)
│   └── env.sh                  # Source to load Silabs environment
│
└── 1-Build-Environment/
    ├── Dockerfile              # Docker image definition
    ├── install_deps.sh         # Ubuntu package installation
    │
    ├── 10-lexra-toolchain/     # Lexra MIPS toolchain
    │   ├── build_toolchain.sh  # Build script
    │   ├── crosstool-ng.config # Crosstool-ng configuration
    │   └── patches/            # GCC/binutils patches for Lexra
    │
    ├── 11-realtek-tools/       # Realtek image tools
    │   ├── build_tools.sh      # Build script
    │   ├── cvimg/              # cvimg source
    │   ├── lzma-4.65/          # LZMA compressor
    │   └── lzma-loader/        # LZMA decompression loader
    │
    └── 12-silabs-toolchain/    # Silicon Labs tools
        └── install_silabs.sh   # Download and install slc-cli + SDK
```

---

## Toolchains Reference

### Lexra MIPS Toolchain

| Item | Value |
|------|-------|
| Target | `mips-lexra-linux-musl` |
| GCC | 8.5.0 |
| C library | musl 1.2.5 |
| Location | `<project>/x-tools/mips-lexra-linux-musl/` |

The Lexra architecture is a MIPS variant without unaligned access instructions (`lwl`, `lwr`, `swl`, `swr`). Standard MIPS toolchains won't work.

### Silabs ARM Toolchain

| Item | Value |
|------|-------|
| Target | `arm-none-eabi` |
| GCC | 12.2 |
| SDK | Gecko SDK 4.5.0 |
| CLI | slc-cli 5.11.1.0 |
| Location | `<project>/silabs-tools/` |

### Realtek Tools

| Tool | Description |
|------|-------------|
| `cvimg` | Create Realtek flash images |
| `lzma` | LZMA compressor |
| `lzma-loader` | LZMA decompressor (legacy, replaced by zboot) |

---

## Troubleshooting

### Docker build fails

If the toolchain build fails with network errors, retry:
```bash
docker build --no-cache -t lidl-gateway-builder .
```

### slc-cli download fails

The Silabs download may require login. If wget fails, manually download from:
https://www.silabs.com/developers/simplicity-studio

### Toolchain not found

Both toolchains are auto-detected by build scripts when installed in the project directory:
- Lexra: `<project>/x-tools/mips-lexra-linux-musl/`
- Silabs: `<project>/silabs-tools/`

If you installed elsewhere, set the PATH manually or use the `env.sh` script generated during installation.

---

## Next Steps

After setting up the build environment:

1. **Build Main SoC:** `./3-Main-SoC-Realtek-RTL8196E/build_rtl8196e.sh` — See [3-Main-SoC-Realtek-RTL8196E](../3-Main-SoC-Realtek-RTL8196E/README.md)
2. **Build EFR32 firmware:** `./2-Zigbee-Radio-Silabs-EFR32/build_efr32.sh` — See [2-Zigbee-Radio-Silabs-EFR32](../2-Zigbee-Radio-Silabs-EFR32/README.md)

Both scripts accept individual targets (e.g., `build_rtl8196e.sh kernel`, `build_efr32.sh ncp rcp`). Run with `--help` for details.
