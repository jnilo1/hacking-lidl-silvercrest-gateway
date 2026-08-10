#!/bin/bash
# test_rtl8196e_eth_iperf3.sh — RTL8196E Ethernet test with iperf3
#
# iperf3 sibling of test_rtl8196e_eth.sh.  The two harnesses are kept
# separate on purpose: iperf2 and iperf3 use incompatible protocols,
# their CLI/output formats differ, and the historical regression
# baselines were established with iperf2 — preserving them under that
# script avoids a measurement bias on long-running comparisons.
#
# This script also captures the rtl8196e-eth-specific ethtool kick
# counters (added in v3.4.1) before/after each TX-bearing test, so the
# coalescing path can be verified at the same time as the throughput.
#
# Test matrix (Full Auto mode):
#   1. TCP Ubuntu -> RTL8196E      (RX, 30s)         iperf3 -c
#   2. TCP RTL8196E -> Ubuntu      (TX, 30s)         iperf3 -c -R
#   3. TCP Parallel 4 streams      (RX, 30s)         iperf3 -c -P 4
#   4. TCP Parallel 8 streams      (RX, 30s)         iperf3 -c -P 8
#   5. TCP Stress Long Duration    (RX, 5 min)       iperf3 -c -t 300
#   6. UDP Ubuntu -> RTL8196E      @ 10M, 50M, 100M  iperf3 -c -u -b
#   7. UDP Bidirectional           50M each way      iperf3 -c --bidir -u -b
#
# Baseline (rtl8196e-eth v2.4 / kernel 6.18.24, v3.4.1):
#   TCP RX: 93.7 Mbit/s  |  TCP TX: 70.0 Mbit/s
#
# Can be run from any directory — results are saved in 32-Kernel/.
#
# Usage: ./scripts/test_rtl8196e_eth_iperf3.sh [description]
#        RTL8196E_IP=10.0.0.1 ./scripts/test_rtl8196e_eth_iperf3.sh "..."
#
# Requires iperf3 on host AND gateway (3.x at both ends; protocol is
# version-stable across minor releases).
#
# J. Nilo — May 2026

set -euo pipefail
export LC_ALL=C

# Configuration
# Gateway address: RTL8196E_IP env > gateway.env > the last gateway installed
# or reached > its hostname > the historic 192.168.1.88 (see lib/gwconf.sh).
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/gwconf.sh"
RTL8196E_IP="${RTL8196E_IP:-$(gwconf_gateway_addr)}"
RTL8196E_USER="${RTL8196E_USER:-root}"
IPERF_PORT=5201		# iperf3 default; differs from iperf2's 5001
DURATION=30
RTL_IFACE="eth0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${KERNEL_DIR}/test_results_iperf3_$(date +%Y%m%d_%H%M%S)"
TEST_MODE="${TEST_MODE:-full}"
TEST_DESCRIPTION="${1:-rtl8196e-eth iperf3 full test}"
TEST_FAILURES=0

