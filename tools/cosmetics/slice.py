# Cuts the ChatGPT sheets (sheets\<sheet>.png: 3x2 grids) into the rarity folders build.py reads, as
# sheets\sheets.json says: { "<sheet>": { "to": "avatar/common", "names": [6 names or null] } }.
#
#   avatar  each cell's round disc, found by its edge (the circle whose rim has the strongest colour / alpha
#           edge; ChatGPT's "transparent" background is sometimes a painted one), cut out on a transparent
#           background, 512 px.
#   frame   each cell squared to 512 px around the whole ring with the centre cut out: the window is 1/1.5
#           of the image (the avatar's place, Data/Cosmetics.FRAME_SCALE) or less when the ring's art reaches
#           further (its sidecar's "scale": outer / window), plus the background connected to the cell's edge.
#
# Only sheets whose outputs are missing are cut (--force: all). contact sheets: build.py.
# Run: <Battlemap>\.venv\Scripts\python.exe -I slice.py [--force] [sheet ...]
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import paths  # noqa: E402

# (avatars and frames are the original art: the private asset root, paths.PRIVATE_COSMETICS)
HERE = os.path.join(paths.PRIVATE_SOURCES, "cosmetics")
# (the raw ChatGPT sheets are development material, outside the repository)
SHEETS = os.path.join(paths.DEV, "cosmetics", "sheets")
OUT = 512
FRAME_SCALE = 1.5


def cells(im):
    w, h = im.size
    cw, ch = w // 3, h // 2
    for j in range(2):
        for i in range(3):
            yield im.crop((i * cw, j * ch, (i + 1) * cw, (j + 1) * ch))


def edge_map(cell):
    a = np.asarray(cell.convert("RGBA"), dtype=np.float32)
    g = np.zeros(a.shape[:2], np.float32)
    for c in range(4):
        ch = a[:, :, c] * (2.0 if c == 3 else 1.0)
        gx = np.abs(np.diff(ch, axis=1, prepend=ch[:, :1]))
        gy = np.abs(np.diff(ch, axis=0, prepend=ch[:1, :]))
        g += gx + gy
    return g


def find_disc(cell):
    """(cx, cy, r) of the cell's disc: the circle (near the centre, 40-47% of the cell) along whose rim the
    edge strength is highest."""
    s = cell.width
    g = edge_map(cell)
    ang = np.linspace(0, 2 * np.pi, 720, endpoint=False)
    cos, sin = np.cos(ang), np.sin(ang)
    best = (-1, s / 2, s / 2, s * 0.44)

    def score(cx, cy, r):
        xs = np.clip((cx + r * cos).astype(int), 0, s - 1)
        ys = np.clip((cy + r * sin).astype(int), 0, s - 1)
        v = g[ys, xs]
        return float(np.median(v)) + float(v.mean()) * 0.25

    for cx in range(int(s * 0.44), int(s * 0.56) + 1, 4):
        for cy in range(int(s * 0.44), int(s * 0.56) + 1, 4):
            for r in range(int(s * 0.40), int(s * 0.47) + 1, 3):
                v = score(cx, cy, r)
                if v > best[0]:
                    best = (v, cx, cy, r)
    _, cx, cy, r = best
    for cx2 in range(cx - 3, cx + 4):
        for cy2 in range(cy - 3, cy + 4):
            for r2 in range(r - 3, r + 4):
                v = score(cx2, cy2, r2)
                if v > best[0]:
                    best = (v, cx2, cy2, r2)
    return best[1], best[2], best[3]


def cut_avatar(cell):
    cx, cy, r = find_disc(cell)
    r -= 2  # (inside the rim's anti-aliased edge)
    box = (cx - r, cy - r, cx + r, cy + r)
    sq = cell.convert("RGBA").crop(box).resize((OUT, OUT), Image.LANCZOS)
    big = Image.new("L", (OUT * 4, OUT * 4), 0)
    ImageDraw.Draw(big).ellipse((2, 2, OUT * 4 - 2, OUT * 4 - 2), fill=255)
    m = big.resize((OUT, OUT), Image.LANCZOS)
    a = np.minimum(np.asarray(sq.getchannel("A")), np.asarray(m))
    # (a painted background: the disc itself is opaque, so the disc mask alone decides)
    if np.asarray(sq.getchannel("A")).mean() > 250:
        a = np.asarray(m)
    out = sq.copy()
    out.putalpha(Image.fromarray(a.astype(np.uint8)))
    return out


