#!/usr/bin/env python3
"""The asset ledger (assets/ledger.json): one row per uploaded file, and the checks that keep it true.

  python tools/ledger.py check        fails on anything below; CI runs it (standard library only)
  python tools/ledger.py doc          rewrites the generated table in ASSETS.md
  python tools/ledger.py fill         sets licence / source / ai on rows from RULES
  python tools/ledger.py provenance   rewrites assets/licenses/third_party/PROVENANCE.csv from the files
  python tools/ledger.py refresh      asks Roblox for each row's moderation state (published place in Studio)

check:
  * every rbxassetid in src has a row, and every row's id is used in src
  * every file in assets/exports has a row with the same hash, and every row has its file
  * private rows (the original art, paths.PRIVATE_PREFIXES): AI-art licence rows must be private; their files are
    checked in the private asset root (paths.PRIVATE_EXPORTS) when it is there, skipped when not (CI, a fresh clone)
  * every row has a known licence; third-party audio takes its licence from PROVENANCE.csv
  * PROVENANCE.csv matches the files, and every third-party file is listed
  * credits the licences require are in the game (REQUIRED_CREDITS, NOTICES)
  * the earlier project's names appear nowhere but in the licence notice
"""
import csv
import hashlib
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths  # noqa: E402

AGPL = "AGPL-3.0"
AI = "AI art, ChatGPT (copyright status unclear)"
#: path prefix inside exports -> (licence, source, ai-generated). First match wins. Audio is looked up instead.
RULES = [
    ("Flags/", "Public domain / CC0", "assets/sources/flags/SOURCE.txt", False),
    ("Cosmetics/atlas/avatars", AI, "assets/sources/cosmetics/avatar", True),
    ("Cosmetics/atlas/frames", AI, "assets/sources/cosmetics/frame", True),
    ("Cosmetics/atlas/badges", "Flags public domain; the others " + AI, "assets/sources/cosmetics/badge", True),
    ("Cosmetics/crate/", AGPL, "assets/sources/crate", False),
    ("Cosmetics/skins/", AGPL, "tools/assets/make_skin_previews.py", False),
    ("Branding/title_logo", AI, "assets/sources/branding", True),
    ("Branding/", AGPL, "tools/assets/make_branding.py", False),
    ("Arsenal/", AGPL, "tools/assets/make_arsenal_art.py, make_arsenal_renders.py", False),
    ("Map/fx/", AGPL, "tools/assets/make_map_fx.py", False),
    ("Map/rails/", AGPL, "tools/assets/make_rail_art.py", False),
    ("Map/sprites/", AGPL, "assets/sources/map_sprites", False),
    ("Map/thumbs/", AGPL + " (from public-domain map data)", "tools/assets/make_map_thumbs.py", False),
    ("UI/icons/", AGPL, "assets/sources/icons", False),
    ("UI/kit/", AGPL, "tools/uikit/make_textures.py", False),
    ("UI/shapes/", AGPL, "tools/ui/make_shapes.py", False),
]
#: exports not uploaded on purpose (make_branding.py writes it; set by hand in the experience's settings)
NOT_UPLOADED = {"Branding/experience_icon_512.png"}
#: licence -> text HelpOverlay.LEGAL must hold when a row has that licence
REQUIRED_CREDITS = {
    "CC BY-SA 4.0": ["OpenFront", "CC BY-SA 4.0"],
    "CC BY 4.0": ["joshuaempyre", "CC BY 4.0"],
}
#: LICENSE's added terms and the AGPL's notices: file -> text it must hold
NOTICES = {
    "src/client/UI/HelpOverlay.luau": ["© OpenFront and Contributors", "modified version", "ABSOLUTELY NO WARRANTY"],
    "src/client/UI/TitleScreen.luau": ["© OpenFront and Contributors"],
}
LEGACY = re.compile(r"roworld|snick co|lukechatton|airfront|rofront", re.I)
#: the licence notice names it, as the AGPL requires
LEGACY_OK = {"src/client/UI/HelpOverlay.luau", "tools/ledger.py"}
TEXT = (".luau", ".py", ".md", ".json", ".toml", ".yml", ".js")
THIRD_PARTY = os.path.join(paths.SOURCES, "third_party")
PROOFS = os.path.join(paths.LICENSES, "third_party")
PROVENANCE = os.path.join(PROOFS, "PROVENANCE.csv")


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def load():
    with open(paths.LEDGER, encoding="utf-8") as f:
        return json.load(f)


def save(ledger):
    tmp = paths.LEDGER + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(ledger, f, indent=1, sort_keys=True)
    os.replace(tmp, paths.LEDGER)


def walk(root):
    for dp, _, files in os.walk(root):
        for name in files:
            yield os.path.relpath(os.path.join(dp, name), root).replace(os.sep, "/")


