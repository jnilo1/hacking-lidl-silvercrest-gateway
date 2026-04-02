/*
    Serial port gateway for Silvercrest (Lidl) Smart Home Gateway
  =================================================================
  Author: Paul Banks [https://paulbanks.org/]
  Revision: J. Nilo - December 2025
  License: GPL-3.0 (https://www.gnu.org/licenses/gpl-3.0.html)

  v2.0 improvements:
    - Fixed buffer type (int -> uint8_t) - memory optimization
    - Added TCP_NODELAY for lower latency (important for EZSP)
    - Added -h help, -v version, -q quiet mode options
    - Validated port range (1-65535) and baud rate
    - Added daemon mode (default), -D for foreground

  v2.1 improvements:
    - STATUS LED brightness adapts to led_mode (bright=255, dim=60)

  v2.2 improvements:
    - Respect led_mode=off (keep STATUS LED at 0)

*/
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/ioctl.h>
#include <signal.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>

#include "serialgateway.h"
#include "serial.h"

#define DEFAULT_SERIAL_PORT "/dev/ttyS1"
#define DEFAULT_TCP_PORT 8888
#define DEFAULT_BAUD_RATE 115200
#define BUF_SIZE 512

#define OOB_HW_FLOW_OFF 0x10
#define OOB_HW_FLOW_ON 0x11

static fd_set _master_read_set;
static fd_set _master_except_set;
static fd_set _read_fd_set;
static fd_set _except_fd_set;

struct serial_settings {
    bool is_hardware_flow_control;
    uint32_t baud_bps;
    char* device;
};

static struct serial_settings _serial_settings;
static int _serial_fd = -1;
static int _connection_fd = -1;
static uint8_t _buf[BUF_SIZE];  /* Fixed: was int, wasting 3x memory */
static bool _quiet_mode = false;

#define LOG_INFO(format, ...) do { if (!_quiet_mode) fprintf(stderr, format "\n", ##__VA_ARGS__); } while(0)

int sockatmark(int fd)
{
    int r;
    return ioctl(fd, SIOCATMARK, &r) == -1 ? -1 : r;
}

static void _set_status_led(bool is_on)
{
    int fd;
    const char *val;
    int len;

    if (!is_on) {
        val = "0\n"; len = 2;
    } else {
        /* Match STATUS LED brightness to LAN LED mode:
         * "bright" (LEDCREG direct) -> 255, "dim" (scan) -> 60. */
        char mode[8] = "";
        fd = open("/sys/class/net/eth0/led_mode", O_RDONLY);
        if (fd >= 0) {
            int n = read(fd, mode, sizeof(mode) - 1);
            if (n > 0) mode[n] = '\0';
            close(fd);
        }
        if (mode[0] == 'o') {
            val = "0\n"; len = 2;
        } else if (mode[0] == 'd') {
            val = "60\n"; len = 3;
        } else {
            val = "255\n"; len = 4;
        }
    }

    fd = open("/sys/class/leds/status/brightness", O_WRONLY);
    if (fd < 0)
        return;
    write(fd, val, len);
    close(fd);
}

static void _error_exit(const char* msg)
{
    perror(msg);
    exit(EXIT_FAILURE);
}

static void _close_connectionfd()
{
    if (_connection_fd >= 0) {
        _set_status_led(0);
        LOG_INFO("Closing existing connection");
        shutdown(_connection_fd, SHUT_RDWR);
        close(_connection_fd);
        FD_CLR(_connection_fd, &_master_read_set);
        FD_CLR(_connection_fd, &_read_fd_set);
        FD_CLR(_connection_fd, &_master_except_set);
        FD_CLR(_connection_fd, &_except_fd_set);
        _connection_fd = -1;
    }
}

static void _open_serial_port()
{
    if (_serial_fd != -1) {
        FD_CLR(_serial_fd, &_master_read_set);
        FD_CLR(_serial_fd, &_read_fd_set);
        close(_serial_fd);
    }
    _serial_fd = serial_port_open(_serial_settings.device,
                                  _serial_settings.baud_bps,
                                  _serial_settings.is_hardware_flow_control);
    if (_serial_fd == -1) {
        _error_exit("Could not open serial port");
    }
    FD_SET(_serial_fd, &_master_read_set);
}

