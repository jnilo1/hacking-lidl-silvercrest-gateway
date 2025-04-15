#!/usr/bin/env python3.12
##################################################################
# Copyright (c) 2024-2024  MDW <mdeweerd@users.noreply.github.com>
##################################################################

# python3 -m pip uninstall crypto
# python3 -m pip uninstall pycrypto
# python3 -m pip install pycryptodome

# Requires PyCrypt
# Not imported at the root so that users without pycrypt can still
# the raw data
import struct
import time
from binascii import unhexlify

import serial

# Interesting info:https://openwrt.org/docs/techref/bootloader/realtek


def send_esc_until_prompt(serial_conn):
    """Send <ESC>\n until remote responds with <RealTek>"""
    while True:
        serial_conn.write(b"\x1b\n")  # ESC + \n
        time.sleep(0.2)
        response = serial_conn.read(serial_conn.in_waiting).decode("utf-8")
        if "<RealTek>" in response:
            print("<RealTek> detected.")
            break


def read_memory(serial_conn, addr, length):
    """Read memory range from Realtek device"""
    # Copy data from flash to RAM
    serial_conn.write(f"FLR 80000000 {addr:X} {length}\n".encode())
    # Wait until Realtek asks for confirmation
    serial_conn.read_until(b"--> ")
    # Confirm
    serial_conn.write(b"y\r")
    # Wait until Realtek confirms
    serial_conn.read_until(b"<RealTek>")
    # Now dump the words we just read
    serial_conn.write(f"DW 80000000 {length // 4}\n".encode())
    # Wait until Realtek confirms
    response = serial_conn.read_until(b"<RealTek>").decode("utf-8")
    # Show the reply on the console
    print(f"Reply:{response}")
    # Split the response
    lines = response.split("\n\r")
    return [line.split("\t")[1:] for line in lines[1:]]


def get_kek(serial_conn):
    """Read KEK from RealTek memory"""
    kek_data = read_memory(serial_conn, 0x401802, 16)
    kek = "".join(kek_data[0])
    return kek


def get_auskey(serial_conn):
    """Read AUSKEY RealTek memory"""
    auskey_data_1 = read_memory(serial_conn, 0x402002, 16)
    auskey_data_2 = read_memory(serial_conn, 0x402012, 16)
    auskey = "".join(auskey_data_1[0] + auskey_data_2[0])
    return auskey


def decode_kek(kek_hex):
    """Read hex KEK value"""

    def _aschar(b):
        return struct.unpack("b", bytes([b & 0xFF]))[0]

    kek = []
    for b in kek_hex:
        c1 = _aschar(kek_hex[0] * b)
        c2 = _aschar((kek_hex[0] * b) // 0x5D)
        kek.append(_aschar(c1 + c2 * -0x5D + ord("!")))
    return bytes(kek)


def main(serial_port):
    """Connect to serial, get KEK and AUSKEY"""
    with serial.Serial(serial_port, 38400, timeout=1) as serial_conn:
        send_esc_until_prompt(serial_conn)

        # Get KEK
        kek_hex = get_kek(serial_conn)
        print(f"> FLR 80000000 401802 16\n< {kek_hex}")

        # Decode KEK
        kek = decode_kek(unhexlify(kek_hex.replace(" ", "")))

        # Get AUSKEY
        auskey_hex = get_auskey(serial_conn)
        print(f"> FLR 80000000 402002 32\n< {auskey_hex}")

        encoded_key = unhexlify(auskey_hex.replace(" ", ""))

        # Decrypt AUSKEY

        if True:
            from Crypto.Cipher import AES

            cipher = AES.new(kek, AES.MODE_ECB)
            auskey = cipher.decrypt(encoded_key)

            print(f"AUSKEY: {auskey.decode('ascii')}")
            print(f"Root password: {auskey[-8:].decode('ascii')}")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="Automate KEK and AUSKEY retrieval"
        " from LIDL Zigbee gateway."
    )
    parser.add_argument(
        "-p",
        "--serial-port",
        type=str,
        required=True,
        help="Serial port device (e.g., /dev/ttyUSB0).",
    )
    args = parser.parse_args()
    main(args.serial_port)
