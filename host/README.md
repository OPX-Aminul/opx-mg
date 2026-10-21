# Host-side binaries (Termux aarch64)

Release assets expected:

| Asset | What |
|---|---|
| `usbredirect-aarch64` | spice/usbredir `tools/usbredirect`, linked against Termux libusb |
| `opx-usb-shim.so` | optional LD_PRELOAD so libusb opens `TERMUX_USB_FD` |

Until those exist, `opx-mg setup` looks for `usbredirect` on PATH and
prints compile instructions.

## Build usbredirect on-device

```
pkg install meson ninja libusb pkg-config git clang
git clone --depth 1 https://gitlab.freedesktop.org/spice/usbredir.git
cd usbredir
meson setup build
ninja -C build
cp build/tools/usbredirect $PREFIX/var/lib/opx-mg/bin/usbredirect
```

The wrap script in `lib/usb.sh` passes `--device /proc/self/fd/$TERMUX_USB_FD`.
If a given build refuses that path, compile `opx-usb-shim.c` and run
usbredirect under `LD_PRELOAD`.

## Build the shim

```
clang -shared -fPIC -o opx-usb-shim.so opx-usb-shim.c -ldl
```

`LIBUSB_WRAP_FD=$TERMUX_USB_FD LD_PRELOAD=./opx-usb-shim.so usbredirect --device dummy --as 127.0.0.1:23456`
