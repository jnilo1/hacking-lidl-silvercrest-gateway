# lib_uart_config.sh — apply a board's UART routing into a generated VCOM header
#
# Sourced by the per-firmware build scripts (build_ncp.sh, build_ot_rcp.sh).
# The board's UART facts come from boards/<board>/board.env (BOARD_UART_*);
# this helper writes them into the slc-generated VCOM config header.
#
# It substitutes ONLY the value token on each `#define` line, preserving the
# header's original whitespace/alignment. For the reference board (lidl) the
# values are unchanged, so the header stays byte-for-byte identical and the
# resulting firmware is unaffected — the mechanism is exercised on every build
# but is a no-op for the board it was modelled on.
#
# Usage: apply_uart_config <header> <define-prefix> <flow-hw-token> <flow-none-token> <flow-sw-token>
#   <define-prefix>   e.g. SL_IOSTREAM_USART_VCOM  (NCP) or SL_UARTDRV_USART_VCOM (OT-RCP)
#   <flow-hw-token>   SDK enum for RTS/CTS handshake (driver-specific)
#   <flow-none-token> SDK enum for no flow control (driver-specific)
#   <flow-sw-token>   SDK enum for software XON/XOFF flow control (driver-specific)

# Resolve BOARD_UART_FLOW (hw|none|sw) to the driver-specific SDK enum token.
# The three args are the hw / none / sw tokens for the driver in question (the
# iostream-usart and uartdrv drivers spell them differently). Echoes the token
# on stdout; returns non-zero on an invalid BOARD_UART_FLOW.
#   Usage: tok=$(flow_control_token <hw-tok> <none-tok> <sw-tok>) || return 1
flow_control_token() {
    case "$BOARD_UART_FLOW" in
        hw)   echo "$1" ;;
        none) echo "$2" ;;
        sw)   echo "$3" ;;
        *) echo "ERROR: board.env BOARD_UART_FLOW='${BOARD_UART_FLOW}' (expected hw|none|sw)" >&2
           return 1 ;;
    esac
}

apply_uart_config() {
    local hdr="$1" p="$2" flow_hw="$3" flow_none="$4" flow_sw="$5"

    # Each BOARD_UART_{TX,RX,CTS,RTS} is "<port-letter> <pin> <loc>".
    local tx_port tx_pin tx_loc rx_port rx_pin rx_loc
    local cts_port cts_pin cts_loc rts_port rts_pin rts_loc flow_tok
    set -- $BOARD_UART_TX;  tx_port=$1  tx_pin=$2  tx_loc=$3
    set -- $BOARD_UART_RX;  rx_port=$1  rx_pin=$2  rx_loc=$3
    set -- $BOARD_UART_CTS; cts_port=$1 cts_pin=$2 cts_loc=$3
    set -- $BOARD_UART_RTS; rts_port=$1 rts_pin=$2 rts_loc=$3

    flow_tok="$(flow_control_token "$flow_hw" "$flow_none" "$flow_sw")" || return 1

    sed -i -E \
        -e "s|(#define ${p}_PERIPHERAL[[:space:]]+)[A-Za-z0-9]+|\1${BOARD_UART_PERIPHERAL}|" \
        -e "s|(#define ${p}_PERIPHERAL_NO[[:space:]]+)[0-9]+|\1${BOARD_UART_PERIPHERAL_NO}|" \
        -e "s|(#define ${p}_TX_PORT[[:space:]]+)gpioPort[A-Z]|\1gpioPort${tx_port}|" \
        -e "s|(#define ${p}_TX_PIN[[:space:]]+)[0-9]+|\1${tx_pin}|" \
        -e "s|(#define ${p}_TX_LOC[[:space:]]+)[0-9]+|\1${tx_loc}|" \
        -e "s|(#define ${p}_RX_PORT[[:space:]]+)gpioPort[A-Z]|\1gpioPort${rx_port}|" \
        -e "s|(#define ${p}_RX_PIN[[:space:]]+)[0-9]+|\1${rx_pin}|" \
        -e "s|(#define ${p}_RX_LOC[[:space:]]+)[0-9]+|\1${rx_loc}|" \
        -e "s|(#define ${p}_CTS_PORT[[:space:]]+)gpioPort[A-Z]|\1gpioPort${cts_port}|" \
        -e "s|(#define ${p}_CTS_PIN[[:space:]]+)[0-9]+|\1${cts_pin}|" \
        -e "s|(#define ${p}_CTS_LOC[[:space:]]+)[0-9]+|\1${cts_loc}|" \
        -e "s|(#define ${p}_RTS_PORT[[:space:]]+)gpioPort[A-Z]|\1gpioPort${rts_port}|" \
        -e "s|(#define ${p}_RTS_PIN[[:space:]]+)[0-9]+|\1${rts_pin}|" \
        -e "s|(#define ${p}_RTS_LOC[[:space:]]+)[0-9]+|\1${rts_loc}|" \
        -e "s|(#define ${p}_FLOW_CONTROL_TYPE[[:space:]]+)[A-Za-z0-9]+|\1${flow_tok}|" \
        "$hdr"
}
