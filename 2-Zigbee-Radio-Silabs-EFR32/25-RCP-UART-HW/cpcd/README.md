# cpcd - CPC Daemon

Build script for cpcd v4.5.3 from Silicon Labs.
Portable: works on x86_64, ARM64 (Raspberry Pi 4/5), etc.

## Prerequisites

```bash
sudo apt install cmake build-essential
```

## Build and Install

```bash
./build_cpcd.sh              # Build + prompt (TTY) or local (non-TTY)
./build_cpcd.sh --local      # Build + install to /usr/local
./build_cpcd.sh --deb        # Build + generate .deb (/usr)
./build_cpcd.sh clean        # Remove source
```

## Configuration

Edit `/usr/local/etc/cpcd.conf`:

```yaml
bus_type: UART
uart_device_file: tcp://192.168.1.xxx:8888
uart_device_baud: 115200
uart_hardflow: true
```

## Usage

```bash
cpcd -c /usr/local/etc/cpcd.conf
```