# Colors & logging
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log(){ echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
log_success(){ echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $1"; }
log_error(){ echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $1"; }
log_warning(){ echo -e "${YELLOW}[$(date +%H:%M:%S)] !${NC} $1"; }
log_info(){ echo -e "${CYAN}[$(date +%H:%M:%S)] ℹ${NC} $1"; }

# ── Helpers (identical to iperf2 sibling) ─────────────────────────────

stat_value(){
  local file=$1 key=$2
  awk -F= -v k="$key" '$1==k {print $2; exit}' "$file" 2>/dev/null || echo 0
}

tcp_value_from_file(){
  local file=$1 field=$2
  awk -v key="$field" '
    $1=="Tcp:" && hdr==0 { for(i=2;i<=NF;i++) idx[$i]=i; hdr=1; next }
    $1=="Tcp:" && hdr==1 && $2 ~ /^[0-9]/ { if (idx[key]>0){print $idx[key]; exit} }
  ' "$file" 2>/dev/null || echo 0
}

ethtool_stat_value(){
  local file=$1 key=$2
  awk -F: -v k="$key" '
    {
      sub(/^[ \t]+/, "", $1)
      if ($1 == k) { gsub(/[ \t]/, "", $2); print $2; exit }
    }
  ' "$file" 2>/dev/null || echo 0
}

delta32(){
  local new=${1:-0} old=${2:-0} diff=$(( ${1:-0} - ${2:-0} ))
  [ $diff -lt 0 ] && diff=$(( (new + 4294967296) - old ))
  echo $diff
}

capture_interface_stats(){
  ssh ${RTL8196E_USER}@${RTL8196E_IP} \
    "cd /sys/class/net/${RTL_IFACE}/statistics && for f in rx_packets rx_errors rx_dropped rx_bytes tx_packets tx_errors tx_dropped tx_bytes; do echo \$f=\$(cat \$f); done" \
    > "$1" 2>&1 || echo "" > "$1"
}
capture_ethtool_stats(){
  ssh ${RTL8196E_USER}@${RTL8196E_IP} "ethtool -S ${RTL_IFACE}" > "$1" 2>&1 || echo "ethtool: not available" > "$1"
}
capture_tcp_stats(){
  { echo "=== /proc/net/snmp ==="; ssh ${RTL8196E_USER}@${RTL8196E_IP} "cat /proc/net/snmp"; echo
    echo "=== /proc/net/netstat ==="; ssh ${RTL8196E_USER}@${RTL8196E_IP} "cat /proc/net/netstat"; } > "$1" 2>&1
}
capture_tcp_stats_local(){
  { echo "=== /proc/net/snmp ==="; cat /proc/net/snmp; echo
    echo "=== /proc/net/netstat ==="; cat /proc/net/netstat; } > "$1" 2>&1
}
capture_udp_stats(){
  ssh ${RTL8196E_USER}@${RTL8196E_IP} "cat /proc/net/snmp" > "$1" 2>&1
}

analyze_tcp_per_test(){
  local test_name=$1
  [[ "$test_name" =~ ^UDP_ ]] && return
  local source="rtl"
  case "$test_name" in
    TCP_Ubuntu_to_RTL8196E*|TCP_Parallel_*|TCP_Stress_Long_Duration) source="local" ;;
    TCP_RTL8196E_to_Ubuntu) source="rtl" ;;
  esac
  local cur="$LOG_DIR/tcp_stats_current_${test_name}_${source}.txt"
  local last="$LOG_DIR/tcp_stats_last_${source}.txt"
  if [ "$source" = "local" ]; then capture_tcp_stats_local "$cur"
  else ssh ${RTL8196E_USER}@${RTL8196E_IP} "cat /proc/net/snmp" > "$cur" 2>/dev/null; fi
  if [ ! -f "$last" ]; then cp "$cur" "$last"; return; fi
  local out_last=$(tcp_value_from_file "$last" OutSegs) retr_last=$(tcp_value_from_file "$last" RetransSegs) inerr_last=$(tcp_value_from_file "$last" InErrs)
  local out_cur=$(tcp_value_from_file "$cur" OutSegs) retr_cur=$(tcp_value_from_file "$cur" RetransSegs) inerr_cur=$(tcp_value_from_file "$cur" InErrs)
  local out_diff=$(delta32 ${out_cur:-0} ${out_last:-0}) retr_diff=$(delta32 ${retr_cur:-0} ${retr_last:-0}) inerr_diff=$(delta32 ${inerr_cur:-0} ${inerr_last:-0})
  local pct=0; [ ${out_diff:-0} -gt 0 ] && pct=$(LC_NUMERIC=C awk "BEGIN {printf \"%.2f\", (${retr_diff:-0} / ${out_diff:-1}) * 100}")
  if [ ${retr_diff:-0} -gt 0 ]; then
    echo -e "${RED}  TCP Retrans [${source}]: +${retr_diff} (${pct}% of ${out_diff} sent segments)${NC}"
  else
    echo -e "${GREEN}  TCP [${source}]: No retransmissions (${out_diff} segments sent)${NC}"
  fi
  [ ${inerr_diff:-0} -gt 0 ] && echo -e "${RED}  TCP InErrs [${source}]: +${inerr_diff}${NC}"
  {
    echo "=== TCP Stats Delta for $test_name [${source}] ==="
    echo "OutSegs (sent): +${out_diff}"
    echo "RetransSegs: +${retr_diff}"
    [ ${out_diff:-0} -gt 0 ] && echo "Retransmission rate: ${pct}%"
    echo "InErrs: +${inerr_diff}"; echo
  } >> "$LOG_DIR/tcp_per_test.log"
  cp "$cur" "$last"
}

analyze_kick_stats_per_test(){
  local test_name=$1
  local b="$LOG_DIR/ethtool_before_${test_name}.txt"
  local a="$LOG_DIR/ethtool_after_${test_name}.txt"
  [ ! -f "$b" ] || [ ! -f "$a" ] && return
  local total_b=$(ethtool_stat_value "$b" rtl8196e_tx_kicks_total)
  local cold_b=$(ethtool_stat_value "$b" rtl8196e_tx_kicks_cold)
  local thresh_b=$(ethtool_stat_value "$b" rtl8196e_tx_kicks_threshold)
  local drain_b=$(ethtool_stat_value "$b" rtl8196e_tx_kicks_drain)
  local total_a=$(ethtool_stat_value "$a" rtl8196e_tx_kicks_total)
  local cold_a=$(ethtool_stat_value "$a" rtl8196e_tx_kicks_cold)
  local thresh_a=$(ethtool_stat_value "$a" rtl8196e_tx_kicks_threshold)
  local drain_a=$(ethtool_stat_value "$a" rtl8196e_tx_kicks_drain)
  local total_d=$(delta32 ${total_a:-0} ${total_b:-0})
  local cold_d=$(delta32 ${cold_a:-0} ${cold_b:-0})
  local thresh_d=$(delta32 ${thresh_a:-0} ${thresh_b:-0})
  local drain_d=$(delta32 ${drain_a:-0} ${drain_b:-0})
  [ ${total_d:-0} -eq 0 ] && return	# no TX through driver during this test
  local pct=0; [ ${total_d:-0} -gt 0 ] && pct=$(LC_NUMERIC=C awk "BEGIN {printf \"%.1f\", (${thresh_d:-0} / ${total_d:-1}) * 100}")
  echo -e "${CYAN}  TX kicks: total +${total_d} (cold ${cold_d}, threshold ${thresh_d} = ${pct}%, drain ${drain_d})${NC}"
}

test_start_marker(){
  local test_name=$1 params=${2:-""}
  echo
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║ TEST START: $test_name"
  [ -n "$params" ] && echo "║ Parameters: $params"
  echo "║ Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo
  capture_ethtool_stats "$LOG_DIR/ethtool_before_${test_name}.txt" >/dev/null 2>&1
  capture_tcp_stats_local "$LOG_DIR/tcp_stats_last_local.txt" >/dev/null 2>&1 || true
  ssh ${RTL8196E_USER}@${RTL8196E_IP} "cat /proc/net/snmp" > "$LOG_DIR/tcp_stats_last_rtl.txt" 2>/dev/null || true
}

test_end_marker(){
  local test_name=$1 exit_code=${2:-0}
  capture_ethtool_stats "$LOG_DIR/ethtool_after_${test_name}.txt" >/dev/null 2>&1
  analyze_tcp_per_test "$test_name"
  analyze_kick_stats_per_test "$test_name"
  echo
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║ TEST END: $test_name"
  echo "║ Exit code: $exit_code"
  echo "║ Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo
}

ask_run_test(){
  local name=$1
  if [ "$TEST_MODE" = "full" ]; then return 0; fi
  echo; read -p "Run $name? [Y/n] " -n 1 -r; echo
  [[ $REPLY =~ ^[Nn]$ ]] && { log_warning "Skipping $name"; return 1; }
  return 0
}

# ── iperf3 result extraction ──────────────────────────────────────────
# iperf3 text summary lines are tagged with a trailing role word:
#   "  sender" or "  receiver" for TCP/UDP one-way, parallel uses "[SUM]".
#   --bidir adds [TX-C]/[RX-C] before the interval.
# The receiver line is the canonical "what was actually delivered" number.

iperf3_receiver_mbps(){
  # Args: log_file [pattern_extra]
  # Returns: last "X.Y Mbits/sec" found on a line ending with "receiver"
  local f=$1 extra=${2:-}
  grep -E "${extra}.*[0-9]+(\.[0-9]+)?[[:space:]]+[KMG]bits/sec.*receiver[[:space:]]*$" "$f" 2>/dev/null | \
    awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/){unit=$i; v=$(i-1); if(unit ~ /Kbits/) v=v/1000; else if(unit ~ /Gbits/) v=v*1000; print v; exit}}'
}

