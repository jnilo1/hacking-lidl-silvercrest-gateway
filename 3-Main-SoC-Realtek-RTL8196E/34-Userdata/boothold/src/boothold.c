/*
 * boothold — Write HOLD magic to DRAM for bootloader entry
 *
 * Writes 0x484F4C44 ("HOLD") to physical address 0x003FFFFC via /dev/mem
 * with O_SYNC.  The bootloader (V2.4+) reads this address via KSEG1
 * (uncached, directly from DRAM) and enters download mode if it finds
 * the magic word.  The flag is one-shot: the bootloader clears it before
 * entering download mode.
 *
 * Does NOT reboot — the caller handles that (e.g. `boothold && reboot`).
 * This allows SSH scripts to use BusyBox reboot which returns cleanly,
 * unlike the reboot() syscall which blocks the SSH session.
 *
 * Why not use BusyBox devmem?
 *
 *   On MIPS, devmem uses mmap(/dev/mem) which maps RAM addresses through
 *   KSEG0 (0x80000000+, cached, write-back).  The write goes into the L1
 *   D-cache but may never reach DRAM before the watchdog reset clears the
 *   cache.  The read-back appears to succeed because it reads from the
 *   same cache — not from DRAM.  The bootloader reads via KSEG1
 *   (0xA0000000+, uncached) and sees stale DRAM content.
 *
 *   This program uses pwrite() with O_SYNC on /dev/mem, which forces
 *   the kernel to write synchronously to physical memory.
 *
 * Why not use cacheflush()?
 *
 *   The Lexra RLX4181 has non-standard cache instructions.  The kernel's
 *   cacheflush() syscall handler crashes when the target address is near
 *   a page boundary (the 16-byte cache line iteration overflows into the
 *   next unmapped page).
 *
 * The HOLD address (0x003FFFFC) is in a 4 KB page declared as
 * reserved-memory with no-map in the device tree — the kernel never
 * allocates it, avoiding KSEG0/KSEG1 coherency conflicts with the
 * page allocator.
 *
 * Build: mips-lexra-linux-musl-gcc -Os -static -o boothold boothold.c
 */

#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <arpa/inet.h>

#define HOLD_PHYS   0x003FFFFC
#define HOLD_MAGIC  0x484F4C44  /* "HOLD" */

int main(void)
{
	int fd;
	uint32_t val, readback;

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("open /dev/mem");
		return 1;
	}

	/* Write HOLD magic (big-endian CPU) */
	val = htonl(HOLD_MAGIC);
	if (pwrite(fd, &val, sizeof(val), HOLD_PHYS) != sizeof(val)) {
		perror("pwrite");
		close(fd);
		return 1;
	}

	/* Verify */
	if (pread(fd, &readback, sizeof(readback), HOLD_PHYS) != sizeof(readback)) {
		perror("pread");
		close(fd);
		return 1;
	}

	if (readback != val) {
		fprintf(stderr, "boothold: verify failed (wrote 0x%08X, read 0x%08X)\n",
			ntohl(val), ntohl(readback));
		close(fd);
		return 1;
	}

	close(fd);

	printf("Boot hold set.\n");
	return 0;
}