static void _handle_oob_command()
{
    char oob_op;
    size_t len = recv(_connection_fd, &oob_op, 1, MSG_OOB);
    if (len == 1) {
        switch (oob_op) {
            case OOB_HW_FLOW_OFF:
                LOG_INFO("Flow control OFF");
                _serial_settings.is_hardware_flow_control = false;
                _open_serial_port();
                break;
            case OOB_HW_FLOW_ON:
                LOG_INFO("Flow control ON");
                _serial_settings.is_hardware_flow_control = true;
                _open_serial_port();
                break;
            default:
                LOG_INFO("Unknown OOB command %d", oob_op);
        }
    }
    FD_SET(_connection_fd, &_master_except_set);
}

static void _print_usage(const char* progname)
{
    fprintf(stderr,
        "Usage: %s [options]\n"
        "\n"
        "Options:\n"
        "  -p <port>    TCP port to listen on (default: %d)\n"
        "  -d <device>  Serial device (default: %s)\n"
        "  -b <baud>    Baud rate (default: %d)\n"
        "  -f           Disable hardware flow control (default: enabled)\n"
        "  -D           Stay in foreground (don't daemonize)\n"
        "  -q           Quiet mode (suppress info messages)\n"
        "  -v           Show version and exit\n"
        "  -h           Show this help\n"
        "\n"
        "Example:\n"
        "  %s -p 8888 -d /dev/ttyS1 -b 115200\n"
        "\n",
        progname, DEFAULT_TCP_PORT, DEFAULT_SERIAL_PORT, DEFAULT_BAUD_RATE, progname);
}

static void _print_version()
{
    fprintf(stderr, "serialgateway %s\n", VERSION);
}

static void _daemonize()
{
    pid_t pid = fork();
    if (pid < 0) {
        _error_exit("fork");
    }
    if (pid > 0) {
        /* Parent exits */
        exit(EXIT_SUCCESS);
    }
    /* Child continues */
    if (setsid() < 0) {
        _error_exit("setsid");
    }
    /* Redirect stdin/stdout/stderr to /dev/null */
    int fd = open("/dev/null", O_RDWR);
    if (fd >= 0) {
        dup2(fd, STDIN_FILENO);
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        if (fd > STDERR_FILENO) {
            close(fd);
        }
    }
}

