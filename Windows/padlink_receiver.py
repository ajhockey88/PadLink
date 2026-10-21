"""PadLink receiver: turns UDP controller packets into a virtual Xbox 360 pad.

Runs with a system tray icon (status, Disable/Enable, Quit). Use `--no-tray` for console only.
Requires ViGEmBus (https://github.com/nefarius/ViGEmBus) and `pip install -r requirements.txt`.
"""
import gc
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import traceback

vg = None  # imported lazily: `import vgamepad` connects to the driver, so the driver must exist first

VERSION = "dev"  # replaced with the release version when the exe is built
REPO = "ajhockey88/PadLink"
RELEASES_URL = f"https://github.com/{REPO}/releases/latest"
CHECK_EVERY = 12 * 3600  # seconds between automatic update checks

PORT = 26760
MAGIC = 0x504C
PING_MAGIC = 0x5049
RUMBLE_MAGIC = 0x5052
PAIR_MAGIC = 0x5041  # "PA": receiver tells the phone a pairing code is needed
TAG_LEN = 8  # signed packets carry the first 8 bytes of HMAC-SHA256 after the payload
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # no 0/O, 1/I/L
SERVICE_TYPE = "_padlink._udp.local."
PACKET = struct.Struct("<HHHBBhhhh")
PING_SIZE = 12  # echoed back untouched so the app can measure round-trip time
IDLE_AFTER = 1.0  # seconds without controller input before everything is released

FROZEN = getattr(sys, "frozen", False)  # True when running as the packaged PadLinkReceiver.exe
APP_DIR = os.path.dirname(os.path.abspath(sys.executable if FROZEN else __file__))  # logs live here
RES_DIR = getattr(sys, "_MEIPASS", APP_DIR)  # bundled files (icon, driver installer)
NO_WINDOW = 0x08000000


class DriverError(Exception):
    pass


def message_box(text, title="PadLink"):
    """Show a popup when there is no console to print to (hidden exe / pythonw)."""
    if sys.stdout is None and sys.platform == "win32":
        try:
            import ctypes
            ctypes.windll.user32.MessageBoxW(None, text, title, 0x40)
        except Exception:
            pass


def newer(seq, last):
    return last is None or 0 < ((seq - last) & 0xFFFF) < 0x8000


