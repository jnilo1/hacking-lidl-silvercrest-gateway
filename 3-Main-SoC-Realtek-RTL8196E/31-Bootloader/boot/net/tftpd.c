// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * tftpd.c - TFTP server for firmware recovery
 *
 * RTL8196E stage-2 bootloader
 *
 * Implements a minimal TFTP server that accepts WRQ (write request)
 * packets, receives firmware images into RAM, validates checksums,
 * and auto-flashes them to SPI flash.
 *
 * Copyright (c) 2009-2020 Realtek Semiconductor Corp.
 * Copyright (c) 2024-2026 J. Nilo
 */

#include "boot_common.h"
#include "boot_soc.h"
#include "boot_net.h"
#include "nic.h"
#include "rtk.h"
#include "spi_common.h"
#include "spi_flash.h"
#include "cache.h"

struct arptable_t arptable_tftp[2];

#define FILESTART JUMP_ADDR

#define prom_printf dprintf

extern struct spi_flash_type spi_flash_info[2];

static void (*jumpF)(void);

extern volatile int get_timer_jiffies(void);
static int tftpd_is_ready = 0;
static int rx_kickofftime = 0;
static unsigned char one_tftp_lock = 0;

struct nic nic;
static unsigned char eth_packet[ETH_FRAME_LEN + 4];
static const unsigned char ETH_BROADCAST[6] = {0xFF, 0xFF, 0xFF,
					       0xFF, 0xFF, 0xFF};

#define IPTOUL(a, b, c, d) ((a << 24) | (b << 16) | (c << 8) | d)

unsigned long image_address = FILESTART;
static unsigned long address_to_store;

unsigned long file_length_to_server;

static inline struct udphdr *tftp_udp_header(void)
{
	return (struct udphdr *)&nic.packet[ETH_HLEN + sizeof(struct iphdr)];
}

static inline struct tftp_t *tftp_packet(void)
{
	return (struct tftp_t *)&nic.packet[ETH_HLEN];
}

static inline void tftp_capture_client(void)
{
	memcpy(arptable_tftp[TFTP_CLIENT].node,
	       (unsigned char *)&(nic.packet[ETH_ALEN]), ETH_ALEN);
	memcpy(&(arptable_tftp[TFTP_CLIENT].ipaddr.s_addr),
	       (unsigned char *)&nic.packet[ETH_HLEN + 12], 4);
}

void tftp_get_server_ip(unsigned char ip[4])
{
	memcpy(ip, arptable_tftp[TFTP_SERVER].ipaddr.ip, 4);
}

void tftp_set_server_ip(const unsigned char ip[4])
{
	memcpy(arptable_tftp[TFTP_SERVER].ipaddr.ip, ip, 4);
}

void tftp_set_server_mac(const unsigned char mac[6])
{
	memcpy(arptable_tftp[TFTP_SERVER].node, mac, 6);
}

static volatile unsigned short block_expected;

typedef void (*Func_t)(void);

/* State-event machine for TFTP boot downloader */

typedef enum BootStateTag {
	INVALID_BOOT_STATE = -1,
	BOOT_STATE0_INIT_ARP = 0,
	BOOT_STATE1_TFTP_CLIENT_WRQ = 1,
	BOOT_STATE2_TFTP_SERVER_RRQ = 2,
	NUM_OF_BOOT_STATES = 3
} BootState_t;

typedef enum BootEventTag {
	INVALID_BOOT_EVENT = -1,
	BOOT_EVENT0_ARP_REQ = 0,
	BOOT_EVENT1_ARP_REPLY = 1,
	BOOT_EVENT2_TFTP_RRQ = 2,
	BOOT_EVENT3_TFTP_WRQ = 3,
	BOOT_EVENT4_TFTP_DATA = 4,
	BOOT_EVENT5_TFTP_ACK = 5,
	BOOT_EVENT6_TFTP_ERROR = 6,
	BOOT_EVENT7_TFTP_OACK = 7,
	NUM_OF_BOOT_EVENTS = 8
} BootEvent_t;

static BootState_t bootState;

static unsigned long read_src;    /* RAM address of next block to send */
static unsigned long read_remain; /* bytes remaining to send */
static unsigned char read_pct;    /* last printed progress percentage */