def provenance_rows():
    with open(PROVENANCE, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def audio_info(rel):
    """(licence, source) of an Audio/bm_<key>.<ext> row, through game_audio's tables and PROVENANCE.csv."""
    sys.path.insert(0, os.path.join(paths.ROOT, "tools", "assets"))
    import game_audio

    key = os.path.splitext(os.path.basename(rel))[0][3:]
    if key.startswith("music_"):
        track = game_audio.TRACKS.get(key[6:])
        source = track[0] if track else None
    else:
        source = game_audio.SFX.get(key)
    if source is None:
        return None, None
    for row in provenance_rows():
        if row["path"] == source:
            return row["licence"], "assets/sources/third_party/" + source
    return None, "assets/sources/third_party/" + source


def fill_row(rel, row):
    """Licence, source and AI flag of a row, from RULES (or the audio tables)."""
    if rel.startswith("Audio/"):
        licence, source = audio_info(rel)
        row.update(license=licence or "UNKNOWN", source=source or "UNKNOWN", ai=False)
        row.pop("private", None)
        return row
    if paths.is_private(rel):
        row["private"] = True
    else:
        row.pop("private", None)
    for prefix, licence, source, ai in RULES:
        if rel.startswith(prefix):
            row.update(license=licence, source=source, ai=ai)
            return row
    row.update(license="UNKNOWN", source="UNKNOWN", ai=False)
    return row


def src_files():
    for rel in walk(os.path.join(paths.ROOT, "src")):
        if rel.endswith(".luau"):
            yield os.path.join(paths.ROOT, "src", rel)


def check():
    errors = []
    ledger = load()
    used = {}
    for path in src_files():
        with open(path, encoding="utf-8", errors="ignore") as f:
            # (short ids such as rbxassetid://123 are dev placeholders)
            for aid in re.findall(r"rbxassetid://(\d{9,})", f.read()):
                used.setdefault(aid, os.path.relpath(path, paths.ROOT))
    known = {row["id"] for row in ledger.values()}
    for aid, where in sorted(used.items()):
        if aid not in known:
            errors.append(f"{where}: rbxassetid://{aid} is not in the ledger")
    private_here = paths.has_private()
    notes = []
    for rel, row in sorted(ledger.items()):
        if row["id"] not in used:
            errors.append(f"{rel}: id {row['id']} is not used in src (remove the row and the file)")
        private = bool(row.get("private"))
        if private != paths.is_private(rel):
            errors.append(f"{rel}: \"private\" is {private}, paths.PRIVATE_PREFIXES says {not private} (ledger.py fill)")
        if AI in row.get("license", "") and not private:
            errors.append(f"{rel}: AI art must be private (paths.PRIVATE_PREFIXES), not in the public repo")
        if row.get("license", "UNKNOWN") == "UNKNOWN":
            errors.append(f"{rel}: no licence (RULES in tools/ledger.py, or PROVENANCE.csv for audio)")
        if private and not private_here:
            continue  # (no private asset root here: its id, licence and credits are still checked)
        path = os.path.join(paths.PRIVATE_EXPORTS if private else paths.EXPORTS, *rel.split("/"))
        where = "the private exports" if private else "assets/exports"
        if not os.path.exists(path):
            errors.append(f"{rel}: the file is missing from {where}")
        elif sha(path) != row["sha256"]:
            errors.append(f"{rel}: the file changed since its upload (upload it again)")
    for rel in sorted(walk(paths.EXPORTS)):
        if rel not in ledger and rel not in NOT_UPLOADED:
            errors.append(f"{rel}: in assets/exports with no ledger row (upload it, or take it out of the repo)")
        elif paths.is_private(rel):
            notes.append(f"{rel}: private art still in assets/exports (it belongs in {paths.PRIVATE_EXPORTS} only)")
    if private_here:
        for rel in sorted(walk(paths.PRIVATE_EXPORTS)):
            if rel not in ledger:
                errors.append(f"{rel}: in the private exports with no ledger row (upload it, or delete it)")
            elif not paths.is_private(rel):
                errors.append(f"{rel}: in the private exports but not private (paths.PRIVATE_PREFIXES)")

    listed = set()
    for row in provenance_rows():
        listed.add(row["path"])
        for root in (THIRD_PARTY, PROOFS):
            path = os.path.join(root, *row["path"].split("/"))
            if os.path.exists(path):
                if sha(path) != row["sha256"]:
                    errors.append(f"PROVENANCE.csv: {row['path']} has a different hash")
                break
        else:
            errors.append(f"PROVENANCE.csv: {row['path']} is missing")
    for rel in walk(THIRD_PARTY):
        if rel not in listed:
            errors.append(f"assets/sources/third_party/{rel} is not in PROVENANCE.csv")

    with open(os.path.join(paths.ROOT, "src/client/UI/HelpOverlay.luau"), encoding="utf-8") as f:
        help_text = f.read()
    for licence, words in REQUIRED_CREDITS.items():
        if any(row.get("license") == licence for row in ledger.values()):
            errors += [f"HelpOverlay.LEGAL must credit {w!r} ({licence})" for w in words if w not in help_text]
    for rel, words in NOTICES.items():
        with open(os.path.join(paths.ROOT, rel), encoding="utf-8") as f:
            text = f.read()
        errors += [f"{rel}: the licence notice {w!r} is gone" for w in words if w not in text]

    for top in ("src", "tests", "tools", ".github"):
        base = os.path.join(paths.ROOT, top)
        for rel in walk(base):
            full = top + "/" + rel
            if rel.endswith(TEXT) and full not in LEGACY_OK and "__pycache__" not in rel:
                with open(os.path.join(base, rel), encoding="utf-8", errors="ignore") as f:
                    if LEGACY.search(f.read()):
                        errors.append(f"{full}: names the earlier project")
    for name in ("README.md", "ASSETS.md", "CLAUDE.md"):
        path = os.path.join(paths.ROOT, name)
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                if LEGACY.search(f.read()):
                    errors.append(f"{name}: names the earlier project")

    for line in notes:
        print("NOTE", line)
    for line in errors:
        print("ERROR", line)
    n_private = sum(1 for row in ledger.values() if row.get("private"))
    state = "checked in " + paths.PRIVATE if private_here else "files not checked: no " + paths.PRIVATE_EXPORTS
    print(f"ledger: {len(ledger)} rows ({n_private} private, {state}), {len(used)} ids in src, {len(errors)} errors")
    return 1 if errors else 0


def doc():
    groups = {}
    for rel, row in load().items():
        parts = rel.split("/")
        where = "/".join(parts[:2]) if len(parts) > 2 else parts[0]
        # (a sound's source file is in the sheet; the table names its pack)
        source = "/".join(row["source"].split("/")[:4]) if rel.startswith("Audio/") else row["source"]
        g = groups.setdefault((where, row["license"], source, bool(row.get("private"))), [0, row.get("ai", False)])
        g[0] += 1
    lines = ["| Exports | Files | Licence | Made from | AI | Private |", "|---|---|---|---|---|---|"]
    for (where, licence, source, private), (n, ai) in sorted(groups.items()):
        lines.append(f"| `{where}` | {n} | {licence} | `{source}` | {'yes' if ai else ''} | {'yes' if private else ''} |")
    path = os.path.join(paths.ROOT, "ASSETS.md")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    start, end = "<!-- ledger:start (tools/ledger.py doc) -->", "<!-- ledger:end -->"
    a, b = text.index(start) + len(start), text.index(end)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text[:a] + "\n" + "\n".join(lines) + "\n" + text[b:])
    os.replace(tmp, path)
    print(f"ASSETS.md: {len(lines) - 2} groups")


