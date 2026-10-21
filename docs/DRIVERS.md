# Guest Wi-Fi chipsets

The release guest image is Ubuntu 24.04 arm64. Drivers are already
installed. Plug the dongle, wait for attach, then in the VM:

```
ip link
iw dev
lsusb
dmesg | grep -iE 'usb|wlan|firmware'
```

## In-tree (Ubuntu linux-modules-extra)

| Chipset | Module | Notes |
|---|---|---|
| Atheros AR9271 / AR7010 | `ath9k_htc` | Best monitor/injection. Alfa AWUS036NHA. |
| Ralink RT5370 / RT5572 | `rt2800usb` | |
| MediaTek MT7601U | `mt7601u` | Cheap dongles. Monitor limited. |
| MediaTek MT7610U / MT7612U | `mt76x0u` / `mt76x2u` | |
| Realtek RTL8188CUS / RTL8192CU | `rtl8xxxu` | |
| Realtek RTL8821AU | `rtw88_8821au` | Kernel 6.x. Needs firmware. |
| Realtek RTL8822BU | `rtw88_8822bu` | |
| Realtek RTL8852AU | `rtw89` | Newer. |

Firmware packages on the image: `linux-firmware`, `linux-firmware-realtek`
equivalent blobs under `/lib/firmware/{rtlwifi,rtw88,rtw89,ath9k_htc,mediatek,brcm}`.

## Out-of-tree (DKMS, prebuilt for the guest ABI)

Shipped as `.ko` under `/lib/modules/$(uname -r)/updates/` and listed in
`/etc/modules-load.d/opx-wifi.conf` only when the in-tree module is
missing for that USB ID.

| Chipset | Module | Typical VID:PID |
|---|---|---|
| RTL8812AU / 8821AU (older) | `88XXau` | `0bda:8812`, `0bda:0811` |
| RTL8814AU | `88XXau` | `0bda:8813` |
| RTL8188EUS | `8188eu` | `0bda:8179` |
| RTL8188FU | `8188fu` | `0bda:f179` (Xiaomi-sensitive) |
| RTL8192EU | `8192eu` | `0bda:818b` |
| RTL8821CU / 8822CU | `8821cu` | `0bda:c811` |
| RTL88x2BU | `88x2bu` | `0bda:b812` |

If a module fails to load, the image still has the firmware; `dmesg`
will say which blob is missing. Open an issue with `lsusb -v` and
`dmesg`.

## What will not work

- Internal phone Wi-Fi. Android owns it. opx-mg never touches it.
- Broadcom SoftMAC full mac80211 on some BCM dongles (firmware-only STA).
- Anything that needs a patched **phone** kernel (monitor on the built-in
  chip, USB gadget HID, etc.).
