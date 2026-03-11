# IPv6 Kernel Configuration for OpenThread Border Router

This document describes the kernel configuration changes required to support OpenThread Border Router (ot-br-posix) on RTL8196E.

## Configuration Files

| File | Description |
|------|-------------|
| `config-5.10.246-realtek.txt` | Kernel config (IPv6 support included since v2.0) |

## Size Impact

| Metric | Without IPv6 | With IPv6 | Difference |
|--------|--------------|-----------|------------|
| vmlinux (ELF) | ~4.9 MB | 5.6 MB | +700 KB |
| vmlinux.bin (raw) | ~4.2 MB | 4.9 MB | +700 KB |
| kernel.img (LZMA) | ~1.0 MB | 1.2 MB | **+200 KB** |

The compressed image increases by approximately **200 KB** due to the high compressibility of network code.

## New Options Enabled (21 total)

### IPv6 Core (9 options)

```
CONFIG_IPV6=y
```
Core IPv6 protocol stack. Required for all IPv6 functionality.

```
CONFIG_IPV6_ROUTER_PREF=y
```
RFC 4191 Router Preference support. Allows hosts to prefer certain routers over others.

```
CONFIG_IPV6_MULTIPLE_TABLES=y
```
Multiple routing tables for IPv6. Essential for Thread border routing where separate routing decisions are needed for Thread and infrastructure networks.

```
CONFIG_IPV6_NDISC_NODETYPE=y
```
Neighbor Discovery node type tracking. Helps identify whether neighbors are routers or hosts.

```
CONFIG_IPV6_TUNNEL=y
```
IPv6-in-IPv6 tunneling. Used for Thread mesh connectivity.

```
CONFIG_IPV6_SIT=y
```
Simple Internet Transition (6in4) tunneling. Provides IPv6 connectivity over IPv4 networks.

```
CONFIG_INET6_TUNNEL=y
```
Generic IPv6 tunnel infrastructure. Base support for various tunnel types.

### TUN Device (1 option)

```
CONFIG_TUN=y
```
TUN/TAP virtual network device. **Critical** for ot-br-posix which creates the `wpan0` interface as a TUN device to communicate with the Thread network.

### Netfilter Framework (11 options)

```
CONFIG_NETFILTER=y
```
Core netfilter framework. Required for packet filtering and NAT.

```
CONFIG_NETFILTER_INGRESS=y
CONFIG_NETFILTER_EGRESS=y
```
Ingress/egress hooks for early packet processing.

```
CONFIG_NETFILTER_NETLINK=y
```
Netlink interface for netfilter. Used by userspace tools.

```
CONFIG_NF_CONNTRACK=y
```
Connection tracking. Tracks network connections for stateful filtering.

```
CONFIG_NF_CONNTRACK_MARK=y
```
Connection mark support. Allows marking connections for policy routing.

```
CONFIG_NF_CONNTRACK_PROCFS=y
```
Procfs interface for connection tracking (`/proc/net/nf_conntrack`).

```
CONFIG_NF_DEFRAG_IPV4=y
CONFIG_NF_CONNTRACK_IPV4=y
```
IPv4 defragmentation and connection tracking. Required even for IPv6-focused usage.

```
CONFIG_NF_DEFRAG_IPV6=y
CONFIG_NF_CONNTRACK_IPV6=y
```
IPv6 defragmentation and connection tracking. Essential for Thread border routing.

### IEEE 802.15.4 (2 options)

```
CONFIG_IEEE802154=y
```
IEEE 802.15.4 low-rate wireless PAN support. This is the physical/MAC layer protocol underlying Thread/Zigbee.

```
CONFIG_IEEE802154_NL802154_EXPERIMENTAL=y
```
Experimental netlink interface for 802.15.4 configuration.

## Options NOT Enabled

The following options were intentionally left disabled to minimize kernel size:

### IPsec (not needed for Thread)
```
# CONFIG_INET6_AH is not set
# CONFIG_INET6_ESP is not set
# CONFIG_INET6_IPCOMP is not set
```

