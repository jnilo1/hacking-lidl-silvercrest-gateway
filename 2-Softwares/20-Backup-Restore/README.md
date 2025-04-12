# 🧠 Backup & Restore of Embedded Flash Memory (GD25Q127C)

## Overview

The Lidl Silvercrest gateway includes a GD25Q127C  flash chip (recognized as GD25Q128C by the linux kernel) storing the bootloader, Linux kernel, root filesystem, and Zigbee configurations.

> ⚠️ **Disclaimer**  
> Flashing or altering your gateway can permanently damage the device if done incorrectly.  
> Always ensure you have verified backups before proceeding.

This guide explains how to **back up and restore** the embedded flash memory using three distinct methods, depending on your level of access to the system:

---

## 🔧 Method 1 – Linux Access via SSH

> ✅ Use this if the gateway is bootable and reachable over SSH.

### 🔄 Backup

```sh
dd if=/dev/mtd0 of=/tmp/mtd0.bin bs=1024k
dd if=/dev/mtd1 of=/tmp/mtd1.bin bs=1024k
dd if=/dev/mtd2 of=/tmp/mtd2.bin bs=1024k
dd if=/dev/mtd3 of=/tmp/mtd3.bin bs=1024k
dd if=/dev/mtd4 of=/tmp/mtd4.bin bs=1024k
```

From the host (using SSH from the host. Ajust ssh port number if needed and replace <gateway_ip> with the relevant IP address):

```sh
ssh -p 2333 -o HostKeyAlgorithms=+ssh-rsa root@<gateway_ip> "cat /tmp/mtd0.bin" > mtd0.bin
ssh -p 2333 -o HostKeyAlgorithms=+ssh-rsa root@<gateway_ip> "cat /tmp/mtd1.bin" > mtd1.bin
ssh -p 2333 -o HostKeyAlgorithms=+ssh-rsa root@<gateway_ip> "cat /tmp/mtd2.bin" > mtd2.bin
ssh -p 2333 -o HostKeyAlgorithms=+ssh-rsa root@<gateway_ip> "cat /tmp/mtd3.bin" > mtd3.bin
ssh -p 2333 -o HostKeyAlgorithms=+ssh-rsa root@<gateway_ip> "cat /tmp/mtd4.bin" > mtd4.bin
```

Then concatenate into a full dump:

```sh
cat mtd0.bin mtd1.bin mtd2.bin mtd3.bin mtd4.bin > fullmtd.bin
```
See the script section at the end of this README to facilitate the process.

---

### ♻️ Restore

> ⚠️ Only restore partitions that are not mounted.  
> `mtd0` to `mtd3` are usually not mounted.  
> `mtd4` (overlay) is mounted read/write — unmount it before restoring or use Method 2 or 3.
Transfer the relevant partition to the gateway, then restore it. E.g.
```sh
ssh -p 2333 -o HostKeyAlgorithms=+ssh-rsa root@<gateway_ip> "cat > /tmp/rootfs-new.bin" < rootfs-new.bin
ssh -p 2333 -o HostKeyAlgorithms=+ssh-rsa root@<gateway_ip> "dd if=/tmp/rootfs-new.bin of=/dev/mtd2 bs=1024k"
```
See the script section at the end of this README to facilitate the process.

---

## 🔧 Method 2 – Bootloader Access (UART + TFTP)

> 🟠 Use this when Linux no longer boots but the Realtek bootloader is accessible via UART.

### 🛠 Setup

> 🛠 **To retrieve or send files using the `FLR` or `FLW` commands, a TFTP server must be running on your host.**

#### Install a tftp client & server on your linux host
```sh
sudo apt install tftpd-hpa tftp-hpa
# start the tftp server daemon
sudo systemctl start tftpd-hpa
```
The default `tftpd-hpa` configuration file is in `/etc/default/tftpd-hpa` and looks like:
```
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/srv/tftp"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure"
```
It shows that the directory used by `tftpd` to store received files or files to be sent is `/srv/tftp`. We need to set up directory access to be able to use it locally:
```
sudo mkdir -p /srv/tftp
sudo chown tftp:tftp /srv/tftp
sudo chmod 775 /srv/tftp
sudo chmod g+s /srv/tftp
sudo usermod -a -G tftp $USER
newgrp tftp
```
You can now read/write to this directory from your $USER account.

#### Accessing the Bootloader
- Connect a USB-to-serial adapter to your host, and wire its RX/TX pins to the gateway's UART interface.
- Power on the gateway and repeatedly press ESC until the <RealTek> prompt appears on the serial console.

---

### 🔄 Backup (via `FLR`)

On the bootloader:
```plaintext
FLR 80000000 00200000 00200000
```

From the host:
```sh
tftp -g -r mtd2.bin 192.168.1.6
```

---

### ♻️ Restore (via `FLW`)

By default, the Realtek bootloader listens on IP address `192.168.1.6`.

```plaintext
LOADADDR 80500000
```

On the host:
```sh
tftp -i 192.168.1.6 put mtd2.bin
```

Back on the bootloader:
```plaintext
FLW 00200000 80500000 00200000 0
```

> ⚠️ All values must be in **hexadecimal**. `AUTOBURN` should be **disabled** (default).

---

### 🧾 Quick Reference: FLR / FLW Commands by Partition

| MTD     | Description        | Offset     | Size       | FLR Command                                       | FLW Command                                       |
|---------|--------------------|------------|------------|--------------------------------------------------|--------------------------------------------------|
| mtd0    | Bootloader + Config| 0x00000000 | 0x00020000 | `FLR 80000000 00000000 00020000`                | `FLW 00000000 80500000 00020000 0`               |
| mtd1    | Kernel             | 0x00020000 | 0x001E0000 | `FLR 80000000 00020000 001E0000`                | `FLW 00020000 80500000 001E0000 0`               |
| mtd2    | Rootfs             | 0x00200000 | 0x00200000 | `FLR 80000000 00200000 00200000`                | `FLW 00200000 80500000 00200000 0`               |
| mtd3    | Tuya Label         | 0x00400000 | 0x00020000 | `FLR 80000000 00400000 00020000`                | `FLW 00400000 80500000 00020000 0`               |
| mtd4    | JFFS2 Overlay      | 0x00420000 | 0x00BE0000 | `FLR 80000000 00420000 00BE0000`                | `FLW 00420000 80500000 00BE0000 0`               |

---

## 🔧 Method 3 – SPI Programmer (CH341A)

> 🔴 Use this if the bootloader is broken or the chip must be restored offline.

### 🔄 Backup

Desolder the chip and use:

```sh
flashrom -p ch341a_spi -c GD25Q127C -r fullmtd_backup.bin
```

---

### ♻️ Restore

```sh
flashrom -p ch341a_spi -c GD25Q127C -w fullmtd.bin
```

---

## 📁 Included Scripts

| Script                        | Method    | Description                                 |
|------------------------------|-----------|---------------------------------------------|
| `backup_mtd_via_ssh.sh`      | Method 1  | Full MTD backup over SSH                    |
| `restore_mtd_via_ssh.sh`     | Method 1  | Restore partitions via SSH + dd             |
| `backup_partition_tftp.sh`   | Method 2  | Backup mtdX partition via FLR + TFTP        |
| `flash_partition_tftp.sh`    | Method 2  | Restore mtdX via LOADADDR, TFTP, and FLW    |

