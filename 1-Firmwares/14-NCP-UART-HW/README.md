# Creating the NCP-UART-HW firmware

## Step 1: Create an NCP-UART-HW Demo File for EFR32MG1B232F256GM48

The `NCP-UART-HW` firmware is not available by default as an example
application for the `EFR32MG1B232F256GM48` chip. Therefore, we need to load
it from another chip.

1. In the **Launcher** tab, add the `EFR32MG12P432F1024GL125` part to the
   **My Products** list, then click **Start**.

   <p align="center">
     <img src="./media/image1.png" alt="Launcher Tab" width="70%">
   </p>

2. In the **Example Projects and Demos** tab, search for `NCP-UART-HW` and
   create the `Zigbee – NCP ncp-uart-hw` project.

   <p align="center">
     <img src="./media/image2.png" alt="Example Projects" width="70%">
   </p>

3. Accept default options and click **Finish**. Wait until the C/C++
   indexation is complete.

4. In the **Overview** panel, go to **Target and Tools settings** and at
   the bottom, click **Change Target/SDK/Generators**. Change the **Part
   reference** to `EFR32MG1B232F256GM48` and save. Wait for the project
   validation task and C/C++ Indexer to complete.

   <p align="center">
     <img src="./media/image3.png" alt="Indexation" width="70%">
   </p>
   <p align="center">
     <img src="./media/image4.png" alt="Indexation" width="70%">
   </p>

Now, we are ready to build an `NCP-UART-HW` firmware for our target device.

______________________________________________________________________

## Step 2: Pin Assignment

1. In the **Configuration Tools** panel, open the **Pin Tool**.

2. Assign `PA0`, `PA1`, `PA4`, and `PA5` respectively to USART0_TX,
   USART0_RX, USART0_RTS and USART0_CTS as shown below:

   <p align="center">
     <img src="./media/image5.png" alt="Pin Assignment" width="70%">
   </p>

3. Exit the **Pin Tab** and save.

______________________________________________________________________

## Step 3: Fix Pre-compilation Warnings

We want to get rid of the following pre-compilation warnings:

<p align="center">
     <img src="./media/image13.png" alt="Pre-compilation warnings" width="70%">
   </p>

1. Go back to the **Project Main Panel** and open the **Software
   Components** tab.

2. Set the filter to `Installed`.

3. Search for `vcom`.

   <p align="center">
     <img src="./media/image6.png" alt="VCOM Search" width="70%">
   </p>

4. Open the component editor for `IO Stream USART` and assign `USART0` to
   `SL_IOSTREAM_USART_VCOM`.

   <p align="center">
     <img src="./media/image7.png" alt="IO Stream USART" width="70%">
   </p>

5. Search for `PTI`.

   <p align="center">
     <img src="./media/image8.png" alt="PTI Search" width="70%">
   </p>

6. Open the component editor for `RAIL Utility, PTI` and assign `PB12` to
   `DOUT`.

   <p align="center">
     <img src="./media/image9.png" alt="RAIL Utility PTI" width="70%">
   </p>

At this stage, the initial pre-compilation warnings should have
disappeared.

______________________________________________________________________

## Step 4: Optimize for EFR32MG1B 256K Memory

If you try to compile the firmware at this stage, you will receive an error
stating that the output exceeds the available memory.

<p align="center">
     <img src="./media/image14.png" alt="Compilation Error" width="70%">
   </p>

To fit within the `256K` memory of the `EFR32MG1B`, remove unnecessary
debug or non-critical functions:

1. Open the **Software Components** tab.
2. Search for and uninstall the following components:
   - Debug Print
   - Debug Extended
   - Zigbee Light Link
   - IO Stream VUART

Ensure that the `*.c` indexation is completed before uninstalling the next
component.

______________________________________________________________________

## Step 5: Delay the EFR32MG1B Boot Process

The boot process must be delayed to allow the `RTL8196E` bootloader to
complete its initialization; otherwise, the `EFR32MG1B232F256GM48` boot
sequence will interfere, preventing the loading of the Linux kernel and
associated file system.

1. In the **Software Components** tab, remove the previous filters and
   search for `Microsecond Delay`.

2. Install the `Microsecond Delay` function.

   <p align="center">
     <img src="./media/image11.png" alt="Microsecond Delay" width="70%">
   </p>

3. Edit the `main.c` file and add:

   ```
   #include "sl_udelay.h"
   ```

4. At the beginning of `int main(void)`, insert:

   ```
   // Add 1sec delay before any reset operation to accommodate RTL8196E boot
   sl_udelay_wait(1000000);     // 1s delay
   ```

   The `main.c` file should now look like:

   <p align="center"> <img src="./media/image12.png" alt="Main.c Modification" width="70%"> </p>

   Save the file.

