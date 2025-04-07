#!/usr/bin/env python3.12
##################################################################
# Copyright (c) 2024-2024  MDW <mdeweerd@users.noreply.github.com>
##################################################################

# nosec B110
# Dump out flash from RTL bootloader... very slowly!
# ====================================================
# Author: Paul Banks [https://paulbanks.org/]
#

import argparse
import struct
import time

import serial


def send_esc_until_prompt(serial_conn):
    """Send <ESC>\n until remote responds with <RealTek>"""
    while True:
        print("Send ESC and NL")
        serial_conn.write(b"\x1b\n")  # ESC + \n
        time.sleep(0.2)
        response = serial_conn.read(serial_conn.in_waiting)
        try:
            response = response.decode("utf_8")
        except UnicodeDecodeError:
            pass
        finally:
            pass
        if "<RealTek>" in response:
            print("<RealTek> detected.")
            break


def doit(s, fOut, start_addr=0x200000, end_addr=0x400000):
    """Read out flash"""
    # Flash starts at address 0x200000
    send_esc_until_prompt(s)

    print("Starting...")

    step = 0x100
    assert step % 4 == 0
    for flash_addr in range(start_addr, end_addr, step):
        print(f"{flash_addr}")
        s.write(b"FLR 80000000 %X %d\n" % (flash_addr, step))
        print(s.read_until(b"--> "))
        s.write(b"y\r")
        print(s.read_until(b"<RealTek>"))

        s.write(b"DW 80000000 %d\n" % (step / 4))

        data = s.read_until(b"<RealTek>")
        try:
            data = data.decode("utf_8")
        except UnicodeDecodeError:
            pass
        finally:
            pass

        data = data.split("\n\r")
        for line in data:
            parts = line.split("\t")
            for p in parts[1:]:
                fOut.write(struct.pack(">I", int(p, 16)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser("RTL Flash Dumper")
    parser.add_argument(
        "-p",
        "--serial-port",
        type=str,
        help="Serial port device - e.g. /dev/ttyUSB0 or COM3 or /dev/ttyS0",
        required=True,
    )
    parser.add_argument(
        "-o",
        "--output-file",
        type=str,
        help="Path to file to save dump into",
        required=True,
    )
    DEFAULT_START = 0x200000
    DEFAULT_SIZE = 16 * 1024 * 1024
    parser.add_argument(
        "-s",
        "--start-addr",
        type=str,
        help="Start address",
        default=hex(DEFAULT_START),
    )
    parser.add_argument(
        "-e",
        "--end-addr",
        type=str,
        help="End address",
        default=hex(DEFAULT_START + DEFAULT_SIZE),
    )

    args = parser.parse_args()

    s = serial.Serial(args.serial_port, 38400)
    start_addr = int(args.start_addr, 0)
    end_addr = int(args.end_addr, 0)

    with open(args.output_file, "wb") as fOut:
        doit(s, fOut, start_addr, end_addr)