static void errorDrop(void);
static void errorTFTP(void);
static void doARPReply(void);
static void updateARPTable(void);
static void setTFTP_WRQ(void);
static void prepareACK(void);
static void handleTFTP_RRQ(void);
static void handleTFTP_ACK(void);

static unsigned short CLIENT_port;
static unsigned short SERVER_port;

void tftpd_send_ack(unsigned short number);
unsigned short ipheader_chksum(unsigned short *ip, int len);
extern void twiddle(void);

static const Func_t BootStateEvent[NUM_OF_BOOT_STATES][NUM_OF_BOOT_EVENTS] = {
    /*BOOT_STATE0_INIT_ARP*/
    {
	/*BOOT_EVENT0_ARP_REQ*/ doARPReply,
	/*BOOT_EVENT1_ARP_REPLY*/ updateARPTable,
	/*BOOT_EVENT2_TFTP_RRQ*/ handleTFTP_RRQ,
	/*BOOT_EVENT3_TFTP_WRQ*/ setTFTP_WRQ,
	/*BOOT_EVENT4_TFTP_DATA*/ errorDrop,
	/*BOOT_EVENT5_TFTP_ACK*/ errorDrop,
	/*BOOT_EVENT6_TFTP_ERROR*/ errorDrop,
	/*BOOT_EVENT7_TFTP_OACK*/ errorDrop,
    },
    /*BOOT_STATE1_TFTP_CLIENT_WRQ*/
    {
	/*BOOT_EVENT0_ARP_REQ*/ doARPReply,
	/*BOOT_EVENT1_ARP_REPLY*/ updateARPTable,
	/*BOOT_EVENT2_TFTP_RRQ*/ errorTFTP,
	/*BOOT_EVENT3_TFTP_WRQ*/ setTFTP_WRQ,
	/*BOOT_EVENT4_TFTP_DATA*/ prepareACK,
	/*BOOT_EVENT5_TFTP_ACK*/ errorDrop,
	/*BOOT_EVENT6_TFTP_ERROR*/ errorTFTP,
	/*BOOT_EVENT7_TFTP_OACK*/ errorTFTP,
    },
    /*BOOT_STATE2_TFTP_SERVER_RRQ*/
    {
	/*BOOT_EVENT0_ARP_REQ*/ doARPReply,
	/*BOOT_EVENT1_ARP_REPLY*/ updateARPTable,
	/*BOOT_EVENT2_TFTP_RRQ*/ errorTFTP,
	/*BOOT_EVENT3_TFTP_WRQ*/ errorTFTP,
	/*BOOT_EVENT4_TFTP_DATA*/ errorDrop,
	/*BOOT_EVENT5_TFTP_ACK*/ handleTFTP_ACK,
	/*BOOT_EVENT6_TFTP_ERROR*/ errorTFTP,
	/*BOOT_EVENT7_TFTP_OACK*/ errorTFTP,
    },
};

static inline void dispatch_event(BootEvent_t event)
{
	if (event == NUM_OF_BOOT_EVENTS)
		return;
	BootStateEvent[bootState][event]();
}

static void errorDrop(void)
{
	if (!tftpd_is_ready)
		return;
	prom_printf("Boot state error: %d\n", bootState);
}

static void errorTFTP(void)
{
	if (!tftpd_is_ready)
		return;
	bootState = BOOT_STATE0_INIT_ARP;
}

static void doARPReply(void)
{
	struct arprequest *arppacket;
	struct arprequest arpreply;
	unsigned long targetIP;

	arppacket = (struct arprequest *)&(nic.packet[ETH_HLEN]);

	memcpy(&targetIP, arppacket->tipaddr, 4);

	if (targetIP == arptable_tftp[TFTP_SERVER].ipaddr.s_addr) {
		arpreply.hwtype = htons(1);
		arpreply.protocol = htons(ETH_P_IP);
		arpreply.hwlen = ETH_ALEN;
		arpreply.protolen = 4;
		arpreply.opcode = htons(ARP_REPLY);
		memcpy(&(arpreply.shwaddr),
		       &(arptable_tftp[TFTP_SERVER].node), ETH_ALEN);
		memcpy(&(arpreply.sipaddr),
		       &(arptable_tftp[TFTP_SERVER].ipaddr),
		       sizeof(in_addr));
		memcpy(&(arpreply.thwaddr), arppacket->shwaddr, ETH_ALEN);
		memcpy(&(arpreply.tipaddr), arppacket->sipaddr,
		       sizeof(in_addr));

		prepare_txpkt(0, ETH_P_ARP, arppacket->shwaddr,
			      (unsigned char *)&arpreply,
			      (unsigned short)sizeof(arpreply));
	}
}

