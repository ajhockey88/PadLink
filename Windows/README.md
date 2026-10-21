# PadLink for Windows

Most people should just download `PadLinkReceiver.exe` from the [latest release](https://github.com/ajhockey88/PadLink/releases/latest)
(see the main [README](../README.md)): it bundles everything and sets itself up on first run. This page is for running from source.

## Run from source
1. Install Python 3.12 or newer.
2. Run `python padlink_receiver.py` (add `--no-tray` for console only).

On first run it does the same setup as the exe, so there is nothing to do by hand:
- installs any missing Python packages (`pip install -r requirements.txt`);
- installs the ViGEmBus driver and adds the **PadLink** firewall rule (UDP 26760 and 5353, local network only) behind one Windows approval prompt;
- asks whether to start at login and whether to require a pairing code.

Do not forward any port on your router; the phone and PC talk over your own network.

## Files
| File | Purpose |
|---|---|
| `padlink_receiver.py` | The program: receives controller packets, makes the virtual Xbox 360 pad, advertises itself on the network, tray icon, updater, pairing |
| `requirements.txt` | `vgamepad`, `zeroconf`, `pystray`, `pillow` |
| `install_startup.ps1` | Optional: a scheduled task that starts it at login and restarts it after a crash. The tray's **Run at login** checkbox is simpler and needs no admin rights. |
| `stamp_version.py` | Build step: writes the release version into the program |

At run time it also creates `settings.json` (pairing code and whether it is required, automatic update check, first-run flag) and `padlink.log` next to the script.

## Tray icon
The receiver shows a PadLink icon in the Windows notification area (click `^` if it is hidden). The badge shows the state: green = phone connected, amber = waiting for the phone, gray = disabled, red = error. Right-click for the menu: status line, **Disable** / **Enable** (Disable removes the virtual controller and stops answering the phone), **Run at login**, **Performance mode** (on by default: high priority, no Windows efficiency mode, 1 ms timer), **Pairing** (require / show / replace the code), **Install update** / **Check for updates** / **Check automatically**, **Open log** and **Quit**.

When running from source the updater does not replace files; **Install update** opens the releases page.

## Run at startup without the tray
Easiest is the tray checkbox. Alternatively, run once in this folder: `powershell -ExecutionPolicy Bypass -File install_startup.ps1`. Stop it with `Stop-ScheduledTask PadLinkReceiver`; remove it with `Unregister-ScheduledTask PadLinkReceiver`.

## Network
Any link works: Wi-Fi, a USB-C Ethernet adapter, or a USB cable plus the iPhone's Personal Hotspot (the PC gets an extra adapter, usually in `172.20.10.x`). The app finds the PC by itself; if it cannot, turn off **Find PC automatically** in the app and enter the PC's IP address.