def write_provenance():
    licence = {}
    for row in provenance_rows():
        licence.setdefault(row["folder"], row["licence"])
    rows = []
    for root in (THIRD_PARTY, PROOFS):
        for rel in walk(root):
            if "/" not in rel:
                continue
            folder = rel.split("/", 1)[0]
            if folder == "LICENSES":
                continue
            path = os.path.join(root, rel)
            rows.append({"folder": folder, "path": rel, "bytes": os.path.getsize(path), "sha256": sha(path),
                         "licence": licence.get(folder, "UNKNOWN")})
    rows.sort(key=lambda r: r["path"])
    with open(PROVENANCE, "w", encoding="utf-8", newline="") as f:
        out = csv.DictWriter(f, ["folder", "path", "bytes", "sha256", "licence"], lineterminator="\n")
        out.writeheader()
        out.writerows(rows)
    print(len(rows), "files in PROVENANCE.csv")


def refresh():
    import upload

    session = upload.Session()
    try:
        ledger = load()
        for rel, row in sorted(ledger.items()):
            info = session.call("GET", f"/assets/v1/assets/{row['id']}?readMask=moderationResult,state,displayName",
                                scopes=["asset:read"])
            row["moderation"] = (info.get("moderationResult") or {}).get("moderationState", "?")
            row["name"] = info.get("displayName", row["name"])
            if info.get("state") != "Active":
                print(f"NOT ACTIVE {rel}: {info.get('state')}")
        save(ledger)
    finally:
        session.close()
    bad = sorted(rel for rel, row in ledger.items() if row["moderation"] != "Approved")
    print(f"{len(ledger) - len(bad)} approved; not approved: {bad}")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "check":
        sys.exit(check())
    elif cmd == "doc":
        doc()
    elif cmd == "fill":
        ledger = load()
        for rel, row in ledger.items():
            fill_row(rel, row)
        save(ledger)
    elif cmd == "provenance":
        write_provenance()
    elif cmd == "refresh":
        refresh()
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
