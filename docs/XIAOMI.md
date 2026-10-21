# Xiaomi / MIUI USB Wi-Fi (`Invalid ep0 maxpacket: 64`)

On Xiaomi / MIUI / HyperOS the host USB stack often reports a full-speed
dongle as low-speed. The guest then does:

```
usb 1-1: new low-speed USB device number 2 using xhci_hcd
usb 1-1: Invalid ep0 maxpacket: 64
usb usb1-port1: unable to enumerate USB device
```

USB spec: low-speed `bMaxPacketSize0` is 8. 64 means full-speed. The
kernel is correct to reject the combination; the host lied about speed.

This is **not** a Termux bug and **not** a usbredirect bug. The same
dongle works on non-Xiaomi phones. Tracked as ExTV/Podroid#85; also
seen in Stryker and KaliDroid.

## What opx-mg can do without flashing the phone

The phone kernel is stock. We cannot patch Xiaomi's host driver.

1. **Guest quirk** (planned, custom guest kernel image): in
   `drivers/usb/core/hub.c`, if `speed == USB_SPEED_LOW && maxpacket == 64`,
   set `speed = USB_SPEED_FULL` and reinit ep0. Same patch Podroid ships.
2. **usbredirect rewrite** (planned): force the usbredir hello /
   device-connect speed field to FULL when the descriptor says 64.
3. **Workaround today**: use a USB 2.0 hub between the phone and the
   dongle. Some Xiaomi controllers report hub-attached devices at the
   right speed. Or use a non-Xiaomi phone.

Until (1) or (2) ships, `opx-mg usb status` will print a hint if the
guest dmesg contains `Invalid ep0 maxpacket`.
