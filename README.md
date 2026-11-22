# Battlemap

Roblox territory-control strategy game, version 2.0. Licensed AGPL-3.0 with added terms (see `LICENSE`); the
copyright notices in the in-game credits (`HelpOverlay.LEGAL`, `TitleScreen.CREDITS`) are required by it and
must stay. Maps are made from public-domain data (Natural Earth, NOAA ETOPO1); asset sources are in `ASSETS.md`.
The original Battlemap art (cosmetics, battle pass and store art, title logo) is not in this repository and is all rights reserved, not AGPL: see `ASSETS-LICENSE`.

## Setup

Tools are pinned in `rokit.toml` (Rojo, Selene, StyLua, luau-lsp, Lune):

```
rokit install
rojo build default.project.json -o build/Battlemap.rbxl   # one-off place file
rojo serve                                               # live sync into Studio (Rojo plugin)
```

`release.project.json` = the same tree without the `Dev` harness folders (use it for publishing).

## Layout

- `src/shared` → `ReplicatedStorage.Battlemap` (simulation core, data, assets, net protocol)
- `src/server` → `ServerScriptService.BattlemapServer` (match server, lobbies via MemoryStore, purchases)
- `src/client` → `StarterPlayerScripts.BattlemapClient` (map rendering, UI, audio)
- `tests/` → Lune tests (`lune run tests/<name>.luau`)
- `assets/` → every file the game uses: `exports/`, `sources/`, `licenses/`, `ledger.json` (see `ASSETS.md`)
- `tools/` → Python asset generators / Studio MCP helpers (need Python; some are macOS-only)

Dev switches are workspace / player attributes prefixed `BM_` (e.g. `BM_DEV`, `BM_NET_STATS`, `BM_Admin`).

## Localization

Every string a player reads is a key in `src/shared/Data/Strings/` (English source, `{name}` parameters, an
optional note for translators); code shows it with `Loc.t(key, args)` (`src/shared/Core/Loc.luau`). Data modules
(Arsenal, ranks, tutorial, cosmetics, country names...) keep their English values and are shown with
`Loc.text(value)`; `Strings/Data.luau` generates their keys. Sim messages travel as a key plus args and are
translated on the client. On the client `Loc` asks the player's Translator
(`LocalizationService:GetTranslatorForPlayerAsync`, `FormatByKey`); a key the cloud table doesn't have yet falls
back to English. Automatic text capture is off (every GUI gets `AutoLocalize = false`): it would collect player
names and numbers.

To ship translations:

1. `lune run tests/localization.luau` checks the keys and writes `build/Localization.csv` (Key, Source, Context,
   Example).
2. Creator Dashboard → the experience → Localization: set the source language to English, add the languages
   (the UI handles Latin and Cyrillic scripts: Spanish, Portuguese, French, German, Italian, Polish, Turkish,
   Indonesian, Vietnamese, Russian), upload the CSV to the experience's localization table, and turn on
   automatic translation for those languages (it fills only empty entries; review or override them there).
3. Re-upload the CSV after adding or changing strings (a changed source keeps its old translations until
   they are re-translated). Badge and game pass names / descriptions are localized on their own dashboard
   pages.

Not translated on purpose: the licence notices (`HelpOverlay.LEGAL`, `TitleScreen.CREDITS`), player, nation
and map-place names on the globe, and analytics event names. A language picked mid-session updates new text;
screens already built keep their language until they are rebuilt or the player rejoins.

## Before publishing

- Robux offers: the developer products (`src/shared/Data/Products.luau`) and the game pass (`src/shared/Data/Passes.luau`) are made in the Battlemap experience (universe 10774637528); their `staging` ids are `0` until a staging experience has them. Never delete or reuse a product id (receipts are retried for days) nor an item id a player may own.
- `src/shared/Data/Staging.luau`: set `UNIVERSE` if you make a staging experience.
- `python tools/ledger.py refresh` then `check`: every asset approved, licensed and credited.
- AGPL: the source is at github.com/0VTSIDER/Battlemap (`HelpOverlay.SOURCE_REPO`, `src/client/UI/HelpOverlay.luau`); make the repository public before the experience.