static void updateARPTable(void) {}

static void tftpd_send_data(unsigned short block, unsigned char *data,
			    unsigned short datalen)
{
	struct iphdr *ip;
	struct udphdr *udp;
	struct tftp_t tftp_tx;

	tftp_tx.opcode = htons(TFTP_DATA);
	tftp_tx.u.data.block = htons(block);
	memcpy(tftp_tx.u.data.download, data, datalen);

	ip = (struct iphdr *)&tftp_tx;
	udp = (struct udphdr *)((unsigned char *)&tftp_tx +
		sizeof(struct iphdr));

	ip->verhdrlen = 0x45;
	ip->service = 0;
	ip->len = htons(20 + 8 + 4 + datalen);
	ip->ident = 0;
	ip->frags = 0;
	ip->ttl = 60;
	ip->protocol = IPPROTO_UDP;
	ip->chksum = 0;
	ip->src.s_addr = arptable_tftp[TFTP_SERVER].ipaddr.s_addr;
	ip->dest.s_addr = arptable_tftp[TFTP_CLIENT].ipaddr.s_addr;
	ip->chksum = ipheader_chksum((unsigned short *)&tftp_tx,
				     sizeof(struct iphdr));

	udp->src = htons(SERVER_port);
	udp->dest = htons(CLIENT_port);
	udp->len = htons(8 + 4 + datalen);
	udp->chksum = 0;

	prepare_txpkt(0, ETH_P_IP, arptable_tftp[TFTP_CLIENT].node,
		      (unsigned char *)&tftp_tx,
		      (unsigned short)(sizeof(struct iphdr) +
				       sizeof(struct udphdr) + 4 + datalen));
}

static void handleTFTP_RRQ(void)
{
	struct udphdr *udpheader;
	unsigned short sent;

	if (!tftpd_is_ready)
		return;

	if (file_length_to_server == 0) {
		prom_printf("**TFTP RRQ Error: no data loaded\n");
		return;
	}

	udpheader = tftp_udp_header();
	if (udpheader->dest != htons(TFTP_PORT))
		return;

	CLIENT_port = ntohs(udpheader->src);
	tftp_capture_client();

	read_src = image_address;
	read_remain = file_length_to_server;
	read_pct = 0;
	block_expected = 1;
	one_tftp_lock = 1;
	bootState = BOOT_STATE2_TFTP_SERVER_RRQ;

	sent = (read_remain > TFTP_DEFAULTSIZE_PACKET) ?
		TFTP_DEFAULTSIZE_PACKET : read_remain;
	tftpd_send_data(block_expected, (unsigned char *)read_src, sent);
	read_src += sent;
	read_remain -= sent;

	prom_printf("\n**TFTP Server Download: %X bytes from %X\n",
		    file_length_to_server, image_address);
}

static void handleTFTP_ACK(void)
{
	struct udphdr *udpheader;
	struct tftp_t *tftppacket;
	unsigned short ack_block;
	unsigned short sent;

	if (!tftpd_is_ready)
		return;

	udpheader = tftp_udp_header();
	if (udpheader->dest != htons(SERVER_port))
		return;

	tftppacket = tftp_packet();
	ack_block = ntohs(tftppacket->u.ack.block);

	if (ack_block != block_expected)
		return;

	block_expected++;
	sent = (read_remain > TFTP_DEFAULTSIZE_PACKET) ?
		TFTP_DEFAULTSIZE_PACKET : read_remain;
	tftpd_send_data(block_expected, (unsigned char *)read_src, sent);
	read_src += sent;
	read_remain -= sent;

	{
		unsigned char pct = ((file_length_to_server - read_remain) *
				     100) / file_length_to_server;
		if (pct != read_pct) {
			read_pct = pct;
			prom_printf("\r%d%%", pct);
		}
	}

	if (sent < TFTP_DEFAULTSIZE_PACKET) {
		bootState = BOOT_STATE0_INIT_ARP;
		one_tftp_lock = 0;
		SERVER_port++;
		prom_printf("\nTFTP Download Complete!\n%s", "<RealTek>");
	}
}

