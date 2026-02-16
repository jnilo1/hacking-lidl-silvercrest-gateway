/* SPDX-License-Identifier: GPL-2.0 */
#ifndef RTL8196E_POOL_H
#define RTL8196E_POOL_H

#include <linux/types.h>

struct sk_buff;
struct rtl8196e_pool;

struct rtl8196e_pool *rtl8196e_pool_create(size_t buf_size, int count);
void rtl8196e_pool_destroy(struct rtl8196e_pool *pool);

void *rtl8196e_pool_alloc(struct rtl8196e_pool *pool, void **skb_out);
void rtl8196e_pool_free(struct rtl8196e_pool *pool, void *buf);

struct sk_buff *rtl8196e_pool_alloc_skb(struct rtl8196e_pool *pool, unsigned int size);

/* Kernel patch hooks (keep symbol names for existing patch) */
int is_rtl865x_eth_priv_buf(unsigned char *head);
void free_rtl865x_eth_priv_buf(unsigned char *head);

#endif /* RTL8196E_POOL_H */
