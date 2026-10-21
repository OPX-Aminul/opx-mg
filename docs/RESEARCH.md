# Research notes (sources that this repo is built on)

All of this was read before the first commit. Links are the proof; the
architecture in `docs/ARCHITECTURE.md` is the conclusion.

## 1. Termux usbredirect + QEMU (the working recipe)

**Kuldeep-Dilliwar/android-hardware-access-without-root**
https://github.com/Kuldeep-Dilliwar/android-hardware-access-without-root

End-to-end Termux guide: compile usbredir with meson/ninja, `termux-usb -l`
/ `-r` / `-E -e ./run.sh PATH`, QEMU `-chardev socket,... -device usb-redir`.
Uses Ubuntu 24.04 cloud image because Alpine + musl broke proprietary
userspace drivers. Demonstrated with an HP M1136 scanner. Explicitly
states: no KVM without root, TCG is slow, usbredirect handles one device
per process.

**termux/termux-packages#19635**
https://github.com/termux/termux-packages/issues/19635

Closed informational thread. The command

```
termux-usb -e usbredirect device "/dev/bus/usb/001/031" --to 127.0.0.1:23456
```

is wrong (`too many arguments`, then `illegal option`). Working form
(Update-5):

```
termux-usb -e "/path/usbredirect --device /dev/bus/usb/001/003 --as 127.0.0.1:23456" /dev/bus/usb/001/003
```

Update-6..10 prove mass-storage in an Alpine QEMU guest: `mkfs`, LUKS,
`eject`, hotplug via QMP `chardev-add` + `device_add usb-redir` after
replug, even SSH-tunnelled usbredirect from a remote host. This is the
hotplug model opx-mg copies.

**termux-usb CLI** (termux-api-package `scripts/termux-usb.in`)

```
termux-usb [-l | [-r] [-E] [-e command] [device | vendorId productId]]
```

`-E` exports the fd as `TERMUX_USB_FD` instead of argv. `-e` is a single
argument — extra flags after `-e usbredirect` are parsed by `termux-usb`,
which is why #19635 exploded. Always wrap usbredirect in a script.

**UsbAPI.java** (termux-api)
`UsbManager.openDevice()` → `connection.getFileDescriptor()` →
`ResultReturner.WithAncillaryFd.sendFd()`. The Java side keeps the
`UsbDeviceConnection` alive in a SparseArray keyed by fd. The connection
must stay open for the lifetime of usbredirect.

**sago35/termux-usb-examples**
https://github.com/sago35/termux-usb-examples

Raw libusb-style userspace on the inherited fd (CDC / UF2). Confirms
the fd is a usable usbfs handle, not a dummy.

**HN item 40507319**
https://hn.edgecompute.app/item/40507319
(gist: NoteAfterNote/7a197233de3d60ff1e23ca90ed2f595a)

Public proof of USB disk as `/dev/sda` on an unrooted phone via Termux +
QEMU + Alpine. Comment thread: QEMU is heavy; people ask for proot USB
nodes; nobody shipped that.

**usbredir**
https://gitlab.freedesktop.org/spice/usbredir
mirror: https://github.com/SPICEorg/usbredir

Protocol + `usbredirhost` (libusb device handle in, socket out).
`usbredirect` is the CLI in `tools/` of modern tarballs. `usbredirserver`
is the older TCP server. QEMU's `-device usb-redir` is the guest side.

## 2. Podroid (ExTV/Podroid) — Android-app usb-host path

https://github.com/ExTV/Podroid
3.6k stars. Rootless Alpine VM, QEMU TCG or AVF/pKVM. USB is **not**
usbredir:

```
UsbManager.openDevice() fd
  -> QMP add-fd (SCM_RIGHTS)
  -> device_add usb-host,hostdevice=/dev/fdset/N
```

`UsbPassthroughManager.kt` registers `ACTION_USB_DEVICE_ATTACHED` only
while the VM is Running. Needs a libusb-enabled QEMU (`libusb_wrap_sys_device`).

**Issue #85** (open): Xiaomi Poco F1 / MIUI, USB Wi-Fi
`usb 1-1: Invalid ep0 maxpacket: 64` then `unable to enumerate`. Same
dongle works on non-Xiaomi. Same failure in Stryker and KaliDroid.
Cause: host reports `USB_SPEED_LOW` but `bMaxPacketSize0 == 64` (USB
spec: low-speed maxpacket ≤ 8). Guest `hub.c` rejects it.

Podroid fix (private OPX fork `FIX-XIAOMI-MIUI-USB.md`):

1. QEMU `hw/usb/host-libusb.c`: if speed==LOW and descriptor[7]==64,
   force FULL.
2. Guest `drivers/usb/core/hub.c`: `else if (LOW && i==64) speed=FULL`.

**Issue #107 / #111**: request UML backend. Stryker 6.5 already has it.
Podroid stays on QEMU/AVF.

Wi-Fi firmware coverage (YourXDemon/OPX fork `build-rootfs.sh`):
`firmware-realtek`, `firmware-atheros`, `firmware-brcm80211`,
`firmware-libertas`, `firmware-misc-nonfree`. Alpine variant listed
`linux-firmware-rtlwifi`, `rtw88`, `rtw89`, `mediatek`, `ath9k_htc`.

## 3. StrykerOSS (zalexdev/strykerapp)

https://github.com/zalexdev/strykerapp
1.9k stars. Rooted Debian trixie chroot is the happy path. Rootless
mode boots the **same** rootfs in QEMU:

```
qemu-system-aarch64 -M virt,gic-version=3 -device qemu-xhci -qmp unix:qmp.sock
QMP add-fd + device_add usb-host  (identical to Podroid)
```

Stock QEMU 11.0.2 with libusb works; a patched rebuild broke USB
("can't attach to VM") — PAC coroutine / shm shims suspected
(`stryker-build/README.md`). 6.5 adds UML (`zalexdev/linux-um-arm64`)
and engine probe: chroot if rooted, else UML, else QEMU.

Not a Termux project. Requires the APK.

## 4. linux-um-arm64 (OPX-Aminul fork of zalexdev)

`ARCH=um SUBARCH=arm64`. Kernel as a normal aarch64 process. USB
passthrough in the README is **USB/IP**, not usb-host: RTL8811AU
appears as `wlan0`, `rtw88_8821au` binds, scan works, assoc untested.
Native speed. Research-grade. No Termux installer. Future optional
engine for opx-mg, not v0.1.

## 5. proroot (coderredlab/proroot)

LD_PRELOAD proot replacement, zero ptrace. Proprietary binaries, no
source. A USB FD compatibility layer was discussed as a possible
future — it is **not implemented**. Even if it were, proroot has no
kernel, so no `ath9k_htc.ko`. Dead end for monitor-mode Wi-Fi.

## 6. Decision

v0.1 = Termux + stock `qemu-system-aarch64-headless` + prebuilt
`usbredirect` + prebaked Ubuntu arm64 qcow2 with firmware/modules +
`opx-mg` CLI that hides every step in #19635 / Kuldeep.

v0.2 candidates: Xiaomi guest `hub.c` quirk, custom guest kernel,
optional UML engine, usb-host QMP path if we ship our own QEMU.
