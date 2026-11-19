# ChatGPT prompts for Battlemap cosmetics

Sheets go to `sheets\`, `slice.py` cuts them into the rarity folders, `build.py` builds the game data.

## Avatars

Shared style block (pasted into every avatar prompt):

> Game avatar icon sheet for a kid-friendly Roblox strategy game. Exactly 6 icons in a 3 columns x 2 rows
> grid, each icon in its own equal square cell, generous empty space between cells. Each icon is a ROUND
> portrait disc (a filled circle with a simple soft background colour inside) showing ONE funny cartoon
> character from the shoulders up, facing the viewer, big expressive face. NO ring, NO border, NO frame, NO
> rim around the disc: just the plain filled circle. Bold clean outlines, bright saturated colours, soft
> cel shading, polished mobile-game style. Fully transparent background outside the discs (no checkerboard,
> no white). No text, no letters, no numbers, no logos, no real people, no flags, no weapons pointed at the
> viewer, no blood, no scary content.

Tier accents (added after the style block): common = muted khaki/grey/blue backgrounds, plain outfits;
uncommon = green backgrounds and small green details; rare = blue backgrounds, a cool accessory each;
epic = purple backgrounds with a few sparkles, fancier outfits; legendary = gold backgrounds with a glow,
the grandest outfits.

Each prompt then lists the 6 characters (left to right, top row first), mixing skin tones, genders and ages.

## Frames

> Avatar FRAME sheet for a kid-friendly Roblox strategy game. Exactly 6 decorative circular frames (rings) in a
> 3 columns x 2 rows grid, each ring perfectly round and centred in its own equal square cell, generous empty
> space between cells. Each ring's outer diameter is about 80% of its cell; the ring band is moderately thin,
> about one fifth of the ring's radius, so the round window inside is large. The inside of every ring is
> completely EMPTY and transparent (an empty round window for a player portrait), nothing inside it. Small
> ornaments may stick out of the outer edge only, never into the window. Polished mobile-game UI style, bold
> clean outlines, soft cel shading, bright colours. Fully transparent background (real alpha, no
> checkerboard, no colour). No characters, no text, no letters, no numbers, no logos.

Then the tier and its 6 rings (common simple materials; uncommon green; rare blue; epic purple with sparkles;
legendary radiant gold). Rank frames: the same block, "RANK frames that clearly escalate, with military rank
insignia (chevrons, stars, laurels) on the band or the outer edge".

ChatGPT sometimes paints the background (white or a checkerboard): slice.py clears it.

2026-11-04: ornaments used to run past 1.5x the window and got cut. Use this size rule instead of the "about 80%"
sentence (frame_legendary_2, frame_epic_2, frame_mixed_1/2 were made with it):

> STRICT SIZE RULE: each frame INCLUDING every ornament fits completely inside a circle whose diameter is 75% of its
> cell's width. Nothing reaches the cell's edges, nothing is cut off, every frame is fully visible with a clear empty
> margin all around. The round empty window in the middle of each ring is 52% of the cell's width, so the band plus
> its ornaments is a compact ring only about 11% of the cell wide on each side; ornaments hug the band tightly.

ChatGPT still draws some bands thicker: slice.py keeps the whole ring and writes the frame's own "scale" (outer /
window, 1.5 to 1.8) to its sidecar, which build.py puts in Catalog/Frames.

## Adding a batch

1. Generate the sheet with the matching prompt and save it as `sheets\<kind>_<tier>_<n>.png`.
2. Add it to `sheets\sheets.json` (where it goes, the 6 names).
3. `slice.py`, then `build.py` (Studio open with Battlemap.rbxl, for the upload).
