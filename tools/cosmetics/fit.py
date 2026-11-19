# Fitting new cosmetic art to the game's shapes (2026-11-18), used by build.py and the art import:
#
#   avatars  auto-fit (build.py runs it on EVERY avatar before packing): a portrait whose opaque pixels reach
#            outside its painted disc (a feather, a hand, a lantern) is scaled down just enough to bring them
#            inside: the new circle is the smallest one around the disc and everything that pokes out of it (so
#            it may sit a little off the disc's centre, towards what pokes out), at most AVATAR_FIT_MAX smaller
#            than the disc (a sidecar's "fit_max" may allow more for one item); beyond that it fails and names
#            the file. The thin rim band that leaves is filled with a soft, slightly enlarged and blurred copy of
#            the picture itself (its own background), then the circle is cut with the same mask slice.py's
#            cut_avatar uses. An avatar that is already a cut disc (every slice.py one: its square filled by its
#            circle, nothing outside it) comes back untouched: the same image object, so its atlas cell is
#            byte-identical.
#   frames   normalise_frame: the ring's body (inner edge to the outer edge of its band, ornaments aside) is
#            stretched radially so its outer / inner ratio is the existing frames' median (measure_frames), then
#            slice.py's cut_frame squares it with its window at the avatar's place (its "scale" sidecar when the
#            ornaments reach further).
#
# Run: .venv\Scripts\python.exe -I tools\cosmetics\fit.py measure     (the existing frames' and avatars' numbers)
import glob
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slice as cut  # noqa: E402  (the sheet cutter: its frame cut and its avatar mask)

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import paths  # noqa: E402

# (avatars and frames are the original art: the private asset root, paths.PRIVATE_COSMETICS)
HERE = os.path.join(paths.PRIVATE_SOURCES, "cosmetics")
#: the most an avatar may be scaled down to bring its art inside its circle (a share of its size)
AVATAR_FIT_MAX = 0.10
#: opaque = alpha above this; "inside" allows this many px past the circle (anti-aliasing)
ALPHA_ON = 24
EDGE_PX = 1.5
#: the background fill: the picture enlarged this much past the disc, blurred this share of the output size
FILL_ENLARGE = 1.06
FILL_BLUR = 0.012


class FitError(ValueError):
    pass


def circle_mask(n):
    """The avatar disc's alpha at n px: slice.cut_avatar's mask (drawn 4x, scaled down)."""
    big = Image.new("L", (n * 4, n * 4), 0)
    ImageDraw.Draw(big).ellipse((2, 2, n * 4 - 2, n * 4 - 2), fill=255)
    return big.resize((n, n), Image.LANCZOS)


def _edge_radius(a, cx, cy, rays=720):
    """Per ray from (cx, cy): the radius where the opaque disc first ends."""
    h, w = a.shape
    rmax = int(np.hypot(w, h) / 2) + 2
    rs = np.arange(rmax)
    out = []
    for t in np.linspace(0, 2 * np.pi, rays, endpoint=False):
        xs = (cx + rs * np.cos(t)).astype(int)
        ys = (cy + rs * np.sin(t)).astype(int)
        ok = (xs >= 0) & (xs < w) & (ys >= 0) & (ys < h)
        r_ok = rs[ok]
        off = np.where(a[ys[ok], xs[ok]] <= 128)[0]
        r = r_ok[off[0]] if len(off) else r_ok[-1]
        out.append((cx + r * np.cos(t), cy + r * np.sin(t), r))
    return np.array(out)


def find_disc(a):
    """(cx, cy, r) of an avatar's painted disc: a circle fitted to its edge, rays that leave it far (art poking
    out of the disc) left out."""
    h, w = a.shape
    cx, cy = w / 2, h / 2
    r = min(w, h) / 2
    for _ in range(4):
        p = _edge_radius(a, cx, cy)
        med = np.median(p[:, 2])
        q = p[np.abs(p[:, 2] - med) < med * 0.02]
        if len(q) < 30:
            break
        A = np.c_[2 * q[:, 0], 2 * q[:, 1], np.ones(len(q))]
        b = q[:, 0] ** 2 + q[:, 1] ** 2
        sx, sy, c = np.linalg.lstsq(A, b, rcond=None)[0]
        cx, cy, r = sx, sy, float(np.sqrt(c + sx * sx + sy * sy))
    return cx, cy, r


def _inside_inscribed(a):
    h, w = a.shape
    if h != w:
        return False
    yy, xx = np.mgrid[0:h, 0:w]
    d = np.hypot(xx + 0.5 - w / 2, yy + 0.5 - h / 2)
    return not bool(((a > ALPHA_ON) & (d > w / 2 + EDGE_PX)).any())


