--!strict
-- Strings that live in the game's data modules (Arsenal, Ranks, Stars, Passes, Cosmetics
-- and its catalogs, Tutorial, MapList, the flags' country names): generated from the modules, so
-- the data keeps its English values (analytics and saves use them). Show them with Loc.text(value),
-- which finds the key by the English text. Keys: data.<module>.<id>[.<field>].
local Arsenal = require("../Arsenal")
local Ranks = require("../Ranks")
local Stars = require("../Stars")
local Passes = require("../Passes")
local Cosmetics = require("../Cosmetics")
local Tutorial = require("../Tutorial")
local MapList = require("../MapList")
local Flags = require("../../Assets/Flags")
local Avatars = require("../../Assets/Catalog/Avatars")
local Badges = require("../../Assets/Catalog/Badges")
local Fonts = require("../../Assets/Catalog/Fonts")
local Frames = require("../../Assets/Catalog/Frames")
local Skins = require("../../Assets/Catalog/Skins")

local out: { [string]: any } = {}

local function put(key: string, v: any, note: string?)
	if type(v) ~= "string" or v == "" then
		return
	end
	out[key] = if note ~= nil then { text = v, note = note } else v
end

for _, it in Arsenal.ITEMS do
	local k = "data.arsenal." .. it.key
	put(k .. ".title", it.title)
	put(k .. ".tagline", it.tagline)
	put(k .. ".blurb", it.blurb)
	put(k .. ".plain", it.plain, "Plain-language version for younger players")
	for i, p in it.perks or {} do
		put(k .. ".perk" .. i, p, "Short, upper case")
	end
	for i, f in it.facts or {} do
		put(k .. ".fact" .. i, f, "Very short")
	end
end

for _, t in Ranks.TIERS do
	put("data.rank." .. t.id, t.name, "A ranked tier")
end

put("data.stars.name", Stars.NAME, "The game's currency")
for id, label in Stars.LABELS do
	put("data.stars." .. id, label)
end

for id, p in Passes :: any do
	put("data.pass." .. id .. ".name", p.name)
	put("data.pass." .. id .. ".blurb", p.blurb)
end

for _, r in Cosmetics.RARITIES do
	put("data.rarity." .. r.id, r.name, "An item rarity")
end
put("data.rarity.exclusive", Cosmetics.EXCLUSIVE.name, "An item rarity")
for _, it in Cosmetics.exclusive_skins or {} do
	put("data.item." .. it.id, it.name)
end
for _, cat in { Avatars, Frames, Fonts, Skins } do
	for _, it in (cat :: any).items do
		put("data.item." .. it.id, it.name, "A cosmetic item's name")
	end
end
for _, it in (Badges :: any).items do
	put("data.item." .. it.id, it.name, "A country or territory (a flag badge)")
end
for _, f in (Flags :: any).flags do
	put("data.place." .. f.code, f.name, "A country or territory")
end

for _, s in Tutorial.STEPS do
	for _, field in { "touch", "desktop", "wait", "early", "note" } do
		put("data.tutorial." .. s.id .. "." .. field, (s :: any)[field], "Tutorial card: keep it short (a phone line)")
	end
end
put("data.tutorial.too_much", Tutorial.RATIO_TOO_MUCH)
put("data.tutorial.floor", Tutorial.FLOOR_REASON)

for _, m in MapList.maps do
	put("data.map." .. m.id, m.name, "A map's name")
end
put("data.maplist.licence", MapList.LICENSE)
put("data.maplist.credits", MapList.CREDITS)

return out