def log(msg):
    """Append to padlink.log next to the script (there is no console when run hidden)."""
    try:
        with open(os.path.join(APP_DIR, "padlink.log"), "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


_pad = None
_state = {"sock": None, "phone": None, "large": 0, "small": 0,
          "enabled": True, "quit": False, "error": False, "note": "", "update": None, "notified": None, "key": b"", "require_pairing": False, "phone_signed": False, "last_seen": 0.0, "phone_ip": None, "ready": False,
          "performance": True, "perf_thread": None, "perf_timer": False}
_started = {"rumble": False, "watch": False}
_zeroconf = {"zc": None, "addrs": []}


def send_rumble():
    """Tell the phone how hard the game wants the controller to vibrate (4 bytes)."""
    sock, phone = _state["sock"], _state["phone"]
    if sock is None or phone is None:
        return
    try:
        payload = struct.pack("<HBB", RUMBLE_MAGIC, _state["large"], _state["small"])
        if _state["phone_signed"]:
            payload += tag_for(_state["key"], payload)
        sock.sendto(payload, phone)
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


def driver_installed():
    if sys.platform != "win32":
        return True
    try:
        return subprocess.run(["sc", "query", "ViGEmBus"], capture_output=True,
                              creationflags=NO_WINDOW).returncode == 0
    except Exception:
        return True  # can't tell: let vgamepad try and report its own error


def find_driver_installer():
    rel = os.path.join("win", "vigem", "install", "x64", "ViGEmBusSetup_x64.msi")
    candidates = [os.path.join(RES_DIR, "vgamepad", rel)]
    try:
        import importlib.util
        spec = importlib.util.find_spec("vgamepad")
        for loc in (spec.submodule_search_locations or []) if spec else []:
            candidates.append(os.path.join(loc, rel))
    except Exception:
        pass
    return next((c for c in candidates if os.path.exists(c)), None)


FIREWALL_RULE = "PadLink"


def firewall_rule_exists():
    if sys.platform != "win32":
        return True
    try:
        return subprocess.run(["netsh", "advfirewall", "firewall", "show", "rule", f"name={FIREWALL_RULE}"],
                              capture_output=True, creationflags=NO_WINDOW).returncode == 0
    except Exception:
        return True  # can't tell: don't nag


def setup_script(driver_msi, need_firewall):
    """PowerShell for the one elevated step. Only what is missing is included."""
    lines = ["$ErrorActionPreference = 'Continue'"]
    if driver_msi:
        msi = driver_msi.replace("'", "''")
        lines.append(f"Start-Process -FilePath msiexec.exe -ArgumentList '/i','\"{msi}\"','/qb','/norestart' -Wait")
    if need_firewall:
        # Same-network devices only (never the internet), on every network profile, no matter where the exe lives.
        lines.append(f"netsh advfirewall firewall add rule name={FIREWALL_RULE} dir=in action=allow protocol=UDP "
                     f"localport={PORT},5353 remoteip=LocalSubnet profile=any enable=yes | Out-Null")
    return "\n".join(lines)


def run_elevated(script):
    """Run PowerShell as administrator (shows the Windows approval prompt). False if declined."""
    import base64
    import ctypes
    encoded = base64.b64encode(script.encode("utf-16-le")).decode()
    args = f"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand {encoded}"
    return ctypes.windll.shell32.ShellExecuteW(None, "runas", "powershell.exe", args, None, 0) > 32


def ensure_driver():
    """First-run setup: the controller driver and the firewall rule, behind one Windows approval prompt."""
    need_driver = not driver_installed()
    need_firewall = not firewall_rule_exists()
    if not need_driver and not need_firewall:
        return
    msi = None
    if need_driver:
        msi = find_driver_installer()
        if not msi:
            raise DriverError("ViGEmBus driver missing: install it from github.com/nefarius/ViGEmBus/releases")
    _state["note"] = "setting up, approve the Windows prompt"
    log(f"First-run setup: driver={need_driver} firewall={need_firewall}")
    if not run_elevated(setup_script(msi, need_firewall)):
        _state["note"] = ""
        if need_driver:
            raise DriverError("setup was declined; use Enable to try again")
        log("Firewall rule not added (prompt declined); allow UDP 26760 and 5353 manually")
        return
    deadline = time.monotonic() + 180
    while True:
        if (not need_driver or driver_installed()) and (not need_firewall or firewall_rule_exists()):
            break
        if time.monotonic() > deadline:
            if need_driver and not driver_installed():
                raise DriverError("driver install did not finish; use Enable to try again")
            log("Firewall rule was not created; allow UDP 26760 and 5353 manually")
            break
        time.sleep(2)
    if need_driver:
        time.sleep(3)
    _state["note"] = ""
    log("First-run setup finished")


def get_pad():
    """Create the virtual pad once. Windows plays the device-connect chime on every creation."""
    global _pad, vg
    if vg is None:
        ensure_driver()
        import vgamepad as _vg
        vg = _vg
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


def destroy_pad():
    """Remove the virtual controller from Windows (used by Disable)."""
    global _pad
    pad, _pad = _pad, None
    if pad is not None:
        try:
            pad.unregister_notification()
        except Exception:
            pass
        del pad
        gc.collect()


def _addresses():
    import ifaddr
    out = []
    for adapter in ifaddr.get_adapters():
        for ip in adapter.ips:
            if ip.is_IPv4 and not ip.ip.startswith(("127.", "169.254.")):
                out.append(socket.inet_aton(ip.ip))
    return sorted(out)


def _service_info(addrs):
    from zeroconf import ServiceInfo
    host = socket.gethostname().split(".")[0]
    return ServiceInfo(SERVICE_TYPE, f"{host}.{SERVICE_TYPE}", addresses=addrs,
                       port=PORT, server=f"{host}.local.")


def advertise_start():
    """Announce this receiver on the local network (Bonjour/mDNS) so the app can find it."""
    if _zeroconf["zc"] is not None:
        return
    try:
        from zeroconf import IPVersion, Zeroconf
        zc = Zeroconf(ip_version=IPVersion.V4Only)
        addrs = _addresses()
        zc.register_service(_service_info(addrs))
    except ImportError:
        print("Auto-discovery is off (run: pip install -r requirements.txt). Enter the IP in the app instead.")
        return
    except Exception:
        log("Auto-discovery failed: " + traceback.format_exc())
        print("Auto-discovery could not start; enter the IP in the app instead.")
        return
    _zeroconf["zc"], _zeroconf["addrs"] = zc, addrs
    print(f"Auto-discovery on: the app will find this PC as '{socket.gethostname().split('.')[0]}'.")
    if not _started["watch"]:
        _started["watch"] = True
        threading.Thread(target=_watch_addresses, daemon=True).start()


def advertise_stop():
    zc, _zeroconf["zc"] = _zeroconf["zc"], None
    if zc is not None:
        try:
            zc.unregister_all_services()
            zc.close()
        except Exception:
            pass


def _watch_addresses():
    # Re-announce if the PC's addresses change (cable plugged in, DHCP renewal...).
    while not _state["quit"]:
        time.sleep(15)
        zc = _zeroconf["zc"]
        if zc is None:
            continue
        try:
            now = _addresses()
            if now != _zeroconf["addrs"]:
                _zeroconf["addrs"] = now
                zc.update_service(_service_info(now))
        except Exception:
            pass


def open_socket():
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
        print("Use its tray icon to Quit, then run this again.")
        message_box("PadLink is already running. Look for its icon in the system tray "
                    "(click ^ if it is hidden). To start a new version, right-click it and choose Quit first.")
        raise SystemExit(0)
    return sock


def loop(sock):
    sock.settimeout(0.25)
    pad = None
    last = None
    last_input = time.monotonic()
    idle = True
    while not _state["quit"]:
        if _state["perf_thread"] != _state["performance"]:
            apply_thread_performance(_state["performance"])
            _state["perf_thread"] = _state["performance"]
        # Enable / Disable from the tray: create or remove the virtual controller.
        if _state["enabled"] and pad is None:
            try:
                pad = get_pad()
            except DriverError as e:
                log(str(e))
                print(f"PadLink: {e}")
                _state["note"] = str(e)
                _state["enabled"] = False
                continue
            _state["error"] = False
            _state["note"] = ""
            _state["ready"] = True
            advertise_start()
            print(f"PadLink listening on UDP {PORT} (virtual Xbox 360 pad created)")
            print("Waiting for the phone...")
            last, idle, last_input = None, True, time.monotonic()
        elif not _state["enabled"] and pad is not None:
            try:
                pad.reset()
                pad.update()
            except Exception:
                pass
            _state["large"] = _state["small"] = 0
            _state["last_seen"] = 0.0
            pad = None
            destroy_pad()
            advertise_stop()
            print("PadLink disabled: virtual controller removed.")

        try:
            data, addr = sock.recvfrom(64)
        except (socket.timeout, OSError):
            data = None

        if pad is not None and data:
            kind, payload, tag = parse_datagram(data)
            signed = kind is not None and is_signed(payload, tag)
            if kind is not None and _state["require_pairing"] and not signed:
                tell_phone_pairing_needed(sock, addr)  # unpaired phones are ignored
                kind = None
            if kind is not None:
                _state["phone"] = addr
                _state["phone_ip"] = addr[0]
                _state["phone_signed"] = signed
                _state["last_seen"] = time.monotonic()
            if kind == "ping":
                try:
                    sock.sendto(data, addr)
                except OSError:
                    pass
            elif kind == "input":
                magic, seq, buttons, lt, rt, lx, ly, rx, ry = PACKET.unpack(payload)
                if newer(seq, last):
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
        if pad is not None and not idle and time.monotonic() - last_input > IDLE_AFTER:
            pad.reset()
            pad.update()
            _state["large"] = _state["small"] = 0
            if last is not None:
                print("Phone went quiet; controller released.")
            idle = True
            last = None

    if pad is not None:
        pad.reset()
        pad.update()
    advertise_stop()


# ------------------------------------------------------------- performance mode

def apply_process_performance(on):
    """Windows only: stop Windows slowing PadLink down while it sits in the tray.

    On: high priority, opt out of efficiency mode (EcoQoS), and 1 ms system timer. Off: back to the defaults.
    Returns True if it could be applied. Nothing here touches the controller itself."""
    if sys.platform != "win32":
        return False
    try:
        import ctypes
        from ctypes import wintypes
        kernel32 = ctypes.windll.kernel32
        process = kernel32.GetCurrentProcess()
        kernel32.SetPriorityClass(process, 0x00000080 if on else 0x00000020)  # HIGH / NORMAL

        class ThrottlingState(ctypes.Structure):
            _fields_ = [("Version", wintypes.ULONG), ("ControlMask", wintypes.ULONG), ("StateMask", wintypes.ULONG)]

        # ControlMask 1 = we decide; StateMask 0 = never throttle. ControlMask 0 = system default.
        state = ThrottlingState(1, 1 if on else 0, 0)
        kernel32.SetProcessInformation(process, 4, ctypes.byref(state), ctypes.sizeof(state))  # ProcessPowerThrottling
        winmm = ctypes.windll.winmm
        if on and not _state["perf_timer"]:
            winmm.timeBeginPeriod(1)
            _state["perf_timer"] = True
        elif not on and _state["perf_timer"]:
            winmm.timeEndPeriod(1)
            _state["perf_timer"] = False
        return True
    except Exception:
        log("Performance mode could not be applied: " + traceback.format_exc())
        return False


def apply_thread_performance(on):
    """Raise (or restore) the priority of the thread that reads controller packets. Call from that thread."""
    if sys.platform != "win32":
        return False
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        kernel32.SetThreadPriority(kernel32.GetCurrentThread(), 2 if on else 0)  # HIGHEST / NORMAL
        return True
    except Exception:
        return False


def load_performance():
    _state["performance"] = bool(load_settings().get("performance_mode", True))
    apply_process_performance(_state["performance"])


def set_performance(on):
    save_settings(performance_mode=bool(on))
    _state["performance"] = bool(on)
    apply_process_performance(bool(on))


def serve(sock):
    # Never give up: if anything unexpected happens, log it and start over.
    while not _state["quit"]:
        try:
            loop(sock)
        except Exception:
            err = traceback.format_exc()
            _state["error"] = True
            log(err)
            print(err)
            print("PadLink hit an error (see above). If you just installed the driver, restart Windows. Retrying in 3s...")
            time.sleep(3)


# ---------------------------------------------------------------- system tray

MINT, AMBER, GRAY, RED, NAVY = (53, 224, 194), (245, 165, 36), (156, 163, 175), (255, 107, 107), (13, 19, 33)


def status():
    """(kind, text) for the tray: connected / waiting / disabled / error."""
    if not _state["enabled"]:
        return "disabled", "PadLink: disabled" + (f" ({_state['note']})" if _state["note"] else "")
    if _state["note"]:
        return "waiting", f"PadLink: {_state['note']}"
    if _state["error"]:
        return "error", "PadLink: error (see padlink.log)"
    if time.monotonic() - _state["last_seen"] < 3:
        return "connected", f"PadLink: phone connected ({_state['phone_ip']})"
    return "waiting", "PadLink: waiting for phone"


def make_icon(kind):
    """The app icon with a small status badge in the corner."""
    from PIL import Image, ImageDraw
    try:
        base = Image.open(os.path.join(RES_DIR, "icon.png")).convert("RGBA").resize((64, 64), Image.LANCZOS)
    except Exception:
        base = Image.new("RGBA", (64, 64), NAVY + (255,))
        ImageDraw.Draw(base).ellipse((22, 22, 42, 42), fill=MINT + (255,))
    if kind == "disabled":
        alpha = base.getchannel("A").point(lambda a: int(a * 0.55))
        base = base.convert("L").convert("RGBA")
        base.putalpha(alpha)
    d = ImageDraw.Draw(base)
    color = {"connected": MINT, "waiting": AMBER, "disabled": GRAY, "error": RED}[kind]
    d.ellipse((34, 34, 64, 64), fill=NAVY + (255,))
    d.ellipse((39, 39, 59, 59), fill=color + (255,))
    if kind == "disabled":  # pause bars
        d.rectangle((44, 44, 47, 54), fill=NAVY + (255,))
        d.rectangle((51, 44, 54, 54), fill=NAVY + (255,))
    return base


RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
RUN_NAME = "PadLink"
LEGACY_TASK = "PadLinkReceiver"  # the scheduled task made by install_startup.ps1
NO_WINDOW = 0x08000000


def installed_exe():
    return os.path.join(os.environ.get("LOCALAPPDATA", APP_DIR), "PadLink", "PadLinkReceiver.exe")


def autostart_command():
    """Command Windows runs at login."""
    if FROZEN:
        # Keep a copy in a permanent folder so deleting or moving the download doesn't break it.
        target = installed_exe()
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.abspath(sys.executable).lower() != os.path.abspath(target).lower():
                shutil.copy2(sys.executable, target)
        except OSError:
            log("Could not copy the exe to " + target + ": " + traceback.format_exc())
            target = os.path.abspath(sys.executable)
        return f'"{target}"'
    # Running from source: this script, hidden (pythonw), from where it is now.
    exe = sys.executable
    pyw = os.path.join(os.path.dirname(exe), "pythonw.exe")
    if os.path.exists(pyw):
        exe = pyw
    return f'"{exe}" "{os.path.abspath(__file__)}"'


def autostart_enabled():
    """True if PadLink starts at login (startup entry, or the older scheduled task)."""
    if sys.platform != "win32":
        return False
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            winreg.QueryValueEx(key, RUN_NAME)
        return True
    except OSError:
        pass
    try:
        return subprocess.run(["schtasks", "/Query", "/TN", LEGACY_TASK], capture_output=True,
                              creationflags=NO_WINDOW).returncode == 0
    except Exception:
        return False


def set_autostart(on):
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
        if on:
            winreg.SetValueEx(key, RUN_NAME, 0, winreg.REG_SZ, autostart_command())
        else:
            try:
                winreg.DeleteValue(key, RUN_NAME)
            except FileNotFoundError:
                pass
    if not on:
        # Also remove the scheduled task from install_startup.ps1, if there is one.
        try:
            r = subprocess.run(["schtasks", "/Delete", "/TN", LEGACY_TASK, "/F"], capture_output=True,
                               creationflags=NO_WINDOW)
            if r.returncode != 0 and b"cannot find" not in (r.stderr or b"").lower():
                log("Could not remove scheduled task (run PowerShell as admin: "
                    f"Unregister-ScheduledTask {LEGACY_TASK} -Confirm:$false)")
        except Exception:
            pass


def refresh_autostart_path():
    """If you moved the folder, point the startup entry at the new location."""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_READ | winreg.KEY_SET_VALUE) as key:
            if winreg.QueryValueEx(key, RUN_NAME)[0] != autostart_command():
                winreg.SetValueEx(key, RUN_NAME, 0, winreg.REG_SZ, autostart_command())
    except Exception:
        pass


