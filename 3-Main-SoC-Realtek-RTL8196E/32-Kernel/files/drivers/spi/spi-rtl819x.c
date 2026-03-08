// SPDX-License-Identifier: GPL-2.0
/*
 * SPI controller driver for Realtek RTL819x SoCs
 *
 * - devm_spi_alloc_master() pour éviter les fuites
 * - readl_poll_timeout() pour borner l'attente HW
 * - Sélection du diviseur d'horloge en fonction de speed_hz
 * - CS par défaut = ALL_HIGH dans les cas inattendus
 * - remove/shutdown sans unregister/put (pas de crash au reboot)
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/spinlock.h>
#include <linux/platform_device.h>
#include <linux/io.h>
#include <linux/bitops.h>
#include <linux/spi/spi.h>
#include <linux/clk.h>
#include <linux/err.h>
#include <linux/of.h>
#include <linux/iopoll.h>
#include <asm/unaligned.h>

#define DRIVER_NAME "realtek-spi"

/* Registers */
#define RTK_SPI_CONFIG_OFFSET 0x00
#define RTK_SPI_CONTROL_STATUS_OFFSET 0x08
#define RTK_SPI_DATA_OFFSET 0x0c

/* CONFIG bits */
#define RTK_SPI_CLK_DIV_SHIFT 29 /* 3 bits: index 0..7 */
#define RTK_SPI_READ_BYTE_ORDER BIT(28)
#define RTK_SPI_WRITE_BYTE_ORDER BIT(27)
#define RTK_SPI_CS_DESELECT_TIME_SHIFT 22 /* 5 bits, 0..31 */

/* CONTROL/STATUS bits */
#define RTK_SPI_CS_0_HIGH BIT(31)
#define RTK_SPI_CS_1_HIGH BIT(30)
#define RTK_SPI_CS_ALL_HIGH (RTK_SPI_CS_0_HIGH | RTK_SPI_CS_1_HIGH)
#define RTK_SPI_DATA_LENGTH_SHIFT 28 /* 2 bits: (len-1) */
#define RTK_SPI_READY BIT(27)

/* Diviseurs possibles : parent_clk / {2,4,6,8,10,12,14,16} */
static const u32 realtek_spi_clk_div_table[] = { 2, 4, 6, 8, 10, 12, 14, 16 };

struct realtek_spi_data {
	struct spi_master *master;
	void __iomem *base;
	u32 ioc_base;
	struct clk *clk; /* optionnel */
	u32 parent_rate; /* Hz */
};

#ifdef CONFIG_CPU_BIG_ENDIAN
static inline u32 realtek_spi_make_data(u32 data, u32 bytes)
{
	return data << ((4 - bytes) << 3);
}
static inline u32 realtek_spi_resolve_data(u32 data, u32 bytes)
{
	return data >> ((4 - bytes) << 3);
}
#else
static inline u32 realtek_spi_make_data(u32 data, u32 bytes)
{
	return data;
}
static inline u32 realtek_spi_resolve_data(u32 data, u32 bytes)
{
	return data;
}
#endif

static inline u32 rtk_rr(struct realtek_spi_data *rsd, unsigned reg)
{
	return ioread32(rsd->base + reg);
}

static inline void rtk_wr(struct realtek_spi_data *rsd, unsigned reg, u32 val)
{
	iowrite32(val, rsd->base + reg);
}

static int rtk_wait_ready(struct realtek_spi_data *rsd)
{
	u32 v;
	/* 10 ms timeout, poll toutes les ~1 µs */
	return readl_poll_timeout(rsd->base + RTK_SPI_CONTROL_STATUS_OFFSET, v,
				  v & RTK_SPI_READY, 1, 10000);
}

static void rtk_set_txrx_size(struct realtek_spi_data *rsd, u32 size)
{
	rtk_wr(rsd, RTK_SPI_CONTROL_STATUS_OFFSET,
	       rsd->ioc_base | ((size - 1) << RTK_SPI_DATA_LENGTH_SHIFT));
}

static void rtk_set_default_config(struct realtek_spi_data *rsd, u32 div_idx)
{
	u32 cfg = (div_idx << RTK_SPI_CLK_DIV_SHIFT) |
		  (31 << RTK_SPI_CS_DESELECT_TIME_SHIFT); /* max deselect */

#ifdef CONFIG_CPU_BIG_ENDIAN
	cfg |= RTK_SPI_READ_BYTE_ORDER | RTK_SPI_WRITE_BYTE_ORDER;
#endif
	rtk_wr(rsd, RTK_SPI_CONFIG_OFFSET, cfg);
}

static u32 rtk_choose_div_idx(struct realtek_spi_data *rsd, u32 hz)
{
	u32 parent = rsd->parent_rate ? rsd->parent_rate : 200000000;
	u32 best_idx =
		ARRAY_SIZE(realtek_spi_clk_div_table) - 1; /* 16 par défaut */
	u32 i;

	if (!hz) /* fallback */
		return best_idx;

	for (i = 0; i < ARRAY_SIZE(realtek_spi_clk_div_table); i++) {
		u32 div = realtek_spi_clk_div_table[i];
		u32 rate = parent / div;
		if (rate <= hz) {
			best_idx = i;
			break;
		}
	}
	return best_idx;
}