static void setTFTP_WRQ(void)
{
	struct udphdr *udpheader;
	struct tftp_t *tftppacket;

	if (!tftpd_is_ready)
		return;

	udpheader = tftp_udp_header();
	if (udpheader->dest == htons(TFTP_PORT)) {
		CLIENT_port = ntohs(udpheader->src);
		tftppacket = tftp_packet();
		tftp_capture_client();
		prom_printf("\n**TFTP Client Upload, File Name: %s\n",
			    tftppacket->u.wrq);

		address_to_store = image_address;
		file_length_to_server = 0;
		tftpd_send_ack(0x0000);
		block_expected = 1;
		one_tftp_lock = 1;
		bootState = BOOT_STATE1_TFTP_CLIENT_WRQ;
	}
}

SIGN_T sign_tbl[] = { //  signature, name, sig_len, skip, maxSize, reboot
    {FW_SIGNATURE, "Linux kernel", SIG_LEN, 0, 0x1000000, 1},
    {FW_SIGNATURE_WITH_ROOT, "Linux kernel (root-fs)", SIG_LEN, 0, 0x1000000, 1},
    {ROOT_SIGNATURE, "Root filesystem", SIG_LEN, 1, 0x1000000, 0},
    {BOOT_SIGNATURE, "Boot code", SIG_LEN, 1, 0x1000000, 0},
    {ALL1_SIGNATURE, "Total Image", SIG_LEN, 1, 0x1000000, 1},
    {ALL2_SIGNATURE, "Total Image (no check)", SIG_LEN, 1, 0x1000000, 1}};

#define MAX_SIG_TBL (sizeof(sign_tbl) / sizeof(SIGN_T))
int autoBurn = 1;

void autoreboot()
{
	jumpF = (void *)(0xbfc00000);
	outl(0, GIMR0); // mask all interrupt
	cli();
	flush_cache();
	prom_printf("\nreboot.......\n");
	/* enable watchdog reset */
	*(volatile unsigned long *)(0xB800311c) = 0;
	for (;;)
		;
}

