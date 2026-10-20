"""PadLink receiver: turns UDP controller packets into a virtual Xbox 360 pad.

Requires ViGEmBus (https://github.com/nefarius/ViGEmBus) and `pip install -r requirements.txt`.
"""
import os
import socket
import struct
import sys
import threading
import time
import traceback

import vgamepad as vg

PORT = 26760
MAGIC = 0x504C
PING_MAGIC = 0x5049
RUMBLE_MAGIC = 0x5052
SERVICE_TYPE = "_padlink._udp.local."
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
_state = {"sock": None, "phone": None, "large": 0, "small": 0}
_started = {"rumble": False, "advertise": False}


def send_rumble():
    """Tell the phone how hard the game wants the controller to vibrate (4 bytes)."""
    sock, phone = _state["sock"], _state["phone"]
    if sock is None or phone is None:
        return
    try:
        sock.sendto(struct.pack("<HBB", RUMBLE_MAGIC, _state["large"], _state["small"]), phone)
    except OSError:
        pass


def on_rumble(client, target, large_motor, small_motor, led_number, user_data):
    _state["large"], _state["small"] = int(large_motor), int(small_motor)
    send_rumble()


def rumble_keepalive():
    # Resend while vibrating so the phone can tell "still on" from "packet lost".
    while True:
        time.sleep(0.1)
        if _state["large"] or _state["small"]:
            send_rumble()


def get_pad():
    """Create the virtual pad once. Windows plays the device-connect chime on every creation."""
    global _pad
    if _pad is None:
        _pad = vg.VX360Gamepad()
        try:
            _pad.register_notification(callback_function=on_rumble)
        except Exception:
            log("Rumble relay unavailable: " + traceback.format_exc())
    if not _started["rumble"]:
        _started["rumble"] = True
        threading.Thread(target=rumble_keepalive, daemon=True).start()
    return _pad


def advertise():
    """Announce this receiver on the local network (Bonjour/mDNS) so the app can find it."""
    if _started["advertise"]:
        return
    _started["advertise"] = True
    try:
        import ifaddr
        from zeroconf import IPVersion, ServiceInfo, Zeroconf
    except ImportError:
        print("Auto-discovery is off (run: pip install -r requirements.txt). Enter the IP in the app instead.")
        return

    def addresses():
        out = []
        for adapter in ifaddr.get_adapters():
            for ip in adapter.ips:
                if ip.is_IPv4 and not ip.ip.startswith(("127.", "169.254.")):
                    out.append(socket.inet_aton(ip.ip))
        return sorted(out)

    host = socket.gethostname().split(".")[0]

    def make(addrs):
        return ServiceInfo(SERVICE_TYPE, f"{host}.{SERVICE_TYPE}", addresses=addrs,
                           port=PORT, server=f"{host}.local.")

    try:
        zc = Zeroconf(ip_version=IPVersion.V4Only)
        addrs = addresses()
        zc.register_service(make(addrs))
    except Exception:
        log("Auto-discovery failed: " + traceback.format_exc())
        print("Auto-discovery could not start; enter the IP in the app instead.")
        return
    print(f"Auto-discovery on: the app will find this PC as '{host}'.")

    def watch():
        # Re-announce if the PC's addresses change (cable plugged in, DHCP renewal...).
        nonlocal addrs
        while True:
            time.sleep(15)
            try:
                now = addresses()
                if now != addrs:
                    addrs = now
                    zc.update_service(make(now))
            except Exception:
                pass

    threading.Thread(target=watch, daemon=True).start()


def main():
    print("PadLink receiver starting...")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if sys.platform == "win32":
        # Windows raises ConnectionResetError on recv after a send hit a closed port
        # (the phone app was closed). Turn that off so the receiver keeps running.
        # (socket.ioctl() does not support this code, so call WSAIoctl directly.)
        try:
            import ctypes
            SIO_UDP_CONNRESET = 0x9800000C
            ctypes.windll.Ws2_32.WSAIoctl(
                sock.fileno(), SIO_UDP_CONNRESET,
                ctypes.byref(ctypes.c_ulong(0)), 4, None, 0,
                ctypes.byref(ctypes.c_ulong(0)), None, None)
        except Exception:
            pass  # only a nicety; recv errors are handled below anyway
    try:
        sock.bind(("0.0.0.0", PORT))
    except OSError:
        # Another copy already owns the port; exit before creating a second pad (no chime).
        log("Already running, exiting.")
        print(f"PadLink is already running in the background (UDP {PORT} is in use).")
        print("To restart it: Stop-ScheduledTask PadLinkReceiver, then run this again.")
        raise SystemExit(0)
    _state["sock"] = sock
    pad = get_pad()
    advertise()
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
            _state["phone"] = addr
            try:
                sock.sendto(data, addr)
            except OSError:
                pass
        elif data and len(data) == PACKET.size:
            magic, seq, buttons, lt, rt, lx, ly, rx, ry = PACKET.unpack(data)
            if magic == MAGIC:
                _state["phone"] = addr
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
            _state["large"] = _state["small"] = 0
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
            err = traceback.format_exc()
            log(err)
            print(err)
            print("PadLink hit an error (see above). Is the ViGEmBus driver installed? Retrying in 3s...")
            time.sleep(3)
