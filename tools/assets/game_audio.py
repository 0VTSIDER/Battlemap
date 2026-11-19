#!/usr/bin/env python3
"""Battlemap's audio from CC0 packs (see ASSETS.md): which file plays for each sound
key, staging the files for upload, and writing the manifests once they are uploaded.

AudioDirector is built for short stings (cooldowns of 0.7-2.5 s, a few copies at once): every sound
effect must be at most MAX_SFX_S long. Longer sources are cut with TRIM (2026-11-02: five combat sounds
were 5 s engine loops, and overlapping copies made a constant drone in a match).

  1. .venv\\Scripts\\python tools\\assets\\game_audio.py stage
       writes each file to exports/Audio/bm_<key>.<ext> (the asset name Roblox keeps); trimmed or
       non-ogg sound effects are re-encoded to .ogg with ffmpeg (on PATH)
  2. .venv\\Scripts\\python tools\\assets\\game_audio.py upload
       uploads what isn't up yet (tools/upload.py; each file keeps its name) and records its id and length
       in assets/ledger.json
  3. .venv\\Scripts\\python tools\\assets\\game_audio.py manifest

Change a sound: edit SFX / TRACKS below, stage, upload the new file, manifest.

Sound styles (2026-11-03): SFX is the default style's full set; STYLE_SFX[style] replaces some of its
sounds (uploaded as bm_<style>_<key>), STYLE_MOODS[style] are that style's playlists. Since 2026-11-04
there is one style ("war") and no choice in Settings: most sound effects are OpenFront's (CC BY-SA 4.0,
sources/third_party/openfront_sounds), the rest CC0.
"""
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from paths import EXPORTS, LEDGER, SOURCES  # noqa: E402

TP = os.path.join(SOURCES, "third_party")
STAGE = os.path.join(EXPORTS, "Audio")
ASSETS = os.path.join(ROOT, "src", "shared", "Assets")

MU = "opengameart_music/"
NB = "qubodup_naval-battle/"
RT = "qubodup_rts-war-sounds/"
HITS = "pauliuw_hits/"

# OpenFront's sound effects (CC BY-SA 4.0, attribution "OpenFront"; openfront_sounds/SOURCE.txt)
OF = "openfront_sounds/"

# every sfx key AudioDirector knows (AudioDirector.SFX_NAMES) -> source file
# (2026-11-04, the user: OpenFront's sounds for everything they have one for; the arcade style is gone.
# The keys OpenFront has nothing like keep their CC0 sound: expand, expand_pop, attack_launch,
# under_attack, shell_hit, shell_splash.)
SFX = {
    # match
    "alliance": OF + "alliance-accepted.mp3",
    "ally_request": OF + "alliance-suggested.mp3",
    "attack_launch": RT + "artil.action.wav",
    "betrayal": OF + "alliance-broken.mp3",
    "boat_launch": OF + "transport-ship.mp3",
    "build": OF + "build-city.mp3",
    # (Ev.CONQUEST: the gold a conquest took)
    "conquer": OF + "ka-ching.mp3",
    "defeat": OF + "defeat.mp3",
    "expand": HITS + "hit.wav",
    "expand_pop": HITS + "hit.wav",
    "eliminate": OF + "conquered.mp3",
    "game_start": OF + "game-start.mp3",
    "nuke_alarm": OF + "nuke-warning.mp3",
    "nuke_explosion": OF + "atom-hit.mp3",
    "nuke_launch": OF + "atom-launch.mp3",
    "order_ack": OF + "click-1.mp3",
    "sam_intercept": OF + "sam-hit.mp3",
    "sam_launch": OF + "sam-shoot.mp3",
    "shell_fire": OF + "warship-shot.mp3",
    "shell_hit": NB + "ExplosionMetal.ogg",
    "shell_splash": NB + "WaterSurfaceExplosion06.ogg",
    "ship_sink": OF + "warship-lost.mp3",
    "spawn_confirm": OF + "spawn.mp3",
    "under_attack": RT + "destroyer.underattack.wav",
    "victory": OF + "victory.mp3",
    "warship": OF + "build-warship.mp3",
    # countdown / lobby
    "countdown_tick": OF + "slider.mp3",
    "countdown_tick_1": OF + "click-1.mp3",
    "countdown_tick_2": OF + "click-2.mp3",
    "countdown_tick_3": OF + "click-3.mp3",
    "countdown_tick_4": OF + "click-2.mp3",
    "countdown_tick_5": OF + "click-1.mp3",
    "countdown_gamestart": OF + "game-start.mp3",
    "queue_start": OF + "click-1.mp3",
    "spectate_switch": OF + "click-2.mp3",
    # interface
    "buy_spend": OF + "ka-ching.mp3",
    "star_get": OF + "ka-ching.mp3",
    "star_tick": OF + "slider.mp3",
    "ui_back": OF + "click-3.mp3",
    "ui_click": OF + "click-1.mp3",
    "ui_confirm": OF + "click-1.mp3",
    "ui_error": OF + "alliance-declined.mp3",
    "ui_hover": OF + "slider.mp3",
    "ui_locked": OF + "alliance-declined.mp3",
    "ui_open": OF + "click-2.mp3",
    "ui_tab": OF + "click-3.mp3",
    "unlock": OF + "sam-built.mp3",
}