void checkAutoFlashing(unsigned long startAddr, int len)
{
	int i = 0;
	unsigned long head_offset = 0, srcAddr, burnLen;
	unsigned short sum = 0;
	int skip_header = 0;
	int reboot = 0;
	IMG_HEADER_T Header;
	int skip_check_signature = 0;
	int trueorfaulse = 0;

	while ((head_offset + sizeof(IMG_HEADER_T)) < len) {
		sum = 0;
		memcpy(&Header, ((char *)startAddr + head_offset),
		       sizeof(IMG_HEADER_T));

		if (!skip_check_signature) {
			for (i = 0; i < MAX_SIG_TBL; i++) {

				if (!memcmp(Header.signature,
					    (char *)sign_tbl[i].signature,
					    sign_tbl[i].sig_len))
					break;
			}
			if (i == MAX_SIG_TBL) {
				head_offset +=
				    Header.len + sizeof(IMG_HEADER_T);
				continue;
			}
			skip_header = sign_tbl[i].skip;
			if (skip_header) {
				srcAddr = startAddr + head_offset +
					  sizeof(IMG_HEADER_T);
				burnLen = Header.len;
			} else {
				srcAddr = startAddr + head_offset;
				burnLen = Header.len + sizeof(IMG_HEADER_T);
			}
			reboot |= sign_tbl[i].reboot;
			prom_printf("\n%s upgrade.\n", sign_tbl[i].comment);
		} else {
			if (!memcmp(Header.signature, BOOT_SIGNATURE, SIG_LEN))
				skip_header = 1;
			else {
				unsigned char *pRoot =
				    ((unsigned char *)startAddr) + head_offset +
				    sizeof(IMG_HEADER_T);
				if (!memcmp(pRoot, SQSH_SIGNATURE, SIG_LEN))
					skip_header = 1;
				else
					skip_header = 0;
			}
			if (skip_header) {
				srcAddr = startAddr + head_offset +
					  sizeof(IMG_HEADER_T);
				burnLen = Header.len;
			} else {
				srcAddr = startAddr + head_offset;
				burnLen = Header.len + sizeof(IMG_HEADER_T);
			}
		}

		if (skip_check_signature) {
			/* 16-bit checksum */
			if (!memcmp(Header.signature, ALL1_SIGNATURE,
				    SIG_LEN) ||
			    !memcmp(Header.signature, ALL2_SIGNATURE,
				    SIG_LEN)) {
				for (i = 0;
				     i < Header.len + sizeof(IMG_HEADER_T);
				     i += 2) {
					sum += *((
					    unsigned short *)(startAddr +
							      head_offset + i));
				}
			} else {
				unsigned short temp = 0;

				for (i = 0; i < Header.len; i += 2) {
					memcpy(
					    &temp,
					    (void *)(startAddr + head_offset +
						     sizeof(IMG_HEADER_T) + i),
					    2); // for alignment issue
					sum += temp;
				}
			}
			if (sum) {
				prom_printf("%.4s image checksum error at %X!\n",
					    Header.signature,
					    startAddr + head_offset);
				return;
			}
			if (!memcmp(Header.signature, ALL1_SIGNATURE,
				    SIG_LEN)) {
				head_offset += sizeof(IMG_HEADER_T);
				continue;
			}
			if (!memcmp(Header.signature, ALL2_SIGNATURE,
				    SIG_LEN)) {
				skip_check_signature = 1;
				head_offset += sizeof(IMG_HEADER_T);
				continue;
			}
		} else {
			/* 16-bit checksum (all cvimg-generated images) */
			for (i = 0; i < Header.len; i += 2) {
				unsigned short temp;
				memcpy(&temp,
				       (void *)(startAddr + head_offset +
						sizeof(IMG_HEADER_T) + i),
				       2);
				sum += temp;
			}
			if (sum) {
				prom_printf("%.4s image checksum error at %X!\n",
					    Header.signature,
					    startAddr + head_offset);
				return;
			}
		}
		prom_printf("checksum Ok !\n");

		if ((burnLen % 0x1000) == 0) { // 4k alignment
			if ((*((unsigned int *)(startAddr + burnLen))) ==
			    0xdeadc0de) { // wrt jffs2 end-of-mark
				prom_printf("it's special wrt image need add 4 "
					    "byte to burnlen =%8x!\n",
					    burnLen);
				burnLen += 4;
			}
		}

		prom_printf(
		    "Flash write: dst=0x%x src=0x%x len=0x%x (%d bytes)\n",
		    Header.burnAddr, srcAddr, burnLen, (int)burnLen);

		if (Header.burnAddr + burnLen >
		    spi_flash_info[0].chip_size) {
			if (spi_flw_image_mio_8198(
				0, Header.burnAddr,
				(unsigned char *)srcAddr,
				spi_flash_info[0].chip_size -
				    Header.burnAddr) &&
			    spi_flw_image_mio_8198(
				1, 0,
				(unsigned char *)(srcAddr +
						  spi_flash_info[0].chip_size -
						  Header.burnAddr),
				Header.burnAddr + burnLen -
				    spi_flash_info[0].chip_size))
				trueorfaulse = 1;
		} else if (spi_flw_image_mio_8198(
			       0, Header.burnAddr,
			       (unsigned char *)srcAddr, burnLen))
			trueorfaulse = 1;

		if (trueorfaulse)
			prom_printf("\nFlash Write Succeeded!\n%s",
				    "<RealTek>");
		else {
			prom_printf("\nFlash Write Failed!\n%s", "<RealTek>");
			return;
		}

		head_offset += Header.len + sizeof(IMG_HEADER_T);
	}
	if (reboot) {
		autoreboot();
	}
}