int main(int argc, char** argv)
{
    FD_ZERO(&_master_read_set);
    FD_ZERO(&_master_except_set);

    uint16_t port = DEFAULT_TCP_PORT;
    bool foreground = false;

    _serial_settings.is_hardware_flow_control = true;
    _serial_settings.baud_bps = DEFAULT_BAUD_RATE;
    _serial_settings.device = strdup(DEFAULT_SERIAL_PORT);
    opterr = 0;

    signal(SIGPIPE, SIG_IGN);

    int c;
    while ((c = getopt(argc, argv, "fp:d:b:Dqvh")) != -1) {
        switch (c) {
            case 'f':
                _serial_settings.is_hardware_flow_control = false;
                break;
            case 'p': {
                int p = atoi(optarg);
                if (p < 1 || p > 65535) {
                    fprintf(stderr, "Error: port must be between 1 and 65535\n");
                    exit(EXIT_FAILURE);
                }
                port = (uint16_t)p;
                break;
            }
            case 'd':
                free(_serial_settings.device);
                _serial_settings.device = strdup(optarg);
                break;
            case 'b': {
                int b = atoi(optarg);
                if (b <= 0) {
                    fprintf(stderr, "Error: invalid baud rate '%s'\n", optarg);
                    exit(EXIT_FAILURE);
                }
                _serial_settings.baud_bps = (uint32_t)b;
                break;
            }
            case 'D':
                foreground = true;
                break;
            case 'q':
                _quiet_mode = true;
                break;
            case 'v':
                _print_version();
                exit(EXIT_SUCCESS);
            case 'h':
                _print_usage(argv[0]);
                exit(EXIT_SUCCESS);
            case '?':
            default:
                fprintf(stderr, "Unknown option: -%c\n", optopt);
                _print_usage(argv[0]);
                exit(EXIT_FAILURE);
        }
    }

    LOG_INFO("serialgateway %s: port %d, serial=%s, baud=%d, flow=%s",
            VERSION, port, _serial_settings.device, _serial_settings.baud_bps,
            (_serial_settings.is_hardware_flow_control) ? "HW" : "sw");

    /* Open serial port first to validate baud rate before daemonizing */
    _open_serial_port();

    /* Daemonize unless -D specified */
    if (!foreground) {
        _daemonize();
    }

    /* Create listening socket */
    int listen_sock;
    struct sockaddr_in name;
    listen_sock = socket(PF_INET, SOCK_STREAM, 0);
    if (listen_sock < 0) {
        _error_exit("socket");
    }

    int enable = 1;
    if (setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR,
                   &enable, sizeof(int)) < 0) {
        _error_exit("setsockopt(SO_REUSEADDR) failed");
    }

    name.sin_family = AF_INET;
    name.sin_port = htons(port);
    name.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(listen_sock, (struct sockaddr *)&name, sizeof(name)) < 0) {
        _error_exit("bind");
    }

    if (listen(listen_sock, 1) < 0) {
        _error_exit("listen");
    }

    FD_SET(listen_sock, &_master_read_set);

    int i;
    for (;;) {
        _read_fd_set = _master_read_set;
        _except_fd_set = _master_except_set;
        if (select(FD_SETSIZE, &_read_fd_set, NULL, &_except_fd_set, NULL) < 0) {
            _error_exit("select");
        }

        for (i = 0; i < FD_SETSIZE; ++i) {
            if (FD_ISSET(i, &_except_fd_set)) {
                FD_CLR(i, &_master_except_set);
                if (_connection_fd == i && sockatmark(i) == 1) {
                    LOG_DEBUG("Socket exceptfd %d", 1);
                    _handle_oob_command();
                }
            }

            if (FD_ISSET(i, &_read_fd_set)) {
                if (i == listen_sock) {
                    struct sockaddr_in clientname;
                    socklen_t size = sizeof(clientname);
                    int new = accept(listen_sock,
                                     (struct sockaddr *)&clientname, &size);
                    if (new < 0) {
                        continue;
                    }
                    _close_connectionfd();
                    _set_status_led(1);
                    LOG_INFO("Connect from %s fd=%d",
                             inet_ntoa(clientname.sin_addr), new);

                    /* Enable TCP keepalive */
                    int enable = 1;
                    if (setsockopt(new, SOL_SOCKET, SO_KEEPALIVE,
                                   &enable, sizeof(enable)) < 0) {
                        LOG_INFO("Failed to set SO_KEEPALIVE");
                    }

                    /* Enable TCP_NODELAY to reduce latency (disable Nagle) */
                    if (setsockopt(new, IPPROTO_TCP, TCP_NODELAY,
                                   &enable, sizeof(enable)) < 0) {
                        LOG_INFO("Failed to set TCP_NODELAY");
                    }

                    FD_SET(new, &_master_read_set);
                    FD_SET(new, &_master_except_set);
                    _connection_fd = new;

                } else if (i == _serial_fd) {
                    ssize_t len = read(_serial_fd, _buf, BUF_SIZE);
                    if (len <= 0) {
                        _error_exit("read serial");
                    }
                    LOG_DEBUG("SERIAL_READ: %zd bytes", len);
                    if (_connection_fd >= 0) {
                        if (write(_connection_fd, _buf, len) < 0) {
                            _close_connectionfd();
                        }
                    }

                } else if (i == _connection_fd) {
                    ssize_t len = read(_connection_fd, _buf, BUF_SIZE);
                    if (len <= 0) {
                        _close_connectionfd();
                    } else {
                        LOG_DEBUG("   TCP_READ: %zd bytes", len);
                        if (write(_serial_fd, _buf, len) < 0) {
                            _error_exit("write serial");
                        }

                        if (sockatmark(_connection_fd) == 1) {
                            _handle_oob_command();
                        }
                    }

                } else {
                    LOG_INFO("Bug: Closing orphaned fd %d.", i);
                    close(i);
                    FD_CLR(i, &_master_read_set);
                    FD_CLR(i, &_master_except_set);
                }
            }
        }
    }
}
