# Building and Running CPC Daemon (cpcd) Locally with TCP Support

This document explains how to set up and run the CPC Daemon (`cpcd`) locally for environments requiring TCP communication instead of direct UART. It covers using `socat` to bridge TCP connections to a virtual serial device and explains how to configure and run `cpcd`.

## Prerequisites

- Linux OS (Ubuntu/Debian recommended)
- `socat` installed (`sudo apt-get install socat`)
- Silicon Labs CPC Daemon (`cpcd`) sources cloned locally

## Setup Overview

The installation process will place `cpcd` binaries and default configuration files in system directories (`/usr/local/bin` and `/usr/local/etc`).

The standard `cpcd.conf` file doesn't support direct TCP socket definitions. To circumvent this, we use `socat` to create a virtual UART device that forwards communications to a TCP socket.

## Step-by-Step Instructions

### 1. Clone and Build `cpcd`

Clone the CPC Daemon repository:

```bash
git clone https://github.com/SiliconLabs/cpc-daemon.git
cd cpc-daemon
mkdir build
cd build
cmake ..
make
sudo make install
```
Optionally, after installation, you may remove the `cpc-daemon` directory:

```bash
cd ../..
rm -rf cpc-daemon
```

### 2. Configure Virtual Serial Device with `socat`

Run `socat` to create a virtual serial port (`ttycpcd`) pointing to your remote CPC secondary via TCP (replace `<gateway_ip>` with the actual gateway IP address):

```bash
sudo socat PTY,link=/dev/ttycpcd,raw TCP:<gateway_ip>:8888 
```
Note: The virtual serial device (`ttycpcd`) created by `socat` disappears whenever `socat` stops or encounters an error. Always ensure `socat` is running before starting `cpcd`, and verify that `/dev/ttycpcd` exists.


### 3. Configure `cpcd.conf`

Create and edit your `cpcd.conf` configuration file as follows:

```bash
sudo nano /usr/local/etc/cpcd.conf
```

Insert:

```
instance_name: cpcd_0
bus_type: UART
uart_device_file: /dev/ttycpcd
uart_device_baud: 115200
uart_hardflow: true
stdout_trace: false
trace_to_file: false
traces_folder: /tmp/traces
enable_frame_trace: false
rlimit_nofile: 2000
disable_encryption: true  # Must match the 'CPC Security' setting of the RCP-UART firmware
```

### 4. Running `cpcd` 

#### Auto-starting socat and cpcd with systemd

To automatically restart `socat` and `cpcd` after system reboot (e.g., after a power failure), configure systemd user units as follows (replace `<gateway_ip>` with the actual gateway IP address):

Create the file `/etc/systemd/system/socat-cpcd.service`:

```ini
[Unit]
Description=Socat Virtual Serial to TCP for CPCD
After=network.target

[Service]
ExecStart=/usr/bin/socat PTY,link=/dev/ttycpcd,raw TCP:<gateway_ip>:8888
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

Create another unit file `cpcd.service`:

```ini
[Unit]
Description=CPC Daemon
After=socat-cpcd.service
Requires=socat-cpcd.service

[Service]
ExecStart=/usr/local/bin/cpcd
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

Activate these services:

```bash
sudo systemctl daemon-reload
sudo systemctl enable socat-cpcd.service cpcd.service
sudo systemctl start socat-cpcd.service cpcd.service
```

### 5. Verifying Communication

To check if `cpcd` has started correctly, use the following methods:

#### Check the systemd service status

If you started `cpcd` with `systemd`, check its status. If `cpcd` is running correctly, you should see `Active: active (running)` in the output.

```bash
jnilo@raspberrypi:/usr/local/etc$ systemctl status cpcd
● cpcd.service - CPC Daemon
     Loaded: loaded (/etc/systemd/system/cpcd.service; enabled; preset: enabled)
     Active: active (running) since Sun 2025-03-16 13:43:49 CET; 1min 13s ago
 Invocation: 8a80a80df7fb459380e830d41b04dbc4
   Main PID: 150411 (cpcd)
      Tasks: 5 (limit: 697)
     Memory: 604K (peak: 1.5M)
        CPU: 75ms
     CGroup: /system.slice/cpcd.service
             └─150411 /usr/local/bin/cpcd

Mar 16 13:43:50 raspberrypi cpcd[150411]: [2025-03-16T12:43:49.569960Z] Info : ENCRYPTION IS DISABLED
Mar 16 13:43:50 raspberrypi cpcd[150411]: [2025-03-16T12:43:49.581447Z] Info : Starting daemon in normal mode
Mar 16 13:43:50 raspberrypi cpcd[150411]: [2025-03-16T12:43:49.594782Z] Info : Connecting to Secondary...
Mar 16 13:43:51 raspberrypi cpcd[150411]: [2025-03-16T12:43:50.708321Z] Info : RX capability is 256 bytes
Mar 16 13:43:51 raspberrypi cpcd[150411]: [2025-03-16T12:43:50.708349Z] Info : Connected to Secondary
Mar 16 13:43:51 raspberrypi cpcd[150411]: [2025-03-16T12:43:50.718283Z] Info : Secondary Protocol v5
Mar 16 13:43:51 raspberrypi cpcd[150411]: [2025-03-16T12:43:50.738262Z] Info : Secondary CPC v4.4.5
Mar 16 13:43:51 raspberrypi cpcd[150411]: [2025-03-16T12:43:50.758278Z] Info : Secondary bus bitrate is 115200
Mar 16 13:43:51 raspberrypi cpcd[150411]: [2025-03-16T12:43:50.778203Z] Info : Secondary APP vUNDEFINED
Mar 16 13:43:51 raspberrypi cpcd[150411]: [2025-03-16T12:43:50.778667Z] Info : Daemon startup was successful. Waiting for client connections
jnilo@raspberrypi:/usr/local/etc$


```

#### Check logs using journalctl

To view logs from `cpcd`, use:

```bash
journalctl -u cpcd.service --follow
```

This will display live logs of `cpcd` in real-time.

## Troubleshooting

- **Ensure Firewall Settings:** Confirm that port `8888` on the remote CPC secondary device (`<gateway_ip>`) is open.
- **Check Virtual UART Link:** Confirm `/dev/ttycpcd` exists and is accessible by `cpcd`.

## Additional Resources

- [Official Silicon Labs CPC Documentation](https://docs.silabs.com/bluetooth/latest/multiprotocol-solution-linux/building-cpcd-locally#building-cpcd-locally)