### Advanced IPv6 Features
```
# CONFIG_IPV6_ROUTE_INFO is not set      # Route information option
# CONFIG_IPV6_OPTIMISTIC_DAD is not set  # Optimistic Duplicate Address Detection
# CONFIG_IPV6_MIP6 is not set            # Mobile IPv6
# CONFIG_IPV6_ILA is not set             # Identifier Locator Addressing
# CONFIG_IPV6_VTI is not set             # Virtual Tunnel Interface
# CONFIG_IPV6_SIT_6RD is not set         # 6rd tunneling
# CONFIG_IPV6_GRE is not set             # GRE tunneling
# CONFIG_IPV6_SUBTREES is not set        # Subtree routing
# CONFIG_IPV6_MROUTE is not set          # Multicast routing
# CONFIG_IPV6_SEG6_LWTUNNEL is not set   # Segment Routing
# CONFIG_IPV6_SEG6_HMAC is not set       # SR HMAC
# CONFIG_IPV6_RPL_LWTUNNEL is not set    # RPL routing
```

### nftables (using minimal iptables-style config instead)
```
# CONFIG_NETFILTER_XTABLES is not set
# CONFIG_NF_TABLES_IPV4 is not set
# CONFIG_NF_TABLES_IPV6 is not set
```

### Advanced Netfilter
```
# CONFIG_NETFILTER_ADVANCED is not set
# CONFIG_NETFILTER_NETLINK_HOOK is not set
# CONFIG_NETFILTER_NETLINK_ACCT is not set
# CONFIG_NETFILTER_NETLINK_QUEUE is not set
# CONFIG_NETFILTER_NETLINK_LOG is not set
# CONFIG_NF_CT_NETLINK is not set
```

### IEEE 802.15.4 Drivers (using RCP via serial, not kernel driver)
```
# CONFIG_IEEE802154_SOCKET is not set    # Raw sockets
# CONFIG_IEEE802154_FAKELB is not set    # Fake loopback
# CONFIG_IEEE802154_AT86RF230 is not set # Atmel driver
# CONFIG_IEEE802154_MRF24J40 is not set  # Microchip driver
# CONFIG_IEEE802154_CC2520 is not set    # TI driver
# CONFIG_IEEE802154_HWSIM is not set     # Hardware simulator
```

## Recommended Options for Full ot-br-posix Deployment

The current configuration provides a **minimal** IPv6 setup. For full ot-br-posix functionality, additional netfilter options are recommended. This section documents what would be needed and why.

### High Priority: ip6tables and ipset

The `otbr-firewall` script uses ip6tables to configure firewall rules:

```bash
# From ot-br-posix/script/otbr-firewall
ip6tables -N OTBR_FORWARD_INGRESS
ip6tables -I FORWARD 1 -o wpan0 -j OTBR_FORWARD_INGRESS
ip6tables -A OTBR_FORWARD_INGRESS -m pkttype --pkt-type unicast -j DROP
ip6tables -A OTBR_FORWARD_INGRESS -m set --match-set otbr-ingress-deny-src src -j DROP
```

**Required options:**
```
CONFIG_NETFILTER_XTABLES=y          # Base for iptables/ip6tables
CONFIG_IP6_NF_IPTABLES=y            # ip6tables core
CONFIG_IP6_NF_FILTER=y              # FILTER table (FORWARD chain)
CONFIG_NETFILTER_XT_MATCH_PKTTYPE=y # -m pkttype match
CONFIG_IP_SET=y                     # ipset core
CONFIG_IP_SET_HASH_NET=y            # hash:net set type
CONFIG_NETFILTER_XT_SET=y           # -m set match for iptables
```

**Estimated size impact:** +50-75 KB compressed

**Note:** Without these options, the `otbr-firewall` script will fail. The border router will still function for basic routing, but without firewall protection.

### Medium Priority: RAW Table for Backbone Router

