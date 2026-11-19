"""Clean BATTLEMAP_Logo_source.png into title_logo.png (1024 wide).

The source has opaque dark fill left inside some letter holes and gaps (B, A, E, P). Everything that is
not the gold letters, their black outline (~14 px) or the drop shadow below (~32 px) becomes transparent;
then the result is cropped to the letters with equal margins and resized.
Run: <Battlemap>/.venv/Scripts/python.exe -I clean_title_logo.py
"""
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import paths  # noqa: E402

# (the logo is the original art: the private asset root)
SRC = os.path.join(paths.PRIVATE_SOURCES, "branding", "BATTLEMAP_Logo_source.png")
OUT = os.path.join(paths.PRIVATE_EXPORTS, "Branding", "title_logo.png")
OUTLINE, SHADOW, PAD, WIDTH = 15, 34, 8, 1024


def dilate(m, steps):
    for _ in range(steps):
        n = m.copy()
        n[1:] |= m[:-1]
        n[:-1] |= m[1:]
        n[:, 1:] |= m[:, :-1]
        n[:, :-1] |= m[:, 1:]
        m = n
    return m


im = Image.open(SRC).convert("RGBA")
a = np.array(im)
lum = a[..., :3].astype(int).mean(-1)
gold = (a[..., 3] > 128) & (lum > 110)
# Drop specks: a gold pixel needs gold around it.
gold = np.array(Image.fromarray(gold.astype(np.uint8) * 255).filter(ImageFilter.MedianFilter(5))) > 127
keep = dilate(gold, OUTLINE)
down = keep.copy()
for _ in range(SHADOW - OUTLINE):
    down[1:] |= down[:-1] & keep[:-1]
    down[1:] |= keep[:-1]
    keep = down.copy()
# Soft edge on the cut.
soft = Image.fromarray(keep.astype(np.uint8) * 255).filter(ImageFilter.GaussianBlur(1.2))
alpha = np.minimum(a[..., 3], np.array(soft))
a[..., 3] = alpha
a[alpha == 0, :3] = 0
out = Image.fromarray(a)

l, t, r, b = Image.fromarray((alpha > 24).astype(np.uint8) * 255).getbbox()
gl, gt, gr, gb = Image.fromarray(gold.astype(np.uint8) * 255).getbbox()
# Centre on the gold letters horizontally, so the visible word sits in the middle of the image.
side = max(gl - l, r - gr) + PAD
l2, r2 = max(0, gl - side), min(out.width, gr + side)
out = out.crop((l2, max(0, t - PAD), r2, min(out.height, b + PAD)))
out = out.resize((WIDTH, round(out.height * WIDTH / out.width)), Image.LANCZOS)
out.save(OUT)
print(out.size, "gold box", (gl, gt, gr, gb), "crop", (l2, r2))
