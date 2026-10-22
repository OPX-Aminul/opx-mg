/*
 * opx-usbredirect — usbredir TCP server that takes an already-open usbfs fd.
 *
 * Termux cannot open /dev/bus/usb. termux-usb exports TERMUX_USB_FD; this
 * program wraps that fd with libusb_wrap_sys_device and speaks usbredir on
 * 127.0.0.1:PORT so QEMU -device usb-redir can connect.
 *
 * CLI (compatible with spice usbredirect --as):
 *   opx-usbredirect --device /proc/self/fd/N --as 127.0.0.1:23456
 *   TERMUX_USB_FD=N opx-usbredirect --as 127.0.0.1:23456
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <libusb.h>
#include "usbredirhost.h"

#define SERVER_VERSION "opx-usbredirect 0.1.0"

static int verbose = usbredirparser_info;
static int client_fd = -1;
static int running = 1;
static libusb_context *ctx;
static struct usbredirhost *host;

static void log_cb(void *priv, int level, const char *msg)
{
    (void)priv;
    if (level <= verbose)
        fprintf(stderr, "%s\n", msg);
}

static int read_cb(void *priv, uint8_t *data, int count)
{
    int r;
    (void)priv;
    r = (int)read(client_fd, data, (size_t)count);
    if (r < 0)
        return errno == EAGAIN ? 0 : -1;
    if (r == 0) {
        close(client_fd);
        client_fd = -1;
    }
    return r;
}

static int write_cb(void *priv, uint8_t *data, int count)
{
    int r;
    (void)priv;
    r = (int)write(client_fd, data, (size_t)count);
    if (r < 0) {
        if (errno == EAGAIN)
            return 0;
        if (errno == EPIPE) {
            close(client_fd);
            client_fd = -1;
            return 0;
        }
        return -1;
    }
    return r;
}

static void quit_handler(int sig)
{
    (void)sig;
    running = 0;
}

static int parse_fd_from_device(const char *dev)
{
    const char *p;
    if (dev == NULL)
        return -1;
    if (strncmp(dev, "/proc/self/fd/", 14) == 0)
        return atoi(dev + 14);
    if (strncmp(dev, "/dev/fd/", 8) == 0)
        return atoi(dev + 8);
    p = getenv("TERMUX_USB_FD");
    if (p && p[0])
        return atoi(p);
    return -1;
}

static void run_main_loop(void)
{
    const struct libusb_pollfd **pollfds = NULL;
    fd_set readfds, writefds;
    int i, n, nfds;
    struct timeval timeout, *timeout_p;

    while (running && client_fd != -1) {
        FD_ZERO(&readfds);
        FD_ZERO(&writefds);
        FD_SET(client_fd, &readfds);
        if (usbredirhost_has_data_to_write(host))
            FD_SET(client_fd, &writefds);
        nfds = client_fd + 1;

        free(pollfds);
        pollfds = libusb_get_pollfds(ctx);
        for (i = 0; pollfds && pollfds[i]; i++) {
            if (pollfds[i]->events & POLLIN)
                FD_SET(pollfds[i]->fd, &readfds);
            if (pollfds[i]->events & POLLOUT)
                FD_SET(pollfds[i]->fd, &writefds);
            if (pollfds[i]->fd >= nfds)
                nfds = pollfds[i]->fd + 1;
        }

        timeout_p = (libusb_get_next_timeout(ctx, &timeout) == 1) ? &timeout : NULL;
        n = select(nfds, &readfds, &writefds, NULL, timeout_p);
        if (n == -1) {
            if (errno == EINTR)
                continue;
            perror("select");
            break;
        }
        memset(&timeout, 0, sizeof(timeout));
        if (n == 0) {
            libusb_handle_events_timeout(ctx, &timeout);
            continue;
        }
        if (FD_ISSET(client_fd, &readfds)) {
            if (usbredirhost_read_guest_data(host))
                break;
        }
        if (client_fd == -1)
            break;
        if (FD_ISSET(client_fd, &writefds)) {
            if (usbredirhost_write_guest_data(host))
                break;
        }
        for (i = 0; pollfds && pollfds[i]; i++) {
            if (FD_ISSET(pollfds[i]->fd, &readfds) || FD_ISSET(pollfds[i]->fd, &writefds)) {
                libusb_handle_events_timeout(ctx, &timeout);
                break;
            }
        }
    }
    if (client_fd != -1) {
        close(client_fd);
        client_fd = -1;
    }
    free(pollfds);
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "Usage: %s [--device PATH | --fd N] --as HOST:PORT\n"
            "  TERMUX_USB_FD is used when --fd / a numeric /proc/self/fd path is omitted.\n",
            argv0);
}

int main(int argc, char **argv)
{
    static const struct option longopts[] = {
        {"device", required_argument, NULL, 'd'},
        {"as", required_argument, NULL, 'a'},
        {"to", required_argument, NULL, 'a'},
        {"fd", required_argument, NULL, 'f'},
        {"verbose", required_argument, NULL, 'v'},
        {"help", no_argument, NULL, 'h'},
        {NULL, 0, NULL, 0},
    };
    const char *device = NULL;
    const char *as = NULL;
    char hostaddr[64];
    int fd = -1, port = 23456, o, server_fd, on = 1, flags, rc;
    struct sockaddr_in addr;
    struct sigaction act;
    libusb_device_handle *handle = NULL;
    const char *envfd;

    memset(hostaddr, 0, sizeof(hostaddr));
    strncpy(hostaddr, "127.0.0.1", sizeof(hostaddr) - 1);

    while ((o = getopt_long(argc, argv, "d:a:f:v:h", longopts, NULL)) != -1) {
        switch (o) {
        case 'd':
            device = optarg;
            break;
        case 'a':
            as = optarg;
            break;
        case 'f':
            fd = atoi(optarg);
            break;
        case 'v':
            verbose = atoi(optarg);
            break;
        case 'h':
        default:
            usage(argv[0]);
            return o == 'h' ? 0 : 1;
        }
    }

    if (as) {
        const char *colon = strrchr(as, ':');
        if (colon && colon != as) {
            size_t n = (size_t)(colon - as);
            if (n >= sizeof(hostaddr))
                n = sizeof(hostaddr) - 1;
            memcpy(hostaddr, as, n);
            hostaddr[n] = '\0';
            port = atoi(colon + 1);
        } else {
            port = atoi(as);
        }
    }

    envfd = getenv("TERMUX_USB_FD");
    if (fd < 0 && envfd && envfd[0])
        fd = atoi(envfd);
    if (fd < 0)
        fd = parse_fd_from_device(device);
    if (fd < 0 && device) {
        fd = open(device, O_RDWR);
        if (fd < 0)
            fprintf(stderr, "open(%s): %s\n", device, strerror(errno));
    }
    if (fd < 0) {
        fprintf(stderr, "no USB fd (set TERMUX_USB_FD or --device /proc/self/fd/N)\n");
        usage(argv[0]);
        return 1;
    }

    memset(&act, 0, sizeof(act));
    act.sa_handler = quit_handler;
    sigaction(SIGINT, &act, NULL);
    sigaction(SIGHUP, &act, NULL);
    sigaction(SIGTERM, &act, NULL);
    sigaction(SIGQUIT, &act, NULL);

    /* libusb documents LIBUSB_OPTION_NO_DEVICE_DISCOVERY as init-time only:
     * "This option should only be used with libusb_init_context() otherwise
     * unspecified behavior may occur", and skipping the device scan is what
     * Android needs because /dev/bus/usb cannot be scanned there. Setting it
     * after libusb_init() (as this program used to) did nothing. */
