#!/bin/bash
# test_rtl8196e_eth.sh — RTL8196E Ethernet robustness test (TCP + UDP, full suite)
#
# Test matrix (Full Auto mode):
#   1. TCP Ubuntu -> RTL8196E      (RX, 30s)
#   2. TCP RTL8196E -> Ubuntu      (TX, 30s)
#   3. TCP Parallel 4 streams      (RX, 30s)
#   4. TCP Parallel 8 streams      (RX, 30s)
#   5. TCP Stress Long Duration    (RX, 5 min)
#   6. UDP Ubuntu -> RTL8196E      @ 10M, 50M, 100M (each 30s)
#   7. UDP Bidirectional           50M each way, 30s
#
# Baseline (legacy rtl819x v2.1.0):
#   TCP RX: 86.6 Mbit/s  |  TCP TX: 48.1 Mbit/s
#
# Can be run from any directory — results are saved in 32-Kernel/.
#
# Usage: ./scripts/test_rtl8196e_eth.sh [description]
#        RTL8196E_IP=10.0.0.1 ./scripts/test_rtl8196e_eth.sh "..."
#
# J. Nilo — February 2026 (full), April 2026 (sysfs/UDP merge for rtl8196e-eth)

set -euo pipefail
export LC_ALL=C

# Configuration
# Gateway address: RTL8196E_IP env > gateway.env > the last gateway installed
# or reached > its hostname > the historic 192.168.1.88 (see lib/gwconf.sh).
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/gwconf.sh"
RTL8196E_IP="${RTL8196E_IP:-$(gwconf_gateway_addr)}"
RTL8196E_USER="${RTL8196E_USER:-root}"
IPERF_PORT=5001
DURATION=30
RTL_IFACE="eth0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${KERNEL_DIR}/test_results_$(date +%Y%m%d_%H%M%S)"
TEST_MODE="${TEST_MODE:-full}"
TEST_DESCRIPTION="${1:-rtl8196e-eth full test}"

