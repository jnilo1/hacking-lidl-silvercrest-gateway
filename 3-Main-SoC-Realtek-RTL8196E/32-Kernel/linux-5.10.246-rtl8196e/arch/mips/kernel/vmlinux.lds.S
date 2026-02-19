/* SPDX-License-Identifier: GPL-2.0 */
/*
 * vmlinux.lds.S — MIPS kernel linker script for RTL8196E.
 *
 * Based on arch/mips/kernel/vmlinux.lds.S (Linux 5.10).
 * Adds optional .iram and .dram output sections for the Lexra RLX4181
 * on-chip SRAM when CONFIG_RTL8196E_IMEM is enabled.
 *
 * The .iram section is placed contiguously within the kernel image (no
 * special VMA/LMA split).  _imem_dmem_init() reads the linker symbol
 * __iram, strips it to its physical address, programs the COP3 Instruction
 * Window registers, then triggers IRAM Fill so the hardware caches that
 * range in on-chip SRAM.  Subsequent instruction fetches from the same
 * physical range are served at zero wait-state.
 *
 * Alignment requirements:
 *   .iram: 16 KB (COP3 IW base uses bits [27:14], mask 0x0fffc000)
 *   .dram:  8 KB (COP3 DW base uses bits [28:13], mask 0x0fffe000)
 */
#include <asm/asm-offsets.h>
#include <asm/thread_info.h>

#define PAGE_SIZE _PAGE_SIZE

/*
 * Put .bss..swapper_pg_dir as the first thing in .bss. This will
 * ensure that it has .bss alignment (64K).
 */
#define BSS_FIRST_SECTIONS *(.bss..swapper_pg_dir)

/* Cavium Octeon should not have a separate PT_NOTE Program Header. */
#ifndef CONFIG_CAVIUM_OCTEON_SOC
#define EMITS_PT_NOTE
#endif

#define RUNTIME_DISCARD_EXIT

#include <asm-generic/vmlinux.lds.h>

#undef mips
#define mips mips
OUTPUT_ARCH(mips)
ENTRY(kernel_entry)
PHDRS {
	text PT_LOAD FLAGS(7);	/* RWX */
#ifndef CONFIG_CAVIUM_OCTEON_SOC
	note PT_NOTE FLAGS(4);	/* R__ */
#endif /* CAVIUM_OCTEON_SOC */
}

#ifdef CONFIG_32BIT
	#ifdef CONFIG_CPU_LITTLE_ENDIAN
		jiffies	 = jiffies_64;
	#else
		jiffies	 = jiffies_64 + 4;
	#endif
#else
	jiffies	 = jiffies_64;
#endif

