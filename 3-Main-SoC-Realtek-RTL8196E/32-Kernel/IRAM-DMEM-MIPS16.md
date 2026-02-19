# RTL8196E — I-MEM, D-MEM and MIPS16e: Research Notes

## 1. Hardware facts (from RTL8196E datasheet)

| Resource | Size | Physical base | Physical top |
|---|---|---|---|
| I-cache | 16 KB | — | — |
| D-cache | 8 KB | — | — |
| **I-MEM** (instruction SRAM) | **16 KB** | `0x00C00000` | `0x00C03FFF` |
| **D-MEM** (data SRAM) | **8 KB** | `0x00C04000` | `0x00C05FFF` |

CPU clock: 400 MHz.  ISA: MIPS-1 + MIPS16e.

I-MEM and D-MEM are **tightly-coupled on-chip SRAM** with zero wait-state access —
unlike external SDRAM which stalls the CPU on every cache miss.

KSEG0 virtual addresses (cached, used by kernel code):
- I-MEM: `0x80C00000` – `0x80C03FFF`
- D-MEM: `0x80C04000` – `0x80C05FFF`

---

## 2. How Realtek uses these resources in the 2.6.30 kernel

### 2.1 Macro system (`rtl_types.h`)

Realtek defines a set of placement macros that expand to GCC section attributes when
`CONFIG_RTL_IMEM` is set, and to empty strings otherwise:

```c
#ifdef CONFIG_RTL_IMEM
# define __IRAM_GEN  __attribute__((section(".iram-gen")))  /* essential hot path */
# define __IRAM_FWD  __attribute__((section(".iram-fwd")))  /* packet forwarding */
# define __IRAM_TX   __attribute__((section(".iram-tx")))   /* TX stack */
# define __DRAM_GEN  __attribute__((section(".dram-gen")))  /* hot data */
# define __DRAM_FWD  __attribute__((section(".dram-fwd")))  /* forwarding data */
  /* ... */
#else
# define __IRAM_GEN   /* no-op */
# define __IRAM_FWD
  /* ... */
#endif
```

This lets the optimisation be enabled/disabled at compile time without touching
the annotated source code.

### 2.2 Which functions are placed in I-MEM

From `linux-2.6.30/drivers/net/rtl819x/`:

| File | Function | Macro |
|---|---|---|
| `rtl_nic.c` | `rtl_rx_interrupt_process` | `__IRAM_GEN` |
| `rtl_nic.c` | `rtl_tx_interrupt_process` | `__IRAM_GEN` |
| `rtl_nic.c` | `rtl_link_change_interrupt_process` | `__IRAM_GEN` |
| `rtl_nic.c` | `rtl_rxSetTxDone` | `__MIPS16 __IRAM_GEN` |
| `rtl_nic.c` | `interrupt_dsr_rx_done` | `__IRAM_FWD` |
| `rtl_nic.c` | `dev_alloc_skb_priv_eth` | `__MIPS16 __IRAM_FWD` |
| `rtl865xc_swNic.c` | `_swNic_send` (TX ring submit) | `__IRAM_FWD` |
| `rtl865xc_swNic.h` | `swNic_receive` (RX ring consume) | `__MIPS16 __IRAM_FWD` |
| `arch/rlx/kernel/irq_cpu.c` | IRQ dispatch | `__IRAM_GEN` |
| `arch/rlx/kernel/irq_vec.c` | IRQ vector handler | `__IRAM_GEN` |
| `kernel/irq/handle.c` | `handle_irq` | `__MIPS16 __IRAM_GEN` |
| `net/core/skbuff.c` | SKB hot path | `__IRAM_FWD` |
| `net/core/dev.c` | packet receive dispatch | `__MIPS16 __IRAM_FWD` |

The combination `__MIPS16 __IRAM_FWD` is the key pattern: MIPS16e reduces code
size by ~30%, allowing more code to fit within the 16 KB I-MEM budget.

### 2.3 Why Realtek disabled I-MEM for RTL8196E in the 3.10 port

`linux-3.10/arch/rlx/soc-rtl8196e/bspcpu.h` sets `cpu_imem_size = 0` and
`boards/rtl8196e/bsp/bspchip.h` redefines `__IRAM_USB` to an empty string.
The 3.10 port was a transitional effort; Realtek did not re-implement the I-MEM
initialisation for RTL8196E.  The 2.6.30 kernel **did** use I-MEM on RTL8196E
(the `__IRAM_FWD`/`__IRAM_GEN` annotations are present and active in the ethernet
driver source).

