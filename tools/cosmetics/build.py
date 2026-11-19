# Builds every cosmetic catalog of the game from the rarity folders in assets/sources/cosmetics and, for the
# original art (paths.PRIVATE_COSMETICS: avatars, frames, badges but the flag ones), the private asset root's
# sources/cosmetics. The atlases go to the private exports (paths.PRIVATE_EXPORTS/Cosmetics/atlas):
#
#   avatar/<rarity>/<name>.png   player icons (round portrait discs, no ring); avatar/default/: free, owned by
#                                everyone, the first (by name) worn from the start
#   frame/<rarity>/<name>.png    rings around the avatar: square, the ring's opening (empty) centred and
#                                1/1.5 of the image's width (never trimmed); frame/rank/<tier>.png:
#                                unlocked by reaching that rank tier (Data/Ranks), never sold
#   badge/<rarity>/<name>.png    small icons on the avatar's top-left corner
#   font/<rarity>/<name>.json    { "name": "Oswald", "family": "Oswald" } (a Roblox font family)
#   skin/<rarity>/<name>.png     territory patterns: a mask tiled over the owner's land. Transparent = their own
#                                fill. Only black opaque pixels: a two-tone pattern (black = their colour shaded
#                                by `tone`, or the fixed `accent`). Any other colours: drawn as they are.
#
#   <rarity> is common, uncommon, rare, epic or legendary. Any item may have a <name>.json sidecar:
#   "name" (else the file name, title-cased) and, for skins, "scale" (mask pixels are 2^scale tiles wide),
#   "tone" (-1..1), "accent" ("#RRGGBB"), "alpha" (0..255). "season": "YYYY-MM" makes it a Battle Pass reward
#   of that season (Data/Seasons): its catalog entry carries `season`, so it is never sold (Data/Store), never on
#   a bot, and the Locker shows it only once owned or while its season runs.
#
#   Avatars are auto-fitted first (fit.py avatar_autofit: art reaching outside the disc is scaled in, at most
#   fit.AVATAR_FIT_MAX, or the sidecar's "fit_max"); the build stops and lists every avatar that would need more.
#   An avatar already inside its circle is packed as it is.
#
# Add or replace an item: drop its file in, run this. Retire one: delete its file. Image kinds are packed into
# 1024 px atlases (more atlases when one fills), uploaded through the open Studio (Battlemap's tools/upload.py,
# the ledger skips what is up: only changed atlases go up) and written to src/shared/Assets/Catalog/<Kind>.luau.
# build/contact_<kind>.png shows each kind by rarity for review.
#
# Run: .venv\Scripts\python.exe -I tools\cosmetics\build.py [--no-upload] [--only avatar,frame]
import argparse
import hashlib
import json
import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import fit as fitting  # noqa: E402
import paths  # noqa: E402

GAME = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.join(GAME, "assets", "sources", "cosmetics")
PRIVATE_HERE = os.path.join(paths.PRIVATE_SOURCES, "cosmetics")
OUT_LUAU = os.path.join(GAME, "src", "shared", "Assets", "Catalog")
OUT_PNG = os.path.join(paths.PRIVATE_EXPORTS, "Cosmetics", "atlas")
LEDGER = os.path.join(GAME, "assets", "ledger.json")
ATLAS = 1024

RARITIES = ["common", "uncommon", "rare", "epic", "legendary"]
#: rank tier (Data/Ranks.TIERS id) -> the rarity its frame shows as
RANK_RARITY = {"bronze": "common", "silver": "uncommon", "gold": "rare", "platinum": "epic", "diamond": "epic",
               "master": "legendary", "grandmaster": "legendary"}

#: folder -> (game kind, id prefix, module name, atlas cell px or None)
KINDS = {
    "avatar": ("icon", "icon_", "Avatars", 128),
    "frame": ("frame", "frame_", "Frames", 192),
    "badge": ("badge", "badge_", "Badges", 128),
    "font": ("font", "font_", "Fonts", None),
    "skin": ("skin", "skin_", "Skins", None),
}


def title(stem):
    return stem.replace("_", " ").title()


def sidecar(path):
    p = path[:-4] + ".json" if path.endswith(".png") else path
    if os.path.exists(p):
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    return {}


def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_val(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, list):
        return "{ " + ", ".join(lua_val(x) for x in v) + " }"
    raise TypeError(v)


def source_dir(folder, group):
    """sources/cosmetics/<folder>/<group>: in the private asset root when paths.PRIVATE_COSMETICS says so."""
    return os.path.join(PRIVATE_HERE if paths.is_private_cosmetic(folder, group) else HERE, folder, group)


