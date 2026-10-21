# Third-party

| Component | Upstream | License |
|---|---|---|
| usbredir / usbredirect | https://gitlab.freedesktop.org/spice/usbredir | GPL-2.0 / LGPL-2.1 |
| QEMU | https://www.qemu.org | GPL-2.0 |
| Ubuntu cloud images | https://cloud-images.ubuntu.com | Ubuntu / Canonical terms |
| Termux / Termux:API | https://github.com/termux | GPLv3 |
| Linux kernel hub.c quirk | Linux / Podroid issue #85 | GPL-2.0 |

The recipe this CLI automates was demonstrated by
Kuldeep-Dilliwar/android-hardware-access-without-root and
termux/termux-packages#19635. Podroid (ExTV) and StrykerOSS (zalexdev)
solved the same problem as Android apps via QMP usb-host, not usbredir.
