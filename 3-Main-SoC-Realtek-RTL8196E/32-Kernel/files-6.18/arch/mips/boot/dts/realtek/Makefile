# SPDX-License-Identifier: GPL-2.0
#
# One dtb per board, selected by the Kconfig "Devicetree selection"
# choice (arch/mips/realtek/Kconfig). Exactly one is built into the
# kernel image (BUILTIN_DTB via __dtb_start, see arch/mips/realtek/setup.c).
#
# Adding a board (e.g. the Sengled G4 port, discussion #119):
#   1. write rtl8196e-<board>.dts here, including rtl819x.dtsi;
#   2. add a CONFIG_DTB_RTL8196E_<BOARD> entry to the Kconfig choice;
#   3. add the matching dtb-$(CONFIG_...) line below;
#   4. teach the BOARD map in build_kernel.sh about it.
dtb-$(CONFIG_DTB_RTL8196E_GEN)	+= rtl8196e.dtb

dtb-$(CONFIG_DTB_RTL8196E_SENGLED_E39_G8C)	+= rtl8196e-sengled-e39-g8c.dtb

obj-y				+= $(patsubst %.dtb, %.dtb.o, $(dtb-y))

# Force kbuild to make empty built-in.o if necessary
obj-				+= dummy.o

always-y			:= $(dtb-y)
clean-files			:= *.dtb *.dtb.S