def scan(folder):
    """The items of one kind: [(rarity, stem, path, extra)] in catalog order (default, rarities, rank)."""
    groups = (["default"] if folder == "avatar" else []) + RARITIES + (["rank"] if folder == "frame" else [])
    ext = ".json" if folder == "font" else ".png"
    rows = []
    for g in groups:
        d = source_dir(folder, g)
        if not os.path.isdir(d):
            continue
        names = sorted(os.listdir(d))
        if g == "rank":  # (lowest tier first)
            names.sort(key=lambda f: list(RANK_RARITY).index(f[:-4]) if f[:-4] in RANK_RARITY else 99)
        for f in names:
            if not f.endswith(ext):
                continue
            stem = f[: -len(ext)]
            extra = {}
            rarity = g
            if g == "default":
                rarity, extra["default"] = "common", True
            elif g == "rank":
                if stem not in RANK_RARITY:
                    sys.exit(f"frame/rank/{f}: not a rank tier ({', '.join(RANK_RARITY)})")
                rarity, extra["rank"] = RANK_RARITY[stem], stem
            rows.append((rarity, stem, os.path.join(d, f), extra))
    return rows


#: path -> its avatar auto-fitted (fitted_avatars fills it before packing)
FITTED = {}


def fitted_avatars(rows):
    """Every avatar auto-fitted (fit.py); stops the build naming each one that can't be."""
    errors = []
    for r in rows:
        im = Image.open(r[2]).convert("RGBA")
        try:
            FITTED[r[2]] = fitting.avatar_autofit(im, sidecar(r[2]).get("fit_max"), "/".join(r[2].replace("\\", "/").split("/")[-3:]))
        except fitting.FitError as e:
            errors.append(str(e))
    if errors:
        sys.exit("avatars that don't fit their circle (scale the art down, or allow it with \"fit_max\" in the "
                 "sidecar):\n  " + "\n  ".join(errors))


