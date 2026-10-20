"""Tests for the PC receiver. Run: python -m unittest discover -s tests -v (no Windows or driver needed)."""
import hashlib
import importlib.util
import io
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECEIVER = os.path.join(ROOT, "Windows", "padlink_receiver.py")


class FakePad:
    instances = []

    def __init__(self):
        self.report = types.SimpleNamespace(wButtons=0, bLeftTrigger=0, bRightTrigger=0,
                                            sThumbLX=0, sThumbLY=0, sThumbRX=0, sThumbRY=0)
        self.updates = 0
        FakePad.instances.append(self)

    def update(self):
        self.updates += 1

    def reset(self):
        self.report.wButtons = 0

    def register_notification(self, callback_function):
        self.callback = callback_function

    def unregister_notification(self):
        pass


def load_receiver():
    stub = types.ModuleType("vgamepad")
    stub.VX360Gamepad = FakePad
    sys.modules["vgamepad"] = stub
    spec = importlib.util.spec_from_file_location("padlink_receiver_under_test", RECEIVER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.APP_DIR = tempfile.mkdtemp()  # keep settings.json / padlink.log out of the repo
    return module


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class PureLogic(unittest.TestCase):
    def setUp(self):
        self.r = load_receiver()

    def test_version_compare(self):
        v = self.r.version_tuple
        self.assertGreater(v("v0.4.1"), v("0.4.0"))
        self.assertGreater(v("v0.10.0"), v("0.9.9"))
        self.assertEqual(v("v1.0"), v("1.0.0"))
        self.assertGreater(v("v0.0.1"), v("dev"))

    def test_codes(self):
        code = self.r.new_code()
        self.assertEqual(len(code), 12)
        self.assertTrue(set(code) <= set(self.r.CODE_ALPHABET))
        self.assertEqual(self.r.normalize_code("abcd-efgh jkmn"), "ABCDEFGHJKMN")
        self.assertEqual(self.r.format_code("ABCDEFGHJKMN"), "ABCD-EFGH-JKMN")
        self.assertEqual(self.r.key_for("abcd-efgh-jkmn"), self.r.key_for("ABCDEFGHJKMN"))
        self.assertNotEqual(self.r.key_for("ABCDEFGHJKMN"), self.r.key_for("ABCDEFGHJKMP"))

    def test_parse_and_sign(self):
        r = self.r
        key = r.key_for("ABCDEFGHJKMN")
        r._state["key"] = key
        payload = struct.pack("<HHHBBhhhh", r.MAGIC, 7, 0x1000, 0, 0, 0, 0, 0, 0)
        kind, p, tag = r.parse_datagram(payload)
        self.assertEqual((kind, p, tag), ("input", payload, b""))
        self.assertFalse(r.is_signed(p, tag))
        signed = payload + r.tag_for(key, payload)
        kind, p, tag = r.parse_datagram(signed)
        self.assertEqual(kind, "input")
        self.assertTrue(r.is_signed(p, tag))
        tampered = bytearray(signed)
        tampered[4] ^= 0xFF
        kind, p, tag = r.parse_datagram(bytes(tampered))
        self.assertFalse(r.is_signed(p, tag))
        ping = struct.pack("<HHQ", r.PING_MAGIC, 1, 99)
        self.assertEqual(r.parse_datagram(ping)[0], "ping")
        self.assertEqual(r.parse_datagram(ping + r.tag_for(key, ping))[0], "ping")
        self.assertIsNone(r.parse_datagram(b"\x00")[0])
        self.assertIsNone(r.parse_datagram(payload[:10])[0])
        self.assertIsNone(r.parse_datagram(b"XX" + payload[2:])[0])

    def test_pairing_persists(self):
        r = self.r
        code = r.load_pairing()
        self.assertEqual(len(code), 12)
        self.assertEqual(r.current_code(), code)
        self.assertEqual(r.load_pairing(), code)  # stable across restarts
        self.assertFalse(r._state["require_pairing"])

    def test_stamp_version(self):
        d = tempfile.mkdtemp()
        os.makedirs(os.path.join(d, "Windows"))
        for name in ("stamp_version.py", "padlink_receiver.py"):
            with open(os.path.join(ROOT, "Windows", name), "rb") as src, open(os.path.join(d, "Windows", name), "wb") as dst:
                dst.write(src.read())
        env = dict(os.environ, RELEASE_TAG="v1.2.3")
        subprocess.run([sys.executable, os.path.join(d, "Windows", "stamp_version.py")], check=True, env=env, capture_output=True)
        self.assertIn('VERSION = "1.2.3"', open(os.path.join(d, "Windows", "padlink_receiver.py")).read())
        bad = subprocess.run([sys.executable, os.path.join(d, "Windows", "stamp_version.py")],
                             env=dict(os.environ, RELEASE_TAG="banana"), capture_output=True)
        self.assertNotEqual(bad.returncode, 0)


class Updater(unittest.TestCase):
    def setUp(self):
        self.r = load_receiver()
        self.payload = b"MZ" + os.urandom(1500)
        sha = hashlib.sha256(self.payload).hexdigest()
        self.api = {"tag_name": "v0.4.1", "assets": [
            {"name": "PadLink.ipa", "browser_download_url": "x"},
            {"name": "PadLinkReceiver.exe", "digest": "sha256:" + sha,
             "browser_download_url": "https://github.com/ajhockey88/PadLink/releases/download/v0.4.1/PadLinkReceiver.exe"}]}
        self.real_urlopen = urllib.request.urlopen

        class Resp(io.BytesIO):
            def __enter__(s):
                return s

            def __exit__(s, *a):
                return False

        def fake(req, timeout=0):
            return Resp(json.dumps(self.api).encode() if "api.github.com" in req.full_url else self.payload)

        urllib.request.urlopen = fake

    def tearDown(self):
        urllib.request.urlopen = self.real_urlopen

    def test_detects_newer_only(self):
        self.r.VERSION = "0.4.0"
        self.assertEqual(self.r.check_update()["tag"], "v0.4.1")
        self.r.VERSION = "0.4.1"
        self.assertIsNone(self.r.check_update())

    def test_download_verified(self):
        self.r.VERSION = "0.4.0"
        update = self.r.check_update()
        dest = os.path.join(tempfile.mkdtemp(), "new.exe")
        self.r.download_update(update, dest)
        self.assertEqual(open(dest, "rb").read(), self.payload)
        self.payload += b"tampered"
        with self.assertRaises(RuntimeError):
            self.r.download_update(update, dest)
        self.assertFalse(os.path.exists(dest))

    def test_refuses_bad_url_or_missing_checksum(self):
        update = {"tag": "v9", "url": "https://evil.example/x.exe", "sha": "0" * 64}
        with self.assertRaises(RuntimeError):
            self.r.download_update(update, os.path.join(tempfile.mkdtemp(), "x"))
        update = {"tag": "v9", "url": "https://github.com/ajhockey88/PadLink/releases/download/v9/PadLinkReceiver.exe", "sha": ""}
        with self.assertRaises(RuntimeError):
            self.r.download_update(update, os.path.join(tempfile.mkdtemp(), "x"))

    def test_swap_script_quotes_paths(self):
        script = self.r.swap_and_restart_script(r"C:\a b\it's\new.exe", r"C:\a b\it's\PadLinkReceiver.exe", [1, 2])
        self.assertIn("'C:\\a b\\it''s\\new.exe'", script)
        self.assertIn("Wait-Process -Id 1", script)
        self.assertIn("Start-Process", script)


class OverUdp(unittest.TestCase):
    """Runs the real receive loop on localhost with a fake virtual pad."""

    @classmethod
    def setUpClass(cls):
        FakePad.instances.clear()
        cls.r = load_receiver()
        cls.r.PORT = free_port()
        cls.code = cls.r.load_pairing()
        cls.key = cls.r.key_for(cls.code)
        sock = cls.r.open_socket()
        cls.r._state["sock"] = sock
        threading.Thread(target=cls.r.serve, args=(sock,), daemon=True).start()
        cls.client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        cls.client.settimeout(0.6)
        time.sleep(0.6)
        cls.pad = FakePad.instances[0]

    @classmethod
    def tearDownClass(cls):
        cls.r._state["quit"] = True
        time.sleep(0.5)

    def send(self, data):
        self.client.sendto(data, ("127.0.0.1", self.r.PORT))

    def recv(self):
        try:
            return self.client.recvfrom(64)[0]
        except socket.timeout:
            return None

    def packet(self, seq, buttons, signed):
        data = struct.pack("<HHHBBhhhh", self.r.MAGIC, seq, buttons, 0, 0, 0, 0, 0, 0)
        return data + self.r.tag_for(self.key, data) if signed else data

    def ping(self, n, signed):
        data = struct.pack("<HHQ", self.r.PING_MAGIC, n, 12345)
        return data + self.r.tag_for(self.key, data) if signed else data

    def test_1_open_mode_accepts_unsigned(self):
        self.r._state["require_pairing"] = False
        p = self.ping(1, False)
        self.send(p)
        self.assertEqual(self.recv(), p)
        self.send(self.packet(1, 0x1000, False))
        time.sleep(0.2)
        self.assertEqual(self.pad.report.wButtons, 0x1000)

    def test_2_required_rejects_unsigned_and_says_why(self):
        self.r._state["require_pairing"] = True
        before = self.pad.report.wButtons
        self.send(self.packet(50, 0x2000, False))
        reply = self.recv()
        self.assertEqual(reply, struct.pack("<HB", self.r.PAIR_MAGIC, 1))
        time.sleep(0.2)
        self.assertEqual(self.pad.report.wButtons, before)
        self.send(self.ping(2, False))
        self.assertNotEqual(self.recv(), self.ping(2, False))

    def test_3_required_accepts_signed(self):
        self.r._state["require_pairing"] = True
        p = self.ping(3, True)
        self.send(p)
        self.assertEqual(self.recv(), p)
        self.send(self.packet(100, 0x4000, True))
        time.sleep(0.2)
        self.assertEqual(self.pad.report.wButtons, 0x4000)

    def test_4_wrong_code_rejected(self):
        self.r._state["require_pairing"] = True
        bad_key = self.r.key_for("ZZZZZZZZZZZZ")
        data = struct.pack("<HHHBBhhhh", self.r.MAGIC, 200, 0x8000, 0, 0, 0, 0, 0, 0)
        self.send(data + self.r.tag_for(bad_key, data))
        self.assertEqual(self.recv(), struct.pack("<HB", self.r.PAIR_MAGIC, 1))
        time.sleep(0.2)
        self.assertNotEqual(self.pad.report.wButtons, 0x8000)

    def test_5_rumble_signed_when_phone_signs(self):
        self.r._state["require_pairing"] = True
        self.send(self.packet(300, 0, True))
        time.sleep(0.2)
        self.r.on_rumble(None, None, 200, 50, 0, None)
        got = self.recv()
        while got is not None and len(got) != 12:  # skip any echoes
            got = self.recv()
        self.assertIsNotNone(got)
        payload, tag = got[:4], got[4:]
        self.assertEqual(struct.unpack("<HBB", payload), (self.r.RUMBLE_MAGIC, 200, 50))
        self.assertEqual(tag, self.r.tag_for(self.key, payload))
        self.r._state["large"] = self.r._state["small"] = 0


if __name__ == "__main__":
    unittest.main()