def _is_cut_disc(a):
    """Already a cut avatar: nothing outside the square's inscribed circle, and its art reaching that circle's
    rim (opaque 3 px inside it on at least half the rays; the cut ones measure 59 % and up, their dents are art,
    and a disc smaller than its square 38 % and down)."""
    if not _inside_inscribed(a):
        return False
    n = a.shape[0]
    r = n / 2 - 3
    t = np.linspace(0, 2 * np.pi, 360, endpoint=False)
    xs = np.clip((n / 2 + r * np.cos(t)).astype(int), 0, n - 1)
    ys = np.clip((n / 2 + r * np.sin(t)).astype(int), 0, n - 1)
    return float((a[ys, xs] > 128).mean()) >= 0.5


def _enclosing(points, cx, cy, r):
    """The smallest circle (x, y, radius) around `points` and the disc (cx, cy, r): a search from the disc's
    centre, coarse to fine."""
    pts = points
    if len(pts) > 40000:
        pts = pts[:: len(pts) // 40000 + 1]

    def reach(x, y):
        return max(float(np.hypot(pts[:, 0] - x, pts[:, 1] - y).max()), float(np.hypot(x - cx, y - cy)) + r)

    bx, by, best = cx, cy, reach(cx, cy)
    for step in (8.0, 2.0, 0.5):
        moved = True
        while moved:
            moved = False
            for dx, dy in ((step, 0), (-step, 0), (0, step), (0, -step), (step, step), (-step, -step), (step, -step),
                           (-step, step)):
                v = reach(bx + dx, by + dy)
                if v < best - 1e-6:
                    bx, by, best, moved = bx + dx, by + dy, v, True
    return bx, by, best


def _premul_blur(im, radius):
    a = np.asarray(im, dtype=np.float32) / 255.0
    rgb = a[:, :, :3] * a[:, :, 3:4]
    chans = [Image.fromarray((np.clip(c, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(radius))
             for c in (rgb[:, :, 0], rgb[:, :, 1], rgb[:, :, 2], a[:, :, 3])]
    p = np.stack([np.asarray(c, dtype=np.float32) / 255.0 for c in chans], axis=2)
    al = p[:, :, 3:4]
    rgb = np.where(al > 1e-4, p[:, :, :3] / np.maximum(al, 1e-4), 0)
    return Image.fromarray((np.clip(np.concatenate([rgb, al], axis=2), 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")


def avatar_autofit(im, fit_max=None, name="", out=512):
    """`im` (RGBA) inside its circle: unchanged (the same object) when it is already, else scaled down about its
    disc's centre to bring every opaque pixel inside, the rim filled, the circle mask applied; `out` px square.
    FitError when that takes more than fit_max (AVATAR_FIT_MAX)."""
    limit = AVATAR_FIT_MAX if fit_max is None else float(fit_max)
    a = np.asarray(im.getchannel("A"))
    if _is_cut_disc(a):
        return im
    cx, cy, r = find_disc(a)
    ys, xs = np.nonzero(a > ALPHA_ON)
    pts = np.c_[xs + 0.5, ys + 0.5].astype(np.float64)
    ex, ey, er = _enclosing(pts, cx, cy, r) if len(pts) else (cx, cy, r)
    if er <= r + EDGE_PX:
        ex, ey, er = cx, cy, r
    k = r / er
    if 1.0 - k > limit + 1e-9:
        raise FitError(f"{name}: its art reaches outside its {r:.0f} px disc: the smallest circle around both is "
                       f"{er:.0f} px, it would shrink {(1 - k) * 100:.1f} % (at most {limit * 100:.0f} %)")
    R = out / 2

    def placed(scale, ox, oy):
        # the picture scaled by `scale` (R px for every px of the disc's radius) with (ox, oy) on the centre
        s = scale * R / r
        w, h = max(1, round(im.width * s)), max(1, round(im.height * s))
        big = im.resize((w, h), Image.LANCZOS)
        canvas = Image.new("RGBA", (out + 2 * w, out + 2 * h), (0, 0, 0, 0))
        canvas.alpha_composite(big, (w + round(R - ox * s), h + round(R - oy * s)))
        return canvas.crop((w, h, w + out, h + out))

    # the fill: the picture with its disc a little past the circle, blurred as much as the band is wide (no edge
    # of it shows through); the portrait: the smallest circle around its art on the circle
    band = R * (1.0 - k) + R * k * float(np.hypot(ex - cx, ey - cy)) / r
    fill = _premul_blur(placed(FILL_ENLARGE, cx, cy), max(out * FILL_BLUR, band * 0.8))
    pic = placed(k, ex, ey)
    comp = Image.new("RGBA", (out, out), (0, 0, 0, 0))
    comp.alpha_composite(fill)
    comp.alpha_composite(pic)
    # (the disc is opaque now: the circle mask alone decides, as slice.cut_avatar does for a painted disc)
    comp.putalpha(circle_mask(out))
    return comp


def _ring(a):
    """(cx, cy, window radius, body outer radius) of a frame's ring: slice.find_opening's window, and the
    median over rays of where the band that starts there ends."""
    n = a.shape[0]
    cx, cy, r = cut.find_opening(a)
    outs = []
    for t in np.linspace(0, 2 * np.pi, 360, endpoint=False):
        inside, last = False, None
        for rr in range(int(r * 0.9), int(n * 0.71)):
            x, y = int(cx + rr * np.cos(t)), int(cy + rr * np.sin(t))
            if not (0 <= x < a.shape[1] and 0 <= y < a.shape[0]):
                break
            if a[y, x] > 128:
                inside, last = True, rr
            elif inside:
                break
        if last:
            outs.append(last)
    return cx, cy, r, float(np.median(outs)) if outs else r * 1.4


def measure_frames(skip_season=True):
    """The existing frames' ring body: the median outer / inner radius."""
    ratios = []
    for p in sorted(glob.glob(os.path.join(HERE, "frame", "*", "*.png"))):
        side = p[:-4] + ".json"
        meta = json.load(open(side, encoding="utf-8")) if os.path.exists(side) else {}
        if skip_season and meta.get("season"):
            continue
        a = np.asarray(Image.open(p).convert("RGBA").getchannel("A"))
        _, _, ri, ro = _ring(a)
        ratios.append(ro / ri)
    return float(np.median(ratios))


def normalise_frame(im, ratio):
    """A frame's art (RGBA, its ring around a transparent window) stretched radially so its band's outer /
    inner radius, measured on the cut frame as on the existing ones, is `ratio`; then cut as slice.cut_frame
    cuts every frame: (512 px image, its scale)."""
    want = ratio
    for _ in range(3):
        res, scale = _stretch_and_cut(im, want)
        _, _, ri, ro = _ring(np.asarray(res.getchannel("A")))
        got = ro / ri
        if abs(got - ratio) < 0.005:
            break
        # (the cut clears its window a little wider than the art's: aim off by what it took)
        want *= ratio / got
    return res, scale


def _stretch_and_cut(im, ratio):
    im = im.convert("RGBA")
    s = min(im.size)
    im = im.crop(((im.width - s) // 2, (im.height - s) // 2, (im.width - s) // 2 + s, (im.height - s) // 2 + s))
    if s > 1024:
        # (the cut is 512 px: 1024 is plenty, and keeps the remap's arrays small)
        im, s = im.resize((1024, 1024), Image.LANCZOS), 1024
    a = np.asarray(im.getchannel("A"))
    cx, cy, ri, ro = _ring(a)
    want = ri * ratio
    if abs(ro - want) > 0.5:
        # every radius past the window's edge moves by the same factor (ornaments with the band)
        f = (ro - ri) / (want - ri)
        n = int(s * 1.3)
        src = np.asarray(im, dtype=np.float32)
        yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
        ox, oy = cx + (n - s) / 2, cy + (n - s) / 2
        dx, dy = xx + 0.5 - ox, yy + 0.5 - oy
        rho = np.hypot(dx, dy)
        rs = np.where(rho > ri, ri + (rho - ri) * f, rho)
        k = np.where(rho > 1e-6, rs / np.maximum(rho, 1e-6), 1.0)
        sx, sy = cx + dx * k - 0.5, cy + dy * k - 0.5
        # bilinear, premultiplied
        x0, y0 = np.floor(sx).astype(int), np.floor(sy).astype(int)
        fx, fy = (sx - x0)[..., None], (sy - y0)[..., None]
        pm = src.copy()
        pm[:, :, :3] *= pm[:, :, 3:4] / 255.0

        def at(x, y):
            ok = (x >= 0) & (x < s) & (y >= 0) & (y < s)
            v = pm[np.clip(y, 0, s - 1), np.clip(x, 0, s - 1)]
            return v * ok[..., None]

        v = (at(x0, y0) * (1 - fx) * (1 - fy) + at(x0 + 1, y0) * fx * (1 - fy) + at(x0, y0 + 1) * (1 - fx) * fy
             + at(x0 + 1, y0 + 1) * fx * fy)
        al = v[:, :, 3:4]
        rgb = np.where(al > 0.5, v[:, :, :3] / np.maximum(al, 1e-3) * 255.0, 0)
        out = np.concatenate([rgb, al], axis=2)
        big = Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8), "RGBA")
        # (back to a square around the window's centre, room for what grew)
        im = big
    res = cut.cut_frame(im)
    return res, res.info.get("frame_scale")


def main():
    if sys.argv[1:2] == ["measure"]:
        print(f"frames: ring outer / inner median {measure_frames():.3f}")
        bad = []
        for p in sorted(glob.glob(os.path.join(HERE, "avatar", "*", "*.png"))):
            im = Image.open(p).convert("RGBA")
            if not _is_cut_disc(np.asarray(im.getchannel("A"))):
                bad.append(os.path.relpath(p, HERE))
        print(f"avatars that aren't a cut disc yet (auto-fit works on them): {bad or 'none'}")
        return
    print(__doc__ or "fit.py measure")


if __name__ == "__main__":
    main()
