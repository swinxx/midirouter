# midirouter

A norns mod that routes MIDI between connected devices. Runs in the background — no script required. Rules survive reboots and device reconnects.

## Installation

Copy the `midirouter` folder to `~/dust/code/midirouter`, then enable it under **SYSTEM › MODS** and restart norns.

## How It Works

midirouter works with **rules**. Each rule defines:

- **From Device** — which MIDI device to receive from (`all` or a specific device name)
- **From Ch** — which MIDI channel to listen on (`all` or 1–16)
- **To Device** — where to send the MIDI (`all` or a specific device name)
- **To Ch** — channel to send on (`=src` to keep the original, or 1–16 to remap)
- **What to pass** — individually toggle Notes, CC, Program Change, Pitchbend, Aftertouch, Clock, SysEx

Up to **16 rules** can be active at the same time. Devices are referenced by name, so rules keep working after reboots or USB reconnects.

## Mod Menu Controls

Open the mod menu via **SYSTEM › MODS › midirouter**.

| Control | Action |
|---|---|
| **E2** | Scroll parameter list |
| **E3** | Change selected value |
| **K3** (hold) | Enter rule select mode |
| **K2** (short) | Back / cancel / exit menu |
| **K2** (long) | Open "Add rule" dialog |
| **K3** (hold) + **K2** (long) | Open "Delete rule" dialog |
| **E2 / E3** in dialog | Move cursor between buttons |
| **K3** in dialog | Confirm |
| **K2** in dialog | Cancel |

## PARAMS Integration

Rules can also be edited from the norns PARAMS menu under **MIDI ROUTER**. Changes take effect immediately and are saved automatically.

Additional options available in PARAMS:
- **Debug Log** — enable routing debug output in maiden
- **SysEx Debug** — verbose SysEx packet logging
- **Diagnostics** — print device and rule state to maiden
- **Rescan devices** — manually refresh the device list
- **+ Add rule / - Delete last rule**

## SysEx

SysEx routing over TRS MIDI (ShieldXL) requires a patched version of `ttymidi`. See [swinxx/ttymidi-sysex](https://github.com/swinxx/ttymidi-sysex).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
