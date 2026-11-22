--!strict
-- The Battle Pass's seasons (Data/BattlePass): one per calendar month (UTC), id "YYYY-MM", and what its
-- reward dots give as catalog item ids (Data/Cosmetics; the art is flagged "season" in its sidecar,
-- tools/cosmetics/build.py, so it is never sold in the Stars store and never on a bot).
--
--   free track     badge (level 30), frame (60), avatar (100)
--   premium track  premium_skin (20), premium_frame (50), premium_avatar (90)
--
-- A month with no entry reruns the most recent season defined before it (Seasons.get); its items are then
-- owned already by those who earned them, and come as Stars instead (BattlePass.BpOwnedItemStars).
-- tests/battlepass.luau fails when an id is not in the catalog.
local Seasons = {}

export type Season = {
	--- a Data/Strings key: the season's name
	name: string,
	badge: string,
	frame: string,
	avatar: string,
	premium_skin: string,
	premium_frame: string,
	premium_avatar: string,
}

Seasons.LIST = {
	["2026-11"] = {
		name = "bp.season.founders",
		badge = "badge_founders_medal",
		frame = "frame_founders_laurel",
		avatar = "icon_founding_marshal",
		premium_skin = "skin_founders_charter",
		premium_frame = "frame_founders_crown",
		premium_avatar = "icon_grand_founder",
	},
	["2026-12"] = {
		name = "bp.season.winter_front",
		badge = "badge_winter_front",
		frame = "frame_winter_front",
		avatar = "icon_polar_scout",
		premium_skin = "skin_snowfall",
		premium_frame = "frame_glacier_crown",
		premium_avatar = "icon_winter_marshal",
	},
	["2027-01"] = {
		name = "bp.season.northern_lights",
		badge = "badge_northern_lights",
		frame = "frame_aurora_ribbon",
		avatar = "icon_aurora_explorer",
		premium_skin = "skin_northern_lights",
		premium_frame = "frame_aurora_crescent",
		premium_avatar = "icon_aurora_seer",
	},
} :: { [string]: Season }

--- The item fields of a season, free track first.
Seasons.FIELDS = { "badge", "frame", "avatar", "premium_skin", "premium_frame", "premium_avatar" }

local ORDER: { string } = {}
for id in Seasons.LIST do
	table.insert(ORDER, id)
end
table.sort(ORDER)

--- The season that runs in month `id` ("YYYY-MM"): its own, else the most recent one defined before it
--- (the first one before them all). Returns the season and the id of the entry it reruns.
function Seasons.get(id: string): (Season, string)
	local own = Seasons.LIST[id]
	if own ~= nil then
		return own, id
	end
	local best = ORDER[1]
	for _, k in ORDER do
		if k <= id then
			best = k
		end
	end
	return Seasons.LIST[best], best
end

--- Seasons that last longer than their one month: id -> BpSeasonMonths, the calendar months it runs
--- (its own and the ones after). The months it covers have no season of their own while it runs: their
--- LIST entry, if any, is skipped.
Seasons.LENGTH_MONTHS = {
	["2026-11"] = 2, -- months: Founders runs to the end of 2026 (the user, 2026-11-22); Winter Front is skipped
} :: { [string]: number }

local function month_index(id: string): number
	return (tonumber(string.sub(id, 1, 4)) or 1970) * 12 + (tonumber(string.sub(id, 6, 7)) or 1) - 1
end

--- How many calendar months season `id` lasts (1 unless LENGTH_MONTHS says more).
function Seasons.months(id: string): number
	return math.max(1, math.floor(Seasons.LENGTH_MONTHS[id] or 1))
end

--- The id of the season running in calendar month `month` ("YYYY-MM"): a longer season that covers it,
--- else the month itself.
function Seasons.of_month(month: string): string
	local at = month_index(month)
	for id, n in Seasons.LENGTH_MONTHS do
		local first = month_index(id)
		if at > first and at < first + math.max(1, math.floor(n)) then
			return id
		end
	end
	return month
end

--- Is item `id` one of any season's rewards?
function Seasons.has_item(id: string): boolean
	for _, s in Seasons.LIST do
		for _, f in Seasons.FIELDS do
			if (s :: any)[f] == id then
				return true
			end
		end
	end
	return false
end

return Seasons
