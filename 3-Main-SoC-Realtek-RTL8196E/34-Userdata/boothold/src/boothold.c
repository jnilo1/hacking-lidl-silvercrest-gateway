/*
 * boothold — Write HOLD magic (and optional TFTP server IP) to DRAM
 *
 * Writes 0x484F4C44 ("HOLD") to the top word of the board's `boothold`
 * reserved-memory page via /dev/mem.  The bootloader (V2.6+) reads this
 * address via KSEG1 (uncached) on next reset and enters download mode if
 * it finds the magic word.  The flag is one-shot: the bootloader clears
 * it before entering download mode.
 *
 * The page is NOT hard-coded: it is discovered at runtime from the live
 * device tree (/sys/firmware/devicetree/base/reserved-memory/boothold@*,
 * `reg` = <base size>), so a board that relocates the reservation —
 * different DRAM size, e.g. the 64 MiB Sengled G4 — moves the flag with
 * its DTS, and the same binary works on every board.  If the node is
 * absent the tool refuses to write: poking a guessed address into
 * unreserved kernel RAM is silent corruption, and the bootloader of such
 * a board has nowhere agreed to look anyway.  Note the bootloader's read
 * side is a compile-time constant per board — the board's DTS and its
 * bootloader build must agree on the page address.
 *
 * Field layout, growing DOWNWARD from the top of the page (page_top =
 * base + size; on the Lidl board base=0x01FFE000, size=0x1000):
 *
 *     page_top -  4 : HOLD magic 0x484F4C44 ("HOLD")
 *     page_top -  8 : IP   magic 0x49505634 ("IPV4")
 *     page_top - 12 : IPv4 packed as (a<<24)|(b<<16)|(c<<8)|d
 *
 *   The page belongs to this hand-off alone.  The watchdog's panic
 *   post-mortem record shared it once and now has a reservation of its
 *   own (`watchdog-crash`, the node its driver takes by memory-region),
 *   so the only party to agree with about offsets is the bootloader,
 *   which reads fixed ones down from the page top.
 *
 * Optional argument — boothold <A.B.C.D>:
 *   If a valid dotted IPv4 is given, boothold also writes the IP record.
 *   The bootloader (V2.7+) honours this IP as its download-mode TFTP
 *   server address, but only when HOLD is also valid (a deliberate warm
 *   reboot from a running Linux).  Without the argument — or on an older
 *   bootloader that ignores it — the bootloader keeps its compiled
 *   default (192.168.1.6).  This lets `flash_remote.sh` make the
 *   gateway's bootloader-mode IP follow its BOOT_IP without recompiling
 *   or touching the serial console.
 *
 * Does NOT reboot — the caller handles that (e.g. `boothold && reboot`).
 *
 * Why the top of DRAM (just below the btcode stack)?
 *
 *   v2.x firmware (Linux 5.10) used 0x003FFFFC at the bottom of DRAM.
 *   On Linux 6.18 (v3.0.0+) that became unreliable: ~13-27% of boots
 *   the bootloader read 0 (or kernel-code-like values) instead of HOLD.
 *   The 6.18 kernel scribbles low DRAM during early init / shutdown
 *   before the reserved-memory `no-map` declaration is honored.
 *
 *   The fix is to put HOLD high in DRAM, just below the btcode stack
 *   (which lives at the very top and grows down).  The page is
 *   reserved-memory no-map in the device tree and is far above any
 *   address the kernel touches in early boot (kernel image is loaded at
 *   phys 0x00500000).  100% reliable.  The IP record lives in the same
 *   page, so it inherits the same guarantee.
 *
 * Build: mips-lexra-linux-musl-gcc -Os -static -o boothold boothold.c
 */

#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <arpa/inet.h>

#define HOLD_MAGIC      0x484F4C44  /* "HOLD" */
#define IP_MAGIC        0x49505634  /* "IPV4" */

#define DT_RESERVED_DIR "/sys/firmware/devicetree/base/reserved-memory"

/*
 * Find the boothold reserved-memory node in the live device tree and
 * parse its `reg` property (#address-cells = #size-cells = 1, so 8
 * big-endian bytes: base, size).  Returns 0 and fills base/size, or -1.
 */
