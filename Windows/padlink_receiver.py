"""PadLink receiver: turns UDP controller packets into a virtual Xbox 360 pad.

Requires ViGEmBus (https://github.com/nefarius/ViGEmBus) and `pip install vgamepad`.
"""
import socket
import struct

import vgamepad as vg

PORT = 26760
MAGIC = 0x504C
PACKET = struct.Struct("<HHHBBhhhh")


def newer(seq, last):
    return last is None or 0 < ((seq - last) & 0xFFFF) < 0x8000


def main():
    pad = vg.VX360Gamepad()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", PORT))
    print(f"PadLink listening on UDP {PORT}")
    last = None
    while True:
        data, _ = sock.recvfrom(64)
        if len(data) != PACKET.size:
            continue
        magic, seq, buttons, lt, rt, lx, ly, rx, ry = PACKET.unpack(data)
        if magic != MAGIC or not newer(seq, last):
            continue
        last = seq
        pad.report.wButtons = buttons
        pad.report.bLeftTrigger = lt
        pad.report.bRightTrigger = rt
        pad.report.sThumbLX = lx
        pad.report.sThumbLY = ly
        pad.report.sThumbRX = rx
        pad.report.sThumbRY = ry
        pad.update()


if __name__ == "__main__":
    main()