The ND Proxy feature (used when `OTBR_BACKBONE_ROUTER=ON`) requires the RAW table:

```cpp
// From ot-br-posix/src/backbone_router/nd_proxy.cpp
"ip6tables -t raw -A PREROUTING -6 -d %s -p icmpv6 --icmpv6-type neighbor-solicitation -i %s -j DROP"
```

**Required options:**
```
CONFIG_IP6_NF_RAW=y                 # RAW table for IPv6
CONFIG_NETFILTER_XT_MATCH_HL=y      # Hop limit matching (optional)
```

**Estimated size impact:** +10-15 KB compressed

**Note:** Only needed if Backbone Router feature is enabled in ot-br-posix.

### Medium Priority: Multicast Routing

Thread uses IPv6 multicast for service discovery. Without multicast routing, multicast packets from Thread devices won't be forwarded to the infrastructure network.

**Required option:**
```
CONFIG_IPV6_MROUTE=y                # IPv6 multicast routing
```

**Estimated size impact:** +15-25 KB compressed

### Low Priority: NAT64

If you want Thread devices to access IPv4-only servers, NAT64 support is needed (requires TAYGA in userspace).

**Required options:**
```
CONFIG_NF_NAT=y                     # NAT core
CONFIG_IP_NF_NAT=y                  # IPv4 NAT
CONFIG_IP6_NF_NAT=y                 # IPv6 NAT
CONFIG_NF_NAT_MASQUERADE_IPV4=y     # Masquerading
```

**Estimated size impact:** +40-60 KB compressed

### Summary Table

| Priority | Feature | Options | Size Impact | When Needed |
|----------|---------|---------|-------------|-------------|
| **High** | ip6tables | `NETFILTER_XTABLES`, `IP6_NF_*` | +50 KB | Firewall script |
| **High** | ipset | `IP_SET`, `XT_SET` | +25 KB | Dynamic ACLs |
| Medium | RAW table | `IP6_NF_RAW` | +10 KB | Backbone Router |
| Medium | Multicast | `IPV6_MROUTE` | +20 KB | Service discovery |
| Low | NAT64 | `NF_NAT`, `IP*_NF_NAT` | +50 KB | IPv4 access |

**Total for full functionality:** ~150-175 KB additional compressed size

### Current Limitations

With the current configuration (`config-5.10.246-realtek.txt`):

1. **No ip6tables** - The `otbr-firewall` script won't work
2. **No ipset** - Dynamic address filtering unavailable
3. **No multicast routing** - Thread multicast stays local
4. **No NAT64** - Thread devices can't reach IPv4 servers

**Workaround:** Basic border routing still works. IPv6 packets are forwarded between wpan0 and eth0 using kernel's built-in forwarding (`net.ipv6.conf.all.forwarding=1`), but without firewall rules.

## Building the Kernel

```bash
cd 32-Kernel

# IPv6 is included in the default config since v2.0
./build_kernel.sh
```

## Verifying IPv6 Support

After booting the new kernel, verify IPv6 is enabled:

```bash
# Check IPv6 is compiled in
cat /proc/net/if_inet6

# Check TUN device support
ls /dev/net/tun

# Check netfilter
cat /proc/net/nf_conntrack_expect

# Test IPv6 connectivity
ping6 ::1
```

## Thread Border Router Requirements

For a functional OpenThread Border Router, the kernel must support:

1. **IPv6 stack** - For Thread-to-IPv6 routing
2. **TUN device** - For the wpan0 interface
3. **Netfilter** - For packet forwarding between interfaces
4. **Multiple routing tables** - For policy routing

All these requirements (except netfilter, see limitations above) are met by the default `config-5.10.246-realtek.txt` since v2.0.

## References

- [OpenThread Border Router Platform](https://openthread.io/guides/border-router)
- [Linux IPv6 HOWTO](https://www.tldp.org/HOWTO/Linux+IPv6-HOWTO/)
- [Netfilter Documentation](https://www.netfilter.org/documentation/)