# a sound effect longer than this would stack into a drone under AudioDirector's cooldowns (seconds)
MAX_SFX_S = 2.5
# sfx key -> (start s, length s, fade-out s): the part of a longer source that plays
TRIM = {
    # OpenFront's longer effects (2.6-6 s): their first 2.5 s, faded out
    "alliance": (0.0, 2.2, 0.5),
    "betrayal": (0.0, 2.5, 0.8),
    "boat_launch": (0.0, 2.5, 0.8),
    "defeat": (0.0, 2.5, 0.8),
    "eliminate": (0.0, 2.5, 0.7),
    "nuke_alarm": (0.0, 2.5, 0.5),
    "nuke_explosion": (0.0, 2.5, 0.9),
    "nuke_launch": (0.0, 2.5, 0.8),
    "sam_launch": (0.0, 2.5, 0.8),
    "ship_sink": (0.0, 2.5, 0.9),
    "victory": (0.0, 2.5, 0.8),
    "warship": (0.0, 2.5, 0.6),
    # a pop rings ~0.05 s, up to 20 a second: only the drum hit's attack
    "expand_pop": (0.0, 0.06, 0.03),
}
# sfx key -> gain in dB at staging, for sources recorded far quieter than the rest (~-10 dB RMS at peak)
GAIN = {}

# soundtrack: key -> (file, title, author)
#   (2026-11-03: chiptunes by Juhani Junkala instead of the orchestral tracks, the user wanted an arcade feel)
#   (2026-11-04: the arcade style and its chiptunes are gone; the war style's tracks are the soundtrack)
TRACKS = {
    # (2026-11-04, the user: one track for the title screen, one for matches)
    # the title: Freesound, CC BY 4.0 (credited in HelpOverlay.LEGAL), the user's pick
    "title_epic_orchestra": ("joshuaempyre_epic-orchestra/epic_orchestra_loop.ogg", "Epic Orchestra - LOOP", "joshuaempyre"),
    "match_laments": ("cethiel_laments-of-the-war/laments_of_the_war.ogg", "Laments of the War", "Cethiel"),
}
# a track that isn't OpenGameArt / CC0: where it is from (Soundtrack.luau's pack)
TRACK_SOURCE = {"title_epic_orchestra": " (Freesound, CC BY 4.0)"}
# (every track in a mood must be over 30 s, tests/soundtrack.luau; the title's first track is its opener)

# One sound style since 2026-11-04 (the arcade one is gone): "war", its sounds SFX itself.
DEFAULT_STYLE = "war"
STYLE_NAMES = {"war": "War"}
# style -> {sfx key -> source}: the default sounds it replaces (TRIM / GAIN key: "<style>_<key>")
STYLE_SFX = {"war": {}}
# style -> its playlists (tracks from TRACKS)
STYLE_MOODS = {
    "war": {
        # the title screen and a public match's waiting room
        "title": ["title_epic_orchestra"],
        "wait": ["title_epic_orchestra"],
        # the match, start to end screen
        "calm": ["match_laments"],
        "war": ["match_laments"],
        "victory": ["match_laments"],
        "defeat": ["match_laments"],
    },
}


def sfx_assets():
    """(asset key, source) of every sound effect to upload: the default set, then each style's own."""
    out = list(SFX.items())
    for style, sounds in STYLE_SFX.items():
        out += [(f"{style}_{key}", rel) for key, rel in sounds.items()]
    return out


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                         capture_output=True, text=True, check=True).stdout
    return float(out.strip())


def stage():
    if os.path.isdir(STAGE):
        shutil.rmtree(STAGE)
    os.makedirs(STAGE)
    too_long = []
    assets = sfx_assets()
    for key, rel in assets:
        src = os.path.join(TP, *rel.split("/"))
        if key not in TRIM and key not in GAIN and src.endswith(".ogg"):
            if duration(src) > MAX_SFX_S:
                too_long.append(key)
            shutil.copyfile(src, os.path.join(STAGE, "bm_" + key + ".ogg"))
            continue
        dst = os.path.join(STAGE, "bm_" + key + ".ogg")
        cmd = ["ffmpeg", "-v", "error", "-y"]
        filters = []
        if key in TRIM:
            start, length, fade = TRIM[key]
            cmd += ["-ss", str(start), "-t", str(length)]
            if start > 0:
                filters.append("afade=t=in:st=0:d=0.03")
            filters.append(f"afade=t=out:st={max(length - fade, 0)}:d={fade}")
        if key in GAIN:
            filters.append(f"volume={GAIN[key]}dB,alimiter=limit=0.89")
        cmd += ["-i", src] + (["-af", ",".join(filters)] if filters else [])
        subprocess.run(cmd + ["-c:a", "libvorbis", "-q:a", "6", dst], check=True)
        if duration(dst) > MAX_SFX_S:
            too_long.append(key)
    if too_long:
        sys.exit(f"over MAX_SFX_S ({MAX_SFX_S} s), add a TRIM: " + ", ".join(sorted(too_long)))
    for key, t in TRACKS.items():
        src = os.path.join(TP, *t[0].split("/"))
        shutil.copyfile(src, os.path.join(STAGE, "bm_music_" + key + os.path.splitext(src)[1]))
    print(f"{len(assets) + len(TRACKS)} files -> {os.path.relpath(STAGE, ROOT)}")