static void realtek_spi_set_cs(struct spi_device *spi, bool cs_high)
{
	struct realtek_spi_data *rsd = spi_master_get_devdata(spi->master);

	cs_high = (spi->mode & SPI_CS_HIGH) ? !cs_high : cs_high;

	if (cs_high) {
		switch (spi->chip_select) {
		case 0:
			rsd->ioc_base = RTK_SPI_CS_0_HIGH;
			break;
		case 1:
			rsd->ioc_base = RTK_SPI_CS_1_HIGH;
			break;
		default:
			rsd->ioc_base = RTK_SPI_CS_ALL_HIGH;
			break;
		}
	} else {
		/* Activer le CS voulu (niveau bas si CS_HIGH non configuré) */
		switch (spi->chip_select) {
		case 0:
			rsd->ioc_base = RTK_SPI_CS_1_HIGH;
			break;
		case 1:
			rsd->ioc_base = RTK_SPI_CS_0_HIGH;
			break;
		default:
			rsd->ioc_base = RTK_SPI_CS_ALL_HIGH;
			break;
		}
	}

	rsd->ioc_base |= RTK_SPI_READY;
	rtk_wr(rsd, RTK_SPI_CONTROL_STATUS_OFFSET, rsd->ioc_base);
}

static int rtk_read(struct realtek_spi_data *rsd, u8 *buf, unsigned len)
{
	int ret;

	if ((size_t)buf % 4) {
		rtk_set_txrx_size(rsd, 1);
		while (((size_t)buf % 4) && len) {
			ret = rtk_wait_ready(rsd);
			if (ret)
				return ret;
			*buf = realtek_spi_resolve_data(
				rtk_rr(rsd, RTK_SPI_DATA_OFFSET), 1);
			buf++;
			len--;
		}
	}

	rtk_set_txrx_size(rsd, 4);
	while (len >= 4) {
		ret = rtk_wait_ready(rsd);
		if (ret)
			return ret;
		put_unaligned(realtek_spi_resolve_data(
			rtk_rr(rsd, RTK_SPI_DATA_OFFSET), 4), (u32 *)buf);
		buf += 4;
		len -= 4;
	}

	rtk_set_txrx_size(rsd, 1);
	while (len) {
		ret = rtk_wait_ready(rsd);
		if (ret)
			return ret;
		*buf = realtek_spi_resolve_data(
			rtk_rr(rsd, RTK_SPI_DATA_OFFSET), 1);
		buf++;
		len--;
	}

	return 0;
}

static int rtk_write(struct realtek_spi_data *rsd, const u8 *buf, unsigned len)
{
	int ret;

	if ((size_t)buf % 4) {
		rtk_set_txrx_size(rsd, 1);
		while (((size_t)buf % 4) && len) {
			rtk_wr(rsd, RTK_SPI_DATA_OFFSET,
			       realtek_spi_make_data(*buf, 1));
			ret = rtk_wait_ready(rsd);
			if (ret)
				return ret;
			buf++;
			len--;
		}
	}

	rtk_set_txrx_size(rsd, 4);
	while (len >= 4) {
		rtk_wr(rsd, RTK_SPI_DATA_OFFSET,
		       realtek_spi_make_data(get_unaligned((const u32 *)buf), 4));
		ret = rtk_wait_ready(rsd);
		if (ret)
			return ret;
		buf += 4;
		len -= 4;
	}

	rtk_set_txrx_size(rsd, 1);
	while (len) {
		rtk_wr(rsd, RTK_SPI_DATA_OFFSET,
		       realtek_spi_make_data(*buf, 1));
		ret = rtk_wait_ready(rsd);
		if (ret)
			return ret;
		buf++;
		len--;
	}

	return 0;
}

static int realtek_spi_transfer_one(struct spi_master *master,
				    struct spi_device *spi,
				    struct spi_transfer *xfer)
{
	struct realtek_spi_data *rsd = spi_master_get_devdata(master);
	u32 hz = xfer->speed_hz ? xfer->speed_hz :
				  (spi->max_speed_hz ? spi->max_speed_hz :
						       master->max_speed_hz);
	u32 div_idx = rtk_choose_div_idx(rsd, hz);

	/* Programme l’horloge et la temporisation CS pour ce transfert */
	rtk_set_default_config(rsd, div_idx);

	if (xfer->tx_buf && xfer->rx_buf) {
		dev_err(&spi->dev,
			"Half-duplex only: TX and RX simultaneously not supported\n");
		return -EPERM;
	}

	if (xfer->tx_buf)
		return rtk_write(rsd, (const u8 *)xfer->tx_buf, xfer->len);