static void prepareACK(void)
{
	struct udphdr *udpheader;
	struct tftp_t *tftppacket;
	unsigned long tftpdata_length;
	volatile unsigned short block_received = 0;
	if (!tftpd_is_ready)
		return;
	udpheader =
	    (struct udphdr *)&nic.packet[ETH_HLEN + sizeof(struct iphdr)];
	if (udpheader->dest == htons(SERVER_port)) {
		CLIENT_port = ntohs(udpheader->src);
		tftppacket = (struct tftp_t *)&nic.packet[ETH_HLEN];
		block_received = tftppacket->u.data.block;
		if (block_received != (block_expected)) {
			prom_printf("TFTP #\n");
			tftpd_send_ack(block_expected - 1);
		} else {
			tftpdata_length =
			    ntohs(udpheader->len) - 4 - sizeof(struct udphdr);
			memcpy((void *)address_to_store,
			       tftppacket->u.data.download, tftpdata_length);
			address_to_store = address_to_store + tftpdata_length;
			file_length_to_server =
			    file_length_to_server + tftpdata_length;
			twiddle();
			tftpd_send_ack(block_expected);
			block_expected = block_expected + 1;
			if (tftpdata_length < TFTP_DEFAULTSIZE_PACKET) {
				prom_printf("\n**TFTP Client Upload File Size "
					    "= %X Bytes at %X\n",
					    file_length_to_server,
					    image_address);
				nic.packet = eth_packet;
				nic.packetlen = 0;
				block_expected = 0;

				address_to_store = image_address;
				bootState = BOOT_STATE0_INIT_ARP;
				one_tftp_lock = 0;
				SERVER_port++;

				prom_printf("\nSuccess!\n%s", "<RealTek>");

				if (autoBurn) {
					checkAutoFlashing(
					    image_address,
					    file_length_to_server);
				}
			}
		}
	}
}

/**
 * tftpd_entry - Initialize the TFTP server state machine
 *
 * Sets the server IP to 192.168.1.6, initializes the ARP table,
 * packet buffer, and state machine to BOOT_STATE0_INIT_ARP.
 * After this call, kick_tftpd() processes incoming packets.
 */
void tftpd_entry(void)
{
	arptable_tftp[TFTP_SERVER].ipaddr.s_addr = IPTOUL(192, 168, 1, 6);
	arptable_tftp[TFTP_CLIENT].ipaddr.s_addr = IPTOUL(192, 162, 1, 116);

	arptable_tftp[TFTP_SERVER].node[5] = eth0_mac[5];
	arptable_tftp[TFTP_SERVER].node[4] = eth0_mac[4];
	arptable_tftp[TFTP_SERVER].node[3] = eth0_mac[3];
	arptable_tftp[TFTP_SERVER].node[2] = eth0_mac[2];
	arptable_tftp[TFTP_SERVER].node[1] = eth0_mac[1];
	arptable_tftp[TFTP_SERVER].node[0] = eth0_mac[0];

	bootState = BOOT_STATE0_INIT_ARP;
	nic.packet = eth_packet;
	nic.packetlen = 0;

	block_expected = 0;
	one_tftp_lock = 0;

	address_to_store = image_address;

	file_length_to_server = 0;

	SERVER_port = 2098;

	tftpd_is_ready = 1;
}

void tftpd_send_ack(unsigned short number)
{
	struct iphdr *ip;
	struct udphdr *udp;
	struct tftp_t tftp_tx;

	tftp_tx.opcode = htons(TFTP_ACK);
	tftp_tx.u.ack.block = htons(number);

	ip = (struct iphdr *)&tftp_tx;
	udp =
	    (struct udphdr *)((unsigned char *)&tftp_tx + sizeof(struct iphdr));

	ip->verhdrlen = 0x45;
	ip->service = 0;
	ip->len = htons(32);
	ip->ident = 0;
	ip->frags = 0;
	ip->ttl = 60;
	ip->protocol = IPPROTO_UDP;
	ip->chksum = 0;
	ip->src.s_addr = arptable_tftp[TFTP_SERVER].ipaddr.s_addr;
	ip->dest.s_addr = arptable_tftp[TFTP_CLIENT].ipaddr.s_addr;
	ip->chksum =
	    ipheader_chksum((unsigned short *)&tftp_tx, sizeof(struct iphdr));

	udp->src = htons(SERVER_port);
	udp->dest = htons(CLIENT_port);
	udp->len =
	    htons(32 - sizeof(struct iphdr)); /* TFTP IP packet is 32 bytes */
	udp->chksum = 0;

	prepare_txpkt(0, ETH_P_IP, arptable_tftp[TFTP_CLIENT].node,
		      (unsigned char *)&tftp_tx,
		      (unsigned short)sizeof(struct iphdr) +
			  sizeof(struct udphdr) + 4);
}

/**
 * kick_tftpd - Process one received Ethernet packet
 *
 * Called from the Ethernet interrupt handler for each received frame.
 * Classifies the packet (ARP request/reply, TFTP WRQ/DATA/ERROR)
 * and dispatches to the appropriate state-event handler.
 */
