"""PadLink receiver: turns UDP controller packets into a virtual Xbox 360 pad.

Requires ViGEmBus (https://github.com/nefarius/ViGEmBus) and `pip install vgamepad`.
"""
import socket
import struct
import time

import vgamepad as vg

PORT = 26760
MAGIC = 0x504C
PING_MAGIC = 0x5049
PACKET = struct.Struct("<HHHBBhhhh")
PING_SIZE = 12  # echoed back untouched so the app can measure round-trip time
IDLE_AFTER = 1.0  # seconds without controller input before everything is released


def newer(seq, last):
    return last is None or 0 < ((seq - last) & 0xFFFF) < 0x8000


def main():
    pad = vg.VX360Gamepad()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", PORT))
    sock.settimeout(0.25)
    print(f"PadLink listening on UDP {PORT}")
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
            sock.sendto(data, addr)
        elif data and len(data) == PACKET.size:
            magic, seq, buttons, lt, rt, lx, ly, rx, ry = PACKET.unpack(data)
            if magic == MAGIC and newer(seq, last):
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
            idle = True
            last = None


if __name__ == "__main__":
    main()