def clear_background(im):
    """A painted background (flat, or a checkerboard: the colours along the cell's border) made transparent
    where it connects to the border or to the centre (the ring's window)."""
    n = im.width
    a = np.asarray(im.getchannel("A")).copy()
    if a.mean() <= 250:
        return a
    rgb = np.asarray(im.convert("RGB")).astype(int)
    border = np.concatenate([rgb[:3].reshape(-1, 3), rgb[-3:].reshape(-1, 3), rgb[:, :3].reshape(-1, 3),
                             rgb[:, -3:].reshape(-1, 3)])
    q = (border // 12) * 12
    keys, counts = np.unique(q, axis=0, return_counts=True)
    bg = keys[counts > len(border) * 0.05] + 6
    near = np.min(np.abs(rgb[:, :, None, :] - bg[None, None]).sum(-1), axis=2) < 90
    seen = np.zeros_like(near)
    stack = [(y, x) for y in (0, n - 1) for x in range(n)] + [(y, x) for x in (0, n - 1) for y in range(n)]
    c = n // 2
    stack += [(y, x) for y in range(c - 20, c + 20) for x in range(c - 20, c + 20)]
    while stack:
        y, x = stack.pop()
        if 0 <= y < n and 0 <= x < n and near[y, x] and not seen[y, x]:
            seen[y, x] = True
            stack += [(y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)]
    a[seen] = 0
    return a


def find_opening(a):
    """(cx, cy, r) of the ring's window: from the cell's centre, where each of 360 rays first meets the ring."""
    n = a.shape[0]
    hits = []
    for t in np.linspace(0, 2 * np.pi, 360, endpoint=False):
        for r in range(int(n * 0.12), int(n * 0.49)):
            x, y = int(n / 2 + r * np.cos(t)), int(n / 2 + r * np.sin(t))
            if a[y, x] > 128:
                hits.append((x, y))
                break
    h = np.array(hits, float)
    cx, cy = h.mean(0)
    r = float(np.median(np.hypot(h[:, 0] - cx, h[:, 1] - cy)))
    return cx, cy, r


def cut_frame(cell):
    """The ring scaled so its window is the avatar's place: 1 / FRAME_SCALE of the image, centred; inside it
    cleared (a 2 px soft edge)."""
    im = cell.convert("RGBA")
    s = min(im.size)
    im = im.crop(((im.width - s) // 2, (im.height - s) // 2, (im.width - s) // 2 + s, (im.height - s) // 2 + s))
    im.putalpha(Image.fromarray(clear_background(im)))
    a0 = np.asarray(im.getchannel("A"))
    cx, cy, r = find_opening(a0)
    # (2026-11-04) the whole ring, ornaments too: at least FRAME_SCALE of the window, more when the art
    # reaches further (the frame's own `scale`, in its sidecar: Data/Cosmetics draws it that much bigger)
    yy0, xx0 = np.mgrid[0:a0.shape[0], 0:a0.shape[1]]
    reach = np.hypot(xx0 - cx, yy0 - cy)[a0 > 24]
    outer = float(np.percentile(reach, 99.9)) if reach.size else 0.0
    w = r * 1.02  # (the window a hair inside the avatar's edge: no gap)
    half = max(w * FRAME_SCALE, outer * 1.03)
    pad = Image.new("RGBA", (im.width * 2, im.height * 2), (0, 0, 0, 0))
    pad.alpha_composite(im, (im.width // 2, im.height // 2))
    ox, oy = cx + im.width // 2, cy + im.height // 2
    im = pad.crop((int(ox - half), int(oy - half), int(ox + half), int(oy + half))).resize((OUT, OUT), Image.LANCZOS)
    a = np.asarray(im.getchannel("A")).astype(float)
    yy, xx = np.mgrid[0:OUT, 0:OUT]
    d = np.hypot(xx - OUT / 2 + 0.5, yy - OUT / 2 + 0.5)
    scale = half / w
    hole = np.clip((d - OUT / 2 / scale + 1) / 2.0, 0, 1)
    im.putalpha(Image.fromarray((a * hole).astype(np.uint8)))
    im.info["frame_scale"] = round(scale, 3)
    return im


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    ap.add_argument("only", nargs="*")
    args = ap.parse_args()
    plan = json.load(open(os.path.join(SHEETS, "sheets.json"), encoding="utf-8"))
    for sheet, spec in plan.items():
        if sheet.startswith("_") or (args.only and sheet not in args.only):
            continue
        dst = os.path.join(HERE, *spec["to"].split("/"))
        os.makedirs(dst, exist_ok=True)
        names = spec["names"]
        todo = [n for n in names if n and (args.force or not os.path.exists(os.path.join(dst, n + ".png")))]
        if not todo:
            continue
        im = Image.open(os.path.join(SHEETS, spec.get("sheet", sheet) + ".png"))
        cut = cut_frame if spec["to"].startswith("frame") else cut_avatar
        for name, cell in zip(names, cells(im)):
            if name in todo:
                out = cut(cell)
                out.save(os.path.join(dst, name + ".png"))
                sc = out.info.get("frame_scale")
                if sc is not None:
                    # (the sidecar keeps any other fields; scale 1.5 is the default and needs none)
                    side = os.path.join(dst, name + ".json")
                    meta = json.load(open(side, encoding="utf-8")) if os.path.exists(side) else {}
                    if sc > FRAME_SCALE + 0.01:
                        meta["scale"] = sc
                    else:
                        meta.pop("scale", None)
                    if meta:
                        json.dump(meta, open(side, "w", encoding="utf-8"))
                    elif os.path.exists(side):
                        os.remove(side)
        print(f"{sheet}: {len(todo)} -> {spec['to']}")


if __name__ == "__main__":
    main()
