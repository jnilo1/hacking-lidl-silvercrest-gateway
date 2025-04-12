# 🧠 Backup & Restore of Embedded Flash Memory (GD25Q127C)

## Overview

The Lidl Silvercrest gateway includes a GD25Q127C  flash chip (recognized as GD25Q128C by the Linux kernel) storing the bootloader, Linux kernel, root filesystem, and Zigbee configurations.

> ⚠️ **Disclaimer**  
> Flashing or altering your gateway can permanently damage the device if done incorrectly.  
> Always ensure you have verified backups before proceeding.

This guide explains how to **back up and restore** the embedded flash memory using three distinct methods, depending on your level of access to the system:

---

## 🔧 Method 1 – Linux Access via SSH

✅ Use this method if the gateway is bootable and reachable over SSH.

### 🔄 Backup

On the gateway (via `ssh`), run:

```sh
dd if=/dev/mtdx of=/tmp/mtdx.bin bs=1024k
```

Replace `x` with `0`, `1`, `2`, `3` or `4`.

⚠️ You must unmount `mtd4` before dumping it, as it is typically mounted read/write.

On the host, retrieve the file using `ssh` (adjust port and IP as needed):

```sh
ssh -p 2333 -o HostKeyAlgorithms=+ssh-rsa root@<gateway_ip> "cat /tmp/mtdx.bin" > mtdx.bin
```

Once you have collected all partitions, concatenate them into a full image:

```sh
cat mtd0.bin mtd1.bin mtd2.bin mtd3.bin mtd4.bin > fullmtd.bin
```

💡 Refer to the script section at the end of this README to automate this process.

---

### ♻️ Restore

⚠️ Only restore partitions that are **not mounted**.  
- `mtd0` to `mtd3` are usually safe to write.  
- `mtd4` (overlay) is mounted read/write — unmount it before restoring.

To restore, first transfer the file to the gateway:

```sh
ssh -p 2333 -o HostKeyAlgorithms=+ssh-rsa root@<gateway_ip> "cat > /tmp/rootfs-new.bin" < rootfs-new.bin
```

Then flash it:

```sh
ssh -p 2333 -o HostKeyAlgorithms=+ssh-rsa root@<gateway_ip> "dd if=/tmp/rootfs-new.bin of=/dev/mtd2 bs=1024k"
```

💡 Refer to the script section at the end of this README for a simpler approach.


## 🔧 Method 2 – Bootloader Access (UART + TFTP)

🟠 Use this method if Linux no longer boots, but the Realtek bootloader is still accessible via UART.

⚠️ Note: If Linux fails to boot, it may be due to a corrupted partition.  
- In that case, backup via the bootloader might be **unreliable or incomplete**,  
- but restore can be useful **if you have previously created a valid backup using Method 1**.


### 🛠 Setup

This second method will use Realtek bootloader's `FLR` and `FLW` commands to transfer files via TFTP. Therefore, a TFTP server must be running on your host.**

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
This indicates that the directory used by `tftpd` to store received files or files to be sent is `/srv/tftp`. We need to set up directory access to be able to use it locally:
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

This procedure allows you to **extract the content of a specific MTD partition** from flash memory to RAM, and then download it to your host using `tftp`.

The command `FLR` (Flash Load to RAM) instructs the bootloader to:
- Read data from the SPI flash starting at the given offset
- Load it into a specified address in RAM

Then, the bootloader automatically exposes the RAM content via `tftp`, allowing the host to download it.

#### Example: Backup of the `rootfs` (mtd2)

On the bootloader:
```plaintext
FLR 80000000 00200000 00200000
```

- `80000000` → RAM address where data will be loaded
- `00200000` → flash offset of mtd2
- `00200000` → size of the partition in bytes (here: 2 MiB)

From the host:
```sh
tftp -g -r mtd2.bin 192.168.1.6
```

This command downloads the content from RAM to your local machine, storing it as `mtd2.bin`.

💡 You can repeat this process for each MTD partition (see reference table below).


---

### ♻️ Restore (via `FLW`)

The `FLW` (Flash Write from RAM) command allows you to **write binary data stored in RAM** into a specific region of the SPI flash.

This is typically used after a file has been transferred to the gateway via TFTP and loaded into RAM at a known address.

The command format is:
```plaintext
FLW <flash_offset> <ram_address> <length> 0
```

- `flash_offset`: destination in SPI flash (in hex)
- `ram_address`: where the data is stored in RAM (in hex, e.g. `80500000`)
- `length`: number of bytes to write (in hex)
- `0`: SPI controller number (always `0` on these devices)

#### Example: Restore of the `rootfs` (mtd2)

1. On the bootloader:
```plaintext
LOADADDR 80500000
```

2. From the host, upload the file:
```sh
tftp -i 192.168.1.6 put mtd2.bin
```

3. Back on the bootloader, write to flash:
```plaintext
FLW 00200000 80500000 00200000 0
```

This writes the file `mtd2.bin` (2 MiB) to SPI flash at offset `0x00200000`.

⚠️ Always double-check offset and size before writing to flash. This process is destructive.

⚠️ All values must be in **hexadecimal**. `AUTOBURN` should be **disabled** (default).

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

## 🔧 Method 3 – SPI Programmer (CH341A or Equivalent)

🔴 Use this method only if the bootloader is corrupted or the gateway is completely unresponsive.

This method involves **physically desoldering the SPI flash chip (GD25Q127C)** from the board and using a USB SPI programmer (such as a CH341A) to read or write its content.

### 🛠 Required Hardware

- A **CH341A** USB SPI programmer (inexpensive and widely available)
- A SOP8 to **200 mil** DIP adapter to insert the chip into the programmer
- **Flux** and either **desoldering braid** or a **small desoldering pump**

⚠️ The use of a programming clip **does not work** on the gateway board and is not recommended. 

### 🔄 Backup using `flashrom`

Once the chip is removed and inserted into the SOP8-to-DIP adapter on your CH341A programmer, you can safely back it up.

To read the full 16 MB content:

```sh
flashrom -p ch341a_spi -c GD25Q127C -r fullmtd_backup.bin
```

- `-p ch341a_spi`: use the CH341A in SPI mode
- `-c GD25Q127C`: specify the chip model
- `-r`: read mode (dump flash to file)

✅ Make sure the chip is powered at 3.3V and properly seated in the adapter.

After the backup, you can inspect or split the image if needed using tools like `dd` or `binwalk`.

---

### ♻️ Restore using `flashrom`

To write a previously saved image (like **fullmtd.bin** previously created using Method 1) back to the flash chip:

```sh
flashrom -p ch341a_spi -c GD25Q127C -w fullmtd.bin
```

- `-w`: write mode (flash binary to chip)

⚠️ **Be careful:** This operation will completely overwrite the chip content.  
Ensure that `fullmtd.bin` is exactly **16 MiB (16,777,216 bytes)** and contains valid data.

## 📁 Included Scripts

| Script                        | Method    | Description                                 |
|------------------------------|-----------|---------------------------------------------|
| `backup_mtd_via_ssh.sh`      | Method 1  | Full MTD backup over SSH                    |
| `restore_mtd_via_ssh.sh`     | Method 1  | Restore partitions via SSH + dd             |
| `backup_partition_tftp.sh`   | Method 2  | Backup mtdX partition via FLR + TFTP        |
| `flash_partition_tftp.sh`    | Method 2  | Restore mtdX via LOADADDR, TFTP, and FLW    |
