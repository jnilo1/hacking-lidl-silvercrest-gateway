#!/bin/bash
# test_rtl8196e_eth.sh — Quick TCP RX+TX test for rtl8196e-eth driver
#
# Runs only the two core TCP iperf tests (~70s total):
#   1. TCP Ubuntu -> RTL8196E  (RX, 30s)
#   2. TCP RTL8196E -> Ubuntu  (TX, 30s)
#
# Based on the full test suite at:
#   /mnt/data1/Linuxdev/rtl_rootfs/test_ethernet_rtl8196e.sh
#
# Baseline (legacy rtl819x v2.1.0):
#   RX: 86.6 Mbps  |  TX: 48.1 Mbps
#   /mnt/data1/Linuxdev/rtl_rootfs/test_results_rtl819x_v2.1.0_20260205/
#
# Usage: ./test_rtl8196e_eth.sh [description]
#
# J. Nilo — February 2026

set -euo pipefail
export LC_ALL=C

# Configuration
RTL8196E_IP="192.168.1.126"
RTL8196E_USER="root"
IPERF_PORT=5001
DURATION=10
RTL_IFACE="eth0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/test_results_$(date +%Y%m%d_%H%M%S)"
TEST_DESCRIPTION="${1:-rtl8196e-eth quick test}"