static int dt_find_boothold(uint32_t *base, uint32_t *size)
{
	char path[sizeof(DT_RESERVED_DIR) + NAME_MAX + 8];
	unsigned char reg[8];
	struct dirent *de;
	int found = 0;
	ssize_t n;
	DIR *dir;
	int fd;

	dir = opendir(DT_RESERVED_DIR);
	if (!dir) {
		perror("opendir " DT_RESERVED_DIR);
		return -1;
	}
	while ((de = readdir(dir)) != NULL) {
		if (strncmp(de->d_name, "boothold@", 9) == 0) {
			snprintf(path, sizeof(path), "%s/%s/reg",
				 DT_RESERVED_DIR, de->d_name);
			found = 1;
			break;
		}
	}
	closedir(dir);
	if (!found) {
		fprintf(stderr, "boothold: no boothold@* node under %s\n"
			"boothold: this board's device tree declares no "
			"boothold page — refusing to write.\n",
			DT_RESERVED_DIR);
		return -1;
	}

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		perror(path);
		return -1;
	}
	n = read(fd, reg, sizeof(reg));
	close(fd);
	if (n != sizeof(reg)) {
		fprintf(stderr, "boothold: short read on %s (%zd bytes, "
			"expected 8)\n", path, n);
		return -1;
	}
	/* DT properties are big-endian regardless of CPU endianness. */
	*base = ((uint32_t)reg[0] << 24) | ((uint32_t)reg[1] << 16) |
		((uint32_t)reg[2] << 8)  |  (uint32_t)reg[3];
	*size = ((uint32_t)reg[4] << 24) | ((uint32_t)reg[5] << 16) |
		((uint32_t)reg[6] << 8)  |  (uint32_t)reg[7];
	if (*size < 16) {
		fprintf(stderr, "boothold: reservation at 0x%08X too small "
			"(0x%X bytes)\n", *base, *size);
		return -1;
	}
	return 0;
}

/* Write a 32-bit word (in DRAM byte order) and read it back to verify. */
static int poke_verify(int fd, off_t phys, uint32_t word)
{
	uint32_t val = htonl(word);
	uint32_t readback;

	if (pwrite(fd, &val, sizeof(val), phys) != sizeof(val)) {
		perror("pwrite");
		return -1;
	}
	if (pread(fd, &readback, sizeof(readback), phys) != sizeof(readback)) {
		perror("pread");
		return -1;
	}
	if (readback != val) {
		fprintf(stderr, "boothold: verify failed at 0x%08lX "
			"(wrote 0x%08X, read 0x%08X)\n",
			(unsigned long)phys, word, ntohl(readback));
		return -1;
	}
	return 0;
}

/* Parse "A.B.C.D" into a packed (a<<24)|(b<<16)|(c<<8)|d host integer. */
static int parse_ipv4(const char *s, uint32_t *out)
{
	int a, b, c, d;

	if (sscanf(s, "%d.%d.%d.%d", &a, &b, &c, &d) != 4)
		return -1;
	if (a < 0 || a > 255 || b < 0 || b > 255 ||
	    c < 0 || c > 255 || d < 0 || d > 255)
		return -1;
	*out = ((uint32_t)a << 24) | ((uint32_t)b << 16) |
	       ((uint32_t)c << 8) | (uint32_t)d;
	return 0;
}

int main(int argc, char **argv)
{
	uint32_t base, size, page_top;
	uint32_t ip = 0;
	int have_ip = 0;
	int fd;

	if (argc > 1) {
		if (parse_ipv4(argv[1], &ip) == 0) {
			have_ip = 1;
		} else {
			fprintf(stderr, "boothold: ignoring invalid IP '%s' "
				"(usage: boothold [A.B.C.D])\n", argv[1]);
		}
	}

	if (dt_find_boothold(&base, &size) != 0)
		return 1;
	page_top = base + size;

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("open /dev/mem");
		return 1;
	}

	if (poke_verify(fd, page_top - 4, HOLD_MAGIC) != 0) {
		close(fd);
		return 1;
	}

	if (have_ip) {
		/* Write the IP value first, then its marker last, so the
		 * bootloader never sees a valid marker over a stale value. */
		if (poke_verify(fd, page_top - 12, ip) != 0 ||
		    poke_verify(fd, page_top - 8, IP_MAGIC) != 0) {
			close(fd);
			return 1;
		}
	}

	close(fd);

	if (have_ip)
		printf("Boot hold set at 0x%08X (TFTP server IP %u.%u.%u.%u).\n",
		       page_top - 4,
		       (ip >> 24) & 0xFF, (ip >> 16) & 0xFF,
		       (ip >> 8) & 0xFF, ip & 0xFF);
	else
		printf("Boot hold set at 0x%08X.\n", page_top - 4);
	return 0;
}
