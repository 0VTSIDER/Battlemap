"""SVG -> PNG with headless Microsoft Edge (or Chrome), in place of the resvg_py package:
svg_to_bytes(svg_string=..., width=..., height=None) -> PNG bytes (transparent background).
height=None keeps the SVG's aspect ratio (its width/height, else its viewBox).

The browser runs with a throwaway profile (never the user's) and only loads the local file.
Set SVG_BROWSER to a browser executable to override the search.
"""
import os
import re
import shutil
import subprocess
import tempfile

_CANDIDATES = [
    os.environ.get("SVG_BROWSER", ""),
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
]
_NUM = r"([0-9.]+(?:[eE][+-]?[0-9]+)?)"


def _browser():
    for c in _CANDIDATES:
        if c and os.path.exists(c):
            return c
    for name in ("msedge", "chrome", "chromium", "google-chrome"):
        p = shutil.which(name)
        if p:
            return p
    raise RuntimeError("svg_render: no Edge/Chrome found (set SVG_BROWSER)")


def _attr(tag, name):
    """A plain-number (or px) attribute of the root tag, else None (percentages etc. don't count)."""
    m = re.search(r"\s" + name + r"\s*=\s*.(" + _NUM[1:-1] + r")(px)?.", tag)
    return float(m.group(1)) if m and m.group(0)[-1] in "\"'" else None


def _aspect(svg):
    """height / width of the SVG's root element."""
    root = re.search(r"<svg\s[^>]*>", svg, re.S)
    tag = root.group(0) if root else ""
    # the intrinsic size (width/height, as resvg uses it) first, else the viewBox
    w, h = _attr(tag, "width"), _attr(tag, "height")
    if w and h:
        return h / w
    vb = re.search(r"viewBox\s*=\s*.([^\"']+)", tag)
    if vb:
        parts = [float(x) for x in re.split(r"[\s,]+", vb.group(1).strip())]
        if len(parts) == 4 and parts[2] > 0:
            return parts[3] / parts[2]
    return 1.0


def svg_to_bytes(svg_string, width, height=None):
    width = int(width)
    height = int(height) if height else max(1, round(width * _aspect(svg_string)))
    with tempfile.TemporaryDirectory(prefix="svg_render_") as tmp:
        svg_path = os.path.join(tmp, "in.svg")
        with open(svg_path, "w", encoding="utf-8") as f:
            f.write(svg_string)
        html = os.path.join(tmp, "page.html")
        with open(html, "w", encoding="utf-8") as f:
            f.write(
                "<!doctype html><html><head><style>html,body{margin:0;padding:0;background:transparent;"
                "overflow:hidden}img{display:block}</style></head><body>"
                f'<img src="in.svg" width="{width}" height="{height}"></body></html>'
            )
        out = os.path.join(tmp, "out.png")
        subprocess.run(
            [_browser(), "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
             "--disable-extensions", "--hide-scrollbars", "--force-device-scale-factor=1",
             "--default-background-color=00000000", f"--user-data-dir={os.path.join(tmp, 'profile')}",
             f"--window-size={width},{height}", f"--screenshot={out}", "file:///" + html.replace("\\", "/")],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60,
        )
        with open(out, "rb") as f:
            return f.read()
