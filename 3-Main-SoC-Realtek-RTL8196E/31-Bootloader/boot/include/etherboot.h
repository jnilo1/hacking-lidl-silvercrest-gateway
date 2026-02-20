/**************************************************************************
Etherboot -  BOOTP/TFTP Bootstrap Program

Author: Martin Renters
  Date: Dec/93

Stripped to network primitives used by the RTL8196E bootloader.
Original etherboot x86 code (BOOTP/DHCP, NFS, ROM, TCP/HTTP) removed.
**************************************************************************/
#ifndef _ETHERBOOT_H_
#define _ETHERBOOT_H_

#include "boot_common.h"
#include "osdep.h"

#define ESC '\033'

#define DEFAULT_DOWNLOADFILE "kernel"
#define DEFAULT_UPLOADFILE "UpLoad"

#define MAX_TFTP_RETRIES 20
#define MAX_ARP_RETRIES 20

#define TICKS_PER_SEC 18

/* Inter-packet retry in ticks */
#define TIMEOUT (10 * TICKS_PER_SEC)

/*
   Ethernet constants (linux/if_ether.h naming).
   60/1514 are the correct numbers for most NIC controllers.
*/
#define ETH_ALEN 6	   /* Size of Ethernet address */
#define ETH_HLEN 14	   /* Size of ethernet header */
#define ETH_ZLEN 60	   /* Minimum packet */
#define ETH_FRAME_LEN 1514 /* Maximum packet */

#define ARP_CLIENT 0
#define ARP_SERVER 1
#define ARP_GATEWAY 2

#define ETH_P_IP 0x0800
#define ETH_P_ARP 0x0806

#define TFTP_PORT 69

#define IPPROTO_ICMP 1
#define IPPROTO_UDP 17
/* Same after going through htonl */
#define IP_BROADCAST 0xFFFFFFFF

#define ICMP_ECHO      8
#define ICMP_ECHOREPLY 0

#define ARP_REQUEST 1
#define ARP_REPLY 2

#define TFTP_DEFAULTSIZE_PACKET 512
#define TFTP_MAX_PACKET 1432 /* 512 */

#define TFTP_RRQ 1
#define TFTP_WRQ 2
#define TFTP_DATA 3
#define TFTP_ACK 4
#define TFTP_ERROR 5
#define TFTP_OACK 6

#define TFTP_CODE_EOF 1
#define TFTP_CODE_MORE 2
#define TFTP_CODE_ERROR 3
#define TFTP_CODE_BOOT 4
#define TFTP_CODE_CFG 5

#define AWAIT_ARP 0
#define AWAIT_BOOTP 1
#define AWAIT_TFTP 2
#define AWAIT_RARP 3
#define AWAIT_RPC 4
#define AWAIT_QDRAIN 5 /* drain queue, process ARP requests */

/* MIB offsets in flash */
#define HW_SETTING_OFFSET 0x6000
#define DEFAULT_SETTING_OFFSET 0x8000
#define CURRENT_SETTING_OFFSET 0xc000

#define HW_NIC0_MAC_OFFSET 1
#define CURRENT_IP_ADDR_OFFSET 0
#define CURRENT_ELAN_MAC_OFFSET 21

#define TFTP_SERVER 0
#define TFTP_CLIENT 1

/* --- Network data structures --- */

typedef union {
	unsigned long s_addr;
	unsigned char ip[4];
} in_addr;

struct arptable_t {
	in_addr ipaddr;
	unsigned char node[6];
};

/*
 * A pity sipaddr and tipaddr are not longword aligned or we could use
 * in_addr. No, I don't want to use #pragma packed.
 */
struct arprequest {
	unsigned short hwtype;
	unsigned short protocol;
	char hwlen;
	char protolen;
	unsigned short opcode;
	char shwaddr[6];
	char sipaddr[4];
	char thwaddr[6];
	char tipaddr[4];
};

/*
 * Custom IP header (not Linux UAPI layout).
 * Field mapping: verhdrlen->version+ihl, service->tos, len->tot_len,
 * ident->id, frags->frag_off, chksum->check, src->saddr, dest->daddr.
 */
struct iphdr {
	char verhdrlen;
	char service;
	unsigned short len;
	unsigned short ident;
	unsigned short frags;
	char ttl;
	char protocol;
	unsigned short chksum;
	in_addr src;
	in_addr dest;
};

/*
 * Custom UDP header (matches Linux UAPI struct udphdr field layout).
 * Fields: src->source, dest->dest, len->len, chksum->check.
 */
struct udphdr {
	unsigned short src;
	unsigned short dest;
	unsigned short len;
	unsigned short chksum;
};

struct icmphdr {
	unsigned char  type;
	unsigned char  code;
	unsigned short chksum;
	unsigned short id;
	unsigned short seq;
};

struct tftp_t {
	struct iphdr ip;
	struct udphdr udp;
	unsigned short opcode;
	union {
		char rrq[TFTP_DEFAULTSIZE_PACKET];
		char wrq[TFTP_DEFAULTSIZE_PACKET];
		struct {
			unsigned short block;
			char download[TFTP_MAX_PACKET];
		} data;
		struct {
			unsigned short block;
		} ack;
		struct {
			unsigned short errcode;
			char errmsg[TFTP_DEFAULTSIZE_PACKET];
		} err;
		struct {
			char data[TFTP_DEFAULTSIZE_PACKET + 2];
		} oack;
	} u;
};

/* Smaller tftp packet for requests (conserves stack, 512 bytes enough) */
struct tftpreq_t {
	struct iphdr ip;
	struct udphdr udp;
	unsigned short opcode;
	union {
		char rrq[512];
		struct {
			unsigned short block;
		} ack;
		struct {
			unsigned short errcode;
			char errmsg[512 - 2];
		} err;
		struct {
			unsigned short block;
			char download[TFTP_MAX_PACKET];
		} data;
	} u;
};

#define TFTP_MIN_PACKET (sizeof(struct iphdr) + sizeof(struct udphdr) + 4)

/* config.c */
extern struct nic nic;

#endif /* _ETHERBOOT_H_ */
