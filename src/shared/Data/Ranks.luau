--!strict
-- The global leaderboard (2026-11-04): Rank Points (RP), earned in public matches only, and the tiers they
-- make (each unlocks its frame around the avatar icon: Data/Cosmetics rank frames). A solo match gives
-- nothing (its result is the player's own device's word). Every public match counts, bot players filling it
-- or not (2026-11-04: it took MIN_HUMANS = 4 people before).
--
--   placement   PLACE_RP x place score     place score = (1 - (place - 1) / (field - 1))^2 (Data/Stars)
--   victory     WIN_RP
--   a person    KILL_RP x the rank gap     2 ^ ((their tier - yours) / 2), within GAP_MIN..GAP_MAX: beating
--               eliminated                 someone two tiers above doubles it, two below halves it. The
--                                          same person pays at most HITS_PER_DAY times a day; an ally or a
--                                          party-mate never.
--   a bot       BOT_RP each, BOT_MAX a match; tribes nothing
--   a party     everything gained x 1 / (1 + PARTY_K x (size - 1))
--   leaving     LEAVE_RP (a loss) and no placement, while the match goes on
-- Stars' 2x pass never touches RP: rank can't be bought.
--
--   Ranks.points(result, ctx) -> number?   nil: the match isn't ranked
--       result: Data/Stars' Result; ctx = { humans, party, tier, victims = { { tier, bot, hits } } }
--   Ranks.tier(rp, top?) -> tier            top: the player's place in the top list (Grandmaster)
--   Ranks.TIERS                             { id, name, rp, color }, lowest first
--   Ranks.board(list, me, key, n) -> (rows, pin?)   a leaderboard's rows on screen, you among them or pinned
local Ranks = {}

Ranks.MIN_HUMANS = 1
Ranks.PLACE_RP = 40
Ranks.WIN_RP = 60
Ranks.KILL_RP = 10
Ranks.GAP_MIN = 0.25
Ranks.GAP_MAX = 4
Ranks.HITS_PER_DAY = 2
Ranks.BOT_RP = 1
Ranks.BOT_MAX = 5
Ranks.PARTY_K = 0.15
Ranks.LEAVE_RP = -10
--- Grandmaster: in the top list's first TOP_N, with Master's RP at least.
Ranks.TOP_N = 100
--- The leaderboards' rows on screen (UI/WorldRanks: the top SHOW_N, and you below them when you aren't).
Ranks.SHOW_N = 10
Ranks.MAX_RP = 100000000

Ranks.TIERS = {
	{ id = "recruit", name = "Recruit", rp = 0, color = 0x8A94A6 },
	{ id = "bronze", name = "Bronze", rp = 200, color = 0xC0773A },
	{ id = "silver", name = "Silver", rp = 600, color = 0xC9D2DC },
	{ id = "gold", name = "Gold", rp = 1200, color = 0xF2C230 },
	{ id = "platinum", name = "Platinum", rp = 2000, color = 0x4FD1C5 },
	{ id = "diamond", name = "Diamond", rp = 3200, color = 0x5DA8FF },
	{ id = "master", name = "Master", rp = 4800, color = 0xB36BFF },
	{ id = "grandmaster", name = "Grandmaster", rp = 4800, color = 0xFF4D6A },
}
local BY_ID: { [string]: any } = {}
for i, t in Ranks.TIERS do
	t.index = i
	BY_ID[t.id] = t
end

function Ranks.by_id(id: any): any
	return if type(id) == "string" then BY_ID[id] else nil
end

--- The tier `rp` makes; `top` = the player's place in the top list (1 = first), if they are on it.
function Ranks.tier(rp: number, top: number?): any
	local master = BY_ID.master
	if top ~= nil and top >= 1 and top <= Ranks.TOP_N and rp >= master.rp then
		return BY_ID.grandmaster
	end
	local best = Ranks.TIERS[1]
	for _, t in Ranks.TIERS do
		if t.id ~= "grandmaster" and rp >= t.rp then
			best = t
		end
	end
	return best
end

--- What a leaderboard shows (UI/WorldRanks): `list`'s top `n` (best first by `key`, "rp" or "secs") with
--- you (`me` = a row: { uid, [key], ... }) among them where you belong, else pinned below them. You count
--- even when the list doesn't have you yet (no points, or not stored yet: an empty board puts you first),
--- unless the list is full (Ranks.TOP_N) and you are below its last. Returns rows ({ { place, row, mine } })
--- and pin ({ place?, row }: place nil = below the whole full list) or nil when you are in the rows.
function Ranks.board(list: { any }, me: any, key: string, n: number): ({ any }, any)
	local at = nil
	for i, r in list do
		if r.uid == me.uid then
			at = i
			break
		end
	end
	local merged = list
	if at == nil then
		local v = tonumber(me[key]) or 0
		local slot = #list + 1
		for i, r in list do
			if v > (tonumber(r[key]) or 0) then
				slot = i
				break
			end
		end
		if slot <= #list or #list < Ranks.TOP_N then
			merged = table.clone(list)
			table.insert(merged, slot, me)
			at = slot
		end
	end
	local rows = {}
	for i = 1, math.min(n, #merged) do
		table.insert(rows, { place = i, row = merged[i], mine = i == at })
	end
	local pin = nil
	if at == nil then
		pin = { place = nil, row = me }
	elseif at > n then
		pin = { place = at, row = merged[at] }
	end
	return rows, pin
end

local function place_score(place: number, field: number): number
	if field <= 1 then
		return 1
	end
	local k = 1 - (math.clamp(place, 1, field) - 1) / (field - 1)
	return k * k
end

--- The RP a public match's result pays (negative: leaving), or nil when it isn't ranked.
function Ranks.points(r: any, ctx: any): number?
	if type(r) ~= "table" or type(ctx) ~= "table" then
		return nil
	end
	if (tonumber(ctx.humans) or 0) < Ranks.MIN_HUMANS or r.spawned ~= true then
		return nil
	end
	if r.left == true then
		return Ranks.LEAVE_RP
	end
	local gain = Ranks.PLACE_RP * place_score(tonumber(r.place) or 1, tonumber(r.field) or 1)
	if r.won == true then
		gain += Ranks.WIN_RP
	end
	local mine = tonumber(ctx.tier) or 1
	local bots = 0
	for _, v in (if type(ctx.victims) == "table" then ctx.victims else {}) :: { any } do
		if v.bot == true then
			if bots < Ranks.BOT_MAX then
				bots += 1
				gain += Ranks.BOT_RP
			end
		elseif v.friend ~= true and (tonumber(v.hits) or 0) < Ranks.HITS_PER_DAY then
			local gap = (tonumber(v.tier) or 1) - mine
			gain += Ranks.KILL_RP * math.clamp(2 ^ (gap / 2), Ranks.GAP_MIN, Ranks.GAP_MAX)
		end
	end
	local party = math.max(1, math.floor(tonumber(ctx.party) or 1))
	gain /= 1 + Ranks.PARTY_K * (party - 1)
	return math.floor(gain + 0.5)
end

return Ranks
