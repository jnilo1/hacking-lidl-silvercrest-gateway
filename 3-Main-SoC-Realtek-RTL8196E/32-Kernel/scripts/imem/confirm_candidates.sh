#!/bin/bash
# Fixed-size, paired confirmation of one I-MEM candidate against its incumbent.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git -C "$KERNEL_DIR" rev-parse --show-toplevel)"
# shellcheck disable=SC1091
. "$REPO_ROOT/lib/gwconf.sh"

TARGET=""; CANDIDATE=""; INCUMBENT=""; OUTPUT=""; EXPECT=""
DURATION=20; GAP=10; REPS=3; ROUNDS=12; STABILIZE=45
BOOT_IP="${BOOT_IP:-192.168.1.6}"
BOOTHOLD_ADDR="${BOOTHOLD_ADDR:-0x01FFEFFC}"
LOCAL_IPERF="$KERNEL_DIR/../34-Userdata/iperf3/iperf3"
REMOTE_IPERF=/tmp/imem-confirm-iperf3

usage() {
	cat <<'EOF'
Usage: confirm_candidates.sh --candidate IMAGE --incumbent IMAGE --output DIR
       --expect RELEASE_PREFIX [gateway-ip]
EOF
}
while [ $# -gt 0 ]; do
	case "$1" in
		--candidate) CANDIDATE="$2"; shift 2 ;;
		--incumbent) INCUMBENT="$2"; shift 2 ;;
		--output) OUTPUT="$2"; shift 2 ;;
		--expect) EXPECT="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) [ -z "$TARGET" ] || { echo "more than one gateway IP" >&2; exit 2; }
			TARGET="$1"; shift ;;
	esac
done
if [ -z "$CANDIDATE" ] || [ -z "$INCUMBENT" ] || [ -z "$OUTPUT" ] || [ -z "$EXPECT" ]; then
	usage >&2; exit 2
fi
CANDIDATE="$(realpath "$CANDIDATE")"; INCUMBENT="$(realpath "$INCUMBENT")"
if [ ! -f "$CANDIDATE" ] || [ ! -f "$INCUMBENT" ]; then echo "image missing" >&2; exit 2; fi
[ -x "$LOCAL_IPERF" ] || { echo "missing static MIPS iperf3: $LOCAL_IPERF" >&2; exit 2; }
if [ -z "$TARGET" ]; then gwconf_resolve_gateway RTL8196E_IP; TARGET="$GWCONF_ADDR"; fi
[ ! -e "$OUTPUT" ] || { echo "output already exists: $OUTPUT" >&2; exit 2; }
# Prove the confirmation-only privilege before touching the gateway.  Testing
# it after the first reboot would leave an avoidable, protocol-empty run and a
# quiesced target when the host sudoers rule is absent or stale.
sudo -n /bin/ip tcp_metrics flush all >/dev/null 2>&1 || {
	echo "tcp_metrics flush preflight failed (sudoers rule missing?)" >&2
	exit 2
}
mkdir -p "$OUTPUT/raw" "$OUTPUT/dmesg"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 \
	-o ServerAliveCountMax=3 -o StrictHostKeyChecking=no "root@$TARGET")
remote() { "${SSH[@]}" "$@"; }
say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
recv_mbps() {
	grep -E '[0-9]+(\.[0-9]+)?[[:space:]]+[KMG]bits/sec.*receiver[[:space:]]*$' \
	| awk '{for(i=1;i<=NF;i++)if($i~/bits\/sec/){u=$i;v=$(i-1);if(u~/Kbits/)v/=1000;else if(u~/Gbits/)v*=1000;print v;exit}}'
}
retr_count() {
	grep -E 'sender[[:space:]]*$' \
	| awk '{for(i=1;i<=NF;i++)if($i~/bits\/sec/){v=$(i+1);print(v~/^[0-9]+$/)?v:"NA";exit}}'
}
median3() { printf '%s\n' "$@" | sort -n | sed -n '2p'; }