	if (xfer->rx_buf)
		return rtk_read(rsd, (u8 *)xfer->rx_buf, xfer->len);

	return 0;
}

static int realtek_spi_probe(struct platform_device *pdev)
{
	struct realtek_spi_data *rsd;
	struct spi_master *master;
	struct resource *res;
	u32 rate = 0;
	int ret;

	master = devm_spi_alloc_master(&pdev->dev, sizeof(*rsd));
	if (!master)
		return -ENOMEM;

	rsd = spi_master_get_devdata(master);
	platform_set_drvdata(pdev, rsd);
	rsd->master = master;

	/* Bus number from DT alias "spi<N>", fallback to platform id or 0 */
	{
		int id = of_alias_get_id(pdev->dev.of_node, "spi");
		if (id < 0)
			id = (pdev->id >= 0) ? pdev->id : 0;
		master->bus_num = id;
	}

	master->dev.of_node = pdev->dev.of_node;
	master->num_chipselect = 2;
	master->mode_bits = SPI_CPOL | SPI_CPHA | SPI_CS_HIGH;
	master->flags = SPI_MASTER_HALF_DUPLEX;
	master->bits_per_word_mask = SPI_BPW_MASK(32) | SPI_BPW_MASK(24) |
				     SPI_BPW_MASK(16) | SPI_BPW_MASK(8);
	master->transfer_one = realtek_spi_transfer_one;
	master->set_cs = realtek_spi_set_cs;

	/* ioremapped regs */
	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	rsd->base = devm_ioremap_resource(&pdev->dev, res);
	if (IS_ERR(rsd->base))
		return PTR_ERR(rsd->base);

	/* Horloge (optionnelle) */
	rsd->clk = devm_clk_get_optional(&pdev->dev, NULL);
	if (IS_ERR(rsd->clk))
		return PTR_ERR(rsd->clk);
	if (rsd->clk) {
		ret = clk_prepare_enable(rsd->clk);
		if (ret)
			return ret;
		rate = clk_get_rate(rsd->clk);
	}
	if (!rate)
		of_property_read_u32(pdev->dev.of_node, "clock-frequency",
				     &rate);
	if (!rate)
		rate = 200000000; /* fallback: LX bus clock on RTL8196E */
	rsd->parent_rate = rate;

	master->max_speed_hz = rate / 2; /* div=2 */
	master->min_speed_hz = rate / 16; /* div=16 */

	/* Config et CS sûrs au départ */
	rtk_set_default_config(rsd, ARRAY_SIZE(realtek_spi_clk_div_table) - 1);
	rtk_wr(rsd, RTK_SPI_CONTROL_STATUS_OFFSET,
	       RTK_SPI_CS_ALL_HIGH | RTK_SPI_READY);

	ret = devm_spi_register_master(&pdev->dev, master);
	if (ret) {
		if (rsd->clk) {
			clk_disable_unprepare(rsd->clk);
			rsd->clk = NULL;
		}
		return ret;
	}

	return 0;
}

static int realtek_spi_remove(struct platform_device *pdev)
{
	struct realtek_spi_data *rsd = platform_get_drvdata(pdev);

	if (rsd) {
		/* État neutre du HW */
		rtk_set_default_config(
			rsd, ARRAY_SIZE(realtek_spi_clk_div_table) - 1);
		rtk_wr(rsd, RTK_SPI_CONTROL_STATUS_OFFSET,
		       RTK_SPI_CS_ALL_HIGH | RTK_SPI_READY);
		if (rsd->clk) {
			clk_disable_unprepare(rsd->clk);
			rsd->clk = NULL;
		}
	}
	return 0;
}

static void realtek_spi_shutdown(struct platform_device *pdev)
{
	struct realtek_spi_data *rsd = platform_get_drvdata(pdev);

	/* Pas d’unregister/put ici : on met juste le HW au repos */
	if (rsd) {
		rtk_set_default_config(
			rsd, ARRAY_SIZE(realtek_spi_clk_div_table) - 1);
		rtk_wr(rsd, RTK_SPI_CONTROL_STATUS_OFFSET,
		       RTK_SPI_CS_ALL_HIGH | RTK_SPI_READY);
		if (rsd->clk) {
			clk_disable_unprepare(rsd->clk);
			rsd->clk = NULL;
		}
	}
}

static const struct of_device_id realtek_spi_match[] = {
	{ .compatible = "realtek,rtl819x-spi" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, realtek_spi_match);

static struct platform_driver realtek_spi_driver = {
	.driver = {
		.name = DRIVER_NAME,
		.of_match_table = realtek_spi_match,
	},
	.probe    = realtek_spi_probe,
	.remove   = realtek_spi_remove,
	.shutdown = realtek_spi_shutdown,
};
module_platform_driver(realtek_spi_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Weijie Gao <hackpascal@gmail.com>");
MODULE_DESCRIPTION("Realtek SoC SPI controller driver (RTL819x)");
MODULE_ALIAS("platform:" DRIVER_NAME);