#if defined(LIBUSB_API_VERSION) && (LIBUSB_API_VERSION >= 0x0100010A)
    {
        struct libusb_init_option opts[1];
        opts[0].option = LIBUSB_OPTION_NO_DEVICE_DISCOVERY;
        opts[0].value.ival = 1;
        rc = libusb_init_context(&ctx, opts, 1);
        if (rc) {
            fprintf(stderr, "libusb_init_context failed: %s\n",
                    libusb_error_name(rc));
            return 1;
        }
    }
#else
    libusb_set_option(NULL, LIBUSB_OPTION_NO_DEVICE_DISCOVERY);
    rc = libusb_init(&ctx);
    if (rc) {
        fprintf(stderr, "libusb_init failed: %s\n", libusb_error_name(rc));
        return 1;
    }
#endif
#if defined(LIBUSB_API_VERSION) && (LIBUSB_API_VERSION >= 0x01000107)
    if (libusb_wrap_sys_device(ctx, (intptr_t)fd, &handle) != 0 || handle == NULL) {
        fprintf(stderr, "libusb_wrap_sys_device(%d) failed\n", fd);
        libusb_exit(ctx);
        return 1;
    }
#else
    fprintf(stderr, "libusb too old for libusb_wrap_sys_device\n");
    libusb_exit(ctx);
    return 1;
#endif

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return 1;
    }
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, hostaddr, &addr.sin_addr) != 1) {
        fprintf(stderr, "bad listen address %s\n", hostaddr);
        return 1;
    }
    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "bind %s:%d: %s\n", hostaddr, port, strerror(errno));
        return 1;
    }
    if (listen(server_fd, 1) < 0) {
        perror("listen");
        return 1;
    }
    fprintf(stderr, "listening on %s:%d (fd %d)\n", hostaddr, port, fd);

    while (running) {
        client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR)
                continue;
            perror("accept");
            break;
        }
        flags = fcntl(client_fd, F_GETFL);
        if (flags >= 0)
            fcntl(client_fd, F_SETFL, flags | O_NONBLOCK);

        host = usbredirhost_open(ctx, handle, log_cb, read_cb, write_cb,
                                 NULL, SERVER_VERSION, verbose, 0);
        if (!host) {
            fprintf(stderr, "usbredirhost_open failed\n");
            close(client_fd);
            client_fd = -1;
            break;
        }
        handle = NULL;
        run_main_loop();
        usbredirhost_close(host);
        host = NULL;
        break;
    }

    close(server_fd);
    libusb_exit(ctx);
    return 0;
}
