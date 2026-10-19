# PadLink receiver (Windows 11)

1. Install ViGEmBus: https://github.com/nefarius/ViGEmBus/releases
2. `pip install vgamepad`
3. `python padlink_receiver.py`
4. Allow Python through Windows Firewall (private networks) for UDP 26760.

Link options: USB cable + iPhone Personal Hotspot (PC gets an adapter, usually
the iPhone is at 172.20.10.1 and the PC at 172.20.10.x), a USB-C Ethernet
adapter, or Wi-Fi. Enter the PC's IP in the app.
