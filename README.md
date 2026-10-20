# PadLink

Use a wired USB-C controller on your iPhone as a controller on your Windows 11 PC, with no Bluetooth.
The iPhone reads the controller over USB and sends its state to the PC over your network. A small
receiver on the PC presents it to Windows and games as a virtual Xbox 360 controller.

```
controller --USB-C--> iPhone (PadLink app) --UDP--> PC receiver --ViGEmBus--> Xbox 360 pad
```

This is not a real USB connection: iOS cannot act as a USB device. The PC sees a virtual pad.

## Features
- Works with any controller iOS supports (Xbox, DualSense, MFi, ...). Several can be connected at once; their inputs are merged.
- Swap A/B and X/Y (for Nintendo-style layouts).
- Keeps running when you switch apps or lock the phone, and starts sending as soon as the app opens.
- Built-in latency test (round trip to the PC) with a live graph.
- The receiver releases all inputs if the phone goes quiet, so nothing gets stuck.

## Install

Download both files from the [latest release](https://github.com/ajhockey88/PadLink/releases/latest).

### PC (Windows 11)
1. Install [Python 3.12+](https://www.python.org/downloads/) (tick "Add python.exe to PATH").
2. Install the [ViGEmBus driver](https://github.com/nefarius/ViGEmBus/releases) and reboot if asked.
3. Unzip `PadLinkReceiver.zip` to a permanent folder, e.g. `C:\PadLink`.
4. In that folder run `pip install -r requirements.txt`.
5. Run `python padlink_receiver.py`. You should see "PadLink listening on UDP 26760" and hear a controller chime.
6. Allow Python through Windows Firewall for UDP 26760 (private networks; if your Ethernet shows as Public, allow that too).
7. Optional, to start it hidden at every login: `powershell -ExecutionPolicy Bypass -File install_startup.ps1`.
   Stop it with `Stop-ScheduledTask PadLinkReceiver`, remove it with `Unregister-ScheduledTask PadLinkReceiver`.

Give the PC a fixed IP (a DHCP reservation in your router) so the address in the app does not change.

### iPhone (no Mac needed)
1. Install [Sideloadly](https://sideloadly.io/) on the PC, plus iTunes and iCloud from Apple's site (not the Microsoft Store versions).
2. Plug in the iPhone, tap Trust, drag `PadLink.ipa` into Sideloadly, enter your Apple ID and click Start.
3. On the iPhone: Settings > General > VPN & Device Management > trust your Apple ID. Enable Developer Mode if asked.
4. A free Apple ID's app expires after 7 days; run Sideloadly again to renew. A paid developer account lasts a year.

## Use
1. Connect the iPhone and PC to the same network (see "Connection options").
2. Plug the controller into the iPhone's USB-C port.
3. Open PadLink, enter the PC's IP address (`ipconfig` on the PC) once, and tap Start. It starts by itself next time.
4. Check `joy.cpl` on Windows or any game. Close the app any time; the receiver keeps running.

To measure latency, tap **Test latency** while running. The receiver must be the current version.

## Connection options
| Option | Setup | Typical round trip |
|---|---|---|
| Wi-Fi (5/6 GHz, near the router) | Same network as the PC | about 5-10 ms |
| USB-C hub with Ethernet | Hub carries controller, Ethernet and power | about 2-4 ms |
| USB cable + Personal Hotspot | Plug the iPhone into the PC | about 2-4 ms |

Numbers are rough; use the latency test on your own setup. If it is hit-or-miss, turn off client/AP isolation
on the router and keep the phone out of Low Power Mode.

## Troubleshooting
- **Nothing happens when I run the receiver:** another copy may already own the port. Close old windows, or
  `Stop-Process -Name python, pythonw -Force` if you don't use Python for anything else. The receiver prints what it is doing.
- **Startup error mentioning ViGEm:** install the ViGEmBus driver and reboot.
- **No controller in `joy.cpl`:** the receiver creates it at start; look for the chime and the console message.
- **Latency test shows "No reply":** wrong IP, receiver not running, or the firewall is blocking UDP 26760.
- **Errors are also written to `padlink.log`** next to the receiver script.

## Limits
- One virtual Xbox 360 pad. Several physical controllers are merged into it, not split into players.
- Gyro, touchpad, adaptive triggers and rumble are not forwarded.
- iOS can end a backgrounded app under memory pressure.

## Build from source
Releases are built by GitHub Actions (`.github/workflows/release.yml`, manual "Run workflow"). The iOS app
is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `iOS/project.yml` on a macOS runner and
packaged as an unsigned IPA for sideloading. The receiver is `Windows/padlink_receiver.py`.
The wire format is in [PROTOCOL.md](PROTOCOL.md).

Not tested on every controller or network; reports and fixes are welcome.