void kick_tftpd(void)
{
	unsigned short pkttype = 0;
	struct arprequest *arppacket;
	unsigned short arpopcode;
	struct tftp_t *tftppacket;
	unsigned short tftpopcode;
	struct iphdr *ipheader;
	in_addr ip_addr;
	void (*jump)(void);
	BootEvent_t kick_event = NUM_OF_BOOT_EVENTS;

	unsigned long UDPIPETHheader =
	    ETH_HLEN + sizeof(struct iphdr) + sizeof(struct udphdr);

	if (nic.packetlen >= ETH_HLEN + sizeof(struct arprequest)) {
		pkttype =
		    ((unsigned short)(nic.packet[12] << 8) |
		     (unsigned short)(nic.packet[13]));
	}

	switch (pkttype) {
	case htons(ETH_P_ARP):
		arppacket = (struct arprequest *)&nic.packet[ETH_HLEN];
		arpopcode = arppacket->opcode;

		switch (arpopcode) {
		case htons(ARP_REQUEST):
			if (!memcmp(arppacket->tipaddr,
				    &arptable_tftp[TFTP_SERVER].ipaddr, 4))
				kick_event = BOOT_EVENT0_ARP_REQ;
			break;
		case htons(ARP_REPLY):
			kick_event = BOOT_EVENT1_ARP_REPLY;
			break;
		}
		dispatch_event(kick_event);
		break;

	case htons(ETH_P_IP):
		ipheader = (struct iphdr *)&nic.packet[ETH_HLEN];
		/* word-aligned copy of destination IP */
		ip_addr.ip[0] = ipheader->dest.ip[0];
		ip_addr.ip[1] = ipheader->dest.ip[1];
		ip_addr.ip[2] = ipheader->dest.ip[2];
		ip_addr.ip[3] = ipheader->dest.ip[3];

		if (nic.packetlen > UDPIPETHheader) {
			if (ipheader->verhdrlen == 0x45) {
				if (ip_addr.s_addr ==
				    arptable_tftp[TFTP_SERVER].ipaddr.s_addr) {
					if (!ipheader_chksum(
						(unsigned short *)ipheader,
						sizeof(struct iphdr))) {
						if (ipheader->protocol ==
						    IPPROTO_UDP) {
							tftppacket =
							    (struct tftp_t
								 *)&nic.packet
								[ETH_HLEN];
							tftpopcode =
							    tftppacket->opcode;
							switch (tftpopcode) {
							case htons(TFTP_RRQ):
								if (one_tftp_lock ==
								    0) {
									kick_event =
									    BOOT_EVENT2_TFTP_RRQ;
									rx_kickofftime =
									    get_timer_jiffies();
								}
								break;
							case htons(TFTP_WRQ):
								if (one_tftp_lock ==
								    0) {
									kick_event =
									    BOOT_EVENT3_TFTP_WRQ;
									rx_kickofftime =
									    get_timer_jiffies();
								} else {
									/* WRQ retransmit or timeout (20s) */
									if ((block_expected ==
									     1) ||
									    ((get_timer_jiffies() -
									      rx_kickofftime) >
									     2000)) {
										kick_event =
										    BOOT_EVENT3_TFTP_WRQ;
										rx_kickofftime =
										    get_timer_jiffies();
									}
								}
								break;
							case htons(TFTP_DATA):
								kick_event =
								    BOOT_EVENT4_TFTP_DATA;
								rx_kickofftime =
								    get_timer_jiffies();
								break;
							case htons(TFTP_ACK):
								if (bootState ==
								    BOOT_STATE2_TFTP_SERVER_RRQ) {
									kick_event =
									    BOOT_EVENT5_TFTP_ACK;
									rx_kickofftime =
									    get_timer_jiffies();
								}
								break;
							case htons(TFTP_ERROR):
								kick_event =
								    BOOT_EVENT6_TFTP_ERROR;
								break;
							case htons(TFTP_OACK):
								kick_event =
								    BOOT_EVENT7_TFTP_OACK;
								break;
							}

							dispatch_event(kick_event);
						}
					}
				}
			}
		}
		break;
	}
}

unsigned short ipheader_chksum(unsigned short *ip, int len)
{
	unsigned long sum = 0;
	len >>= 1;
	while (len--) {
		sum += *(ip++);
		if (sum > 0xFFFF)
			sum -= 0xFFFF;
	}
	return ((~sum) & 0x0000FFFF);
}
