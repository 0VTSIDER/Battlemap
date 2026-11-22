--!strict
-- The Battle Pass (2026-11-18): a season a calendar month long (UTC; Data/Seasons), 100 levels of
-- BpXpPerLevel XP and then bonus levels without end. XP comes from playing (public matches, and solo matches
-- by the server's clock), winning, and the daily missions (Data/Missions). A reward dot every
-- BpMilestoneEvery levels on two tracks: the free one (Stars, and the season's badge, frame and avatar) and
-- the premium one (a Robux developer product, Data/Products.bp_premium: twice the Stars, and the season's
-- territory skin, frame and avatar). Rewards are given the moment their level is reached (no claim).
--
-- The player's pass is a field of their Purchases record (`bp`, BattlePass.clean): it resets lazily, on the
-- first read in a new month (XP, level, premium, missions; items earned stay owned) and in a new UTC day (the
-- missions). A match's XP and mission progress ride on its Stars payout (server/Purchases: the same write and
-- payout id, so a retried payout applies once): BattlePass.apply.
--
--   BattlePass.now() -> unix s                   (the dev diag's day offset, behind DebugBpClock)
--   BattlePass.season_of(t) -> "YYYY-MM"          BattlePass.day_of(t) -> UTC days since 1970
--   BattlePass.season_end(id) -> unix s           BattlePass.days_left(t) -> whole days, at least 1
--   BattlePass.level(xp) -> level                 BattlePass.reward(season, track, level) -> Reward?
--   BattlePass.match_xp_public(result) / match_xp_solo(result, real_minutes) -> XP
--   BattlePass.clean(v, t) -> Bp                  BattlePass.apply(rec, user_id, gain, t) -> Outcome
--   BattlePass.unlock_premium(rec, t) -> (ok, Outcome)
local IS_ROBLOX = typeof(game) == "Instance"
local Cosmetics: any = if IS_ROBLOX then require((script :: any).Parent.Cosmetics) else require("./Cosmetics")
local Seasons: any = if IS_ROBLOX then require((script :: any).Parent.Seasons) else require("./Seasons")
local Missions: any = if IS_ROBLOX then require((script :: any).Parent.Missions) else require("./Missions")

local BattlePass = {}

-- =============================================================================================
-- Tunables
-- =============================================================================================
BattlePass.BpXpPerLevel = 250 -- XP per level (main and bonus levels alike)
BattlePass.BpMainLevels = 100 -- levels with the season's rewards; past them, bonus levels (free Stars only)
BattlePass.BpMilestoneEvery = 10 -- a reward dot every this many levels, on each track
BattlePass.BpXpPerMinutePublic = 10 -- XP per minute played in a public match
BattlePass.BpXpMatchCapPublic = 300 -- the most XP a public match's minutes pay
BattlePass.BpXpPerMinuteSolo = 6 -- XP per minute of a solo match, by the server's clock
BattlePass.BpXpMatchCapSolo = 300 -- the most XP a solo match's minutes pay
BattlePass.BpXpWinBonusPublic = 300 -- XP for winning a public match
BattlePass.BpXpWinBonusSolo = 100 -- XP for winning a solo match
BattlePass.BpSoloWinMinMinutes = 5 -- server-clocked minutes a solo win needs before its bonus pays
BattlePass.BpSoloMissionMinMinutes = 3 -- server-clocked minutes a solo match needs to count for missions
BattlePass.BpMissionXp = { easy = 100, medium = 150, hard = 250 } -- XP a completed daily mission gives
--- Stars on the free track's Stars dots (level -> Stars)
BattlePass.BpFreeStars = { [10] = 1000, [20] = 1500, [40] = 2000, [50] = 2500, [70] = 3000, [80] = 3500, [90] = 4000 }
--- Premium Stars where the free dot is an item (level -> Stars; elsewhere premium pays twice the free Stars)
BattlePass.BpPremiumItemLevelStars = { [30] = 4000, [60] = 6000, [100] = 10000 }
BattlePass.BpBonusStars = 2000 -- free Stars every BpMilestoneEvery bonus levels past BpMainLevels
--- An item reward the player owns already comes as this many Stars (by the item's rarity)
BattlePass.BpOwnedItemStars = { common = 500, uncommon = 1000, rare = 2000, epic = 4000, legendary = 8000 }
--- A Stars dot's colour (Cosmetics.RARITIES): common below 2,000 Stars, uncommon from 2,000, rare from 3,000
BattlePass.BpStarsUncommon = 2000
BattlePass.BpStarsRare = 3000

--- The season's items on each track (level -> Data/Seasons field).
BattlePass.FREE_ITEMS = { [30] = "badge", [60] = "frame", [100] = "avatar" }
BattlePass.PREMIUM_ITEMS = { [20] = "premium_skin", [50] = "premium_frame", [90] = "premium_avatar" }
--- Bounds on what a record or a payout may hold.
BattlePass.MAX_XP = 10000000
BattlePass.MAX_STARS = 1000000000
BattlePass.MAX_MATCH_XP = math.max(
	BattlePass.BpXpMatchCapPublic + BattlePass.BpXpWinBonusPublic,
	BattlePass.BpXpMatchCapSolo + BattlePass.BpXpWinBonusSolo
)

-- =============================================================================================
-- The clock
-- =============================================================================================
--- Dev diag only (Studio, BM_DIAG): when on, the clock runs debug_offset_s ahead (the "day" diag, a
--- season rollover test). Never on in a live server.
BattlePass.DebugBpClock = false
BattlePass.debug_offset_s = 0
--- Dev diag only: the server's Battle Pass diag commands (ServerMain.bp_diag; Studio + BM_DIAG anyway), and
--- their log lines.
BattlePass.DebugBpDiag = true
BattlePass.DebugLogBp = false

function BattlePass.now(): number
	return os.time() + (if BattlePass.DebugBpClock then BattlePass.debug_offset_s else 0)
end

-- (civil dates from day numbers and back: H. Hinnant's algorithms, integers only)
local function days_from_civil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function civil_from_days(z: number): (number, number, number)
	z += 719468
	local era = (if z >= 0 then z else z - 146096) // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	return (if m <= 2 then y + 1 else y), m, d
end

--- UTC days since 1970 of unix time `t`.
function BattlePass.day_of(t: number): number
	return math.floor(t) // 86400
end

--- The season ("YYYY-MM": the month it starts in) of unix time `t`: the month's own, or a longer
--- season that covers the month (Seasons.LENGTH_MONTHS).
function BattlePass.season_of(t: number): string
	local y, m = civil_from_days(BattlePass.day_of(t))
	return Seasons.of_month(string.format("%04d-%02d", y, m))
end

--- When season `id` ends (the first second of the month after its last), unix s.
function BattlePass.season_end(id: string): number
	local y = tonumber(string.sub(id, 1, 4)) or 1970
	local m = (tonumber(string.sub(id, 6, 7)) or 1) + Seasons.months(id)
	while m > 12 do
		y, m = y + 1, m - 12
	end
	return days_from_civil(y, m, 1) * 86400
end

--- Whole days left in the season at `t` (at least 1: the last day shows 1).
function BattlePass.days_left(t: number): number
	local left = BattlePass.season_end(BattlePass.season_of(t)) - t
	return math.max(1, math.ceil(left / 86400))
end

-- =============================================================================================
-- Levels and rewards
-- =============================================================================================
function BattlePass.level(xp: number): number
	return math.max(0, math.floor(xp)) // BattlePass.BpXpPerLevel
end

--- (level, XP into it, XP the level takes)
function BattlePass.progress(xp: number): (number, number, number)
	local x = math.max(0, math.floor(xp))
	return x // BattlePass.BpXpPerLevel, x % BattlePass.BpXpPerLevel, BattlePass.BpXpPerLevel
end

export type Reward = { kind: string, id: string?, stars: number? }

--- The reward of `track` ("free" | "premium") at `level` in season `season_id`, or nil (no dot there).
function BattlePass.reward(season_id: string, track: string, level: number): Reward?
	local every = BattlePass.BpMilestoneEvery
	if level <= 0 or level % every ~= 0 then
		return nil
	end
	local season = Seasons.get(season_id)
	if track == "free" then
		if level > BattlePass.BpMainLevels then
			return { kind = "stars", stars = BattlePass.BpBonusStars }
		end
		local f = BattlePass.FREE_ITEMS[level]
		if f ~= nil then
			return { kind = "item", id = season[f] }
		end
		local n = BattlePass.BpFreeStars[level]
		return if n ~= nil then { kind = "stars", stars = n } else nil
	end
	if level > BattlePass.BpMainLevels then
		return nil
	end
	local f = BattlePass.PREMIUM_ITEMS[level]
	if f ~= nil then
		return { kind = "item", id = season[f] }
	end
	local free = BattlePass.BpFreeStars[level]
	local n = if free ~= nil then free * 2 else BattlePass.BpPremiumItemLevelStars[level]
	return if n ~= nil then { kind = "stars", stars = n } else nil
end

--- A reward's rarity id (Cosmetics.RARITIES): an item's own, Stars by amount.
function BattlePass.rarity(r: Reward): string
	if r.kind == "item" then
		local it = Cosmetics.item(r.id)
		return if it ~= nil then it.rarity else "epic"
	end
	local n = r.stars or 0
	if n >= BattlePass.BpStarsRare then
		return "rare"
	elseif n >= BattlePass.BpStarsUncommon then
		return "uncommon"
	end
	return "common"
end

-- =============================================================================================
-- XP for a match
-- =============================================================================================
--- A public match's XP (a Data/Stars result the server measured).
function BattlePass.match_xp_public(r: any): number
	if type(r) ~= "table" or r.spawned ~= true then
		return 0
	end
	local mins = math.max(tonumber(r.minutes) or 0, 0)
	local xp = math.min(math.floor(BattlePass.BpXpPerMinutePublic * mins), BattlePass.BpXpMatchCapPublic)
	if r.won == true then
		xp += BattlePass.BpXpWinBonusPublic
	end
	return xp
end

--- A solo match's XP: its (sanitized) result, and the minutes it really lasted by the server's clock.
--- Minutes never count past that time, and the win bonus needs BpSoloWinMinMinutes of it.
function BattlePass.match_xp_solo(r: any, real_minutes: number): number
	if type(r) ~= "table" or r.spawned ~= true then
		return 0
	end
	local real = math.max(real_minutes, 0)
	local mins = math.min(math.max(tonumber(r.minutes) or 0, 0), real)
	local xp = math.min(math.floor(BattlePass.BpXpPerMinuteSolo * mins), BattlePass.BpXpMatchCapSolo)
	if r.won == true and real >= BattlePass.BpSoloWinMinMinutes then
		xp += BattlePass.BpXpWinBonusSolo
	end
	return xp
end

-- =============================================================================================
-- The saved pass
-- =============================================================================================
--- The record's `bp` field: season, XP, premium bought for it, the highest level whose free / premium
--- reward was given, the day of the missions, their progress and which are done.
export type Bp = {
	s: string,
	xp: number,
	prem: boolean,
	fl: number,
	pl: number,
	d: number,
	mp: { [string]: number },
	md: { [string]: boolean },
}

local function whole(x: any, top: number): number
	local n = tonumber(x) or 0
	return if n ~= n then 0 else math.clamp(math.floor(n), 0, top)
end

--- `v` (a stored `bp`, or nil) made safe, and rolled over to the season and day of unix time `t`: a new
--- month starts the pass over, a new day the missions.
function BattlePass.clean(v: any, t: number): Bp
	local season, day = BattlePass.season_of(t), BattlePass.day_of(t)
	local bp: Bp = { s = season, xp = 0, prem = false, fl = 0, pl = 0, d = day, mp = {}, md = {} }
	if type(v) ~= "table" or v.s ~= season then
		return bp
	end
	bp.xp = whole(v.xp, BattlePass.MAX_XP)
	bp.prem = v.prem == true
	bp.fl = whole(v.fl, 1000000)
	bp.pl = whole(v.pl, 1000000)
	if tonumber(v.d) == day then
		if type(v.mp) == "table" then
			for id, n in v.mp do
				if Missions.get(id) ~= nil then
					bp.mp[id] = whole(n, 1e12)
				end
			end
		end
		if type(v.md) == "table" then
			for id, on in v.md do
				if on == true and Missions.get(id) ~= nil then
					bp.md[id] = true
				end
			end
		end
	end
	return bp
end

--- A payout's pass part (as it travels and is kept for later) made safe, or nil:
--- { s = season, d = day, xp = n, st = { [stat]: n }? }.
function BattlePass.clean_gain(g: any): any
	if type(g) ~= "table" or type(g.s) ~= "string" or #g.s > 8 then
		return nil
	end
	local out: any = { s = g.s, d = whole(g.d, 1e7), xp = whole(g.xp, BattlePass.MAX_MATCH_XP) }
	if type(g.st) == "table" then
		local st = {}
		local n = 0
		for k, v in g.st do
			if type(k) == "string" and #k <= 16 and n < 40 then
				st[k] = whole(v, 1e12)
				n += 1
			end
		end
		out.st = st
	end
	return out
end

export type Outcome = {
	--- XP added (the match's and its completed missions')
	xp: number,
	--- the XP before and after
	from: number,
	to: number,
	--- the missions it completed (ids)
	missions: { string },
	--- the rewards given: { track, level, kind = "item" | "stars", id?, stars, owned? (an item owned already, as Stars) }
	grants: { any },
}

--- Gives every reward reached and not given yet (free, and premium when bought) on record `rec`
--- (Purchases' record: bp, owned, stars, stars_earned). Free Stars count as earned; premium ones were bought.
local function settle(rec: any, grants: { any })
	local bp: Bp = rec.bp
	local lv = BattlePass.level(bp.xp)
	local every = BattlePass.BpMilestoneEvery
	local function give(track: string, level: number)
		local r = BattlePass.reward(bp.s, track, level)
		if r == nil then
			return
		end
		local g: any = { track = track, level = level, kind = r.kind, id = r.id, stars = 0 }
		local stars = r.stars or 0
		if r.kind == "item" then
			if rec.owned[r.id] then
				local it = Cosmetics.item(r.id)
				stars = BattlePass.BpOwnedItemStars[if it ~= nil then it.rarity else "epic"] or 0
				g.owned = true
			else
				rec.owned[r.id] = true
			end
		end
		if stars > 0 then
			g.stars = stars
			rec.stars = math.min((rec.stars or 0) + stars, BattlePass.MAX_STARS)
			if track == "free" then
				rec.stars_earned = math.min((rec.stars_earned or 0) + stars, BattlePass.MAX_STARS)
			end
		end
		table.insert(grants, g)
	end
	if lv > bp.fl then
		for level = (bp.fl // every + 1) * every, lv, every do
			give("free", level)
		end
		bp.fl = lv
	end
	if bp.prem then
		local top = math.min(lv, BattlePass.BpMainLevels)
		if top > bp.pl then
			for level = (bp.pl // every + 1) * every, top, every do
				give("premium", level)
			end
			bp.pl = top
		end
	end
end

--- Applies a payout's pass part `gain` (BattlePass.clean_gain) to record `rec` of user `user_id` at unix
--- time `t`: the XP, the day's missions it advances (each completed one adds its XP), and every reward
--- reached. A gain from a season that is over adds nothing to this one, and mission progress from another
--- day counts for none (a payout kept for later and stored after midnight).
function BattlePass.apply(rec: any, user_id: number, gain: any, t: number): Outcome
	local bp = BattlePass.clean(rec.bp, t)
	rec.bp = bp
	local out: Outcome = { xp = 0, from = bp.xp, to = bp.xp, missions = {}, grants = {} }
	local g = BattlePass.clean_gain(gain)
	if g == nil or g.s ~= bp.s then
		return out
	end
	local add = g.xp
	if g.d == bp.d and g.st ~= nil then
		for _, x in Missions.today(user_id, bp.d) do
			if not bp.md[x.id] then
				local before = bp.mp[x.id] or 0
				local p = math.min(Missions.step(x, before, g.st), x.goal)
				if p ~= before then
					bp.mp[x.id] = p
				end
				if p >= x.goal then
					bp.md[x.id] = true
					add += BattlePass.BpMissionXp[x.diff] or 0
					table.insert(out.missions, x.id)
				end
			end
		end
	end
	bp.xp = math.min(bp.xp + add, BattlePass.MAX_XP)
	out.xp = add
	out.to = bp.xp
	settle(rec, out.grants)
	return out
end

--- Premium for the season of `t` on record `rec`, and every premium reward already reached. False when it
--- has premium already (nothing changes).
function BattlePass.unlock_premium(rec: any, t: number): (boolean, Outcome)
	local bp = BattlePass.clean(rec.bp, t)
	rec.bp = bp
	local out: Outcome = { xp = 0, from = bp.xp, to = bp.xp, missions = {}, grants = {} }
	if bp.prem then
		return false, out
	end
	bp.prem = true
	settle(rec, out.grants)
	return true, out
end

--- What the client is sent of a pass (the inventory's `bp`): the record's fields, the season's end and
--- the server's clock (the client counts from it: the dev diag's offset shows too).
function BattlePass.view(bp: Bp, t: number): any
	return {
		s = bp.s,
		xp = bp.xp,
		prem = bp.prem,
		d = bp.d,
		mp = table.clone(bp.mp),
		md = table.clone(bp.md),
		ends = BattlePass.season_end(bp.s),
		now = t,
	}
end

return BattlePass
