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
- Built-in latency test (round trip to the PC) with a live graph, plus a 10-second **benchmark** that rates the controller you are using and saves the result per controller, so you can compare controllers.
- The receiver releases all inputs if the phone goes quiet, so nothing gets stuck.
- Optional pairing code so only your phone can send input.
- Stick and trigger dead zones.
- PC tray icon with live status, Disable / Enable, Run at login, self-update, Open log and Quit.

## Install

Download both files from the [latest release](https://github.com/ajhockey88/PadLink/releases/latest).

### PC (Windows 11)
1. Download `PadLinkReceiver.exe` and double-click it. That is the only step; it sets itself up.
2. **On first run it does this for you** (one Windows approval prompt, because it changes system settings):
   - installs the virtual-controller driver (ViGEmBus), which is bundled inside the exe;
   - adds a Windows Firewall rule named **PadLink** that allows UDP 26760 (controller data) and 5353 (finding the PC), from devices on your own network only, on any network type (Private, Public, Domain);
   - then asks two yes/no questions: start PadLink when you sign in to Windows (recommended), and require a pairing code so only your phone can send input (recommended).
3. A PadLink icon appears in the system tray (click `^` if hidden) and you hear a controller chime. If the driver was just installed and it still reports an error, restart Windows once.
4. If you said no to starting at login, you can turn it on any time: right-click the tray icon and tick **Run at login**. This copies the exe to `%LOCALAPPDATA%\PadLink` so you can delete the download.

**Port forwarding is not needed, and you should not set it up.** The phone and PC talk over your own network (Wi-Fi, Ethernet or a USB tether), so nothing has to be opened on your router. Forwarding the port would expose your controller input to the internet. PadLink deliberately does not do this (no UPnP, no router changes).

Windows SmartScreen may warn because the exe is not code-signed: choose **More info** then **Run anyway**.

**Updates:** PadLink checks GitHub for a new release about once a day (tray menu > **Check automatically** to turn that off) and pops up a notice. Right-click the tray icon > **Install update vX** to download it, verify its checksum, and restart on the new version; no manual download. **Check for updates** checks right now. The iPhone app is not covered; reinstall its `.ipa` with Sideloadly. (Versions before 0.4.1 have no updater: replace them by hand once.)

Advanced / from source: unzip `PadLinkReceiver.zip`, install Python 3.12+ and run `python padlink_receiver.py` (`--no-tray` for console only). On first run it installs any missing Python packages itself (`pip install -r requirements.txt`) and does the same driver and firewall setup as the exe. `install_startup.ps1` makes a scheduled task that also restarts it after a crash; the tray toggle detects and can remove that task.

Give the PC a fixed IP (a DHCP reservation in your router) so the address in the app does not change.

### iPhone (no Mac needed)
On first launch the app shows a short welcome card with the steps below; it goes away when you tap **Got it** or once the app connects to a PC. iOS itself asks for Local Network access the first time; tap Allow (apps cannot do that for you).

1. Install [Sideloadly](https://sideloadly.io/) on the PC, plus iTunes and iCloud from Apple's site (not the Microsoft Store versions).
2. Plug in the iPhone, tap Trust, drag `PadLink.ipa` into Sideloadly, enter your Apple ID and click Start.
3. On the iPhone: Settings > General > VPN & Device Management > trust your Apple ID. Enable Developer Mode if asked.
4. A free Apple ID's app expires after 7 days; run Sideloadly again to renew. A paid developer account lasts a year.

## Use
1. Connect the iPhone and PC to the same network (see "Connection options").
2. Plug the controller into the iPhone's USB-C port.
3. Open PadLink, enter the PC's IP address (`ipconfig` on the PC) once, and tap Start. It starts by itself next time.
4. Check `joy.cpl` on Windows or any game. Close the app any time; the receiver keeps running.

To measure latency, tap **Test latency** while running for a live graph of the network round trip. To rate a controller, tap **Run benchmark** and move its stick in circles (or mash buttons) for 10 seconds. The app measures two things at once: how often the controller reports input (its report rate, giving the average wait before a press is sent) and the network round trip to the PC (200 pings). **Input latency** = half the average gap between the controller's reports + half the network round trip, and it is saved under the controller's name. Run it with each controller (and each connection, wired or Bluetooth, shows up as a separate run of the same name, so compare over time); the **Saved controllers** card lists them fastest first with the report rate, best result and number of runs. The estimate does not include the PC, the game or your display. The receiver must be version 0.4.x or newer.

### Tray icon (PC)
The receiver lives in the notification area. The badge on the icon shows the state: green = phone connected,
amber = waiting for the phone, gray = disabled, red = error. Right-click for status, **Disable** / **Enable**
(Disable removes the virtual controller and stops answering the phone), **Pairing**, **Run at login**, **Install update** / **Check for updates**, **Open log** and **Quit**.
Pass `--no-tray` to run without it.

### Pairing (recommended)
Without it, anyone on your network could send controller input to the PC. To turn it on: right-click the PC tray icon >
**Pairing** > **Require pairing code**. A message shows a 12-character code like `K7QD-4FHX-93MP`. Type it into the **Pairing code**
box in the iPhone app (PC section) once; it is remembered. From then on the PC ignores any packet that is not signed with
that code, and the app tells you if the code is missing or wrong. **New pairing code...** replaces it (re-enter it on the phone).
Pairing is off by default so existing setups keep working. It stops other devices from injecting input; it does not encrypt the
traffic or protect against someone who can capture your network traffic and replay it, so keep the PC on a network you trust.

### Tuning (iPhone)
The **Tuning** card has dead zone sliders for the sticks and triggers (0-30%). A dead zone ignores small movement near the
center (stick drift) and rescales the rest so full travel still reaches 100%.

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
- **Latency test shows "No reply":** wrong IP, receiver not running, or the firewall rule was not added (you declined the prompt). Quit PadLink from the tray and run it again to retry, or run once as administrator: `netsh advfirewall firewall add rule name=PadLink dir=in action=allow protocol=UDP localport=26760,5353 remoteip=LocalSubnet profile=any`.
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

## License
PadLink is released under the [MIT License](LICENSE). The Windows exe bundles third-party components under their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
