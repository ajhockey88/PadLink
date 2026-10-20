"""PadLink receiver: turns UDP controller packets into a virtual Xbox 360 pad.

Runs with a system tray icon (status, Disable/Enable, Quit). Use `--no-tray` for console only.
Requires ViGEmBus (https://github.com/nefarius/ViGEmBus) and `pip install -r requirements.txt`.
"""
import gc
import os
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import traceback

vg = None  # imported lazily: `import vgamepad` connects to the driver, so the driver must exist first

PORT = 26760
MAGIC = 0x504C
PING_MAGIC = 0x5049
RUMBLE_MAGIC = 0x5052
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
          "enabled": True, "quit": False, "error": False, "note": "", "last_seen": 0.0, "phone_ip": None}
_started = {"rumble": False, "watch": False}
_zeroconf = {"zc": None, "addrs": []}


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


def ensure_driver():
    """Install the ViGEmBus driver (one Windows approval prompt) if it is missing."""
    if driver_installed():
        return
    msi = find_driver_installer()
    if not msi:
        raise DriverError("ViGEmBus driver missing: install it from github.com/nefarius/ViGEmBus/releases")
    _state["note"] = "installing the controller driver, approve the Windows prompt"
    log("Installing ViGEmBus driver from " + msi)
    import ctypes
    rc = ctypes.windll.shell32.ShellExecuteW(None, "runas", "msiexec.exe", f'/i "{msi}" /qb /norestart', None, 1)
    if rc <= 32:
        raise DriverError("driver install was declined; use Enable to try again")
    deadline = time.monotonic() + 180
    while not driver_installed():
        if time.monotonic() > deadline:
            raise DriverError("driver install did not finish; use Enable to try again")
        time.sleep(2)
    time.sleep(3)
    _state["note"] = ""
    log("ViGEmBus driver installed")


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
            if len(data) == PING_SIZE and struct.unpack_from("<H", data)[0] == PING_MAGIC:
                _state["phone"] = addr
                _state["phone_ip"] = addr[0]
                _state["last_seen"] = time.monotonic()
                try:
                    sock.sendto(data, addr)
                except OSError:
                    pass
            elif len(data) == PACKET.size:
                magic, seq, buttons, lt, rt, lx, ly, rx, ry = PACKET.unpack(data)
                if magic == MAGIC:
                    _state["phone"] = addr
                    _state["phone_ip"] = addr[0]
                    _state["last_seen"] = time.monotonic()
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

    menu = pystray.Menu(
        pystray.MenuItem(lambda item: status()[1], None, enabled=False),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem(lambda item: "Enable" if not _state["enabled"] else "Disable", toggle),
        pystray.MenuItem("Run at login", toggle_autostart, checked=lambda item: _state.get("autostart", False),
                         visible=sys.platform == "win32"),
        pystray.MenuItem("Open log", open_log),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Quit", quit_app),
    )
    kind, text = status()
    icon = pystray.Icon("PadLink", make_icon(kind), text, menu)

    def refresh(icon):
        icon.visible = True
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
    sock = open_socket()
    _state["sock"] = sock
    threading.Thread(target=serve, args=(sock,), daemon=True).start()
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