# ------------------------------------------------------------------ pairing

def new_code():
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(12))


def format_code(code):
    return "-".join(code[i:i + 4] for i in range(0, len(code), 4))


def normalize_code(text):
    return "".join(ch for ch in (text or "").upper() if ch in CODE_ALPHABET)


def key_for(code):
    return hashlib.sha256(b"padlink-v1:" + normalize_code(code).encode()).digest()


def tag_for(key, payload):
    return hmac.new(key, payload, hashlib.sha256).digest()[:TAG_LEN]


def load_pairing():
    """Read (or create) the pairing code and whether it is required."""
    settings = load_settings()
    code = normalize_code(settings.get("pairing_code", ""))
    if len(code) != 12:
        code = new_code()
        save_settings(pairing_code=code)
    _state["key"] = key_for(code)
    _state["require_pairing"] = bool(settings.get("pairing_required", False))
    return code


def current_code():
    return normalize_code(load_settings().get("pairing_code", ""))


def parse_datagram(data):
    """Split a datagram into (kind, payload, tag); kind is 'ping', 'input' or None."""
    if len(data) < 2:
        return None, b"", b""
    magic = struct.unpack_from("<H", data)[0]
    if magic == PING_MAGIC and len(data) in (PING_SIZE, PING_SIZE + TAG_LEN):
        return "ping", data[:PING_SIZE], data[PING_SIZE:]
    if magic == MAGIC and len(data) in (PACKET.size, PACKET.size + TAG_LEN):
        return "input", data[:PACKET.size], data[PACKET.size:]
    return None, b"", b""


