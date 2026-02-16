# RTL8196E Minimal Ethernet Driver (Linux 5.10) - Specification

## 1. Objectifs
- Driver propre, documente, cible RTL8196E uniquement.
- Un seul port physique Ethernet (port 4 sur la passerelle actuelle).
- Performances maximales (zero-copy RX/TX).
- Compatibilite DT existante (node `ethernet` + `interface@0`).
- IPv4 et IPv6 via le stack Linux (aucun traitement special dans le driver).
- NAPI + interruptions, ethtool stats de base.

## 2. Non-objectifs
- QoS / files multiples / netfilter offload / L3-L4 HW.
- VLANs HW multiples (on ne cree qu'un netdev).
- Scatter-gather (NETIF_F_SG reste desactive).
- XDP / page_pool.

## 3. Contraintes HW incontournables (isoler dans `rtl8196e_hw.*`)
- DMA utilise des adresses KSEG1 (0xAxxxxxxx), pas des dma_addr_t standard.
- Flush cache TX obligatoire: `dma_cache_wback_inv()`.
- Invalidate cache RX/TX descriptors: `dma_cache_inv()`.
- Deux rings RX obligatoires: pkthdr + mbuf.
- Sequence init obligatoire (MEMCR, reset, TRXRDY).
- L2 toCPU entry requise pour reception CPU.
- IRQ passe par le controleur SoC (GIMR bit 15), pas IP4 direct.
- BIST ignore (ne pas bloquer l'init).

## 4. Buffer pool (zero-copy RX)
- Pool prive d'skbs/buffers, adresses stables.
- Hypothese: patch kernel actif dans `net/core/skbuff.c` qui redirige
  `skb_free_head()` vers `free_rtl865x_eth_priv_buf()`.
- Sans ce patch, le driver ne garantit pas l'integrite (option non supportee).

## 5. Compatibilite Device Tree (mode compatible)
- Node parent: `&ethernet` (compatible: `realtek,rtl8196e-mac`).
- On lit le premier enfant `interface@0` uniquement:
  - `ifname` (nom interface)
  - `local-mac-address`
  - `vlan-id` (VID)
  - `member-ports` (masque ports; port 4 = 0x10)
  - `untag-ports` (masque untag)
  - `mtu`
- Les autres enfants sont ignores avec un warning.
- Si `local-mac-address` absent: MAC random locale.
- Par defaut, on fixe port mask sur `member-ports`.

## 6. Architecture fichiers (nouveau repertoire)
- `rtl8196e_main.c`
  - net_device, NAPI, IRQ, ethtool, stats, start_xmit, poll.
- `rtl8196e_hw.c` / `rtl8196e_hw.h`
  - MMIO regs, init sequence, KSEG1 helpers, L2 toCPU, PHY basics.
- `rtl8196e_ring.c` / `rtl8196e_ring.h`
  - Gestion rings TX/RX, descriptors, ownership, cache ops.
- `rtl8196e_pool.c` / `rtl8196e_pool.h`
  - Pool prive RX, alloc/free, hook is_rtl.../free_rtl...
- `rtl8196e_dt.c` / `rtl8196e_dt.h`
  - Parsing DT `interface@0`.
- `rtl8196e_desc.h`
  - struct pktHdr, mbuf (minimal).
- `rtl8196e_regs.h`
  - Registres strictement necessaires (trimmes).
- `Kconfig`, `Makefile`, `AGENTS.md`, `SPEC.md`.

## 7. RX path (zero-copy)
- Deux rings RX:
  - pkthdr ring (descriptors)
  - mbuf ring (buffers)
- Refills via pool prive.
- NAPI poll:
  - lit descriptors, construit skb, `napi_gro_receive()`.
  - remet buffer au ring (pas au kernel).
- Seuil de refill configurable.

## 8. TX path (perf)
- Un seul ring TX.
- Un seul flush cache par paquet (dans `ring.c` juste avant OWN).
- Reclaim TX non bloque par RX:
  - reclaim opportuniste dans `start_xmit` quand ring bas.
  - reclaim dans NAPI (quand RX arrive).
  - timer TX leger si TX-only (1-2 ms) quand `tx_pending > 0`.
- `TXFD` pulse uniquement si ring etait vide.
- BQL actif (`netdev_tx_sent_queue` + `netdev_tx_completed_queue`).

## 9. PHY / Link
- Init PHY minimal, sequence extraite du driver existant mais isolee.
- Lectures de status via registres port (link up, speed, duplex).
- `netif_carrier_on/off` selon lien.

## 10. Valeurs par defaut (tuneables)
- TX descriptors: 600 (comme driver actuel).
- RX pkthdr descriptors: 500.
- Pool RX: 1100 buffers (~2.2MB).
- Threshold stop/wake TX:
  - stop < 32
  - wake > 128
- Ces valeurs seront des macros/params dans `rtl8196e_ring.c`.

## 11. Etapes d'init (resume)
1. Reset switch core
2. MEMCR = 0 puis 0x7f
3. FULL_RST + delay
4. Init PHY
5. Setup rings (KSEG1 addrs)
6. CPUICR: TXCMD | RXCMD | BURST | MBUF_2048 | EXCLUDE_CRC
7. CPUIIMR: RX_DONE | TX_DONE | LINK_CHANGE | RUNOUT
8. TRXRDY

## 12. Tests
- Ping IPv4/IPv6
- SSH stable
- iperf TCP (TX/RX) >= 80 Mbps sur RX, gap TX < 10%
- `ethtool -S` (ring, pool, tx_full)
- Pas de warnings `rx_pool_empty_events`.

