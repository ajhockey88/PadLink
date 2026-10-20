"""Render the interface mockups in docs/mockups/*.dc.html to PNGs in docs/images/.

The mockups are design renders, not screenshots of the running apps. They use a tiny template syntax
(<sc-for>, <sc-if>, {{holes}}) that this script expands, using Node to evaluate each file's data.

    python docs/render_mockups.py            # needs Node.js, Pillow and Chromium/Chrome (set CHROME=... if not on PATH)
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# name -> (output file, window width, window height or None to use the mockup's own size)
TARGETS = {
    "AppScreen": ("app-connected.png", None, None),
    "AppPairing": ("app-pairing.png", None, None),
    "AppBenchmark": ("app-benchmark.png", None, None),
    "AppWelcome": ("app-welcome.png", None, 650),
    "AppLatency": ("app-latency.png", None, None),
    "Tray": ("tray-menu.png", None, 520),
    "Windows": ("windows-dialogs.png", None, 770),
}


def find_chrome():
    for candidate in (os.environ.get("CHROME"), shutil.which("chromium"), shutil.which("google-chrome"),
                      shutil.which("chrome"), *glob.glob("/opt/pw-browsers/chromium-*/chrome-linux/chrome")):
        if candidate and os.path.exists(candidate):
            return candidate
    sys.exit("Chromium/Chrome not found; set CHROME to its path.")


def lookup(path, scope):
    value = scope
    for part in path.split("."):
        if isinstance(value, dict):
            value = value.get(part)
        else:
            value = getattr(value, part, None)
        if value is None:
            return None
    return value


def render(text, scope):
    def each(m):
        items = lookup(m.group(1), scope) or []
        return "".join(render(m.group(3), {**scope, m.group(2): item}) for item in items)

    text = re.sub(r'<sc-for list="\{\{\s*([\w.]+)\s*\}\}" as="(\w+)"[^>]*>(.*?)</sc-for>', each, text, flags=re.S)

    def cond(m):
        expr = m.group(1).strip()
        value = {"true": True, "false": False}.get(expr, lookup(expr, scope))
        return m.group(2) if value else ""

    text = re.sub(r'<sc-if value="\{\{\s*([\w.]+)\s*\}\}"[^>]*>(.*?)</sc-if>', cond, text, flags=re.S)
    return re.sub(r"\{\{\s*([\w.$]+)\s*\}\}", lambda m: str(lookup(m.group(1), scope) if lookup(m.group(1), scope) is not None else ""), text)


def page(path):
    source = open(path, encoding="utf-8").read()
    body = re.search(r"<x-dc>(.*)</x-dc>", source, re.S).group(1)
    css = "".join(re.findall(r"<style>(.*?)</style>", re.search(r"<helmet>(.*?)</helmet>", body, re.S).group(1), re.S))
    body = re.sub(r"<helmet>.*?</helmet>", "", body, flags=re.S)
    script = re.search(r'<script type="text/x-dc"[^>]*>(.*?)</script>', source, re.S).group(1)
    props = re.search(r"data-props='(.*?)'", source, re.S).group(1)
    size = json.loads(props)["$preview"]
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write("class DCLogic { constructor() { this.props = {}; } }\n" + script +
                "\nconsole.log(JSON.stringify(new Component().renderVals()));\n")
    data = json.loads(subprocess.run(["node", f.name], capture_output=True, text=True, check=True).stdout)
    os.unlink(f.name)
    html = ('<!doctype html><html><head><meta charset="utf-8"><style>' + css +
            "</style></head><body>" + render(body, data) + "</body></html>")
    return html, size["width"], size["height"]


def crop(path, width, height):
    from PIL import Image
    image = Image.open(path).convert("RGB")
    image.crop((0, 0, width, height)).save(path, optimize=True)


def main():
    chrome = find_chrome()
    out_dir = os.path.join(HERE, "images")
    os.makedirs(out_dir, exist_ok=True)
    for name, (out, width, height) in TARGETS.items():
        html, w, h = page(os.path.join(HERE, "mockups", name + ".dc.html"))
        crop_w, crop_h = width or w, height or h
        with tempfile.TemporaryDirectory() as tmp:
            html_path = os.path.join(tmp, name + ".html")
            open(html_path, "w", encoding="utf-8").write(html)
            target = os.path.join(out_dir, out)
            # Headless Chrome's page area is about 90 px shorter than its window, so use a taller window
            # and crop back to the mockup's real size afterwards.
            subprocess.run([chrome, "--headless", "--no-sandbox", "--disable-gpu", "--hide-scrollbars",
                            "--force-device-scale-factor=2", f"--window-size={crop_w},{crop_h + 160}",
                            f"--screenshot={target}", "file://" + html_path],
                           capture_output=True, check=True)
        crop(target, crop_w * 2, crop_h * 2)
        print("rendered", out)


if __name__ == "__main__":
    main()