iperf3_result_valid(){
  local file=$1 minimum_summaries=${2:-1}
  local summaries

  summaries=$(grep -Ec "[0-9]+(\.[0-9]+)?[[:space:]]+[KMG]bits/sec.*receiver[[:space:]]*$" "$file" 2>/dev/null || true)
  [ "$summaries" -ge "$minimum_summaries" ]
}

record_test_failure(){
  local test_name=$1 exit_code=$2

  if [ "$exit_code" -eq 0 ]; then
    log_error "$test_name failed (missing iperf3 receiver summary)"
  else
    log_error "$test_name failed (exit code: $exit_code)"
  fi
  TEST_FAILURES=$((TEST_FAILURES + 1))
}

# ── Tests ─────────────────────────────────────────────────────────────

test_tcp_to_rtl(){
  local test_name="TCP_Ubuntu_to_RTL8196E"; ask_run_test "$test_name" || return 0
  test_start_marker "$test_name" "duration: ${DURATION}s"
  set +e
  timeout --kill-after=3 $((DURATION + 10)) iperf3 -c ${RTL8196E_IP} -p ${IPERF_PORT} -t ${DURATION} -i 1 > "$LOG_DIR/${test_name}.log" 2>&1
  local ec=$?
  set -e
  if [ $ec -eq 0 ] && iperf3_result_valid "$LOG_DIR/${test_name}.log"; then
    log_success "$test_name completed"
    grep -E "^\[.*\][[:space:]]+0\.0+-.*sec.*[0-9]+(\.[0-9]+)?[[:space:]]+[KMG]bits/sec.*receiver" "$LOG_DIR/${test_name}.log" | tail -1 || true
  else
    record_test_failure "$test_name" "$ec"
    [ $ec -eq 0 ] && ec=1
  fi
  test_end_marker "$test_name" "$ec"
}