______________________________________________________________________

## Step 6: define post-build command to create gbl file

The `ncp-uart-hw.gbl` file is not created by default. You have to define
post-build instructions. Right-click on the project name and go to
`properties --> C/C++ Build -> Settings --> Build Steps` and enter:

```
"C:\SiliconLabs\SimplicityStudio\v5\developer\adapter_packs\commander\commander.exe" gbl create ncp-uart-hw.gbl --app ncp-uart-hw.s37
```

<p align="center">
     <img src="./media/image15.png" alt="Post-build NCP" width="80%">
   </p>

______________________________________________________________________

## Step 7 (optional) Customizing EZSP Configuration Parameters

If you're using this firmware with [Zigbee2mqtt](https://www.zigbee2mqtt.io/) or [ZHA](https://www.home-assistant.io/integrations/zha/), you may want to optimize how the Zigbee stack allocates memory and handles routing.

The values shown in the output of `universal-silabs-flasher probe` (such as `PACKET_BUFFER_COUNT`, `NEIGHBOR_TABLE_SIZE`, etc.) are defined at compile time inside the Silicon Labs Zigbee stack.

You can **modify these parameters** by editing the following two files:

```c
<project_root>/autogen/sl_zigbee_source_route_config.h
<project_root>/autogen/sl_zigbee_pro_stack_config.h
```

These files are automatically generated but can be customized by setting configuration options in **Simplicity Studio** or directly in the `.slcp` project file.

---

### 🔧 Key Parameters to Tune

| Parameter                          | Description                                                                                                  |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `CONFIG_PACKET_BUFFER_COUNT`       | Number of buffers used to store messages. Higher values allow better performance in busy networks.           |
| `CONFIG_NEIGHBOR_TABLE_SIZE`       | Max number of Zigbee routers that can be stored. Affects routing stability.                                  |
| `CONFIG_SOURCE_ROUTE_TABLE_SIZE`   | Controls the number of source routes cached. Essential for large end-device networks.                        |
| `CONFIG_APS_UNICAST_MESSAGE_COUNT` | Max number of unicast messages in flight. Important for group commands or simultaneous actions.              |
| `CONFIG_BROADCAST_TABLE_SIZE`      | Limits how many broadcast messages are tracked to avoid duplicates.                                          |
| `CONFIG_BINDING_TABLE_SIZE`        | Number of Zigbee bindings supported. Needed for certain device pairing.                                      |
| `CONFIG_KEY_TABLE_SIZE`            | Number of security keys that can be stored.                                                                  |
| `CONFIG_ADDRESS_TABLE_SIZE`        | Number of IEEE<->network address mappings cached. Important for direct communication, ZCL bindings, and OTA. |

---

### 🧪 Recommended Defaults in EZSP 7.5.0.0

For reference, here are the current default values on the Lidl/Silvercrest gateway running EZSP 7.5.0.0:

```c
CONFIG_PACKET_BUFFER_COUNT=255
CONFIG_SOURCE_ROUTE_TABLE_SIZE=7
CONFIG_ADDRESS_TABLE_SIZE=12
CONFIG_NEIGHBOR_TABLE_SIZE=16
CONFIG_APS_UNICAST_MESSAGE_COUNT=10
```

These values are already well-balanced for many networks.

---

### 🧩 Optional Adjustments Based on Community Feedback

Community member [@gpaesano](https://github.com/gpaesano) suggested the following adjustments across two configuration headers:

In `sl_zigbee_source_route_config.h`:
```c
#define EMBER_SOURCE_ROUTE_TABLE_SIZE   200
```

In `sl_zigbee_pro_stack_config.h`:
```c
#define EMBER_BROADCAST_TABLE_SIZE   30
#define EMBER_APS_UNICAST_MESSAGE_COUNT   64
#define EMBER_NEIGHBOR_TABLE_SIZE   26
```

These changes increase capacity for routing and message handling, which is helpful for larger or more active Zigbee networks.

---

### 📚 Documentation & References

- [AN1233: Zigbee Stack Configuration Guide (Silicon Labs)](https://www.silabs.com/documents/public/application-notes/an1233-zigbee-stack-config.pdf)
- [Zigbee Stack API Reference (Silicon Labs)](https://siliconlabs.github.io/zigbee_sdk_doc/)


## Step 8: build the firmware

Right-click on the project name (`ncp-uart-hw`) in the left-panel and click
on `Build Project`. The compilation should run without any errors. The
generated file `ncp-uart-hw.gbl` is located in the
`GNU ARM v12.2.1 - Default directory` ready to be flashed.