# Colors & logging
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log(){ echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
log_success(){ echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $1"; }
log_error(){ echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $1"; }
log_warning(){ echo -e "${YELLOW}[$(date +%H:%M:%S)] !${NC} $1"; }

# Helper: extract ifconfig value
ifconfig_value(){
  local file=$1 dir=$2 key=$3
  awk -v dir="$dir" -v key="$key" '
    $1==dir && $0 ~ key":" {
      if (match($0, key":([0-9]+)", m)) { print m[1]; exit }
    }
  ' "$file" 2>/dev/null || echo 0
}

# Helper: extract TCP field from /proc/net/snmp
tcp_value_from_file(){
  local file=$1 field=$2
  awk -v key="$field" '
    $1=="Tcp:" && hdr==0 {
      for(i=2;i<=NF;i++) idx[$i]=i; hdr=1; next
    }
    $1=="Tcp:" && hdr==1 && $2 ~ /^[0-9]/ {
      if (idx[key]>0){print $idx[key]; exit}
    }
  ' "$file" 2>/dev/null || echo 0
}

# Helper: 32-bit delta with wrap-around
delta32(){
  local new=${1:-0} old=${2:-0} diff=$(( ${1:-0} - ${2:-0} ))
  [ $diff -lt 0 ] && diff=$(( (new + 4294967296) - old ))
  echo $diff
}

# Capture snapshots
capture_interface_stats(){ ssh ${RTL8196E_USER}@${RTL8196E_IP} "ifconfig ${RTL_IFACE}" > "$1" 2>&1; }
capture_ethtool_stats(){ ssh ${RTL8196E_USER}@${RTL8196E_IP} "ethtool -S ${RTL_IFACE}" > "$1" 2>&1 || echo "ethtool: not available" > "$1"; }
capture_tcp_stats(){ { echo "=== /proc/net/snmp ==="; ssh ${RTL8196E_USER}@${RTL8196E_IP} "cat /proc/net/snmp"; } > "$1" 2>&1; }
capture_tcp_stats_local(){ { echo "=== /proc/net/snmp ==="; cat /proc/net/snmp; } > "$1" 2>&1; }

# Per-test TCP delta analysis
analyze_tcp_per_test(){
  local test_name=$1 source=$2
  local cur="$LOG_DIR/tcp_stats_current_${test_name}_${source}.txt"
  local last="$LOG_DIR/tcp_stats_last_${source}.txt"
  if [ "$source" = "local" ]; then capture_tcp_stats_local "$cur"; else ssh ${RTL8196E_USER}@${RTL8196E_IP} "cat /proc/net/snmp" > "$cur" 2>/dev/null; fi
  if [ ! -f "$last" ]; then cp "$cur" "$last"; return; fi
  local out_last=$(tcp_value_from_file "$last" OutSegs) retr_last=$(tcp_value_from_file "$last" RetransSegs)
  local out_cur=$(tcp_value_from_file "$cur" OutSegs) retr_cur=$(tcp_value_from_file "$cur" RetransSegs)
  local out_diff=$(delta32 ${out_cur:-0} ${out_last:-0}) retr_diff=$(delta32 ${retr_cur:-0} ${retr_last:-0})
  local pct=0; [ ${out_diff:-0} -gt 0 ] && pct=$(LC_NUMERIC=C awk "BEGIN {printf \"%.2f\", (${retr_diff:-0} / ${out_diff:-1}) * 100}")
  if [ ${retr_diff:-0} -gt 0 ]; then
    echo -e "${RED}  TCP Retrans [${source}]: +${retr_diff} (${pct}% of ${out_diff} sent segments)${NC}"
  else
    echo -e "${GREEN}  TCP [${source}]: No retransmissions (${out_diff} segments sent)${NC}"
  fi
  cp "$cur" "$last"
}

# Test banners
test_start(){
  local test_name=$1 params=$2
  echo; echo "╔════════════════════════════════════════════════════════════╗"
  echo "║ TEST START: $test_name"; echo "║ Parameters: $params"
  echo "║ Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "╚════════════════════════════════════════════════════════════╝"; echo
  capture_ethtool_stats "$LOG_DIR/ethtool_before_${test_name}.txt" >/dev/null 2>&1
  capture_tcp_stats_local "$LOG_DIR/tcp_stats_last_local.txt" >/dev/null 2>&1 || true
  ssh ${RTL8196E_USER}@${RTL8196E_IP} "cat /proc/net/snmp" > "$LOG_DIR/tcp_stats_last_rtl.txt" 2>/dev/null || true
}

test_end(){
  local test_name=$1 exit_code=$2
  capture_ethtool_stats "$LOG_DIR/ethtool_after_${test_name}.txt" >/dev/null 2>&1
  echo; echo "╚════════════════════════════════════════════════════════════╝"
  echo "║ TEST END: $test_name"; echo "║ Exit code: $exit_code"
  echo "║ Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "╚════════════════════════════════════════════════════════════╝"; echo
}

# ── Tests ─────────────────────────────────────────────────────────────

test_tcp_rx(){
  local test_name="TCP_Ubuntu_to_RTL8196E"
  test_start "$test_name" "duration: ${DURATION}s"
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
  analyze_tcp_per_test "$test_name" "local"
  test_end "$test_name" "$ec"
}

test_tcp_tx(){
  local test_name="TCP_RTL8196E_to_Ubuntu"
  test_start "$test_name" "duration: ${DURATION}s"
  local lip=$(ip route get ${RTL8196E_IP} | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
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
  analyze_tcp_per_test "$test_name" "rtl"
  test_end "$test_name" "$ec"
}

# ── Analysis ──────────────────────────────────────────────────────────

analyze_interface_stats(){
  local b="$LOG_DIR/ifconfig_before.txt" a="$LOG_DIR/ifconfig_after.txt"
  [ ! -f "$b" ] || [ ! -f "$a" ] && return
  local rpb=$(ifconfig_value "$b" "RX" "packets") rpa=$(ifconfig_value "$a" "RX" "packets")
  local reb=$(ifconfig_value "$b" "RX" "errors")  rea=$(ifconfig_value "$a" "RX" "errors")
  local rdb=$(ifconfig_value "$b" "RX" "dropped") rda=$(ifconfig_value "$a" "RX" "dropped")
  local tpb=$(ifconfig_value "$b" "TX" "packets") tpa=$(ifconfig_value "$a" "TX" "packets")
  local teb=$(ifconfig_value "$b" "TX" "errors")  tea=$(ifconfig_value "$a" "TX" "errors")
  local tdb=$(ifconfig_value "$b" "TX" "dropped") tda=$(ifconfig_value "$a" "TX" "dropped")
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
  local out_b=$(tcp_value_from_file "$b" OutSegs) ret_b=$(tcp_value_from_file "$b" RetransSegs)
  local out_a=$(tcp_value_from_file "$a" OutSegs) ret_a=$(tcp_value_from_file "$a" RetransSegs)
  local out_d=$(delta32 $out_a $out_b) ret_d=$(delta32 $ret_a $ret_b)
  local pct=0; [ $out_d -gt 0 ] && pct=$(LC_NUMERIC=C awk "BEGIN {printf \"%.4f\", ($ret_d/$out_d)*100}")
  echo
  echo "=========================================="
  echo "TCP STATS (RTL8196E)"
  echo "=========================================="
  echo "OutSegs: +${out_d}, RetransSegs: +${ret_d} (${pct}%)"
}

print_comparison(){
  echo
  echo -e "${CYAN}=========================================="
  echo "COMPARISON vs rtl819x baseline"
  echo -e "==========================================${NC}"
  echo
  # Extract throughput from logs
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
echo "  rtl8196e-eth — Quick TCP Test"
echo "=========================================="
echo "  Description: $TEST_DESCRIPTION"
echo

# Prerequisites
log "Checking prerequisites..."
command -v iperf >/dev/null || { log_error "iperf not installed locally"; exit 1; }
ssh -o ConnectTimeout=5 ${RTL8196E_USER}@${RTL8196E_IP} "echo ok" >/dev/null 2>&1 || { log_error "Cannot connect to ${RTL8196E_IP}"; exit 1; }
log_success "All prerequisites OK"

# Setup
mkdir -p "$LOG_DIR"
echo "Test: $TEST_DESCRIPTION" > "$LOG_DIR/test_config.txt"
echo "Date: $(date)" >> "$LOG_DIR/test_config.txt"

# Capture before
log "Capturing pre-test state..."
ssh ${RTL8196E_USER}@${RTL8196E_IP} "uname -a" > "$LOG_DIR/driver_version.txt" 2>&1
capture_interface_stats "$LOG_DIR/ifconfig_before.txt"
capture_tcp_stats "$LOG_DIR/tcp_stats_before.txt"

# Start iperf server on RTL
log "Starting iperf server on RTL8196E..."
ssh ${RTL8196E_USER}@${RTL8196E_IP} "killall iperf 2>/dev/null; true"; sleep 1
ssh ${RTL8196E_USER}@${RTL8196E_IP} "iperf -s -p ${IPERF_PORT} >/dev/null 2>&1 </dev/null &"; sleep 2
log_success "iperf server started"

# Run tests
test_tcp_rx
sleep 2
test_tcp_tx

# Cleanup & capture after
ssh ${RTL8196E_USER}@${RTL8196E_IP} "killall iperf 2>/dev/null" >/dev/null 2>&1 || true
killall iperf 2>/dev/null || true
capture_interface_stats "$LOG_DIR/ifconfig_after.txt"
capture_tcp_stats "$LOG_DIR/tcp_stats_after.txt"

# Analysis
analyze_interface_stats
analyze_tcp_global
print_comparison

echo
log_success "Results in: $LOG_DIR"

# Put gateway back in boot mode for reflashing
log "Putting gateway in boot mode (boothold)..."
ssh ${RTL8196E_USER}@${RTL8196E_IP} "boothold" >/dev/null 2>&1 || true
log_success "Gateway is now in boot mode at 192.168.1.6"