test_tcp_from_rtl(){
  local test_name="TCP_RTL8196E_to_Ubuntu"; ask_run_test "$test_name" || return 0
  test_start_marker "$test_name" "duration: ${DURATION}s (-R reverse mode)"
  set +e
  # iperf3 -R: client requests reverse mode; server sends, client receives.
  # Avoids the iperf2 dance of running a server on the host + a client on
  # the gateway via SSH.
  timeout --kill-after=3 $((DURATION + 10)) iperf3 -c ${RTL8196E_IP} -p ${IPERF_PORT} -R -t ${DURATION} -i 1 > "$LOG_DIR/${test_name}.log" 2>&1
  local ec=$?
  set -e
  if [ $ec -eq 0 ] && iperf3_result_valid "$LOG_DIR/${test_name}.log"; then
    log_success "$test_name completed"
    grep -E "^\[.*\][[:space:]]+0\.0+-.*sec.*[0-9]+(\.[0-9]+)?[[:space:]]+[KMG]bits/sec.*receiver" "$LOG_DIR/${test_name}.log" | tail -1 || true
  else
    record_test_failure "$test_name" "$ec"
    [ $ec -eq 0 ] && ec=1
  fi
  test_end_marker "$test_name" "$ec"
}

test_tcp_parallel(){
  local n=$1; local test_name="TCP_Parallel_${n}_streams"; ask_run_test "$test_name" || return 0
  test_start_marker "$test_name" "streams: ${n}, duration: ${DURATION}s"
  set +e
  timeout --kill-after=3 $((DURATION + 10)) iperf3 -c ${RTL8196E_IP} -p ${IPERF_PORT} -P ${n} -t ${DURATION} > "$LOG_DIR/${test_name}.log" 2>&1
  local ec=$?
  set -e
  if [ $ec -eq 0 ] && iperf3_result_valid "$LOG_DIR/${test_name}.log"; then
    log_success "$test_name completed"
    grep -E "\[SUM\].*receiver" "$LOG_DIR/${test_name}.log" | tail -1 || true
  else
    record_test_failure "$test_name" "$ec"
    [ $ec -eq 0 ] && ec=1
  fi
  test_end_marker "$test_name" "$ec"
}