def fit(path, cell, trim=True):
    """The image squared and scaled to `cell`. Trimmed to its opaque part first, except frames (their
    opening must stay 1 / FRAME_SCALE of the whole: Data/Cosmetics)."""
    im = FITTED[path] if path in FITTED else Image.open(path).convert("RGBA")
    box = im.getchannel("A").getbbox()
    if box and trim:
        im = im.crop(box)
    s = max(im.size)
    sq = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sq.alpha_composite(im, ((s - im.width) // 2, (s - im.height) // 2))
    return sq.resize((cell, cell), Image.LANCZOS)


def pack(module, rows, cell, trim):
    cols = ATLAS // cell
    per = cols * cols
    atlases, rects = [], []
    for a in range((len(rows) + per - 1) // per):
        chunk = rows[a * per:(a + 1) * per]
        used = (len(chunk) + cols - 1) // cols
        sheet = Image.new("RGBA", (cols * cell, used * cell), (0, 0, 0, 0))
        for k, r in enumerate(chunk):
            x, y = (k % cols) * cell, (k // cols) * cell
            sheet.alpha_composite(fit(r[2], cell, trim), (x, y))
            rects.append((a + 1, x, y))
        p = os.path.join(OUT_PNG, f"{module.lower()}_{a + 1}.png")
        sheet.save(p, optimize=True)
        atlases.append(p)
    return atlases, rects


def upload(files, no_upload):
    if not files:
        return []
    if no_upload:
        known = {r["sha256"]: "rbxassetid://" + r["id"] for r in json.load(open(LEDGER, encoding="utf-8")).values()}
        return [known.get(hashlib.sha256(open(p, "rb").read()).hexdigest(), "") for p in files]
    sys.path.insert(0, os.path.join(GAME, "tools"))
    import upload as studio_upload  # noqa: E402

    got = studio_upload.upload_images(files)
    return [got[os.path.abspath(p)] for p in files]


def skin_fields(path, meta):
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    px = im.load()
    palette = []
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a >= 128 and (r, g, b) not in palette:
                palette.append((r, g, b))
    two_tone = palette in ([], [(0, 0, 0)])
    if not two_tone and len(palette) > 35:
        sys.exit(f"{path}: {len(palette)} colours (35 at most)")
    keys = "123456789abcdefghijklmnopqrstuvwxyz"
    rows = []
    for y in range(h):
        row = ""
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 128:
                row += "."
            elif two_tone:
                row += "#"
            else:
                row += keys[palette.index((r, g, b))]
        rows.append(row)
    out = {"scale": int(meta.get("scale", 0))}
    if two_tone:
        if "accent" in meta:
            out["accent"] = int(str(meta["accent"]).lstrip("#"), 16)
        else:
            out["tone"] = float(meta.get("tone", -0.24))
    else:
        out["colors"] = [(r << 16) | (g << 8) | b for r, g, b in palette]
    if "alpha" in meta:
        out["alpha"] = int(meta["alpha"])
    out["mask"] = rows
    return out


def contact(folder, rows, kind_cell):
    """Every item by rarity row, for review."""
    if kind_cell is None or not rows:
        return
    groups = {}
    for r in rows:
        groups.setdefault("rank" if "rank" in r[3] else ("default" if "default" in r[3] else r[0]), []).append(r)
    order = [g for g in ["default"] + RARITIES + ["rank"] if g in groups]
    wrap = 16
    cs, n = 96, min(wrap, max(len(v) for v in groups.values()))
    lines = sum((len(groups[g]) + wrap - 1) // wrap for g in order)
    sheet = Image.new("RGBA", (110 + n * (cs + 8), lines * (cs + 8) + 8), (20, 24, 36, 255))
    d = ImageDraw.Draw(sheet)
    line = 0
    for g in order:
        d.text((8, 8 + line * (cs + 8) + cs // 2 - 6), g, fill=(220, 220, 220, 255))
        for j, r in enumerate(groups[g]):
            y = 8 + (line + j // wrap) * (cs + 8)
            sheet.alpha_composite(fit(r[2], cs, folder != "frame"), (110 + (j % wrap) * (cs + 8), y))
        line += (len(groups[g]) + wrap - 1) // wrap
    os.makedirs(os.path.join(GAME, "build"), exist_ok=True)
    sheet.save(os.path.join(GAME, "build", f"contact_{folder}.png"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-upload", action="store_true", help="keep the ids already uploaded (by content hash)")
    ap.add_argument("--only", default="", help="comma-separated folders (default: all)")
    args = ap.parse_args()
    only = [s for s in args.only.split(",") if s] or list(KINDS)
    if any(f in paths.PRIVATE_COSMETICS for f in only) and not os.path.isdir(PRIVATE_HERE):
        # (before writing anything: a build without the art would empty the catalogs)
        sys.exit(f"no private asset root ({PRIVATE_HERE}): set BATTLEMAP_PRIVATE_ASSETS, or --only font,skin")
    os.makedirs(OUT_LUAU, exist_ok=True)
    if any(KINDS[f][3] is not None for f in only):
        os.makedirs(OUT_PNG, exist_ok=True)
    for folder in only:
        kind, prefix, module, cell = KINDS[folder]
        rows = scan(folder)
        if folder == "avatar":
            fitted_avatars(rows)
        ids = [prefix + r[1] for r in rows]
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        if dupes:
            sys.exit(f"{folder}: the same name in two rarity folders: {dupes}")
        L = [
            "--!strict",
            f"-- GENERATED by tools/cosmetics/build.py from assets/sources/cosmetics/{folder}/<rarity>/ folders:",
            "-- do not edit by hand (add, replace or delete the files there and run it again).",
            "return {",
        ]
        if cell is not None:
            atlases, rects = pack(module, rows, cell, folder != "frame")
            uris = upload(atlases, args.no_upload)
            missing = [os.path.basename(a) for a, u in zip(atlases, uris) if not u]
            if missing:
                print(f"{folder}: not uploaded yet: {missing}")
            L.append("\tatlases = " + ("{ " + ", ".join(lua_str(u) for u in uris) + " }" if uris else "{}") + ",")
            L.append(f"\tcell = {cell},")
        L.append("\titems = {")
        for k, (rarity, stem, path, extra) in enumerate(rows):
            meta = sidecar(path)
            f = {"id": prefix + stem, "name": meta.get("name") or title(stem), "rarity": rarity}
            f.update(extra)
            if cell is not None:
                a, x, y = rects[k]
                f.update({"atlas": a, "x": x, "y": y})
                if folder == "frame" and meta.get("scale"):
                    # (art reaching past 1.5x the avatar: drawn that much bigger, slice.py)
                    f["scale"] = float(meta["scale"])
            elif folder == "font":
                if not meta.get("family"):
                    sys.exit(f"{path}: no \"family\"")
                f["family"] = meta["family"]
            elif folder == "skin":
                f.update(skin_fields(path, meta))
            if meta.get("season"):
                # (a Battle Pass reward, Data/Seasons; last, so the fields before keep their order)
                f["season"] = str(meta["season"])
            if "mask" in f:
                mask = f.pop("mask")
                body = ", ".join(f"{k} = {lua_val(v)}" for k, v in f.items())
                L.append(f"\t\t{{ {body}, mask = {{")
                L += [f"\t\t\t{lua_str(r)}," for r in mask]
                L.append("\t\t} },")
            else:
                L.append("\t\t{ " + ", ".join(f"{k} = {lua_val(v)}" for k, v in f.items()) + " },")
        L += ["\t},", "}"]
        with open(os.path.join(OUT_LUAU, module + ".luau"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join(L) + "\n")
        contact(folder, rows, cell)
        by = {r: sum(1 for x in rows if x[0] == r) for r in RARITIES}
        print(f"{folder}: {len(rows)} -> Assets/Catalog/{module}.luau  " + " ".join(f"{r}={n}" for r, n in by.items()))


if __name__ == "__main__":
    main()
