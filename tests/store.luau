--!nocheck
-- The Stars store (Data/Store): prices by kind and rarity, nothing for an exclusive, and a purchase
-- (server/Purchases.buy_item): the Stars taken, the item owned and worn in one write, refused when owned,
-- unaffordable, unknown or not for sale. Run: lune run tests/store.luau
require("./prelude")
local Store = require("../src/shared/Data/Store")
local Cosmetics = require("../src/shared/Data/Cosmetics")
local Purchases = require("../src/server/Purchases")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

-- prices
local country = Cosmetics.item("badge_us")
local designed = Cosmetics.item("badge_pumpkin_king")
expect(country ~= nil and Store.price(country) == Store.PRICES.badge.common, "a country badge: the common badge price")
expect(
	designed ~= nil and Store.price(designed) == Store.PRICES.badge.legendary,
	"a designed Legendary badge: the legendary badge price"
)
expect(Store.price(country) < Store.price(designed), "a country badge costs less than a designed one")
local rank = Cosmetics.item("frame_gold")
expect(rank ~= nil and rank.rank == "gold" and Store.price(rank) == nil, "a rank frame is never sold")
local ex = Cosmetics.exclusives()[1]
expect(ex == nil or Store.price(ex) == nil, "an exclusive is not for sale")
expect(Store.price(nil) == nil and Store.price({ kind = "nope", rarity = "common" }) == nil, "an unknown kind: no price")
expect(
	Cosmetics.catalog_owned({ badge_pumpkin_king = true, badge_us = true }) == 2,
	"the Locker's N of M counts badges"
)

-- a purchase
local rows = {}
local ds = {}
function ds:UpdateAsync(k, fn)
	local v = fn(rows[k])
	if v ~= nil then
		rows[k] = v
	end
	return v
end
function ds:GetAsync(k)
	return rows[k]
end
local P = { UserId = 7, Name = "Buyer" }
Purchases.reset()
Purchases.configure({
	datastore = ds,
	players = {
		GetPlayerByUserId = function(_, id)
			return if id == 7 then P else nil
		end,
	},
})
Purchases.load(P)
local start = Purchases.inventory(P).stars
local ok, err = Purchases.buy_item(P, "badge_pumpkin_king")
expect(not ok and err == "not enough", "too few Stars: refused, \"not enough\"")
Purchases.add_stars(P, Store.PRICES.badge.common + 100 - start)
ok = Purchases.buy_item(P, "badge_us")
local inv = Purchases.inventory(P)
expect(ok and table.find(inv.owned, "badge_us") ~= nil, "bought: the badge is theirs")
expect(inv.equipped.badge == "badge_us", "... and worn at once")
expect(inv.stars == 100, "... for its price in Stars")
ok, err = Purchases.buy_item(P, "badge_us")
expect(not ok and err == "owned" and Purchases.inventory(P).stars == 100, "again: refused, \"owned\", nothing taken")
ok, err = Purchases.buy_item(P, "no_such_item")
expect(not ok and err == "unknown item", "an unknown id: refused")
if ex ~= nil then
	ok, err = Purchases.buy_item(P, ex.id)
	expect(not ok and err == "not for sale", "an exclusive: refused, \"not for sale\"")
end
expect(Purchases.equip(P, "badge", false) and Purchases.equip(P, "badge", "badge_us"), "equip: off, then on again")

-- avatar icons (2026-11-04)
local icons, by = 0, {}
for _, it in Cosmetics.all() do
	if it.kind == "icon" then
		icons += 1
		by[it.rarity] = (by[it.rarity] or 0) + 1
	end
end
expect(icons >= 50 and by.common and by.rare and by.epic and by.legendary, ("%d icons, every rarity"):format(icons))
local first = Cosmetics.DEFAULT_AVATARS[1]
local def = Cosmetics.item(first)
expect(#Cosmetics.DEFAULT_AVATARS >= 3 and def ~= nil and def.kind == "icon" and Store.price(def) == nil, "the default avatars: icons, never sold")
local leg = Cosmetics.item("icon_golden_emperor")
expect(
	leg ~= nil and Store.price(leg) == Store.PRICES.icon.legendary and Store.PRICES.icon.legendary > Store.PRICES.badge.legendary * 10,
	"a legendary icon costs far more than any badge (grindy)"
)
local N = { UserId = 21, Name = "Newbie" }
Purchases.configure({
	players = {
		GetPlayerByUserId = function(_, id)
			return if id == 21 then N elseif id == 7 then P else nil
		end,
	},
})
Purchases.load(N)
local ni = Purchases.inventory(N)
local worn = ni.equipped.icon
expect(
	table.find(ni.owned, first) ~= nil
		and table.find(Cosmetics.DEFAULT_AVATARS, worn) ~= nil
		and worn == Purchases.default_avatar(21)
		and #ni.owned == #Cosmetics.DEFAULT_AVATARS,
	"a new player owns every default avatar and wears one picked for them"
)
local picks = {}
for uid = 1, 200 do
	picks[Purchases.default_avatar(uid) or ""] = true
end
local npick = 0
for _ in picks do
	npick += 1
end
expect(npick == #Cosmetics.DEFAULT_AVATARS, "the pick spreads over every default avatar")
expect(not Purchases.equip(N, "icon", false), "an avatar is always worn (no head shot)")
Purchases.add_stars(N, 1) -- (a write: the record is read again)
expect(Purchases.inventory(N).equipped.icon == worn, "... and the same one stays on")
Purchases.add_stars(N, Store.PRICES.icon.common)
ok = Purchases.buy_item(N, "icon_army_cook")
expect(ok and Purchases.inventory(N).equipped.icon == "icon_army_cook", "a bought icon is worn at once")
expect(not Purchases.equip(N, "icon", "badge_us"), "a badge in the icon slot: refused")

if fails > 0 then
	error(("store: %d failed"):format(fails))
end
print("store ok")