wait_linux() {
	for _ in $(seq 1 60); do remote true >/dev/null 2>&1 && return 0; sleep 2; done
	return 1
}
flash_image() {
	local image="$1"
	remote "devmem $BOOTHOLD_ADDR 32 0x484F4C44; sync; reboot" >/dev/null 2>&1 || true
	for _ in $(seq 1 30); do ping -c1 -W1 "$BOOT_IP" >/dev/null 2>&1 && break; done
	ping -c1 -W2 "$BOOT_IP" >/dev/null
	( cd "$KERNEL_DIR" && CONFIRM=y ./flash_kernel.sh "$BOOT_IP" --image "$image" ) >/dev/null
	wait_linux
}
check_dmesg() {
	local path="$1"
	remote dmesg >"$path" 2>&1
	! grep -Eiq 'WARNING:|BUG:|Oops:|Kernel panic|can.t patch jump_label|section mismatch' "$path"
}
quiesce() {
	# shellcheck disable=SC2016 # variables expand on the gateway.
	remote 'for s in S80netwatch S70otbr S50uart_bridge S50serialgateway S60serialgateway S40button; do
	          [ -x /userdata/etc/init.d/$s ] && /userdata/etc/init.d/$s stop >/dev/null 2>&1
	        done
	        rm -f /userdata/thread/* 2>/dev/null
	        sleep 2
	        if ps w | grep -E "[o]tbr-agent|[o]tbr-monitor|[s]40button|[s]erialgateway"; then exit 42; fi
	        if [ -r /sys/module/rtl8196e_uart_bridge/parameters/armed ] &&
	           [ "$(cat /sys/module/rtl8196e_uart_bridge/parameters/armed)" = 1 ]; then exit 42; fi'
}
running_set() {
	remote "ps | awk 'NR>1 {print \$5}'" \
	| sort -u \
	| grep -Ev '^(|\[.*\]|dropbear|sh|ps|awk|grep|tail|imem-confirm-iperf3)$' \
	| paste -sd, -
}
net_snapshot() {
	# shellcheck disable=SC2016 # $c expands on the gateway.
	remote 'for c in rx_errors tx_errors rx_over_errors rx_crc_errors rx_fifo_errors rx_missed_errors rx_length_errors rx_frame_errors tx_fifo_errors tx_aborted_errors tx_carrier_errors collisions rx_dropped tx_dropped; do cat /sys/class/net/eth0/statistics/$c; done' \
	| tr -d '\r' | paste -sd, -
}
counter_delta() {
	awk -v a="$1" -v b="$2" 'BEGIN{n=split(a,x,",");split(b,y,",");h=0;for(i=1;i<=12;i++){d=y[i]-x[i];h+=(d<0?-d:d)};printf "hard=%d soft=%d,%d",h,y[13]-x[13],y[14]-x[14]}'
}
restart_server() {
	remote "killall imem-confirm-ip imem-confirm-iperf3 iperf3 2>/dev/null || true; $REMOTE_IPERF -s -p 5201 -D </dev/null >/dev/null 2>&1"
	sleep 1
}
measure_one() {
	local mode="$1" tag="$2" rep out value count
	restart_server
	if [ "$mode" = tx ]; then
		out="$(timeout --kill-after=5 $((DURATION+15)) iperf3 -c "$TARGET" -p 5201 -R -t "$DURATION" 2>&1 || true)"
	else
		out="$(timeout --kill-after=5 $((DURATION+15)) iperf3 -c "$TARGET" -p 5201 -t "$DURATION" 2>&1 || true)"
	fi
	printf '%s\n' "$out" >"$OUTPUT/raw/$tag.log"
	value="$(printf '%s\n' "$out" | recv_mbps || true)"
	count="$(printf '%s\n' "$out" | retr_count || true)"
	case "$value" in ''|*[!0-9.]*) return 1 ;; esac
	case "$count" in ''|NA|*[!0-9]*) return 1 ;; esac
	MEASURE_VALUE="$value"; MEASURE_RETR="$count"
}

# Freeze all six draws and their exact reverses before the first measurement.
printf 'round\tposition1\tposition2\n' >"$OUTPUT/plan.tsv"
for pair in $(seq 1 6); do
	if [ "$(printf 'C\nI\n' | shuf | head -1)" = C ]; then a=C; b=I; else a=I; b=C; fi
	r1=$((pair*2-1)); r2=$((pair*2))
	printf '%s\t%s\t%s\n%s\t%s\t%s\n' "$r1" "$a" "$b" "$r2" "$b" "$a" >>"$OUTPUT/plan.tsv"
done
printf 'label\tround\ttx\trx\tuname\tpos\tretr\ttcpflush\tretr_unparsed\terr_delta\tstill_running\n' >"$OUTPUT/sweep.tsv"
sha256sum "$CANDIDATE" "$INCUMBENT" "$LOCAL_IPERF" >"$OUTPUT/SHA256SUMS"
printf 'target=%s\nexpect=%s\nduration=%s\ngap=%s\nreps=%s\nrounds=%s\n' \
	"$TARGET" "$EXPECT" "$DURATION" "$GAP" "$REPS" "$ROUNDS" >"$OUTPUT/protocol.txt"

point=0
while IFS=$'\t' read -r round first second; do
	[ "$round" = round ] && continue
	for label in "$first" "$second"; do
		point=$((point+1)); [ "$label" = C ] && image="$CANDIDATE" || image="$INCUMBENT"
		pos=1; [ "$label" = "$second" ] && pos=2
		say "point $point/24: round $round position $pos label $label"
		flash_image "$image" || { echo "flash/boot failure" >&2; exit 1; }
		uname_r="$(remote uname -r)"; case "$uname_r" in "$EXPECT"*) ;; *) echo "unexpected release: $uname_r" >&2; exit 1;; esac
		sleep "$STABILIZE"
		scp -q -O -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$LOCAL_IPERF" "root@$TARGET:$REMOTE_IPERF"
		remote "chmod 755 $REMOTE_IPERF"
		check_dmesg "$OUTPUT/dmesg/${round}-${label}-before.txt" || { echo "kernel warning before point" >&2; exit 1; }
		quiesce || { echo "userland quiesce failed" >&2; exit 1; }
		sleep 15
		still="$(running_set)"
		if sudo -n /bin/ip tcp_metrics flush all >/dev/null 2>&1; then tcpflush=yes; else tcpflush=no; fi
		[ "$tcpflush" = yes ] || { echo "tcp_metrics flush failed" >&2; exit 1; }
		before="$(net_snapshot)"; retr=0; retr_bad=0; txv=(); rxv=()
		for rep in $(seq 1 "$REPS"); do
			measure_one tx "${round}-${label}-tx${rep}" || { echo "invalid TX measurement" >&2; exit 1; }
			txv+=("$MEASURE_VALUE"); retr=$((retr+MEASURE_RETR)); sleep "$GAP"
		done
		for rep in $(seq 1 "$REPS"); do
			measure_one rx "${round}-${label}-rx${rep}" || { echo "invalid RX measurement" >&2; exit 1; }
			rxv+=("$MEASURE_VALUE"); retr=$((retr+MEASURE_RETR)); [ "$rep" -eq "$REPS" ] || sleep "$GAP"
		done
		after="$(net_snapshot)"; errors="$(counter_delta "$before" "$after")"
		check_dmesg "$OUTPUT/dmesg/${round}-${label}-after.txt" || { echo "kernel warning after point" >&2; exit 1; }
		tx="$(median3 "${txv[@]}")"; rx="$(median3 "${rxv[@]}")"
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$label" "$round" "$tx" "$rx" "$uname_r" "$pos" "$retr" "$tcpflush" "$retr_bad" "$errors" "$still" >>"$OUTPUT/sweep.tsv"
		say "point $point/24 recorded (aggregate remains sealed)"
	done
done <"$OUTPUT/plan.tsv"

python3 "$SCRIPT_DIR/confirm_results.py" --dir "$OUTPUT" --candidate C --incumbent I
say "confirmation complete: $OUTPUT"