def audio_rows():
    """Asset name (bm_<key>) -> its ledger row, for the sounds in the ledger."""
    with open(LEDGER, encoding="utf-8") as f:
        ledger = json.load(f)
    return {os.path.splitext(rel.split("/", 1)[1])[0]: row for rel, row in ledger.items() if rel.startswith("Audio/")}


def upload_stage():
    import upload
    for name in sorted(os.listdir(STAGE)):
        path = os.path.join(STAGE, name)
        upload.upload_asset(path, name=os.path.splitext(name)[0])
        with open(LEDGER, encoding="utf-8") as f:
            ledger = json.load(f)
        row = ledger["Audio/" + name]
        if "length" not in row:
            row["length"] = duration(path)
            with open(LEDGER, "w", encoding="utf-8", newline="\n") as f:
                json.dump(ledger, f, indent=1, sort_keys=True)
    print(len(audio_rows()), "sounds in", os.path.relpath(LEDGER, ROOT))


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def manifest():
    ids = audio_rows()
    missing = [k for k, _ in sfx_assets() if "bm_" + k not in ids] + [k for k in TRACKS if "bm_music_" + k not in ids]
    if missing:
        sys.exit("not uploaded yet: " + ", ".join(missing))

    def entry(asset_key):
        e = ids["bm_" + asset_key]
        return f'{{ id = "rbxassetid://{e["id"]}", length = {round(float(e["length"]), 6)} }}'

    L = ["-- GENERATED by tools/assets/game_audio.py — do not edit by hand.",
         "-- Sound effects by OpenFront (CC BY-SA 4.0) and from CC0 packs (ASSETS.md).",
         "-- sfx: key -> {id, length}, the default style's set; styles[style].sfx: the sounds that style",
         "-- replaces (AudioDirector.set_style).",
         "return {", "\tmusic = {},", f"\tdefault_style = {lua_str(DEFAULT_STYLE)},", "\tsfx = {"]
    for k in sorted(SFX):
        L.append(f"\t\t{k} = {entry(k)},")
    L += ["\t},", "\tstyles = {"]
    for style in STYLE_SFX:
        L += [f"\t\t{style} = {{", f"\t\t\tname = {lua_str(STYLE_NAMES[style])},", "\t\t\tsfx = {"]
        for k in sorted(STYLE_SFX[style]):
            L.append(f"\t\t\t\t{k} = {entry(style + '_' + k)},")
        L += ["\t\t\t},", "\t\t},"]
    L += ["\t},", "}"]
    with open(os.path.join(ASSETS, "Audio.luau"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")
    L = ["-- GENERATED by tools/assets/game_audio.py — do not edit by hand.",
         "-- Music: each track's assets/licenses/third_party/<folder>/SOURCE.txt and ASSETS.md (pack: author, site, licence).",
         "-- tracks: key -> {id, length (s), title, pack}; moods: playlists by mood, the first title track",
         "-- is the opener. Played whole and crossfaded by AudioDirector.",
         "return {", '\tcredit = "Music: Epic Orchestra - LOOP by joshuaempyre (Freesound, CC BY 4.0); Laments of the War by Cethiel (OpenGameArt, CC0)",', "\ttracks = {"]
    for k in sorted(TRACKS):
        e = ids["bm_music_" + k]
        _, title, author = TRACKS[k]
        L.append(f'\t\t{k} = {{ id = "rbxassetid://{e["id"]}", length = {round(float(e["length"]), 6)}, '
                 f'title = {lua_str(title)}, pack = {lua_str(author + TRACK_SOURCE.get(k, " (OpenGameArt, CC0)"))} }},')
    def moods(indent, table):
        out = []
        for m, keys in table.items():
            out.append(f"{indent}{m} = {{ " + ", ".join(lua_str(k) for k in keys) + (" }," if keys else "},"))
        return out

    L += ["\t},", "\t-- the default style's playlists; styles[style].moods: each style's own", "\tmoods = {"]
    L += moods("\t\t", STYLE_MOODS[DEFAULT_STYLE])
    L += ["\t},", "\tstyles = {"]
    for style, table in STYLE_MOODS.items():
        L += [f"\t\t{style} = {{", "\t\t\tmoods = {"] + moods("\t\t\t\t", table) + ["\t\t\t},", "\t\t},"]
    L += ["\t},", "}"]
    with open(os.path.join(ASSETS, "Soundtrack.luau"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")
    print("wrote Audio.luau, Soundtrack.luau")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "stage":
        stage()
    elif len(sys.argv) >= 2 and sys.argv[1] == "upload":
        upload_stage()
    elif len(sys.argv) >= 2 and sys.argv[1] == "manifest":
        manifest()
    else:
        print(__doc__)
        sys.exit(1)
