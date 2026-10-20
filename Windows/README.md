# PadLink receiver (Windows 11)

1. Install ViGEmBus: https://github.com/nefarius/ViGEmBus/releases
2. `pip install -r requirements.txt` (installs `vgamepad`)
3. `python padlink_receiver.py`
4. Allow Python through Windows Firewall (private networks) for UDP 26760.

Link options: USB cable + iPhone Personal Hotspot (PC gets an adapter, usually
the iPhone is at 172.20.10.1 and the PC at 172.20.10.x), a USB-C Ethernet
adapter, or Wi-Fi. Enter the PC's IP in the app.

## Run at startup (no terminal needed)
Run once in the receiver folder: `powershell -ExecutionPolicy Bypass -File install_startup.ps1`.
It starts hidden at login and restarts if it crashes. Stop it with
`Stop-ScheduledTask PadLinkReceiver`; remove it with `Unregister-ScheduledTask PadLinkReceiver`.

## Tray icon
The receiver shows a PadLink icon in the Windows notification area (click `^` if it is hidden).
The badge shows the state: green = phone connected, amber = waiting for the phone, gray = disabled, red = error.
Right-click for the menu: status line, **Disable** / **Enable** (Disable removes the virtual controller and stops
answering the phone; Enable brings it back), **Open log**, and **Quit**. Run with `--no-tray` for a console-only receiver.
