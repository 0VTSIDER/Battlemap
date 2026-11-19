"""Where Battlemap's asset files live. Everything the game uses is in the repository, under assets/, except the
original art (PRIVATE).

EXPORTS  finished files, one per ledger row. tools/upload.py uploads only from here and PRIVATE_EXPORTS, the
         folders approved in Studio (MCP Permissions -> Open Cloud upload directories).
SOURCES  what those are made from (SVGs, third-party audio, cosmetics art).
LEDGER   every uploaded file: id, name, hash, licence, moderation state. See tools/ledger.py.
LICENSES proofs for third-party files, and PROVENANCE.csv.

DEV      development material the game doesn't use: raw downloads, unused art, sheets. Outside the repo.
UNUSED   art the game no longer uses (tools/fx, tools/globe, tools/glyphs write here).

PRIVATE  the original Battlemap art (ASSETS-LICENSE: not AGPL, not in the public repo), the same layout as assets/
         (exports/, sources/). Its ledger rows are "private"; the game uses only their Roblox ids.
         BATTLEMAP_PRIVATE_ASSETS overrides it. Absent (no exports/ in it, e.g. CI): ledger.py skips those files.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")
EXPORTS = os.path.join(ASSETS, "exports")
SOURCES = os.path.join(ASSETS, "sources")
LICENSES = os.path.join(ASSETS, "licenses")
LEDGER = os.path.join(ASSETS, "ledger.json")

#: (BATTLEMAP_DEV overrides it; default: the _AGENTS/Battlemap folder two levels above the repository)
DEV = os.path.normpath(os.environ.get("BATTLEMAP_DEV") or os.path.join(ROOT, os.pardir, os.pardir, "_AGENTS", "Battlemap"))
UNUSED = os.path.join(DEV, "sources", "unused")

PRIVATE = os.path.normpath(os.environ.get("BATTLEMAP_PRIVATE_ASSETS") or os.path.join(DEV, "private_assets"))
PRIVATE_EXPORTS = os.path.join(PRIVATE, "exports")
PRIVATE_SOURCES = os.path.join(PRIVATE, "sources")
#: paths inside exports/ whose files are private (they live in PRIVATE_EXPORTS)
PRIVATE_PREFIXES = ("Cosmetics/atlas/", "Branding/title_logo")
#: cosmetics source folders (sources/cosmetics/<kind>/<group>) that are private; the rest stay in the repo
#: (badge/common: the country-flag badges, public domain)
PRIVATE_COSMETICS = {"avatar": None, "frame": None, "badge": ("uncommon", "rare", "epic", "legendary")}


def is_private(rel):
    """True for a private export (`rel`: its path inside exports/, forward slashes)."""
    return rel.startswith(PRIVATE_PREFIXES)


def is_private_cosmetic(kind, group):
    """True when sources/cosmetics/<kind>/<group> is private art (PRIVATE_COSMETICS)."""
    return kind in PRIVATE_COSMETICS and (PRIVATE_COSMETICS[kind] is None or group in PRIVATE_COSMETICS[kind])


def has_private():
    """True when the private exports are on this machine (not on CI or a fresh clone)."""
    return os.path.isdir(PRIVATE_EXPORTS)


def export_path(rel):
    """Where the export `rel` lives: PRIVATE_EXPORTS for private art, else EXPORTS."""
    return os.path.join(PRIVATE_EXPORTS if is_private(rel) else EXPORTS, *rel.split("/"))
