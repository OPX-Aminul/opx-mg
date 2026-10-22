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

One command in Termux installs everything — packages, QEMU for your arch
(`termux-main` on aarch64, TUR's QEMU 9 on 32-bit), `usbredirect`, the
cloud-init seed and the guest disk:

```
curl -fsSL https://raw.githubusercontent.com/OPX-Aminul/opx-mg/main/install.sh | sh
```

The only manual step left is an APK, because Android does not let a shell
install one: get **Termux:API** from the same source as Termux (F-Droid or
GitHub, not Play Store).

Or from a clone:

```
git clone https://github.com/OPX-Aminul/opx-mg.git
cd opx-mg
sh ./bin/opx-mg setup
```

To install packages by hand instead (`setup` runs exactly this):

```
# 64-bit Termux (aarch64)
pkg install termux-api qemu-system-aarch64-headless qemu-utils xorriso python curl git openssh

# 32-bit Termux (armv7a): QEMU 9 comes from TUR, which still builds for arm
pkg install termux-api xorriso python curl git openssh
pkg install tur-repo x11-repo
pkg install qemu-system-aarch64-9 qemu-utils-10
```

`sh ./bin/opx-mg` (rather than `./bin/opx-mg`) is deliberate: Termux has no
`/usr/bin/env`, so running the script directly only works when the Termux
exec wrapper is installed. The installed `opx-mg` command is a launcher that
already handles this.

`setup` detects the Termux userspace arch (`aarch64` or `armv7a`), downloads
the matching `usbredirect-<arch>` and shim, plus the guest disk, from this
repo's [Releases](https://github.com/OPX-Aminul/opx-mg/releases). A GitHub
Actions workflow builds both arches on every `v*` tag and on
`workflow_dispatch`. Until a release exists, setup falls back to the
Ubuntu 24.04 cloud image.

## Architectures

| Host | USB binaries | Guest VM |
|------|--------------|----------|
| `aarch64` (64-bit Termux) | `usbredirect-aarch64` + `opx-usb-shim-aarch64.so` | `qemu-system-aarch64-headless` from `termux-main` |
| `armv7a` (32-bit Termux) | `usbredirect-armv7a` + `opx-usb-shim-armv7a.so` | `qemu-system-aarch64` from TUR (`qemu-system-aarch64-9`) |

There is nothing to choose: `setup`, `update`, and `doctor` read the arch of
the running Termux userspace (a 32-bit Termux on a 64-bit phone reports
`armv8l` and gets `armv7a` assets).

32-bit Termux has no QEMU in `termux-main`, which is why
`pkg install qemu-system-aarch64-headless` fails there. TUR keeps the QEMU 9
series for 32-bit hosts: its `qemu-system-aarch64-9` is a 32-bit ARM build
that still carries `bin/qemu-system-aarch64`, and `qemu-common-10` supplies
`share/qemu/edk2-aarch64-code.fd`. `setup` installs `tur-repo` + `x11-repo`
and those two packages automatically.

The guest itself is arm64 (`OPX_GUEST_ARCH`) on both hosts, so 32-bit
Termux runs it in TCG with 1G / 2 vCPU by default — slower than aarch64. If
the phone is 64-bit, `getprop ro.product.cpu.abi` says `arm64-v8a`, and
64-bit Termux gets the aarch64 assets plus the stock QEMU package.

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
opx-mg logs
opx-mg -u
```

### Logs

Everything from setup to USB passthrough is appended to one file:
`${OPX_MG_HOME:-$PREFIX/var/lib/opx-mg}/logs/opx-mg.log`. That includes
`pkg install` and download output, VM start/stop, USB permission and
usbredirect messages, and the guest serial console. The path is
`~/.opx-mg/logs/opx-mg.log` outside Termux.

```
opx-mg logs path
opx-mg logs            # last 200 lines
opx-mg logs system     # arch, QEMU, termux-usb, attached devices
opx-mg logs bundle     # tar.gz with logs/ + system-info.txt, for sharing
```

The log rotates to `opx-mg.log.<timestamp>` at CLI start when it exceeds
2 MB and the VM is stopped (`OPX_LOG_MAX_BYTES` overrides the size).

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
- 32-bit armv7a: QEMU 9 comes from TUR and runs the arm64 guest in TCG, so
  it is the slowest supported setup. Guest defaults drop to 1G / 2 vCPU.
  `OPX_QEMU_BIN` overrides the binary for a custom build.
- One `usbredirect` process per device.
- Xiaomi / MIUI often reports full-speed dongles as low-speed
  (`Invalid ep0 maxpacket: 64`). That is a host-stack lie, not a Termux
  bug. See `docs/XIAOMI.md`. A guest `hub.c` quirk is planned.
- Internal phone Wi-Fi is never touched.

## Troubleshooting

Everything that happens on the phone is written to one file. Start here:

```
# current state: arch, QEMU, termux-usb, disk, attached devices, log path
opx-mg doctor

# last 200 lines, including setup, VM, USB and guest serial output
opx-mg logs

# follow it live while plugging the adapter in
opx-mg console
```

If you need help, send the bundle: it contains `opx-mg.log` and
`system-info.txt`, not your GitHub token or Wi-Fi credentials.

```
opx-mg logs bundle
```

### `opx-mg: not found` right after install

Termux has no `/usr/bin/env`, so a script whose first line is
`#!/usr/bin/env sh` fails with `not found` when the Termux exec wrapper is
absent (32-bit and custom bootstraps usually lack it). Re-run the installer:
it writes `$PREFIX/bin/opx-mg` as a launcher that uses the absolute Termux
`sh` path. For a git clone, run `sh ./bin/opx-mg setup` instead of
`./bin/opx-mg setup`.

### `Unable to locate package qemu-system-aarch64-headless`

That is the aarch64 package name and the running Termux userspace is 32-bit,
where `termux-main` has no QEMU. Use TUR's QEMU 9 build (what `setup` does):

```
pkg install tur-repo x11-repo
pkg install qemu-system-aarch64-9 qemu-utils-10
```

`opx-mg doctor` then shows the QEMU path. If TUR is unreachable, a 64-bit
Termux is the faster route on a 64-bit phone (`getprop ro.product.cpu.abi`
= `arm64-v8a`); `OPX_QEMU_BIN` still overrides the binary.

### Setup stops or downloads fail

- The log shows every URL and its byte count; a failed download appears as
  `[WARN] download failed:` followed by the URL. Re-run `opx-mg setup`.
- `release asset ... not published yet` means that file is missing from the
  latest GitHub release. The guest disk falls back to the Ubuntu cloud
  image; `usbredirect` cannot fall back.
- `termux-usb missing` or `termux-usb -l failed` means the Termux:API APK
  is absent or signed by a different key. Install the APK from the same
  source as Termux.
- `edk2-aarch64-code.fd not found` means the QEMU package is incomplete:
  `pkg install qemu-system-aarch64-headless`.
- On 32-bit Termux QEMU comes from TUR (see
  [Architectures](#architectures)); if `pkg` cannot reach it, set
  `OPX_QEMU_BIN` to your own build.

### The VM does not boot

```
opx-mg logs | grep -iE 'qemu|error|firmware|panic'
opx-mg console
```

`QEMU failed to start` means the binary exited immediately. The log records
the failure and the disk/seed paths; QEMU's own message is printed on the
terminal. A guest that starts but never reaches SSH is still visible on
`opx-mg console` (kernel and cloud-init messages). Confirm the disk exists
with `opx-mg doctor`.

### USB attach hangs or fails

- The Android permission dialog must be accepted; the log records
  `waiting for USB permission dialog`. If nothing appears, the Termux:API
  app is missing or from another source.
- `usbredirect did not bind 127.0.0.1:<port>`: the wrapper could not open
  the inherited fd, or the port is taken. The log has the wrapper's own
  lines tagged `[USB]`.
- `QMP hotplug failed`: the VM is up but QEMU rejected the device. Re-run
  `opx-mg usb attach /dev/bus/usb/BBB/DDD`; one `usbredirect` runs per
  device, so detach it first if it is listed twice.
- `opx-mg usb status` shows the raw device list and the attached map.

### The adapter is attached but the guest has no wlan0

Inside the guest:

```
lsusb
dmesg | grep -iE 'usb|wlan|firmware|ath9k|rtl|mt7'
ip link
```

Missing firmware or a driver that failed to probe is recorded there and in
the same log file. Xiaomi/MIUI full-speed dongles reported as low-speed are
covered in `docs/XIAOMI.md`.

## Layout

```
bin/opx-mg            CLI
lib/                  setup, vm, usb, watch, logs
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