test_stress_long(){
  local test_name="TCP_Stress_Long_Duration"; local L=300
  ask_run_test "$test_name (5 minutes)" || return 0
  test_start_marker "$test_name" "duration: ${L}s (5 minutes)"
  set +e
  timeout --kill-after=5 $((L + 10)) iperf3 -c ${RTL8196E_IP} -p ${IPERF_PORT} -t ${L} -i 10 > "$LOG_DIR/${test_name}.log" 2>&1
  local ec=$?
  set -e
  if [ $ec -eq 0 ] && iperf3_result_valid "$LOG_DIR/${test_name}.log"; then
    log_success "$test_name completed"
    grep -E "^\[.*\][[:space:]]+0\.0+-.*sec.*[0-9]+(\.[0-9]+)?[[:space:]]+[KMG]bits/sec.*receiver" "$LOG_DIR/${test_name}.log" | tail -1 || true
  else
    record_test_failure "$test_name" "$ec"
    [ $ec -eq 0 ] && ec=1
  fi
  test_end_marker "$test_name" "$ec"
}

test_udp_to_rtl(){
  local bw=$1; local test_name="UDP_Ubuntu_to_RTL8196E_${bw}"
  ask_run_test "$test_name" || return 0
  test_start_marker "$test_name" "bandwidth: ${bw}, duration: ${DURATION}s"
  set +e
  timeout --kill-after=3 $((DURATION + 10)) iperf3 -c ${RTL8196E_IP} -p ${IPERF_PORT} -u -b ${bw} -t ${DURATION} -i 1 > "$LOG_DIR/${test_name}.log" 2>&1
  local ec=$?
  set -e
  if [ $ec -eq 0 ] && iperf3_result_valid "$LOG_DIR/${test_name}.log"; then
    log_success "$test_name completed"
    # UDP receiver line carries Lost/Total Datagrams in the same row.
    grep -E "^\[.*\][[:space:]]+0\.0+-.*sec.*receiver" "$LOG_DIR/${test_name}.log" | tail -1 || true
  else
    record_test_failure "$test_name" "$ec"
    [ $ec -eq 0 ] && ec=1
  fi
  test_end_marker "$test_name" "$ec"
}

test_udp_bidirectional(){
  local test_name="UDP_Bidirectional"
  ask_run_test "$test_name" || return 0
  test_start_marker "$test_name" "bandwidth: 50M each way (--bidir), duration: ${DURATION}s"
  set +e
  # iperf3 --bidir runs both directions on a single connection — replaces
  # the iperf2 two-process dance (server on host + client on gateway).
  # Output rows are tagged [TX-C] (host -> gw) and [RX-C] (gw -> host).
  timeout --kill-after=3 $((DURATION + 10)) iperf3 -c ${RTL8196E_IP} -p ${IPERF_PORT} -u -b 50M --bidir -t ${DURATION} > "$LOG_DIR/${test_name}.log" 2>&1
  local ec=$?
  set -e
  if [ $ec -eq 0 ] && iperf3_result_valid "$LOG_DIR/${test_name}.log" 2; then
    log_success "$test_name completed"
    echo "  [host -> gw]"; grep -E "\[TX-C\].*receiver" "$LOG_DIR/${test_name}.log" | tail -1 || true
    echo "  [gw -> host]"; grep -E "\[RX-C\].*receiver" "$LOG_DIR/${test_name}.log" | tail -1 || true
  else
    record_test_failure "$test_name" "$ec"
    [ $ec -eq 0 ] && ec=1
  fi
  test_end_marker "$test_name" "$ec"
}

# ── Analysis ──────────────────────────────────────────────────────────