def is_signed(payload, tag):
    return len(tag) == TAG_LEN and hmac.compare_digest(tag, tag_for(_state["key"], payload))


_pair_notice = {}


def tell_phone_pairing_needed(sock, addr):
    """Reply (at most once a second per phone) so the app can say the code is missing or wrong."""
    now = time.monotonic()
    if now - _pair_notice.get(addr[0], 0.0) < 1.0:
        return
    _pair_notice[addr[0]] = now
    try:
        sock.sendto(struct.pack("<HB", PAIR_MAGIC, 1), addr)
    except OSError:
        pass


# ------------------------------------------------------------------ updates

def load_settings():
    try:
        with open(os.path.join(APP_DIR, "settings.json")) as f:
            return json.load(f)
    except Exception:
        return {}


def save_settings(**changes):
    settings = load_settings()
    settings.update(changes)
    try:
        with open(os.path.join(APP_DIR, "settings.json"), "w") as f:
            json.dump(settings, f)
    except OSError:
        log("Could not save settings: " + traceback.format_exc())


def version_tuple(v):
    nums = [int(n) for n in re.findall(r"\d+", v or "")][:3]
    return tuple(nums + [0] * (3 - len(nums)))


def check_update():
    """Ask GitHub for the latest release. Sets _state['update'] and returns it (None if up to date)."""
    import urllib.request
    req = urllib.request.Request(f"https://api.github.com/repos/{REPO}/releases/latest",
                                 headers={"User-Agent": "PadLink-updater", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.load(r)
    tag = data.get("tag_name", "")
    asset = next((a for a in data.get("assets", []) if a.get("name") == "PadLinkReceiver.exe"), None)
    if asset and version_tuple(tag) > version_tuple(VERSION):
        sha = (asset.get("digest") or "").lower().replace("sha256:", "")
        _state["update"] = {"tag": tag, "url": asset["browser_download_url"], "sha": sha}
    else:
        _state["update"] = None
    return _state["update"]


def download_update(update, dest):
    """Download the new exe and verify it against the SHA-256 GitHub publishes for the asset."""
    import urllib.request
    if not update["url"].startswith(f"https://github.com/{REPO}/releases/download/"):
        raise RuntimeError("unexpected download address")
    if len(update["sha"]) != 64:
        raise RuntimeError("the release has no checksum, so it is not installed automatically")
    digest = hashlib.sha256()
    req = urllib.request.Request(update["url"], headers={"User-Agent": "PadLink-updater"})
    with urllib.request.urlopen(req, timeout=60) as r, open(dest, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
            digest.update(chunk)
    if digest.hexdigest() != update["sha"]:
        os.remove(dest)
        raise RuntimeError("downloaded file did not match its checksum")


def swap_and_restart_script(new, target, pids):
    """PowerShell run after we exit: put the new exe in place (retrying while Windows lets go), start it."""
    q = lambda path: "'" + path.replace("'", "''") + "'"
    waits = "".join(f"Wait-Process -Id {int(pid)} -Timeout 30 -ErrorAction SilentlyContinue; " for pid in pids)
    move = f"Move-Item -LiteralPath {q(new)} -Destination {q(target)} -Force -ErrorAction Stop"
    start = f"Start-Process -FilePath {q(target)}"
    return (waits +
            "$ok = $false; for ($i = 0; $i -lt 40 -and -not $ok; $i++) { try { " + move + "; $ok = $true } "
            "catch { Start-Sleep -Milliseconds 500 } }; "
            "Start-Sleep -Seconds 2; "  # let the old process release the port and its temp folder
            "if ($ok) { " + start + " }")


def install_update(icon):
    update = _state["update"]
    if not update:
        return
    if not FROZEN:
        import webbrowser
        webbrowser.open(RELEASES_URL)
        return
    target = os.path.abspath(sys.executable)
    new = target + ".new"
    try:
        _state["note"] = f"downloading {update['tag']}"
        try:
            download_update(update, new)
        except OSError:  # folder not writable: use the temp folder instead
            import tempfile
            new = os.path.join(tempfile.gettempdir(), "PadLinkReceiver.new.exe")
            download_update(update, new)
        _state["note"] = ""
        pids = [os.getpid()]
        parent = os.getppid()  # the one-file launcher, but only wait for it if it is our own exe (not explorer or cmd)
        try:
            out = subprocess.run(["tasklist", "/FI", f"PID eq {parent}", "/FO", "CSV", "/NH"],
                                 capture_output=True, text=True, timeout=10, creationflags=NO_WINDOW).stdout
            if os.path.basename(target).lower() in out.lower():
                pids.append(parent)
        except Exception:
            pass
        script = swap_and_restart_script(new, target, pids)
        env = dict(os.environ, PYINSTALLER_RESET_ENVIRONMENT="1")
        cmd = ["powershell", "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-Command", script]
        flags = NO_WINDOW | 0x00000008 | 0x00000200  # no window, detached
        try:  # leave the job object so the helper is not killed when we exit
            subprocess.Popen(cmd, env=env, close_fds=True, creationflags=flags | 0x01000000)
        except OSError:
            subprocess.Popen(cmd, env=env, close_fds=True, creationflags=flags)
        log(f"Updating to {update['tag']}")
        _state["quit"] = True
        icon.stop()
    except Exception as e:
        _state["note"] = ""
        log("Update failed: " + traceback.format_exc())
        notify(icon, f"Update failed: {e}")


def notify(icon, message, title="PadLink"):
    try:
        icon.notify(message, title)
    except Exception:
        pass


def update_checker(icon):
    time.sleep(30)  # let startup settle first
    while not _state["quit"]:
        if load_settings().get("auto_update_check", True):
            try:
                update = check_update()
                if update and update["tag"] != _state["notified"]:
                    _state["notified"] = update["tag"]
                    notify(icon, f"PadLink {update['tag']} is available. Right-click the tray icon to install it.",
                           "PadLink update")
                    icon.update_menu()
            except Exception:
                log("Update check failed: " + traceback.format_exc())
        for _ in range(CHECK_EVERY // 5):
            if _state["quit"]:
                return
            time.sleep(5)


def ask_yes_no(text, title="PadLink"):
    if sys.platform != "win32":
        return False
    try:
        import ctypes
        return ctypes.windll.user32.MessageBoxW(None, text, title, 0x24) == 6  # Yes/No, question icon
    except Exception:
        return False


def show_pairing_code():
    text = (f"Pairing code: {format_code(current_code())}\n\n"
            "In the PadLink app on your iPhone, type this into the PC section's Pairing code box.")
    if sys.platform == "win32":
        try:
            import ctypes
            ctypes.windll.user32.MessageBoxW(None, text, "PadLink pairing code", 0x40)
        except Exception:
            pass
    else:
        print(text)


def set_pairing_required(on):
    save_settings(pairing_required=bool(on))
    _state["require_pairing"] = bool(on)


def first_run_wizard():
    """After setup succeeds, ask the two questions that need a human, once."""
    if load_settings().get("first_run_done"):
        return
    deadline = time.monotonic() + 600
    while not _state["ready"] and not _state["quit"] and time.monotonic() < deadline:
        time.sleep(1)
    if not _state["ready"]:
        return
    if not autostart_enabled() and ask_yes_no(
            "PadLink is set up and running in the system tray (the icon near the clock; click ^ if hidden).\n\n"
            "Start PadLink automatically when you sign in to Windows? (recommended)"):
        try:
            set_autostart(True)
        except Exception:
            log("Run at login failed: " + traceback.format_exc())
    if not _state["require_pairing"] and ask_yes_no(
            "Require a pairing code, so only your phone can send input to this PC? (recommended)\n\n"
            "You will type the code into the PadLink app once."):
        set_pairing_required(True)
        show_pairing_code()
    save_settings(first_run_done=True)


def ensure_requirements():
    """Running from source: install any missing packages on first run (the exe already has them)."""
    if FROZEN:
        return
    import importlib
    import importlib.util
    needed = {"zeroconf": "zeroconf", "ifaddr": "ifaddr", "pystray": "pystray", "PIL": "pillow", "vgamepad": "vgamepad"}
    missing = [pkg for mod, pkg in needed.items() if importlib.util.find_spec(mod) is None]
    if not missing:
        return
    req = os.path.join(APP_DIR, "requirements.txt")
    cmd = [sys.executable, "-m", "pip", "install", "-r", req] if os.path.exists(req) else [sys.executable, "-m", "pip", "install", *missing]
    print("First run: installing " + ", ".join(missing) + " ...")
    log("Installing missing packages: " + ", ".join(missing))
    try:
        subprocess.run(cmd, check=True, creationflags=NO_WINDOW if sys.platform == "win32" else 0)
        importlib.invalidate_caches()
    except Exception:
        log("Package install failed: " + traceback.format_exc())
        print("Could not install the required packages automatically. Run: pip install -r requirements.txt")


def run_tray():
    import pystray

    _state["autostart"] = autostart_enabled()
    if sys.platform == "win32":
        refresh_autostart_path()

    def toggle_autostart(icon, item):
        try:
            set_autostart(not _state["autostart"])
        except Exception:
            log("Run at login toggle failed: " + traceback.format_exc())
        _state["autostart"] = autostart_enabled()
        icon.update_menu()

    def toggle(icon, item):
        _state["enabled"] = not _state["enabled"]
        icon.update_menu()

    def open_log(icon, item):
        path = os.path.join(APP_DIR, "padlink.log")
        try:
            os.startfile(path if os.path.exists(path) else APP_DIR)
        except Exception:
            pass

    def quit_app(icon, item):
        _state["quit"] = True
        icon.stop()

    def check_now(icon, item):
        def work():
            try:
                update = check_update()
                icon.update_menu()
                if update:
                    notify(icon, f"PadLink {update['tag']} is available. Right-click the tray icon to install it.",
                           "PadLink update")
                else:
                    notify(icon, f"You are up to date (version {VERSION}).", "PadLink update")
            except Exception:
                log("Update check failed: " + traceback.format_exc())
                notify(icon, "Could not check for updates. Are you online?", "PadLink update")
        threading.Thread(target=work, daemon=True).start()

    def toggle_auto_check(icon, item):
        save_settings(auto_update_check=not load_settings().get("auto_update_check", True))
        icon.update_menu()

    def show_code(icon=None, item=None):
        show_pairing_code()

    def toggle_pairing(icon, item):
        set_pairing_required(not _state["require_pairing"])
        icon.update_menu()
        if _state["require_pairing"]:
            show_pairing_code()

    def regenerate_code(icon, item):
        save_settings(pairing_code=new_code())
        load_pairing()
        show_code()

    def toggle_performance(icon, item):
        set_performance(not _state["performance"])
        icon.update_menu()

    def do_update(icon, item):
        threading.Thread(target=install_update, args=(icon,), daemon=True).start()

    menu = pystray.Menu(
        pystray.MenuItem(lambda item: status()[1], None, enabled=False),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem(lambda item: "Enable" if not _state["enabled"] else "Disable", toggle),
        pystray.MenuItem("Run at login", toggle_autostart, checked=lambda item: _state.get("autostart", False),
                         visible=sys.platform == "win32"),
        pystray.MenuItem("Performance mode", toggle_performance, checked=lambda item: _state["performance"],
                         visible=sys.platform == "win32"),
        pystray.MenuItem("Pairing", pystray.Menu(
            pystray.MenuItem("Require pairing code", toggle_pairing, checked=lambda item: _state["require_pairing"]),
            pystray.MenuItem("Show pairing code...", show_code),
            pystray.MenuItem("New pairing code...", regenerate_code),
        )),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem(lambda item: f"Install update {_state['update']['tag']}" if _state["update"] else "",
                         do_update, visible=lambda item: bool(_state["update"])),
        pystray.MenuItem(lambda item: f"Check for updates (this is {VERSION})", check_now),
        pystray.MenuItem("Check automatically", toggle_auto_check,
                         checked=lambda item: load_settings().get("auto_update_check", True)),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Open log", open_log),
        pystray.MenuItem("Quit", quit_app),
    )
    kind, text = status()
    icon = pystray.Icon("PadLink", make_icon(kind), text, menu)

    def refresh(icon):
        icon.visible = True
        threading.Thread(target=update_checker, args=(icon,), daemon=True).start()
        shown = None
        while not _state["quit"]:
            now = status()
            if now != shown:
                shown = now
                icon.icon = make_icon(now[0])
                icon.title = now[1]
                icon.update_menu()
            time.sleep(1)

    icon.run(lambda i: threading.Thread(target=refresh, args=(i,), daemon=True).start())


def main():
    print("PadLink receiver starting...")
    ensure_requirements()
    sock = open_socket()
    _state["sock"] = sock
    load_pairing()
    load_performance()
    threading.Thread(target=serve, args=(sock,), daemon=True).start()
    threading.Thread(target=first_run_wizard, daemon=True).start()
    if "--no-tray" not in sys.argv:
        try:
            run_tray()  # blocks until Quit
        except ImportError:
            print("Tray icon unavailable (run: pip install -r requirements.txt); running in console only.")
        except Exception:
            log("Tray failed: " + traceback.format_exc())
    try:
        while not _state["quit"]:
            time.sleep(0.5)
    except KeyboardInterrupt:
        _state["quit"] = True


if __name__ == "__main__":
    main()
