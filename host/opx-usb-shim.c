/*
 * Minimal LD_PRELOAD helper: when usbredirect/libusb tries to open a
 * usbfs path Android will not allow, reuse TERMUX_USB_FD / LIBUSB_WRAP_FD
 * instead. Not a full libusb_wrap_sys_device implementation — it only
 * intercepts open() of /dev/bus/usb/* and /proc/self/fd/*.
 *
 * Build: clang -shared -fPIC -o opx-usb-shim.so opx-usb-shim.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int wrap_fd(void) {
    const char *e = getenv("LIBUSB_WRAP_FD");
    if (e == NULL || e[0] == '\0')
        e = getenv("TERMUX_USB_FD");
    if (e == NULL || e[0] == '\0')
        return -1;
    return atoi(e);
}

static int is_usb_path(const char *path) {
    if (path == NULL)
        return 0;
    if (strncmp(path, "/dev/bus/usb/", 13) == 0)
        return 1;
    if (strncmp(path, "/proc/self/fd/", 14) == 0)
        return 1;
    return 0;
}

int open(const char *path, int flags, ...) {
    static int (*real_open)(const char *, int, ...) = NULL;
    if (real_open == NULL)
        real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    if (is_usb_path(path)) {
        int fd = wrap_fd();
        if (fd >= 0)
            return dup(fd);
    }
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return real_open(path, flags, mode);
    }
    return real_open(path, flags);
}

int open64(const char *path, int flags, ...) {
    return open(path, flags);
}
