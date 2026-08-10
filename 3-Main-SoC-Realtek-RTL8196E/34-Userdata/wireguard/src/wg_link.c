/* wg_link.c — minimal RTM_NEWLINK/RTM_DELLINK helper for WireGuard.
 *
 * BusyBox ip on the gateway can configure addresses and routes but cannot
 * create a link with a specific kind.  Keep this helper intentionally small:
 * WireGuard configuration itself remains the responsibility of wg(8).
 */
#include <errno.h>
#include <linux/if_link.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <net/if.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int send_and_ack(struct nlmsghdr *nlh);

static int addattr(struct nlmsghdr *nlh, size_t maxlen, int type,
                   const void *data, size_t len)
{
    size_t offset = NLMSG_ALIGN(nlh->nlmsg_len);
    size_t attr_len = RTA_LENGTH(len);
    struct rtattr *rta;

    if (offset + RTA_ALIGN(attr_len) > maxlen)
        return -1;
    rta = (struct rtattr *)((char *)nlh + offset);
    rta->rta_type = type;
    rta->rta_len = attr_len;
    memcpy(RTA_DATA(rta), data, len);
    nlh->nlmsg_len = offset + RTA_ALIGN(attr_len);
    return 0;
}

static int create_link(const char *name)
{
    struct {
        struct nlmsghdr nlh;
        struct ifinfomsg ifi;
        char attrs[256];
    } req;
    struct rtattr *linkinfo;

    memset(&req, 0, sizeof(req));
    req.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(req.ifi));
    req.nlh.nlmsg_type = RTM_NEWLINK;
    req.nlh.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL;
    req.ifi.ifi_family = AF_UNSPEC;
    if (addattr(&req.nlh, sizeof(req), IFLA_IFNAME, name, strlen(name) + 1))
        return -1;

    linkinfo = (struct rtattr *)((char *)&req + NLMSG_ALIGN(req.nlh.nlmsg_len));
    linkinfo->rta_type = IFLA_LINKINFO | NLA_F_NESTED;
    linkinfo->rta_len = RTA_LENGTH(0);
    req.nlh.nlmsg_len = NLMSG_ALIGN(req.nlh.nlmsg_len) + RTA_ALIGN(linkinfo->rta_len);
    if (addattr(&req.nlh, sizeof(req), IFLA_INFO_KIND, "wireguard", 10))
        return -1;
    linkinfo->rta_len = (char *)&req + req.nlh.nlmsg_len - (char *)linkinfo;
    return send_and_ack(&req.nlh);
}

static int delete_link(const char *name)
{
    struct {
        struct nlmsghdr nlh;
        struct ifinfomsg ifi;
    } req;

    memset(&req, 0, sizeof(req));
    req.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(req.ifi));
    req.nlh.nlmsg_type = RTM_DELLINK;
    req.nlh.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
    req.ifi.ifi_family = AF_UNSPEC;
    req.ifi.ifi_index = if_nametoindex(name);
    if (!req.ifi.ifi_index) {
        errno = ENODEV;
        return -1;
    }
    return send_and_ack(&req.nlh);
}

static int send_and_ack(struct nlmsghdr *nlh)
{
    struct sockaddr_nl addr = { .nl_family = AF_NETLINK };
    char reply[4096];
    struct nlmsghdr *ack;
    int fd;

    fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (fd < 0)
        return -1;
    if (sendto(fd, nlh, nlh->nlmsg_len, 0, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
        recv(fd, reply, sizeof(reply), 0) < 0) {
        close(fd);
        return -1;
    }
    close(fd);
    ack = (struct nlmsghdr *)reply;
    if (ack->nlmsg_type != NLMSG_ERROR ||
        ack->nlmsg_len < NLMSG_LENGTH(sizeof(struct nlmsgerr))) {
        errno = EPROTO;
        return -1;
    }
    if (((struct nlmsgerr *)NLMSG_DATA(ack))->error) {
        errno = -((struct nlmsgerr *)NLMSG_DATA(ack))->error;
        return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    int rc;

    if (argc != 3 || strlen(argv[2]) >= IFNAMSIZ) {
        fprintf(stderr, "Usage: %s add|del IFACE\n", argv[0]);
        return 1;
    }
    if (!strcmp(argv[1], "add"))
        rc = create_link(argv[2]);
    else if (!strcmp(argv[1], "del"))
        rc = delete_link(argv[2]);
    else {
        fprintf(stderr, "Usage: %s add|del IFACE\n", argv[0]);
        return 1;
    }
    if (rc) {
        fprintf(stderr, "%s %s: %s\n", argv[1], argv[2], strerror(errno));
        return 1;
    }
    return 0;
}