analyze_interface_stats(){
  local b="$LOG_DIR/ifstat_before.txt" a="$LOG_DIR/ifstat_after.txt"
  [ ! -f "$b" ] || [ ! -f "$a" ] && return
  local rpb=$(stat_value "$b" rx_packets) rpa=$(stat_value "$a" rx_packets)
  local reb=$(stat_value "$b" rx_errors)  rea=$(stat_value "$a" rx_errors)
  local rdb=$(stat_value "$b" rx_dropped) rda=$(stat_value "$a" rx_dropped)
  local tpb=$(stat_value "$b" tx_packets) tpa=$(stat_value "$a" tx_packets)
  local teb=$(stat_value "$b" tx_errors)  tea=$(stat_value "$a" tx_errors)
  local tdb=$(stat_value "$b" tx_dropped) tda=$(stat_value "$a" tx_dropped)
  local rpd=$(delta32 $rpa $rpb) red=$(delta32 $rea $reb) rdd=$(delta32 $rda $rdb)
  local tpd=$(delta32 $tpa $tpb) ted=$(delta32 $tea $teb) tdd=$(delta32 $tda $tdb)
  echo
  echo "=========================================="
  echo "INTERFACE STATISTICS (${RTL_IFACE})"
  echo "=========================================="
  echo "RX: +${rpd} pkts, errors: +${red}, dropped: +${rdd}"
  echo "TX: +${tpd} pkts, errors: +${ted}, dropped: +${tdd}"
  if [ $rdd -gt 0 ] || [ $tdd -gt 0 ] || [ $red -gt 0 ] || [ $ted -gt 0 ]; then
    echo -e "${YELLOW}⚠ Errors or drops detected${NC}"
  else
    echo -e "${GREEN}✓ No errors or drops${NC}"
  fi
}

analyze_tcp_global(){
  local b="$LOG_DIR/tcp_stats_before.txt" a="$LOG_DIR/tcp_stats_after.txt"
  [ ! -f "$b" ] || [ ! -f "$a" ] && return
  local out_b=$(tcp_value_from_file "$b" OutSegs) ret_b=$(tcp_value_from_file "$b" RetransSegs) in_b=$(tcp_value_from_file "$b" InSegs)
  local out_a=$(tcp_value_from_file "$a" OutSegs) ret_a=$(tcp_value_from_file "$a" RetransSegs) in_a=$(tcp_value_from_file "$a" InSegs)
  local in_d=$(delta32 $in_a $in_b) out_d=$(delta32 $out_a $out_b) ret_d=$(delta32 $ret_a $ret_b)
  local pct=0; [ $out_d -gt 0 ] && pct=$(LC_NUMERIC=C awk "BEGIN {printf \"%.4f\", ($ret_d/$out_d)*100}")
  echo
  echo "=========================================="
  echo "TCP STATS (RTL8196E)"
  echo "=========================================="
  echo "InSegs: +${in_d}, OutSegs: +${out_d}, RetransSegs: +${ret_d} (${pct}%)"
}

analyze_udp_global(){
  local b="$LOG_DIR/snmp_before.txt" a="$LOG_DIR/snmp_after.txt"
  [ ! -f "$b" ] || [ ! -f "$a" ] && return
  parse_udp(){
    awk '
      $1=="Udp:" && hdr==0 {for(i=2;i<=NF;i++) idx[$i]=i; hdr=1; next}
      $1=="Udp:" && hdr==1 { print $(idx["InDatagrams"])+0, $(idx["NoPorts"])+0, $(idx["InErrors"])+0, $(idx["OutDatagrams"])+0, $(idx["RcvbufErrors"])+0, $(idx["SndbufErrors"])+0; exit }
    ' "$1"
  }
  read ib nb ie ob rb sb < <(parse_udp "$b")
  read ia na iae oa ra sa < <(parse_udp "$a")
  local din=$(delta32 ${ia:-0} ${ib:-0}) dno=$(delta32 ${na:-0} ${nb:-0}) die=$(delta32 ${iae:-0} ${ie:-0})
  local dout=$(delta32 ${oa:-0} ${ob:-0}) drb=$(delta32 ${ra:-0} ${rb:-0}) dsb=$(delta32 ${sa:-0} ${sb:-0})
  local total=$((din + drb)); local loss_pct=0
  [ $total -gt 0 ] && loss_pct=$(LC_NUMERIC=C awk "BEGIN {printf \"%.2f\", ($drb/$total)*100}")
  echo
  echo "=========================================="
  echo "UDP STATS (RTL8196E)"
  echo "=========================================="
  echo "InDatagrams:  +${din}"
  echo "OutDatagrams: +${dout}"
  echo "RcvbufErrors: +${drb}, SndbufErrors: +${dsb}, InErrors: +${die}, NoPorts: +${dno}"
  if [ $total -gt 0 ]; then
    echo "Total packets arrived (in+rcvbuf): ${total}"
    echo "Loss rate (RcvbufErrors / total): ${loss_pct}%"
  fi
}

