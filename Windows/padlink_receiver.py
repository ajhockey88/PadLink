"""PadLink receiver: turns UDP controller packets into a virtual Xbox 360 pad.

Requires ViGEmBus (https://github.com/nefarius/ViGEmBus) and `pip install vgamepad`.
"""
import os
import socket
import struct
import sys
import time
import traceback

import vgamepad as vg

PORT = 26760
MAGIC = 0x504C
PING_MAGIC = 0x5049
PACKET = struct.Struct("<HHHBBhhhh")
PING_SIZE = 12  # echoed back untouched so the app can measure round-trip time
IDLE_AFTER = 1.0  # seconds without controller input before everything is released


def newer(seq, last):
    return last is None or 0 < ((seq - last) & 0xFFFF) < 0x8000


def log(msg):
    """Append to padlink.log next to the script (there is no console when run hidden)."""
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "padlink.log"), "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


_pad = None


def get_pad():
    """Create the virtual pad once. Windows plays the device-connect chime on every creation."""
    global _pad
    if _pad is None:
        _pad = vg.VX360Gamepad()
    return _pad


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if sys.platform == "win32":
        # Windows raises ConnectionResetError on recv after a send hit a closed port
        # (the phone app was closed). Turn that off so the receiver keeps running.
        SIO_UDP_CONNRESET = 0x9800000C
        sock.ioctl(SIO_UDP_CONNRESET, False)
    try:
        sock.bind(("0.0.0.0", PORT))
    except OSError:
        # Another copy already owns the port; exit before creating a second pad (no chime).
        log("Already running, exiting.")
        print(f"PadLink is already running in the background (UDP {PORT} is in use).")
        print("To restart it: Stop-ScheduledTask PadLinkReceiver, then run this again.")
        raise SystemExit(0)
    pad = get_pad()
    sock.settimeout(0.25)
    print(f"PadLink listening on UDP {PORT} (virtual Xbox 360 pad created)")
    print("Waiting for the phone...")
    last = None
    last_input = time.monotonic()
    idle = False
    while True:
        try:
            data, addr = sock.recvfrom(64)
        except socket.timeout:
            data = None
        except OSError:
            data = None

        if data and len(data) == PING_SIZE and struct.unpack_from("<H", data)[0] == PING_MAGIC:
            try:
                sock.sendto(data, addr)
            except OSError:
                pass
        elif data and len(data) == PACKET.size:
            magic, seq, buttons, lt, rt, lx, ly, rx, ry = PACKET.unpack(data)
            if magic == MAGIC and newer(seq, last):
                if idle or last is None:
                    print(f"Phone connected: {addr[0]}")
                last = seq
                last_input = time.monotonic()
                idle = False
                pad.report.wButtons = buttons
                pad.report.bLeftTrigger = lt
                pad.report.bRightTrigger = rt
                pad.report.sThumbLX = lx
                pad.report.sThumbLY = ly
                pad.report.sThumbRX = rx
                pad.report.sThumbRY = ry
                pad.update()

        # Phone went quiet (app closed, controller unplugged): release everything.
        if not idle and time.monotonic() - last_input > IDLE_AFTER:
            pad.reset()
            pad.update()
            if last is not None:
                print("Phone went quiet; controller released.")
            idle = True
            last = None


if __name__ == "__main__":
    # Never exit: if anything unexpected happens, log it and start over.
    while True:
        try:
            main()
        except Exception:
            log(traceback.format_exc())
            time.sleep(1)