---

## 3. I-MEM/D-MEM initialisation sequence (from `imem-dmem.S`)

The function `_imem_dmem_init()` in
`linux-2.6.30/arch/rlx/mm/imem-dmem.S` initialises the on-chip SRAM via the
Lexra COP3 coprocessor.  For RTL8196E the code takes the non-RLX5281 `#else`
branch, which configures **one 16 KB I-MEM bank** and **one 8 KB D-MEM bank**:

### Step-by-step for RTL8196E

```asm
/* 1. Enable COP3 access in the MIPS Status register (COP0 $12) */
mfc0  $8, $12
or    $8, 0x80000000
mtc0  $8, $12

/* 2. Invalidate the IRAM */
mtc0  $0,  $20            /* CCTL = 0 */
li    $8,  0x00000020     /* bit 5: IRAM Off */
mtc0  $8,  $20

/* 3. Invalidate I-cache and D-cache */
mtc0  $0,  $20
li    $8,  0x00000202     /* bit 9: inv ICACHE, bit 1: inv DCACHE */
mtc0  $8,  $20

/* 4. Program I-MEM window in COP3 */
la    $8,  __iram         /* linker symbol → virtual 0x80C00000 */
and   $8,  $8, 0x0fffc000 /* strip to physical bits [27:14] */
mtc3  $8,  $0             /* COP3 $0 = IW base */
addiu $8,  $8, 0x3fff     /* base + 16 KB − 1 */
mtc3  $8,  $1             /* COP3 $1 = IW top  */

/* 5. IRAM Fill: copy .iram section from SDRAM into on-chip SRAM */
mtc0  $0,  $20
li    $8,  0x00000010     /* bit 4: IRAM Fill */
mtc0  $8,  $20

/* 6. Program D-MEM window in COP3 */
la    $8,  __dram_start   /* linker symbol → virtual 0x80C04000 */
and   $8,  $8, 0x0fffe000
mtc3  $8,  $4             /* COP3 $4 = DW base */
addiu $8,  $8, 0x1fff     /* base + 8 KB − 1 */
mtc3  $8,  $5             /* COP3 $5 = DW top  */

/* 7. Enable D-MEM */
mfc0  $8,  $20
or    $8,  0x00000400     /* bit 10: DMEM On */
mtc0  $8,  $20
```

### COP3 register map (RTL8196E)

| Register | Role | Value |
|---|---|---|
| COP3 `$0` | I-MEM base | `0x00C00000` |
| COP3 `$1` | I-MEM top  | `0x00C03FFF` |
| COP3 `$4` | D-MEM base | `0x00C04000` |
| COP3 `$5` | D-MEM top  | `0x00C05FFF` |
| COP3 `$2/$3` | (I-MEM bank 1) | **not used** on RTL8196E |
| COP3 `$6/$7` | (D-MEM bank 1) | **not used** on RTL8196E |

### COP0 `$20` (CCTL) bit definitions

| Bit pattern | Meaning |
|---|---|
| `0x00000020` | IRAM Off (invalidate) |
| `0x00000010` | IRAM Fill (copy SDRAM → SRAM) |
| `0x00000202` | Invalidate I-cache + D-cache |
| `0x00000400` | DMEM On |

---

## 4. MIPS16e

The Lexra RLX4181 supports the MIPS16e ISA extension (16-bit compressed
instructions, ~30% smaller code).  Both the 2.6.30 and 5.10 kernels declare
`cpu_has_mips16 = 1` in `cpu-feature-overrides.h`.

Realtek uses MIPS16e in two scenarios:

1. **Combined with I-MEM** (`__MIPS16 __IRAM_FWD`): smaller code fits better in the
   16 KB I-MEM budget.  The most critical hot-path functions carry both attributes.

2. **Assembly files**: `.set nomips16` appears throughout `.S` files to explicitly
   *disable* MIPS16 encoding for assembly routines that use MIPS32-specific
   instructions (delay slots, 32-bit multiplies, etc.).

In C, GCC accepts `__attribute__((mips16))` per function, or the `-mmips16` flag
globally.  For kernel code, per-function annotation is safer.

---

## 5. Porting roadmap for the 5.10 / rtl8196e-eth driver

### 5.1 Prerequisite: platform infrastructure

Three new/modified files in `files/arch/mips/realtek/`:

| File | What to add |
|---|---|
| `imem.S` | `_imem_dmem_init()` function (RTL8196E path from `imem-dmem.S`) |
| `setup.c` | Call `_imem_dmem_init()` early in `plat_mem_setup()` |
| `rtl8196e.lds.S` | Custom linker script; place `.iram` at `0x80C00000`, `.dram` at `0x80C04000` |
| `Kconfig` | Add `config RTL8196E_IMEM` bool option |

### 5.2 Driver-level placement macros

New header `linux-5.10.246-rtl8196e/drivers/net/ethernet/rtl8196e-eth/rtl8196e_imem.h`:

```c
#ifdef CONFIG_RTL8196E_IMEM
# define __iram_gen  __attribute__((section(".iram-gen")))
# define __iram_fwd  __attribute__((section(".iram-fwd")))
# define __dram_fwd  __attribute__((section(".dram-fwd")))
#else
# define __iram_gen
# define __iram_fwd
# define __dram_fwd
#endif
```

### 5.3 Annotations — rtl8196e-eth hot path

Mapping from the Realtek 2.6.30 pattern to the new driver:

| rtl8196e-eth function | 2.6.30 equivalent | Proposed macro |
|---|---|---|
| `rtl8196e_isr` | `irq_cpu.c` handler | `__iram_gen` |
| `rtl8196e_poll` | `rtl_rx/tx_interrupt_process` | `__iram_gen` |
| `rtl8196e_start_xmit` | `rtl_nic.c` xmit wrapper | `__iram_fwd` |
| `rtl8196e_ring_tx_submit` | `_swNic_send` | `__iram_fwd` |
| `rtl8196e_ring_kick_tx` | `rtl_rxSetTxDone` | `__MIPS16 __iram_gen` |
| `rtl8196e_ring_tx_reclaim` | `rtl_tx_interrupt_process` | `__iram_gen` |
| `rtl8196e_ring_rx_poll` | `swNic_receive` | `__MIPS16 __iram_fwd` |

Estimated I-MEM footprint of the annotated functions: **~2.5 KB** (well within
16 KB; remaining budget available for kernel IRQ dispatch and TCP checksum code).

### 5.4 Expected benefit

I-MEM eliminates instruction-fetch stalls on the driver hot path.  The dominant
TX bottleneck (`dma_cache_wback_inv`, ~300 cycles, DRAM bandwidth-bound) is
**not** affected.  The gain comes from secondary costs:

| Source of gain | Estimated saving |
|---|---|
| I-cache misses on ISR/NAPI entry | 20–50 cycles/packet |
| I-cache misses on TX ring submit | 10–30 cycles/packet |
| `ring_kick_tx` with MIPS16 | code size only |
| Total (optimistic) | ~50–80 cycles/packet |

At 400 MHz and ~1500-byte packets on a fully CPU-bound TX path (~800 cycles/pkt),
this corresponds to a theoretical **6–10% TX throughput improvement**.

---

## 6. What is not worth doing

| Optimisation | Reason to skip |
|---|---|
| D-MEM for ring state | D-cache working set for ring indices is tiny; D-cache pressure is lower than I-cache pressure |
| MIPS16e on TX data path | I-MEM already eliminates miss penalties; MIPS16 adds GCC complexity for marginal gain |
| Global `-mmips16` compilation | Known GCC 8.5.0 issues with kernel inline asm; too broad |
| IRAM for TCP stack | TCP stack is kernel code outside the driver; patching it is out of scope |

---

## 7. Key source files for reference

| File | Content |
|---|---|
| `~/rtl819x/boards/rtl8196e/bsp/bspchip.h:179` | `BSP_IMEM_BASE/TOP`, `BSP_DMEM_BASE/TOP` |
| `~/rtl819x/linux-2.6.30/arch/rlx/mm/imem-dmem.S` | Complete COP3 init sequence |
| `~/rtl819x/linux-2.6.30/include/net/rtl/rtl_types.h` | `__IRAM_*` / `__DRAM_*` macro system |
| `~/rtl819x/linux-2.6.30/drivers/net/rtl819x/rtl_nic.c` | `__IRAM_GEN`/`__IRAM_FWD` usage in ethernet driver |
| `~/rtl819x/linux-2.6.30/drivers/net/rtl819x/rtl865xc_swNic.c` | `__IRAM_FWD` on TX/RX ring functions |
| `~/rtl819x/linux-3.10/arch/rlx/soc-rtl8196e/vmlinux.lds.S` | Linker script with `.iram`/`.dram` sections |