SECTIONS
{
#ifdef CONFIG_BOOT_ELF64
	/* Read-only sections, merged into text segment: */
	/* . = 0xc000000000000000; */

	/* This is the value for an Origin kernel, taken from an IRIX kernel.  */
	/* . = 0xc00000000001c000; */

	/* Set the vaddr for the text segment to a value
	 *   >= 0xa800 0000 0001 9000 if no symmon is going to configured
	 *   >= 0xa800 0000 0030 0000 otherwise
	 */

	/* . = 0xa800000000300000; */
	. = 0xffffffff80300000;
#endif
	. = LINKER_LOAD_ADDRESS;
	/* read-only */
	_text = .;	/* Text and read-only data */
	.text : {
		TEXT_TEXT
		SCHED_TEXT
		CPUIDLE_TEXT
		LOCK_TEXT
		KPROBES_TEXT
		IRQENTRY_TEXT
		SOFTIRQENTRY_TEXT
		*(.text.*)
		*(.fixup)
		*(.gnu.warning)
	} :text = 0
	_etext = .;	/* End of text section */

	EXCEPTION_TABLE(16)

	/* Exception table for data bus errors */
	__dbe_table : {
		__start___dbe_table = .;
		KEEP(*(__dbe_table))
		__stop___dbe_table = .;
	}

	/*
	 * On-chip I-MEM hot-path section (CONFIG_RTL8196E_IMEM only).
	 *
	 * Placed after .text so that __iram resolves to an address within the
	 * regular kernel image in SDRAM.  _imem_dmem_init() computes the
	 * physical address from __iram and programs the COP3 IW window so the
	 * hardware fills on-chip SRAM from that SDRAM range.
	 *
	 * Maximum size: 16 KB (one I-MEM bank on RTL8196E).
	 * Alignment:    16 KB (COP3 IW base register uses bits [27:14]).
	 */
#ifdef CONFIG_RTL8196E_IMEM
	. = ALIGN(16384);
	__iram		= .;
	__iram_start	= .;
	.iram : {
		*(.iram-gen)		/* essential hot path */
		*(.iram-fwd)		/* packet forwarding */
		*(.iram-tx)		/* TX stack */
		*(.iram)		/* other */
	}
	__iram_tail	= .;
	. = ALIGN(16384);
	__iram_end	= .;

	/*
	 * On-chip D-MEM data section.
	 *
	 * Placed immediately after .iram.  Maximum size: 8 KB (one D-MEM bank).
	 * Currently unused (no .dram-* annotations in rtl8196e-eth); when
	 * __dram_start == __dram_end the init code skips D-MEM programming.
	 */
	. = ALIGN(8192);
	__dram		= .;
	__dram_start	= .;
	.dram : {
		*(.dram-gen)		/* hot data */
		*(.dram-fwd)		/* forwarding data */
		*(.dram)		/* other */
	}
	__dram_tail	= .;
	. = ALIGN(8192);
	__dram_end	= .;
#endif /* CONFIG_RTL8196E_IMEM */

	_sdata = .;			/* Start of data section */
	RO_DATA(4096)

	/* writeable */
	.data : {	/* Data */
		. = . + DATAOFFSET;		/* for CONFIG_MAPPED_KERNEL */

		INIT_TASK_DATA(THREAD_SIZE)
		NOSAVE_DATA
		PAGE_ALIGNED_DATA(PAGE_SIZE)
		CACHELINE_ALIGNED_DATA(1 << CONFIG_MIPS_L1_CACHE_SHIFT)
		READ_MOSTLY_DATA(1 << CONFIG_MIPS_L1_CACHE_SHIFT)
		DATA_DATA
		CONSTRUCTORS
	}
	BUG_TABLE
	_gp = . + 0x8000;
	.lit8 : {
		*(.lit8)
	}
	.lit4 : {
		*(.lit4)
	}
	/* We want the small data sections together, so single-instruction offsets
	   can access them all, and initialized data all before uninitialized, so
	   we can shorten the on-disk segment size.  */
	.sdata : {
		*(.sdata)
	}
	_edata =  .;			/* End of data section */

	/* will be freed after init */
	. = ALIGN(PAGE_SIZE);		/* Init code and data */
	__init_begin = .;
	INIT_TEXT_SECTION(PAGE_SIZE)
	INIT_DATA_SECTION(16)

	. = ALIGN(4);
	.mips.machines.init : AT(ADDR(.mips.machines.init) - LOAD_OFFSET) {
		__mips_machines_start = .;
		KEEP(*(.mips.machines.init))
		__mips_machines_end = .;
	}

	/* .exit.text is discarded at runtime, not link time, to deal with
	 * references from .rodata
	 */
	.exit.text : {
		EXIT_TEXT
	}
	.exit.data : {
		EXIT_DATA
	}
#ifdef CONFIG_SMP
	PERCPU_SECTION(1 << CONFIG_MIPS_L1_CACHE_SHIFT)
#endif

#ifdef CONFIG_MIPS_ELF_APPENDED_DTB
	.appended_dtb : AT(ADDR(.appended_dtb) - LOAD_OFFSET) {
		*(.appended_dtb)
		KEEP(*(.appended_dtb))
	}
#endif

#ifdef CONFIG_RELOCATABLE
	. = ALIGN(4);

	.data.reloc : {
		_relocation_start = .;
		/*
		 * Space for relocation table
		 * This needs to be filled so that the
		 * relocs tool can overwrite the content.
		 * An invalid value is left at the start of the
		 * section to abort relocation if the table
		 * has not been filled in.
		 */
		LONG(0xFFFFFFFF);
		FILL(0);
		. += CONFIG_RELOCATION_TABLE_SIZE - 4;
		_relocation_end = .;
	}
#endif

#ifdef CONFIG_MIPS_RAW_APPENDED_DTB
	__appended_dtb = .;
	/* leave space for appended DTB */
	. += 0x100000;
#endif
	/*
	 * Align to 64K in attempt to eliminate holes before the
	 * .bss..swapper_pg_dir section at the start of .bss.  This
	 * also satisfies PAGE_SIZE alignment as the largest page size
	 * allowed is 64K.
	 */
	. = ALIGN(0x10000);
	__init_end = .;
	/* freed after init ends here */

	/*
	 * Force .bss to 64K alignment so that .bss..swapper_pg_dir
	 * gets that alignment.	 .sbss should be empty, so there will be
	 * no holes after __init_end. */
	BSS_SECTION(0, 0x10000, 8)

	_end = . ;

	/* These mark the ABI of the kernel for debuggers.  */
	.mdebug.abi32 : {
		KEEP(*(.mdebug.abi32))
	}
	.mdebug.abi64 : {
		KEEP(*(.mdebug.abi64))
	}

	/* This is the MIPS specific mdebug section.  */
	.mdebug : {
		*(.mdebug)
	}

	STABS_DEBUG
	DWARF_DEBUG
	ELF_DETAILS

	/* These must appear regardless of  .  */
	.gptab.sdata : {
		*(.gptab.data)
		*(.gptab.sdata)
	}
	.gptab.sbss : {
		*(.gptab.bss)
		*(.gptab.sbss)
	}

	/* Sections to be discarded */
	DISCARDS
	/DISCARD/ : {
		/* ABI crap starts here */
		*(.MIPS.abiflags)
		*(.MIPS.options)
		*(.options)
		*(.pdr)
		*(.reginfo)
	}
}
