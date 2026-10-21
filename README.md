# opx-mg

**Rootless USB Wi-Fi on stock Android, inside Termux.**

No custom phone kernel. No Magisk. No NetHunter flash. Plug a USB adapter,
type `opx-mg`, tap OK on the permission dialog — the dongle shows up as
`wlan0` inside a real Linux VM with drivers already installed.

```
USB dongle -> termux-usb FD -> usbredirect -> QEMU usb-redir -> guest wlan0
```

## Why

Android will not let Termux open `/dev/bus/usb`. `termux-usb` is the only
public API: it asks `UsbManager` for a file descriptor and hands that fd to
a child process. `usbredirect` (spice/usbredir) turns the fd into a TCP
usbredir stream. Termux's stock `qemu-system-aarch64` consumes it with
`-device usb-redir`. The guest is a normal Linux kernel, so real Wi-Fi
drivers and firmware work.

This is the path proven by:

- [Kuldeep-Dilliwar/android-hardware-access-without-root](https://github.com/Kuldeep-Dilliwar/android-hardware-access-without-root)
- [termux/termux-packages#19635](https://github.com/termux/termux-packages/issues/19635) (Update-5 / Update-6)

opx-mg packages it: one CLI, binaries from this repo's releases, a guest
image with Wi-Fi firmware preinstalled, and a watcher that attaches a
dongle the moment it is plugged in.

It is **not** Podroid (Android APK, QMP `usb-host` + SCM_RIGHTS) and **not**
Stryker (rooted chroot). Those are documented in `docs/RESEARCH.md`.

## Requirements

- Unrooted Android 8+ with Termux (the CLI supports `aarch64` and `armv7a`)
- [Termux](https://github.com/termux/termux-app) **and** [Termux:API](https://github.com/termux/termux-api) from the **same** source (F-Droid or GitHub, not Play Store)
- USB OTG + a USB Wi-Fi adapter (Atheros AR9271 / Realtek 88xx / MT76 recommended)
- ~3 GB free storage for the guest image
- Patience: no KVM without root, so QEMU runs in TCG. Slow, but real.

## Install

In Termux:

```
pkg update
pkg install termux-api qemu-system-aarch64-headless qemu-utils xorriso python curl git
```

On 32-bit Termux, leave out the two QEMU packages: the `arm` repo does not
ship them (see [Architectures](#architectures)).

Install the **Termux:API APK** from the same source as Termux.

Then either:

```
curl -fsSL https://raw.githubusercontent.com/OPX-Aminul/opx-mg/main/install.sh | sh
```

or:

```
git clone https://github.com/OPX-Aminul/opx-mg.git
cd opx-mg
./bin/opx-mg setup
```

`setup` detects the Termux userspace arch (`aarch64` or `armv7a`), downloads
the matching `usbredirect-<arch>` and shim, plus the guest disk, from this
repo's [Releases](https://github.com/OPX-Aminul/opx-mg/releases). A GitHub
Actions workflow builds both arches on every `v*` tag and on
`workflow_dispatch`. Until a release exists, setup falls back to the
Ubuntu 24.04 cloud image.

## Architectures

| Host | USB binaries | Guest VM |
|------|--------------|----------|
| `aarch64` (64-bit Termux) | `usbredirect-aarch64` + `opx-usb-shim-aarch64.so` | `qemu-system-aarch64` from Termux |
| `armv7a` (32-bit Termux) | `usbredirect-armv7a` + `opx-usb-shim-armv7a.so` | needs a custom QEMU via `OPX_QEMU_BIN` |

There is nothing to choose: `setup`, `update`, and `doctor` read the arch of
the running Termux userspace (a 32-bit Termux on a 64-bit phone reports
`armv8l` and gets `armv7a` assets). 32-bit Termux's `arm` repo has
`termux-api` but no QEMU package, so the guest VM cannot boot there with
stock packages. `setup` says so instead of failing halfway.

## Use

```
opx-mg
```

That is setup (first run) + start the VM + watch USB. Plug the adapter,
tap **OK**. In another session:

```
opx-mg ssh
```

Password is `opx`. Then:

```
lsusb
ip link
iw dev
dmesg | grep -iE 'usb|wlan|firmware'
```

Other commands:

```
opx-mg status
opx-mg usb list
opx-mg usb attach /dev/bus/usb/001/002
opx-mg console
opx-mg stop
opx-mg doctor
opx-mg -u
```

`opx-mg doctor` prints the detected arch, QEMU path, guest disk, seed, and
USB state. `opx-mg -u` (or `opx-mg update`) pulls the newest release: CLI
tarball, `usbredirect-<arch>`, shim, seed ISO. Add `--image` to replace the
guest disk (stop the VM first). Assets are re-selected by arch on every
update, so a release published for both arches upgrades either host.

Useful overrides: `OPX_QEMU_BIN` (QEMU binary), `OPX_MEM` / `OPX_SMP`
(guest size), `OPX_MG_HOME` (state dir), `OPX_MG_REPO` (release repo).

SSH is forwarded to `127.0.0.1:2222`.

## Guest

Ubuntu 24.04 arm64, glibc. Firmware and in-tree USB Wi-Fi modules are
intended to ship in the release qcow2 (`guest/build-image.sh`). Chipset
table: `docs/DRIVERS.md`.

Login: `opx` / `opx` (root password `opx`).

## Limits

- TCG is slow. Monitor-mode packet rates will not match a native
  NetHunter kernel.
- 32-bit armv7a: architecture detection, `usbredirect-armv7a`, and the shim
  are built and installed, but 32-bit Termux's repo has no QEMU package, so
  the guest VM cannot start there. Point `OPX_QEMU_BIN` at a 32-bit QEMU
  build if you have one. Guest defaults drop to 1G / 2 vCPU.
- One `usbredirect` process per device.
- Xiaomi / MIUI often reports full-speed dongles as low-speed
  (`Invalid ep0 maxpacket: 64`). That is a host-stack lie, not a Termux
  bug. See `docs/XIAOMI.md`. A guest `hub.c` quirk is planned.
- Internal phone Wi-Fi is never touched.

## Layout

```
bin/opx-mg            CLI
lib/                  setup, vm, usb, watch
host/                 usbredirect build notes + optional fd shim
guest/                cloud-init seed + image bake script
docs/ARCHITECTURE.md  design
docs/RESEARCH.md      sources
```

## License

GPL-2.0. usbredir, QEMU, Ubuntu, and Termux keep their own licenses.

## Disclaimer

For authorized security testing, education, and research on networks you
own or have permission to test. You are responsible for complying with
applicable law.
