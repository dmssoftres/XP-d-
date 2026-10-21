# XPPen ACK05 Shortcut Remote — Bluetooth driver mode

Interoperability notes written by the XP[d] project from live captures of an
ACK05-B remote (October 2026). Unofficial: not provided or confirmed by XPPen
or Hanvon Ugee. No vendor code or binaries are reproduced here.

## Why it matters

Over Bluetooth the remote acts as a standard keyboard and sends factory
shortcuts. Several keys share modifiers, so holding one key can hide another
(K10 + K5 arrives as K10 only). The remote also has a vendor mode in which it
reports each control as its own bit, which fixes every such collision.

## Device identity

| Item | Value |
|---|---|
| Bluetooth name | `Shortcut Remote` |
| USB/HID vendor / product | `0x28BD` / `0x0202` |
| Device Information 2A29 | `HANWUGEE` |
| Device Information 2A50 (PnP ID) | `02 BD 28 02 02 01 00` |
| Main chip (ACK05-B, from public FCC photos, ID 2AKDT-ACK05B) | Telink TLSR8258 |

Check the PnP ID before writing anything.

## GATT

| Service | Characteristic | Properties | Use |
|---|---|---|---|
| `FFE0` | `0001` | write, write without response | commands |
| `FFE0` | `0002` | notify | command replies |
| `FFE0` | `0003` | notify | battery and driver-mode input |
| `00010203-0405-0607-0809-0A0B0C0D1912` | `…2B12` | read, write w/o response, notify | Telink OTA (firmware update) — **do not write** |

Subscribe to both `0002` and `0003` (`0003` stays silent unless both are on).

## Commands (write to `FFE0/0001`, 10 bytes)

| Bytes | Effect | Reply on `0002` |
|---|---|---|
| `02 B0 04 00 00 00 00 00 00 00` | enter driver mode | `02 B0 01 00 …` |
| `02 B0 00 00 00 00 00 00 00 00` | leave driver mode (normal keyboard) | `02 B0 01 00 …` |
| `80 06 02 00 00 00 00 00 00 00` | read device name | `80 06 02 01` + `Shortcut Remote` |

Notes:
- The reply `02 B0 01` is the same for on and off, so track which command was
  sent last.
- Driver mode is not stored: switching the remote off and on returns it to
  normal mode. Send `02 B0 04` again on every connection.
- While in driver mode the standard HID keyboard output is silent (one final
  all-zero report is sent on entry).
- Never send `04 30 …` / `04 31 …` (they rename the device) or anything to the
  OTA service.

## Battery (`FFE0/0003`)

`02 F2 01 <percent> …` about every 5 seconds; `<percent>` is 0–100.

## Driver-mode input (`FFE0/0003`)

```
02 F0 <lo> <hi> 00 00 00 <wheel> 00 00
```

| Field | Meaning |
|---|---|
| `lo` bit 0…7 | K1 … K8 held |
| `hi` bit 0, 1 | K9, K10 held |
| `hi` bit 2 (`0x04`) | wheel center held |
| `wheel` | `01` = one clockwise detent, `02` = one counter-clockwise detent |

- All bits clear = everything released.
- Several keys held at once set several bits (K5 + K10 = `lo 10`, `hi 02`).
- A held key repeats the same packet about every 45 ms; ignore unchanged states.
- The bit order matches the remote's wired "report 2" (`F0`-marked) bitmask.

## Example session

```
→ 0001  02 B0 04 00 00 00 00 00 00 00
← 0002  02 B0 01 00 00 00 00 00 00 00
← 0003  02 F0 00 02 00 00 00 00 00 00   K10 down
← 0003  02 F0 10 02 00 00 00 00 00 00   K5 down while K10 held
← 0003  02 F0 00 02 00 00 00 00 00 00   K5 up
← 0003  02 F0 00 00 00 00 00 00 00 00   K10 up
← 0003  02 F0 00 00 00 00 00 01 00 00   wheel one step clockwise
→ 0001  02 B0 00 00 00 00 00 00 00 00   back to normal keyboard
```