analyze_kick_stats_global(){
  local b="$LOG_DIR/ethtool_before.txt" a="$LOG_DIR/ethtool_after.txt"
  [ ! -f "$b" ] || [ ! -f "$a" ] && return
  local total_d=$(delta32 $(ethtool_stat_value "$a" rtl8196e_tx_kicks_total) $(ethtool_stat_value "$b" rtl8196e_tx_kicks_total))
  local cold_d=$(delta32  $(ethtool_stat_value "$a" rtl8196e_tx_kicks_cold)  $(ethtool_stat_value "$b" rtl8196e_tx_kicks_cold))
  local thresh_d=$(delta32 $(ethtool_stat_value "$a" rtl8196e_tx_kicks_threshold) $(ethtool_stat_value "$b" rtl8196e_tx_kicks_threshold))
  local drain_d=$(delta32 $(ethtool_stat_value "$a" rtl8196e_tx_kicks_drain) $(ethtool_stat_value "$b" rtl8196e_tx_kicks_drain))
  [ ${total_d:-0} -eq 0 ] && return
  local cold_pct=$(LC_NUMERIC=C awk "BEGIN {printf \"%.1f\", (${cold_d:-0} / ${total_d:-1}) * 100}")
  local thresh_pct=$(LC_NUMERIC=C awk "BEGIN {printf \"%.1f\", (${thresh_d:-0} / ${total_d:-1}) * 100}")
  local drain_pct=$(LC_NUMERIC=C awk "BEGIN {printf \"%.1f\", (${drain_d:-0} / ${total_d:-1}) * 100}")
  echo
  echo "=========================================="
  echo "TX KICK STATS (rtl8196e_tx_kicks_*)"
  echo "=========================================="
  printf "  Total:     +%d\n" "${total_d}"
  printf "  Cold:      +%d (%s%%)\n" "${cold_d}"  "${cold_pct}"
  printf "  Threshold: +%d (%s%%)  ← coalescing batch path\n" "${thresh_d}" "${thresh_pct}"
  printf "  Drain:     +%d (%s%%)\n" "${drain_d}" "${drain_pct}"
}

print_comparison(){
  echo
  echo -e "${CYAN}=========================================="
  echo "COMPARISON vs rtl8196e-eth v3.4.1 baseline"
  echo -e "==========================================${NC}"
  echo
  local rx_mbps=$(iperf3_receiver_mbps "$LOG_DIR/TCP_Ubuntu_to_RTL8196E.log")
  local tx_mbps=$(iperf3_receiver_mbps "$LOG_DIR/TCP_RTL8196E_to_Ubuntu.log")
  printf "  %-25s %10s %10s\n" "" "v3.4.1" "this run"
  printf "  %-25s %10s %10s\n" "TCP RX (host → gw)" "93.7" "${rx_mbps:---}"
  printf "  %-25s %10s %10s\n" "TCP TX (gw → host)" "70.0" "${tx_mbps:---}"
  echo
}

# ── Main ──────────────────────────────────────────────────────────────

cleanup(){ echo; log_warning "Interrupted..."; ssh ${RTL8196E_USER}@${RTL8196E_IP} "killall iperf3 2>/dev/null" >/dev/null 2>&1 || true; pkill iperf3 2>/dev/null || true; exit 1; }
trap cleanup INT TERM

echo "=========================================="
echo "  rtl8196e-eth — iperf3 Test Suite (TCP + UDP)"
echo "=========================================="
echo "  Description: $TEST_DESCRIPTION"
echo "  Mode: $TEST_MODE   (set TEST_MODE=manual for prompts)"
echo

