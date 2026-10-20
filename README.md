<p align="center">
  <img src="design/icon-256.png" width="128" height="128" alt="PadLink app icon: a game controller sending a signal">
</p>

<h1 align="center">PadLink</h1>

<p align="center">Use a wired controller on your iPhone as a controller on your Windows PC.</p>

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
- PC tray icon with live status, Disable / Enable, Run at login, Open log and Quit.

## Install

Download both files from the [latest release](https://github.com/ajhockey88/PadLink/releases/latest).

### PC (Windows 11)
1. Download `PadLinkReceiver.exe` and double-click it. Nothing else to install.
2. First run only: it installs the virtual-controller driver (ViGEmBus). Approve the Windows prompt. If it still says the driver is missing afterwards, restart Windows once.
3. A PadLink icon appears in the system tray (click `^` if hidden) and you hear a controller chime.
4. Allow it through Windows Firewall when asked (private networks; if your Ethernet shows as Public, allow that too). It uses UDP 26760, plus 5353 for finding the PC.
5. To start it automatically at every login, right-click the tray icon and tick **Run at login**. This copies the exe to `%LOCALAPPDATA%\PadLink` so you can delete the download.

Windows SmartScreen may warn because the exe is not code-signed: choose **More info** then **Run anyway**. To update, right-click the tray icon, **Quit**, then run the new exe (with Run at login ticked it updates its saved copy the next time you run it).

Advanced / from source: unzip `PadLinkReceiver.zip`, install Python 3.12+, run `pip install -r requirements.txt` and `python padlink_receiver.py`
(`--no-tray` for console only). `install_startup.ps1` makes a scheduled task that also restarts it after a crash; the tray toggle detects and can remove that task.

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

### Tray icon (PC)
The receiver lives in the notification area. The badge on the icon shows the state: green = phone connected,
amber = waiting for the phone, gray = disabled, red = error. Right-click for status, **Disable** / **Enable**
(Disable removes the virtual controller and stops answering the phone), **Run at login**, **Open log** and **Quit**.
Pass `--no-tray` to run without it.

## Connection options
| Option | Setup | Typical round trip |
|---|---|---|
| Wi-Fi (5/6 GHz, near the router) | Same network as the PC | about 5-10 ms |
| USB-C hub with Ethernet | Hub carries controller, Ethernet and power | about 2-4 ms |
| USB cable + Personal Hotspot | Plug the iPhone into the PC | about 2-4 ms |

Numbers are rough; use the latency test on your own setup. If it is hit-or-miss, turn off client/AP isolation
on the router and keep the phone out of Low Power Mode.

## Troubleshooting
- **Nothing happens when I run the receiver:** another copy may already own the port. Look for its tray icon and use Quit, or
  `Stop-Process -Name python, pythonw -Force` if you don't use Python for anything else. The receiver prints what it is doing.
- **"Driver missing" / startup error mentioning ViGEm:** the exe installs the driver on first run; if you declined the prompt, right-click the tray icon and choose **Enable** to retry, then restart Windows. Manual installer: [ViGEmBus releases](https://github.com/nefarius/ViGEmBus/releases).
- **No controller in `joy.cpl`:** the receiver creates it at start; look for the chime and the console message.
- **Latency test shows "No reply":** wrong IP, receiver not running, or the firewall is blocking UDP 26760.
- **Errors are also written to `padlink.log`** next to the exe (tray menu > **Open log**).

## Limits
- One virtual Xbox 360 pad. Several physical controllers are merged into it, not split into players.
- Gyro, touchpad, adaptive triggers and rumble are not forwarded.
- iOS can end a backgrounded app under memory pressure.

## Design
The app icon (a controller sending a signal) and its source files are in [`design/`](design/):
`icon.svg` is the master artwork, `icon-1024.png` is the App Store size used by the iOS project, and
`icon-256.png` is the preview shown above. Colors: navy `#0D1321`, off-white `#F2F4F8`, mint `#35E0C2`.
The in-app logo (`iOS/PadLink/LogoMark.swift`) is the same artwork drawn as a vector.

## Build from source
Releases are built by GitHub Actions (`.github/workflows/release.yml`, manual "Run workflow"). The PC exe is `Windows/padlink_receiver.py` packed with PyInstaller on a Windows runner (the `vgamepad` driver installer is bundled and run on first launch). The iOS app
is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `iOS/project.yml` on a macOS runner and
packaged as an unsigned IPA for sideloading. The receiver is `Windows/padlink_receiver.py`.
The wire format is in [PROTOCOL.md](PROTOCOL.md).

Not tested on every controller or network; reports and fixes are welcome.
