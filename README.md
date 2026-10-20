<p align="center">
  <img src="design/icon-256.png" width="128" height="128" alt="PadLink app icon: a game controller sending a signal">
</p>

<h1 align="center">PadLink</h1>

<p align="center">Use a wired controller on your iPhone as a controller on your Windows PC.</p>

PadLink reads a controller plugged into your iPhone's USB-C port and sends its state to your PC over your own network,
with no Bluetooth in the path. A small program on the PC presents it to Windows and games as a virtual Xbox 360 controller.

```
controller --USB-C--> iPhone (PadLink app) --UDP--> PadLink on the PC --ViGEmBus--> Xbox 360 pad
```

This is not a real USB connection: iOS cannot act as a USB device, so the PC sees a virtual pad.

## Features

**Controller**
- Works with any controller iOS supports (Xbox, DualSense, MFi, ...). Several can be plugged in at once; their inputs are merged into one pad.
- Rumble: vibration from games is sent back to the controller (on controllers whose haptics iOS exposes).
- Swap A/B and X/Y (Nintendo-style layouts), and stick and trigger dead zones.
- Reconnects on its own after a dropped network, a replugged controller or a restarted PC program, and releases every input if the phone goes quiet so nothing gets stuck.

**Connection**
- The app finds your PC automatically (Bonjour); typing an IP address is only a fallback.
- Live status in the app (Searching, Connecting, Connected, Reconnecting, Pairing code needed) and a tray icon on the PC with the same states.
- Optional pairing code so only your phone can send input.
- Keeps running when you switch apps or lock the phone, and starts sending as soon as the app opens.

**Measuring**
- **Test latency:** live graph of the network round trip to the PC.
- **Run benchmark:** a 10-second test that rates the controller you are using and saves the result under its name, so you can compare controllers.

**Setup**
- The Windows program is one `.exe`. On first run it installs the controller driver and adds its firewall rule itself, behind a single Windows approval prompt.
- Tray menu on the PC: Disable / Enable, Run at login, Pairing, Check for updates (checksum-verified self-update), Open log, Quit.
- First-launch welcome card in the iPhone app.

## Screenshots

> These are design renders of the interface (the mockups it was built from), with sample numbers, not photos of a running device. Real screenshots can replace them: save yours over the files in [`docs/images/`](docs/images/) with the same names.

**iPhone app**

<table>
  <tr>
    <td align="center" valign="top"><img src="docs/images/app-welcome.png" width="230" alt="First-launch welcome card with three setup steps"><br><sub>First launch</sub></td>
    <td align="center" valign="top"><img src="docs/images/app-connected.png" width="230" alt="Connected: PC list, controller, swap buttons and tuning sliders"><br><sub>Connected, with the tuning sliders</sub></td>
    <td align="center" valign="top"><img src="docs/images/app-pairing.png" width="230" alt="Pairing code needed: the code typed in does not match the PC"><br><sub>Pairing code needed</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><img src="docs/images/app-benchmark.png" width="230" alt="Benchmark result for a DualSense controller and the saved controllers list"><br><sub>Benchmark result and saved controllers</sub></td>
    <td align="center" valign="top"><img src="docs/images/app-latency.png" width="230" alt="Live latency test graph"><br><sub>Live latency test</sub></td>
    <td></td>
  </tr>
</table>

**PC tray menu** (status, Disable / Enable, Run at login, Pairing, updates, log, Quit)

<img src="docs/images/tray-menu.png" width="860" alt="The PadLink tray menu when connected with an update available, with the Pairing submenu open, and when disabled">

**PC dialogs, notifications and console**

<img src="docs/images/windows-dialogs.png" width="860" alt="The pairing code dialog, the already-running message, update notifications and console output">