# Colors & logging
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log(){ echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
log_success(){ echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $1"; }
log_error(){ echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $1"; }
log_warning(){ echo -e "${YELLOW}[$(date +%H:%M:%S)] !${NC} $1"; }
log_info(){ echo -e "${CYAN}[$(date +%H:%M:%S)] ℹ${NC} $1"; }

# Helper: extract key=value from a /sys-style snapshot file
# File format: one "key=value" per line (e.g. "rx_packets=12345")
stat_value(){
  local file=$1 key=$2
  awk -F= -v k="$key" '$1==k {print $2; exit}' "$file" 2>/dev/null || echo 0
}

# Robust TCP field extraction from /proc/net/snmp snapshot
tcp_value_from_file(){
  local file=$1 field=$2
  awk -v key="$field" '
    $1=="Tcp:" && hdr==0 { for(i=2;i<=NF;i++) idx[$i]=i; hdr=1; next }
    $1=="Tcp:" && hdr==1 && $2 ~ /^[0-9]/ { if (idx[key]>0){print $idx[key]; exit} }
  ' "$file" 2>/dev/null || echo 0
}

# 32-bit delta with wrap-around
delta32(){
  local new=${1:-0} old=${2:-0} diff=$(( ${1:-0} - ${2:-0} ))
  [ $diff -lt 0 ] && diff=$(( (new + 4294967296) - old ))
  echo $diff
}

# Capture snapshots
# Read /sys/class/net/<iface>/statistics/* (always available on any Linux,
# no need for busybox ifconfig or ethtool). Output format: key=value.
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

# Per-test TCP delta analysis
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

# Test banners
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
  echo
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║ TEST END: $test_name"
  echo "║ Exit code: $exit_code"
  echo "║ Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo
}

# ── Test mode helper ──────────────────────────────────────────────────
ask_run_test(){
  local name=$1
  if [ "$TEST_MODE" = "full" ]; then return 0; fi
  echo; read -p "Run $name? [Y/n] " -n 1 -r; echo
  [[ $REPLY =~ ^[Nn]$ ]] && { log_warning "Skipping $name"; return 1; }
  return 0
}

# ── Tests ─────────────────────────────────────────────────────────────

test_tcp_to_rtl(){
  local test_name="TCP_Ubuntu_to_RTL8196E"; ask_run_test "$test_name" || return 0
  test_start_marker "$test_name" "duration: ${DURATION}s"
  set +e
  timeout --kill-after=3 $((DURATION + 3)) iperf -c ${RTL8196E_IP} -p ${IPERF_PORT} -t ${DURATION} -i 1 > "$LOG_DIR/${test_name}.log" 2>&1
  local ec=$?
  set -e
  if [ $ec -eq 0 ] || [ $ec -eq 124 ] || [ $ec -eq 137 ]; then
    log_success "$test_name completed"
    tail -5 "$LOG_DIR/${test_name}.log" | grep -E "^\[.*\] +0\.0+-.* sec.*[0-9]+\.[0-9]+ (Mbits|Kbits|Gbits)/sec" || true
  else
    log_error "$test_name failed (exit code: $ec)"
  fi
  test_end_marker "$test_name" "$ec"
}

test_tcp_from_rtl(){
  local test_name="TCP_RTL8196E_to_Ubuntu"; ask_run_test "$test_name" || return 0
  test_start_marker "$test_name" "duration: ${DURATION}s"
  local lip=$(ip route get ${RTL8196E_IP} 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
  log "Local IP used: $lip"
  killall iperf 2>/dev/null || true; sleep 1
  iperf -s -p ${IPERF_PORT} -B ${lip} > "$LOG_DIR/${test_name}.log" 2>&1 & local sp=$!
  sleep 3
  set +e
  timeout $((DURATION + 10)) ssh ${RTL8196E_USER}@${RTL8196E_IP} "iperf -c ${lip} -p ${IPERF_PORT} -t ${DURATION}" >> "$LOG_DIR/${test_name}.log" 2>&1
  local ec=$?
  set -e
  sleep 2; kill $sp 2>/dev/null || true; wait $sp 2>/dev/null || true
  if [ $ec -eq 0 ]; then
    log_success "$test_name completed"
    tail -5 "$LOG_DIR/${test_name}.log" | grep -E "^\[.*\] +0\.0+-.*\.[0-9]{3,}.* sec.*[0-9]+\.[0-9]+ (Mbits|Kbits|Gbits)/sec" | head -1 || true
  else
    log_error "$test_name failed (exit code: $ec)"
  fi
  test_end_marker "$test_name" "$ec"
}

test_tcp_parallel(){
  local n=$1; local test_name="TCP_Parallel_${n}_streams"; ask_run_test "$test_name" || return 0
  test_start_marker "$test_name" "streams: ${n}, duration: ${DURATION}s"
  set +e
  timeout --kill-after=3 $((DURATION + 3)) iperf -c ${RTL8196E_IP} -p ${IPERF_PORT} -P ${n} -t ${DURATION} > "$LOG_DIR/${test_name}.log" 2>&1
  local ec=$?
  set -e
  if [ $ec -eq 0 ] || [ $ec -eq 124 ] || [ $ec -eq 137 ]; then
    log_success "$test_name completed"
    grep "SUM" "$LOG_DIR/${test_name}.log" | tail -1 || true
  else
    log_error "$test_name failed (exit code: $ec)"
  fi
  test_end_marker "$test_name" "$ec"
}

test_stress_long(){
  local test_name="TCP_Stress_Long_Duration"; local L=300
  ask_run_test "$test_name (5 minutes)" || return 0
  test_start_marker "$test_name" "duration: ${L}s (5 minutes)"
  set +e
  timeout --kill-after=5 $((L + 5)) iperf -c ${RTL8196E_IP} -p ${IPERF_PORT} -t ${L} -i 10 > "$LOG_DIR/${test_name}.log" 2>&1
  local ec=$?
  set -e
  if [ $ec -eq 0 ] || [ $ec -eq 124 ] || [ $ec -eq 137 ]; then
    log_success "$test_name completed"
    tail -5 "$LOG_DIR/${test_name}.log" | grep -E "^\[.*\] +0\.0+-.* sec.*[0-9]+\.[0-9]+ (Mbits|Kbits|Gbits)/sec" || true
  else
    log_error "$test_name failed (exit code: $ec)"
  fi
  test_end_marker "$test_name" "$ec"
}

test_udp_to_rtl(){
  local bw=$1; local test_name="UDP_Ubuntu_to_RTL8196E_${bw}"
  ask_run_test "$test_name" || return 0
  test_start_marker "$test_name" "bandwidth: ${bw}, duration: ${DURATION}s"
  set +e
  timeout --kill-after=3 $((DURATION + 3)) iperf -c ${RTL8196E_IP} -p ${IPERF_PORT} -u -b ${bw} -t ${DURATION} -i 1 > "$LOG_DIR/${test_name}.log" 2>&1
  local ec=$?
  set -e
  if [ $ec -eq 0 ] || [ $ec -eq 124 ] || [ $ec -eq 137 ]; then
    log_success "$test_name completed"
    tail -10 "$LOG_DIR/${test_name}.log" | grep -E "^\[.*\] +0\.0+-.* sec.*[0-9]+\.[0-9]+ (Mbits|Kbits)/sec" || true
    grep -E "\[[^]]+\].*loss" "$LOG_DIR/${test_name}.log" | tail -1 2>/dev/null || true
  else
    log_error "$test_name failed (exit code: $ec)"
  fi
  test_end_marker "$test_name" "$ec"
}

test_udp_bidirectional(){
  local test_name="UDP_Bidirectional"
  ask_run_test "$test_name" || return 0
  test_start_marker "$test_name" "bandwidth: 50M each way, duration: ${DURATION}s"
  local lip=$(ip route get ${RTL8196E_IP} 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
  killall iperf 2>/dev/null || true; sleep 1
  iperf -s -p ${IPERF_PORT} -u -B ${lip} > "$LOG_DIR/${test_name}_server.log" 2>&1 & local sp=$!
  sleep 3
  iperf -c ${RTL8196E_IP} -p ${IPERF_PORT} -u -b 50M -t ${DURATION} > "$LOG_DIR/${test_name}_to_rtl.log" 2>&1 & local p1=$!
  set +e
  timeout $((DURATION + 10)) ssh ${RTL8196E_USER}@${RTL8196E_IP} "iperf -c ${lip} -p ${IPERF_PORT} -u -b 50M -t ${DURATION}" > "$LOG_DIR/${test_name}_from_rtl.log" 2>&1 & local p2=$!
  set -e
  wait $p1 2>/dev/null || true; wait $p2 2>/dev/null || true
  sleep 2; kill $sp 2>/dev/null || true; wait $sp 2>/dev/null || true
  log_success "$test_name completed"
  test_end_marker "$test_name" 0
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

print_comparison(){
  echo
  echo -e "${CYAN}=========================================="
  echo "COMPARISON vs rtl819x baseline"
  echo -e "==========================================${NC}"
  echo
  local rx_mbps=$(grep -E "^\[.*\] +0\.0+-.* sec" "$LOG_DIR/TCP_Ubuntu_to_RTL8196E.log" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1)}' | tail -1)
  local tx_mbps=$(grep -E "^\[.*\] +0\.0+-.*\.[0-9]{3,}.* sec" "$LOG_DIR/TCP_RTL8196E_to_Ubuntu.log" 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1)}' | tail -1)
  printf "  %-25s %10s %10s\n" "" "rtl819x" "rtl8196e-eth"
  printf "  %-25s %10s %10s\n" "TCP RX (host → gw)" "86.6" "${rx_mbps:---}"
  printf "  %-25s %10s %10s\n" "TCP TX (gw → host)" "48.1" "${tx_mbps:---}"
  echo
}

# ── Main ──────────────────────────────────────────────────────────────

cleanup(){ echo; log_warning "Interrupted..."; ssh ${RTL8196E_USER}@${RTL8196E_IP} "killall iperf 2>/dev/null" >/dev/null 2>&1 || true; killall iperf 2>/dev/null || true; exit 1; }
trap cleanup INT TERM

echo "=========================================="
echo "  rtl8196e-eth — Full Test Suite (TCP + UDP)"
echo "=========================================="
echo "  Description: $TEST_DESCRIPTION"
echo "  Mode: $TEST_MODE   (set TEST_MODE=manual for prompts)"
echo

# Prerequisites
log "Checking prerequisites..."
command -v iperf >/dev/null || { log_error "iperf not installed locally"; exit 1; }
ssh -o ConnectTimeout=5 ${RTL8196E_USER}@${RTL8196E_IP} "echo ok" >/dev/null 2>&1 || { log_error "Cannot connect to ${RTL8196E_IP}"; exit 1; }
ssh ${RTL8196E_USER}@${RTL8196E_IP} "iperf --version" >/dev/null 2>&1 || { log_error "iperf not installed on RTL8196E"; exit 1; }
log_success "All prerequisites OK"

# Setup
mkdir -p "$LOG_DIR"
{
  echo "Test: $TEST_DESCRIPTION"
  echo "Mode: $TEST_MODE"
  echo "Date: $(date)"
  echo "RTL8196E: ${RTL8196E_IP} (${RTL_IFACE})"
} > "$LOG_DIR/test_config.txt"

# Capture before
log "Capturing pre-test state..."
ssh ${RTL8196E_USER}@${RTL8196E_IP} "uname -a" > "$LOG_DIR/driver_version.txt" 2>&1
capture_interface_stats "$LOG_DIR/ifstat_before.txt"
capture_ethtool_stats "$LOG_DIR/ethtool_before.txt"
capture_tcp_stats "$LOG_DIR/tcp_stats_before.txt"
capture_tcp_stats_local "$LOG_DIR/tcp_stats_before_local.txt"
capture_udp_stats "$LOG_DIR/snmp_before.txt"

# Start iperf servers (TCP + UDP) on RTL
log "Starting iperf servers on RTL8196E..."
ssh ${RTL8196E_USER}@${RTL8196E_IP} "killall iperf 2>/dev/null; true"; sleep 1
ssh ${RTL8196E_USER}@${RTL8196E_IP} "iperf -s -p ${IPERF_PORT} >/dev/null 2>&1 </dev/null &"; sleep 1
ssh ${RTL8196E_USER}@${RTL8196E_IP} "iperf -s -u -p ${IPERF_PORT} -w 512K >/dev/null 2>&1 </dev/null &"; sleep 2
log_success "iperf servers started"

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
ssh ${RTL8196E_USER}@${RTL8196E_IP} "killall iperf 2>/dev/null" >/dev/null 2>&1 || true
killall iperf 2>/dev/null || true
capture_interface_stats "$LOG_DIR/ifstat_after.txt"
capture_ethtool_stats "$LOG_DIR/ethtool_after.txt"
capture_tcp_stats "$LOG_DIR/tcp_stats_after.txt"
capture_tcp_stats_local "$LOG_DIR/tcp_stats_after_local.txt"
capture_udp_stats "$LOG_DIR/snmp_after.txt"

# Analysis
analyze_interface_stats
analyze_tcp_global
analyze_udp_global
print_comparison

echo
log_success "Results in: $LOG_DIR"
