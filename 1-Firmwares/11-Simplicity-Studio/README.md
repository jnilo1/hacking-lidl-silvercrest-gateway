# Installing Simplicity Studio V5

## Overview

Simplicity Studio V5 (SSV5) is the official development environment
provided by **Silicon Labs** for developing, compiling, and flashing
firmware onto **EFR32** chips. This guide outlines the installation steps
for both **Windows** and **Linux** systems.

______________________________________________________________________

## 1. Creating a Silicon Labs Account

Before downloading Simplicity Studio, you must create a **free Silicon Labs
account**:

1. Go to [Silicon Labs Developer Portal](https://www.silabs.com/developers)
2. Click **Sign Up** and complete the registration process.
3. Once registered, log in to your account to access the download page.

______________________________________________________________________

## 2. Installation on Windows

### **2.1 Download Simplicity Studio V5**

- Visit the official Silicon Labs website:
  [https://www.silabs.com/developers/simplicity-studio](https://www.silabs.com/developers/simplicity-studio)
- Log in to your account and download the **Windows Installer**.

### **2.2 Install Simplicity Studio**

1. Run the downloaded installer (`SimplicityStudio.exe`).
2. Follow the on-screen instructions and accept the license agreements.
3. Select the **installation directory** (default is recommended).
4. Allow the installation to complete, then launch **Simplicity Studio
   V5**.

### **2.3 Install Required Components**

1. **Access Package Manager**: From the Simplicity Studio home page,
   navigate to the top menu and select **Install** > **Manage Installed
   Packages**.

2. **Open SDKs Tab**: In the Package Manager window, click on the **SDKs**
   tab to view the list of installed Software Development Kits.

3. **Modify Gecko SDK Version**:

   - Locate the Gecko SDK in the list.
   - Click the three-dot menu (ellipsis) next to the current Gecko SDK
     version.
   - From the dropdown menu, select **Change Version**.

4. **Select New Version**: In the subsequent dialog, choose the desired
   Gecko SDK version from the available options.

5. **Finalize Changes**: Click **Finish** to apply the changes and install
   the selected SDK version.

For more detailed information, refer to the official Silicon Labs
documentation on upgrading a project to a new GSDK version.

### **2.4 Verifying the Installation**

1. Optionally, connect an **ARM** or **Segger J-Link** debugger to the
   gateway JTAG interface (See
   [Backup & restore section](./12-Backup-Flash-Restore) for details).
2. Open the **Tools** menu and select `Commander`.
3. Run the following command to check the device:
   ```sh
   commander device info
   ```
   If the device is detected, Simplicity Studio is correctly installed.

______________________________________________________________________

## 3. Installation on Linux

### **3.1 Download and Install Dependencies**

Before installing SSV5, ensure you have the required system dependencies:

```sh
sudo apt update && sudo apt install -y libncurses5 libtinfo5 libx11-6 libxext6 libxrender1 libxtst6 libxi6
```

These are required for the GUI to function correctly.

### **3.2 Download Simplicity Studio V5**

- Visit the Silicon Labs website:
  [https://www.silabs.com/developers/simplicity-studio](https://www.silabs.com/developers/simplicity-studio)
- Log in to your account and download the **Linux installer**
  (`SimplicityStudioV5.tgz`).

### **3.3 Extract and Install**

1. Open a terminal and navigate to the download location:
   ```sh
   cd ~/Downloads
   ```
2. Extract the archive:
   ```sh
   tar -xvzf SimplicityStudioV5.tgz
   ```
3. Move into the extracted directory:
   ```sh
   cd SimplicityStudioV5
   ```
4. Run the installer:
   ```sh
   ./studio.sh
   ```

### **3.4 Install Required Components**

Follow the same steps as in the Windows installation to install: the
**Gecko SDK Suite**.

### **3.5 Verifying the Installation**

1. Optionally, connect an **ARM** or **Segger J-Link** debugger to the
   gateway JTAG interface (See Backup & restore section for details).
2. Open a terminal and run:
   ```sh
   commander device info
   ```
   If the device is detected, your installation is complete.

______________________________________________________________________

## 4. Additional Notes

- **Administrator Privileges**: On some Linux systems, you may need to run
  Simplicity Studio as root.
  ```sh
  sudo ./studio.sh
  ```
- **udev Rules for Debugger Access**: If your debugger is not recognized,
  create a udev rule:
  ```sh
  echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="1366", MODE="0666"' | sudo tee /etc/udev/rules.d/99-segger.rules
  sudo udevadm control --reload-rules
  ```
- **Java Dependencies**: If Simplicity Studio fails to start, ensure you
  have Java installed:
  ```sh
  sudo apt install default-jre
  ```

______________________________________________________________________

This guide ensures a smooth installation process for **Simplicity Studio
V5** on both **Windows** and **Linux**. You are now ready to compile and
flash firmware onto the Lidl Silvercrest gateway.