## Requirements
- An iPhone with a USB-C port (iPhone 15 or newer) on iOS 16 or later, and a wired controller that works with it.
- A Windows 11 PC. Windows 10 should work but is untested.
- The phone and PC on the same network: Wi-Fi, Ethernet, or a USB tether (see [Connection options](#connection-options)).
- No Mac is needed: the iPhone app is built in the cloud and installed from Windows with Sideloadly.

## Install

Everything is on the [latest release](https://github.com/ajhockey88/PadLink/releases/latest):
`PadLinkReceiver.exe` (the Windows program), `PadLink.ipa` (the iPhone app), and `PadLinkReceiver.zip` (the same Windows program as a Python script, for advanced use).

### PC (Windows 11)
1. Download `PadLinkReceiver.exe` and double-click it. That is the only step; it sets itself up.
2. **On first run it does this for you** (one Windows approval prompt, because it changes system settings):
   - installs the virtual-controller driver (ViGEmBus), which is bundled inside the exe;
   - adds a Windows Firewall rule named **PadLink** that allows UDP 26760 (controller data) and 5353 (finding the PC), from devices on your own network only, on any network type (Private, Public, Domain);
   - then asks two yes/no questions: start PadLink when you sign in to Windows (recommended), and require a pairing code so only your phone can send input (recommended).
3. A PadLink icon appears in the system tray (click `^` if hidden) and you hear a controller chime. If the driver was just installed and it still reports an error, restart Windows once.
4. If you said no to starting at login, turn it on any time: right-click the tray icon and tick **Run at login**. This copies the exe to `%LOCALAPPDATA%\PadLink` so you can delete the download.

**Port forwarding is not needed, and you should not set it up.** The phone and PC talk over your own network, so nothing has to be opened on your router. Forwarding the port would expose your controller input to the internet. PadLink deliberately does not do this (no UPnP, no router changes).

Windows SmartScreen may warn because the exe is not code-signed: choose **More info** then **Run anyway**. Some antivirus programs flag unsigned PyInstaller programs; the source is in this repository.

Give the PC a fixed IP (a DHCP reservation in your router) if you ever need the manual IP fallback.

**Updates:** PadLink checks GitHub for a new release about once a day (tray > **Check automatically** to turn that off) and shows a notice. Tray > **Install update vX** downloads it, verifies its SHA-256 checksum, and restarts on the new version; **Check for updates** checks right now. Versions before 0.4.1 have no updater: replace them by hand once. The iPhone app is not covered by this; reinstall its `.ipa` with Sideloadly.

**From source (advanced):** unzip `PadLinkReceiver.zip`, install Python 3.12+ and run `python padlink_receiver.py` (`--no-tray` for console only). On first run it installs any missing Python packages itself and does the same driver and firewall setup as the exe. See [`Windows/README.md`](Windows/README.md).

### iPhone (no Mac needed)
1. Install [Sideloadly](https://sideloadly.io/) on the PC, plus iTunes and iCloud from Apple's site (not the Microsoft Store versions).
2. Plug in the iPhone, tap Trust, drag `PadLink.ipa` into Sideloadly, enter your Apple ID and click Start.
3. On the iPhone: Settings > General > VPN & Device Management > trust your Apple ID. Enable Developer Mode if asked.
4. A free Apple ID's app expires after 7 days; run Sideloadly again to renew. A paid developer account lasts a year.
5. Open PadLink. A welcome card lists the steps; it goes away when you tap **Got it** or once the app connects to a PC. iOS asks for **Local Network** access the first time; tap Allow (apps cannot do that for you).

## Use
1. Connect the iPhone and PC to the same network (see [Connection options](#connection-options)) and start PadLink on the PC.
2. Plug the controller into the iPhone's USB-C port.
3. Open PadLink. It finds your PC by itself and connects; if more than one PC answers, tap the one you want (it remembers). If the PC asked for a pairing code, type it in the **PC** card once.
4. Check `joy.cpl` on Windows, or any game. Close the app whenever you like; the PC program keeps running, and the app reconnects the next time you open it.

The status line at the top of the app shows where things stand:

| Status | Meaning |
|---|---|
| Searching for PC | No PadLink program found yet. If you typed an IP address, the app falls back to it after a few seconds. |
| Connecting | Found a PC, waiting for it to answer. |
| Connected | The PC is answering. |
| Reconnecting | The PC stopped answering (network change, PC restarted); the app is rebuilding the connection. |
| Pairing code needed | The PC requires a pairing code and yours is missing or wrong. |

**Find PC automatically** can be turned off to type an IP address instead (`ipconfig` on the PC).

### Latency test and benchmark
- **Test latency** shows a live graph of the network round trip (phone to PC and back), with average, minimum, maximum, jitter and lost pings. It does not run unless you press it.
- **Run benchmark** rates a controller. While it runs (10 seconds), move the controller's stick in circles or mash buttons. The app measures two things at once: how often the controller reports input, and the network round trip (200 pings). **Input latency** = half the average gap between the controller's reports (a press waits that long, on average, for the next report) + half the network round trip. The result also shows median, 95th percentile, jitter, min, max and lost pings, and a rating (Excellent under 10 ms, Good under 20, Fair under 40).
- Results are saved under the controller's name (up to 10 runs each), compared with its previous run, and listed fastest-first in **Saved controllers**, so you can try several controllers and see their values side by side.
- It is an estimate: it covers the controller and the network, not the PC, the game or your display. Two controllers of the same model share one entry, and so do wired and Bluetooth use of one controller, because iOS does not say which connection it is.

### Tuning (iPhone)
- **Swap A and B** / **Swap X and Y** flip those face buttons.
- **Stick dead zone** and **Trigger dead zone** (0-30%) ignore small movement near the center (stick drift) and rescale the rest, so full travel still reaches 100%.

## The PC program
It lives in the notification area. The badge on its icon shows the state: green = phone connected, amber = waiting for the phone (or busy setting up or updating), gray = disabled, red = error. Hover for the exact status. Right-click for:

- **Disable / Enable:** Disable removes the virtual controller from Windows and stops answering the phone; Enable brings it back.
- **Run at login** (a checkbox): starts it hidden every time you sign in. No administrator rights needed.
- **Pairing:** Require pairing code, Show pairing code, New pairing code (see below).
- **Install update / Check for updates / Check automatically.**
- **Open log:** opens `padlink.log`.
- **Quit.**

Its files sit next to the exe: `settings.json` (pairing code and whether it is required, automatic update check, first-run flag) and `padlink.log` (errors and update messages).

### Pairing (recommended)
Without it, anyone on your network could send controller input to the PC. Turn it on at the first-run question, or any time with tray > **Pairing** > **Require pairing code**. A message shows a 12-character code like `K7QD-4FHX-93MP`. Type it into the **Pairing code** box in the iPhone app (PC card) once; it is remembered. From then on the PC ignores any packet that is not signed with that code, and the app tells you if the code is missing or wrong. **New pairing code...** replaces it (re-enter it on the phone).

Pairing proves a packet came from your phone; it does not encrypt the traffic or stop someone who can capture your network traffic from replaying it. Keep the PC on a network you trust.

## Connection options
| Option | Setup | Typical round trip |
|---|---|---|
| Wi-Fi (5/6 GHz, near the router) | Same network as the PC | about 5-10 ms |
| USB-C hub with Ethernet | Hub carries controller, Ethernet and power | about 2-4 ms |
| USB cable + Personal Hotspot | Plug the iPhone into the PC | about 2-4 ms |

These numbers are rough; use the latency test on your own setup. If Wi-Fi is hit-or-miss, turn off client/AP isolation on the router and keep the phone out of Low Power Mode.

## Troubleshooting
- **The app says "Searching for PC":** make sure the PadLink icon is in the PC's tray, both devices are on the same network, and you allowed Local Network access for the app (iPhone Settings > PadLink). Finding the PC uses UDP 5353, which the first-run firewall rule opens. As a fallback, turn off **Find PC automatically** and type the PC's IP address.
- **"Pairing code needed":** the PC requires a code. On the PC: tray > Pairing > Show pairing code, then type it into the app's PC card.
- **Latency test shows "No reply":** wrong address, PadLink not running, wrong pairing code, or the firewall rule was not added (you declined the prompt). Quit PadLink from the tray and run it again to retry, or run once as administrator: `netsh advfirewall firewall add rule name=PadLink dir=in action=allow protocol=UDP localport=26760,5353 remoteip=LocalSubnet profile=any`.
- **A second copy of PadLink opens a message saying it is already running:** use the tray icon of the first copy to Quit it, then start the new one (or use the tray's update).
- **"Driver missing" or a startup error mentioning ViGEm:** the exe installs the driver on first run; if you declined the prompt, right-click the tray icon, choose **Enable** to retry, then restart Windows. Manual installer: [ViGEmBus releases](https://github.com/nefarius/ViGEmBus/releases).
- **No controller in `joy.cpl`:** the controller is created when PadLink starts or is re-enabled; look for the chime.
- **No vibration:** it needs a controller whose haptics iOS supports (for example DualSense or Xbox), and a game that sends rumble.
- **Anything else:** tray > **Open log**.

## Limits
- One virtual Xbox 360 pad. Several physical controllers are merged into it, not split into players.
- Gyro, touchpad and adaptive triggers are not forwarded.
- iOS can end a backgrounded app under memory pressure, and the app keeps itself alive with a silent audio session, which costs a little battery.
- Pairing authenticates but does not encrypt (see above).
- The exe is not code-signed, and the iPhone app must be re-signed every 7 days with a free Apple ID.
- Built and checked with automated tests and cloud builds; not tested on every controller, network or Windows version. Reports and fixes are welcome.

## Privacy and security
- No accounts, no analytics. Controller data goes only from your phone to your PC over your network.
- The PC program contacts GitHub (`api.github.com`) to check for releases and downloads updates from this repository's releases, verifying a SHA-256 checksum. Turn the check off in the tray menu.
- The firewall rule only allows devices on your own subnet, and PadLink never touches your router.
- The pairing code lives in plain text in `settings.json` next to the exe.

## Project layout and building
| Path | What it is |
|---|---|
| `iOS/` | The iPhone app (SwiftUI) and `project.yml` for XcodeGen |
| `Windows/padlink_receiver.py` | The PC program (also packed into the exe), `requirements.txt`, `install_startup.ps1`, `stamp_version.py` |
| `tests/` | Automated tests for the PC program (packet format, pairing, updater, first-run setup) |
| `design/` | App icon artwork |
| `docs/` | The interface mockups (`docs/mockups/`) and the images rendered from them for this README (`docs/images/`); regenerate with `python docs/render_mockups.py` (needs Node.js, Pillow and Chromium) |
| `PROTOCOL.md` | The wire format |
| `.github/workflows/release.yml` | Builds and publishes releases |

Run the tests with `python -m unittest discover -s tests -v` (no Windows or driver needed).

Releases are built by GitHub Actions ("Build and release", started manually from the Actions tab). The `RELEASE_TAG` value at the top of `release.yml` is the version published. The workflow runs the tests first, then builds in parallel: the iPhone app on a macOS runner (generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen), packaged as an unsigned IPA for sideloading) and the PC exe on a Windows runner (PyInstaller; it fetches the `vgamepad` source directly and verifies its checksum, because installing that package normally launches a driver installer). Then it creates the GitHub release with the `.ipa`, `.exe` and `.zip`, and stamps the version into the exe so its updater knows what it is running.

## Design
The app icon (a controller sending a signal) and its source files are in [`design/`](design/): `icon.svg` is the master artwork, `icon-1024.png` is the size used by the iOS project, and `icon-256.png` is the preview shown above. Colors: navy `#0D1321`, off-white `#F2F4F8`, mint `#35E0C2`. The in-app logo (`iOS/PadLink/LogoMark.swift`) is the same artwork drawn as a vector.

## License
PadLink is released under the [MIT License](LICENSE). The Windows exe bundles third-party components under their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
