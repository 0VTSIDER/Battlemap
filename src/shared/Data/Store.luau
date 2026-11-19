--!strict
-- The Stars store (2026-11-03): every cosmetic is bought once, for good, with Stars (Data/Stars: what
-- matches pay, about 1,000 an average match and 3,300 an hour of play), in the Locker. Robux buy Stars
-- (Data/Products), never an item. An item's price is its kind's and rarity's (PRICES); kinds and
-- rarities without one, exclusives (Cosmetics.exclusive_skins) and the Battle Pass's season items (`season` in
-- their catalog entry: Data/Seasons, earned on the pass only) are not for sale.
--
--   badges  shouldn't feel grindy: a common one (a country's flag) is half a match
--   icons   should: a common one is a few matches, a legendary one weeks of play (about 75 hours)
--   frames  a little above icons (rank frames are never sold: Data/Ranks unlocks them)
--   fonts   very expensive: a common one is 40 matches
--   skins   (territory patterns) the most expensive of all: a legendary one is the long goal
--
-- server/Purchases.buy_item takes the Stars and adds the item in one write; the Locker shows the price.
local Store = {}

--- Stars by item kind, then rarity.
Store.PRICES = {
	badge = { common = 500, uncommon = 1000, rare = 1500, epic = 3000, legendary = 6000 },
	icon = { common = 3000, uncommon = 7500, rare = 15000, epic = 60000, legendary = 250000 },
	frame = { common = 10000, uncommon = 25000, rare = 50000, epic = 120000, legendary = 300000 },
	font = { common = 40000, uncommon = 70000, rare = 100000, epic = 200000, legendary = 400000 },
	skin = { common = 60000, uncommon = 100000, rare = 150000, epic = 350000, legendary = 750000 },
} :: { [string]: { [string]: number } }

--- The Stars item `it` (a Cosmetics item) costs, or nil when it isn't for sale.
function Store.price(it: any): number?
	if type(it) ~= "table" or it.exclusive or it.default or it.rank ~= nil or it.season ~= nil then
		return nil
	end
	local by_rarity = Store.PRICES[it.kind]
	return if by_rarity ~= nil then by_rarity[it.rarity] else nil
end

return Store
