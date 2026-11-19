# Asset & licence ledger

Every asset Battlemap uses, where it comes from and under what licence. `assets/ledger.json` is the record;
`python tools/ledger.py check` proves it true, and CI runs it. "UEFN OK" = safe to reuse in a closed (non-AGPL)
Fortnite/UEFN island.

## Where asset files live

| What | Where |
|---|---|
| Finished files, one per live upload | `assets/exports/` (`UI`, `Map`, `Arsenal`, `Flags`, `Cosmetics`, `Audio`, `Branding`). The only folder `tools/upload.py` uploads from |
| What they are made from | `assets/sources/` (`flags`, `crate`, `icons`, `skins`, `map_sprites`, `cosmetics`, `branding`, `third_party`) |
| Each upload's id, name, hash, licence, source, AI flag and moderation state | `assets/ledger.json` |
| Ids the game uses | `src/shared/Assets/*.luau` (generated) and `TitleScreen.LOGO` |
| Licence proofs for third-party audio | `assets/licenses/third_party/` |
| Everything else: raw downloads, ChatGPT sheets, unused art and packs, store listing, product and trailer material | Outside the repository (the developer's own files). The game doesn't use it |

Only what the game uses goes in `assets/`. A file nothing references leaves it (`ledger.py check` fails on it).
The original art (the ledger's private rows and their sources) lives outside the repository in the private asset root
a private folder outside the repository (`paths.PRIVATE`, the same `exports/` and `sources/` layout); see `ASSETS-LICENSE`.

## How uploads work

`tools/upload.py` is the one uploader: Open Cloud through Studio's MCP, with no API key. It needs the published place
open in Studio (`tools/studio.py open-published`) and **Publish & manage assets** allowed in MCP Permissions, with
`assets/exports` and the private root's `exports` as approved upload folders. A file goes up only when its bytes change, and uploads can't be
deleted through Open Cloud, so upload settled art only. New uploads are named `bm_<folders>_<file>` unless the
generator passes a name, and get their licence from `RULES` in `tools/ledger.py`.

After adding or changing an asset: `python tools/ledger.py check`, then `python tools/ledger.py doc`.

## Roblox inventory

In Studio's Asset Manager, everything sits under `Battlemap/`: `UI`, `Audio`, `Map`, `Flags`, `Cosmetics` (with
`Crate`), `Arsenal` and `Branding` hold what the game uses, `Store` holds game pass and developer product icons, and
`Unused` holds images the game doesn't use. New uploads land at the top of the inventory, and Roblox has no public API
for folders, so move them into place through the Asset Manager window after each batch.

Sound uploads the game doesn't use are archived, which hides them and can be undone with Open Cloud's `:restore`.
Roblox doesn't allow archiving images, so unused images go in `Unused`. Never archive an id that is in the ledger, or
anything in `Store`.

## What's in the ledger

<!-- ledger:start (tools/ledger.py doc) -->
| Exports | Files | Licence | Made from | AI | Private |
|---|---|---|---|---|---|
| `Arsenal/renders` | 8 | AGPL-3.0 | `tools/assets/make_arsenal_art.py, make_arsenal_renders.py` |  |  |
| `Arsenal/ui` | 12 | AGPL-3.0 | `tools/assets/make_arsenal_art.py, make_arsenal_renders.py` |  |  |
| `Audio` | 1 | CC BY 4.0 | `assets/sources/third_party/joshuaempyre_epic-orchestra` |  |  |
| `Audio` | 41 | CC BY-SA 4.0 | `assets/sources/third_party/openfront_sounds` |  |  |
| `Audio` | 1 | CC0 1.0 | `assets/sources/third_party/cethiel_laments-of-the-war` |  |  |
| `Audio` | 2 | CC0 1.0 | `assets/sources/third_party/pauliuw_hits` |  |  |
| `Audio` | 2 | CC0 1.0 | `assets/sources/third_party/qubodup_naval-battle` |  |  |
| `Audio` | 2 | CC0 1.0 | `assets/sources/third_party/qubodup_rts-war-sounds` |  |  |
| `Branding` | 1 | AI art, ChatGPT (copyright status unclear) | `assets/sources/branding` | yes | yes |
| `Cosmetics/atlas` | 2 | AI art, ChatGPT (copyright status unclear) | `assets/sources/cosmetics/avatar` | yes | yes |
| `Cosmetics/atlas` | 2 | AI art, ChatGPT (copyright status unclear) | `assets/sources/cosmetics/frame` | yes | yes |
| `Cosmetics/atlas` | 5 | Flags public domain; the others AI art, ChatGPT (copyright status unclear) | `assets/sources/cosmetics/badge` | yes | yes |
| `Cosmetics/crate` | 8 | AGPL-3.0 | `assets/sources/crate` |  |  |
| `Cosmetics/skins` | 1 | AGPL-3.0 | `tools/assets/make_skin_previews.py` |  |  |
| `Flags` | 5 | Public domain / CC0 | `assets/sources/flags/SOURCE.txt` |  |  |
| `Map/fx` | 1 | AGPL-3.0 | `tools/assets/make_map_fx.py` |  |  |
| `Map/rails` | 6 | AGPL-3.0 | `tools/assets/make_rail_art.py` |  |  |
| `Map/sprites` | 20 | AGPL-3.0 | `assets/sources/map_sprites` |  |  |
| `Map/thumbs` | 1 | AGPL-3.0 (from public-domain map data) | `tools/assets/make_map_thumbs.py` |  |  |
| `UI/icons` | 47 | AGPL-3.0 | `assets/sources/icons` |  |  |
| `UI/kit` | 17 | AGPL-3.0 | `tools/uikit/make_textures.py` |  |  |
| `UI/shapes` | 10 | AGPL-3.0 | `tools/ui/make_shapes.py` |  |  |
<!-- ledger:end -->

All uploads belong to account OUTSIDER_DEV (user 11217351242). Some early uploads keep their first names on Roblox;
the ledger shows each real name.

## Code and data

| Path | What | Licence | UEFN OK |
|---|---|---|---|
| `src/`, `tests/`, `tools/` | Code (Luau, Python) | AGPL-3.0 with added terms (`LICENSE`); the copyright notices in `HelpOverlay.LEGAL` and `TitleScreen.CREDITS` must stay | No (copyleft code; UEFN uses Verse anyway) |
| `src/server/MapData/`, `src/shared/Data/Maps/`, `src/shared/Assets/MapThumbs.luau` | Maps built by `tools/maps/make_maps.py` from Natural Earth and NOAA ETOPO1 | Data public domain; the generated maps AGPL-3.0 | Not as-is: rebuild from the public-domain data |
| `assets/sources/flags/*.svg` | Country flags, Wikimedia Commons | Public domain / CC0 per file, see `SOURCE.txt` there. Some are official insignia (other laws may restrict misuse) | Yes |
| `assets/sources/cosmetics/`, `assets/sources/branding/` | Avatar, frame, Uncommon–Legendary badge and logo art generated with ChatGPT / OpenAI image tools (`PROMPTS.md`); country-flag badges from the flags | AI output: copyright status unclear; flag badges public domain | Not recommended: regenerate or replace |
| Other `assets/exports` and `assets/sources` | Art generated by `tools/assets/*.py` and the other tools | AGPL-3.0 | No: replace for UEFN |

## Third-party audio (`assets/sources/third_party/`, proofs in `assets/licenses/third_party/`)

Each pack's proof folder keeps `SOURCE.txt` (source, author, licence, date checked), the author's own `README` / `INFO` /
licence file where the pack ships one, and `LICENSE_EVIDENCE.txt` for OpenGameArt pages. `PROVENANCE.csv` lists every
file with its size, SHA-256 and licence (`tools/ledger.py provenance` rewrites it). Full CC0 text: `LICENSES/CC0-1.0.txt`.
`tools/assets/game_audio.py` maps each sound key to its source file.

### CC0 1.0 (commercial use OK, no attribution needed, OK for Roblox and UEFN)

| Path | Use | Source |
|---|---|---|
| `cethiel_laments-of-the-war/` | match music | https://opengameart.org/content/laments-of-the-war (Cethiel) |
| `pauliuw_hits/` | the "hit" sounds | https://opengameart.org/node/4252 (pauliuw) |
| `qubodup_naval-battle/` | sound effects | https://opengameart.org/content/tiny-naval-battle-sounds-set (qubodup) |
| `qubodup_rts-war-sounds/` | sound effects | https://opengameart.org/content/sci-fi-rts-war-unit-sounds (qubodup) |

### CC BY 4.0 (attribution required)

| Path | Use | Source |
|---|---|---|
| `joshuaempyre_epic-orchestra/` | title screen and waiting room music | https://freesound.org/s/250856/ (Epic Orchestra - LOOP, joshuaempyre), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |

Re-encoded from WAV to OGG (the WAV is kept outside the repository). Credited in
`HelpOverlay.LEGAL` and `Soundtrack.credit`.

### CC BY-SA 4.0 (attribution and share-alike required)

| Path | Use | Source |
|---|---|---|
| `openfront_sounds/` | most sound effects | https://github.com/openfrontio/OpenFrontIO/tree/main/resources/sounds/effects (commit `0d61b4b`; OpenFront Inc. and Contributors), [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), attribution "OpenFront" |

Shortened to at most 2.5 s with a fade-out (the shortened versions are CC BY-SA 4.0 too). Credited in
`HelpOverlay.LEGAL`. UEFN OK only with the same attribution and licence.

An upload Roblox's moderation rejects shows "Asset is not approved" (a moderation result, not a licence
problem); re-upload it from a different source file.

## Tooling (project-local `.venv`, `requirements.txt`)

pillow, numpy, zstandard from PyPI as binary wheels only (`pip install --only-binary=:all:`). SVGs are rendered
with Microsoft Edge (`tools/assets/svg_render.py`). `tools/ledger.py` needs only Python's standard library.