# Prerequisites
log "Checking prerequisites..."
command -v iperf3 >/dev/null || { log_error "iperf3 not installed locally (sudo apt install iperf3)"; exit 1; }
ssh -o ConnectTimeout=5 ${RTL8196E_USER}@${RTL8196E_IP} "echo ok" >/dev/null 2>&1 || { log_error "Cannot connect to ${RTL8196E_IP}"; exit 1; }
LOCAL_IPERF3_VERSION=$(iperf3 --version 2>&1 | head -1)
REMOTE_IPERF3_VERSION=$(ssh ${RTL8196E_USER}@${RTL8196E_IP} "iperf3 --version" 2>&1 | head -1) || {
  log_error "iperf3 not installed on RTL8196E (build via 34-Userdata/iperf3/ then scp -O to /userdata/usr/bin/)"
  exit 1
}
[[ "$LOCAL_IPERF3_VERSION" =~ ^iperf[[:space:]]+3\. ]] || {
  log_error "Local iperf3 is not version 3.x: $LOCAL_IPERF3_VERSION"
  exit 1
}
[[ "$REMOTE_IPERF3_VERSION" =~ ^iperf[[:space:]]+3\. ]] || {
  log_error "Gateway iperf3 is not version 3.x: $REMOTE_IPERF3_VERSION"
  log_error "iperf2 and iperf3 are protocol-incompatible; use test_rtl8196e_eth.sh or deploy a genuine iperf3 binary"
  exit 1
}
log_success "All prerequisites OK"

# Setup
mkdir -p "$LOG_DIR"
{
  echo "Test: $TEST_DESCRIPTION"
  echo "Mode: $TEST_MODE"
  echo "Date: $(date)"
  echo "RTL8196E: ${RTL8196E_IP} (${RTL_IFACE})"
  echo "iperf3 host:    $LOCAL_IPERF3_VERSION"
  echo "iperf3 gateway: $REMOTE_IPERF3_VERSION"
} > "$LOG_DIR/test_config.txt"

# Capture before
log "Capturing pre-test state..."
ssh ${RTL8196E_USER}@${RTL8196E_IP} "uname -a" > "$LOG_DIR/driver_version.txt" 2>&1
capture_interface_stats "$LOG_DIR/ifstat_before.txt"
capture_ethtool_stats "$LOG_DIR/ethtool_before.txt"
capture_tcp_stats "$LOG_DIR/tcp_stats_before.txt"
capture_tcp_stats_local "$LOG_DIR/tcp_stats_before_local.txt"
capture_udp_stats "$LOG_DIR/snmp_before.txt"

# Start single iperf3 server on gateway. iperf3 -s handles both TCP and
# UDP from clients on the same port — no separate UDP server needed
# (unlike iperf2 which needed `iperf -s -u` alongside `iperf -s`).
log "Starting iperf3 server on RTL8196E..."
ssh ${RTL8196E_USER}@${RTL8196E_IP} "killall iperf3 2>/dev/null; true"; sleep 1
ssh ${RTL8196E_USER}@${RTL8196E_IP} "iperf3 -s -p ${IPERF_PORT} -D >/dev/null 2>&1 </dev/null"; sleep 2
log_success "iperf3 server started (port ${IPERF_PORT})"

# Run tests
log "=== TCP Tests ==="
test_tcp_to_rtl;            sleep 2
test_tcp_from_rtl;          sleep 2

log "=== Parallel TCP Tests ==="
test_tcp_parallel 4;        sleep 2
test_tcp_parallel 8;        sleep 2

log "=== Stress Test ==="
test_stress_long

log "=== UDP Tests ==="
test_udp_to_rtl 10M;        sleep 2
test_udp_to_rtl 50M;        sleep 2
test_udp_to_rtl 100M;       sleep 2
test_udp_bidirectional;     sleep 2

# Cleanup & capture after
ssh ${RTL8196E_USER}@${RTL8196E_IP} "killall iperf3 2>/dev/null" >/dev/null 2>&1 || true
pkill iperf3 2>/dev/null || true
capture_interface_stats "$LOG_DIR/ifstat_after.txt"
capture_ethtool_stats "$LOG_DIR/ethtool_after.txt"
capture_tcp_stats "$LOG_DIR/tcp_stats_after.txt"
capture_tcp_stats_local "$LOG_DIR/tcp_stats_after_local.txt"
capture_udp_stats "$LOG_DIR/snmp_after.txt"

# Analysis
analyze_interface_stats
analyze_tcp_global
analyze_udp_global
analyze_kick_stats_global
print_comparison

echo
if [ "$TEST_FAILURES" -gt 0 ]; then
  log_error "$TEST_FAILURES test(s) failed; results in: $LOG_DIR"
  exit 1
fi
log_success "Results in: $LOG_DIR"
