--!strict
-- Daily missions (2026-11-18; the Battle Pass, Data/BattlePass): every player gets BpDailyMissionCount of
-- them each UTC day, always BpMissionMix (2 easy, 2 medium, 1 hard), picked from POOL by (user id, day):
-- the same five on every server and on the client, never the same mission twice in a day.
--
-- A mission counts one stat of a match (Missions.stats: what the server measured itself in a public match,
-- server/MatchServer's Stars.Tracker; or, in a solo match, only what the server-clocked time and the bounded
-- solo report can vouch for, SOLO_STATS). A mission on any other stat counts in public matches only, and its
-- text says so (Missions.public_only). "sum" adds the stat over the day's matches; "best" is the best single
-- match.
--
--   Missions.today(user_id, day) -> { mission }   the day's missions, easy first
--   Missions.stats(result, extra?) -> stats       a match's stats (result: Data/Stars.Result)
--   Missions.step(m, progress, stats) -> progress  a mission's progress after one more match
local Missions = {}

--- Missions per player per day, and the mix by difficulty (each count: missions).
Missions.BpDailyMissionCount = 5
Missions.BpMissionMix = { easy = 2, medium = 2, hard = 1 }
--- The difficulties, easiest first.
Missions.DIFFICULTIES = { "easy", "medium", "hard" }

export type Mission = {
	id: string,
	diff: string,
	--- the stat it counts (Missions.stats' keys)
	stat: string,
	goal: number,
	--- "sum": over the day's matches; "best": one match's best
	mode: string,
}

--- The stats a solo match can report (its time is the server's clock; the rest is Stars.sanitize'd, bounded).
Missions.SOLO_STATS = {
	matches = true,
	minutes = true,
	survive = true,
	wins = true,
	top3 = true,
	top5 = true,
	top10 = true,
	land = true,
	kills = true,
}

local function m(id: string, diff: string, stat: string, goal: number, mode: string?): Mission
	return { id = id, diff = diff, stat = stat, goal = goal, mode = mode or "sum" }
end

--- Every mission. Its text is Data/Strings "bp.m.<id>" with {n} = the goal. Ids are saved in player
--- records: never reuse one for a different mission.
Missions.POOL = {
	-- easy
	m("play2", "easy", "matches", 2),
	m("minutes20", "easy", "minutes", 20),
	m("public1", "easy", "public", 1),
	m("survive10", "easy", "survive", 10, "best"),
	m("top10", "easy", "top10", 1),
	m("land10", "easy", "land", 10, "best"),
	m("kill1", "easy", "kills", 1),
	m("tribes5", "easy", "tribes", 5),
	m("cities3", "easy", "city", 3),
	m("ports2", "easy", "port", 2),
	m("factories2", "easy", "factory", 2),
	m("defense3", "easy", "defense", 3),
	m("warship1", "easy", "warship", 1),
	m("trade3", "easy", "trade", 3),
	m("ally1", "easy", "ally", 1),
	m("gold1m", "easy", "gold", 1000000),
	m("troops200k", "easy", "troops", 200000, "best"),
	-- medium
	m("play4", "medium", "matches", 4),
	m("minutes45", "medium", "minutes", 45),
	m("public3", "medium", "public", 3),
	m("survive25", "medium", "survive", 25, "best"),
	m("top5", "medium", "top5", 1),
	m("land25", "medium", "land", 25, "best"),
	m("kill3", "medium", "kills", 3),
	m("tribes15", "medium", "tribes", 15),
	m("cities8", "medium", "city", 8),
	m("sam2", "medium", "sam", 2),
	m("silo1", "medium", "silo", 1),
	m("warships3", "medium", "warship", 3),
	m("nukes2", "medium", "nuke", 2),
	m("airstrike2", "medium", "airstrike", 2),
	m("railgun3", "medium", "slug", 3),
	m("intercept1", "medium", "intercept", 1),
	m("accept1", "medium", "accept", 1),
	m("gold4m", "medium", "gold", 4000000),
	m("troops1m", "medium", "troops", 1000000, "best"),
	-- hard
	m("win1", "hard", "wins", 1),
	m("top3x2", "hard", "top3", 2),
	m("minutes120", "hard", "minutes", 120),
	m("land50", "hard", "land", 50, "best"),
	m("kill8", "hard", "kills", 8),
	m("pwin1", "hard", "pwins", 1),
	m("mirv1", "hard", "mirv", 1),
	m("nukes5", "hard", "nuke", 5),
	m("intercept5", "hard", "intercept", 5),
	m("ally3", "hard", "ally", 3),
	m("gold15m", "hard", "gold", 15000000),
	m("troops3m", "hard", "troops", 3000000, "best"),
} :: { Mission }

local BY_ID: { [string]: Mission } = {}
for _, x in Missions.POOL do
	assert(BY_ID[x.id] == nil, "duplicate mission id " .. x.id)
	BY_ID[x.id] = x
end

function Missions.get(id: any): Mission?
	return if type(id) == "string" then BY_ID[id] else nil
end

--- True when the mission counts in public matches only (a solo report can't vouch for its stat).
function Missions.public_only(x: Mission): boolean
	return not Missions.SOLO_STATS[x.stat]
end

--- Its text's Data/Strings key.
function Missions.key(x: Mission): string
	return "bp.m." .. x.id
end

--- The place a "top N" mission names (its stat "top3" / "top5" / "top10"), or nil.
function Missions.place(x: Mission): number?
	return tonumber(string.match(x.stat, "^top(%d+)$"))
end

-- (a Park-Miller generator: integers only, exact in doubles, the same in Lune and on Roblox)
local P = 2147483647
local function seed_of(user_id: number, day: number, salt: number): number
	local u = math.floor(math.abs(tonumber(user_id) or 0))
	local s = ((u % P) * 7919 + (u // P) % P * 104729 + (day % P) * 1000003 + salt * 7777) % P
	if s == 0 then
		s = 1
	end
	-- (a few rounds so near seeds part ways)
	for _ = 1, 3 do
		s = s * 48271 % P
	end
	return s
end

--- The day's missions of user `user_id` (`day`: UTC days since 1970): BpMissionMix of each difficulty,
--- easy first, no two the same (and, where the pool allows, no two on the same stat).
function Missions.today(user_id: number, day: number): { Mission }
	local out: { Mission } = {}
	local stats: { [string]: boolean } = {}
	for k, diff in Missions.DIFFICULTIES do
		local want = Missions.BpMissionMix[diff] or 0
		local list: { Mission } = {}
		for _, x in Missions.POOL do
			if x.diff == diff then
				table.insert(list, x)
			end
		end
		-- Fisher-Yates with the seeded generator
		local s = seed_of(user_id, day, k)
		for i = #list, 2, -1 do
			s = s * 48271 % P
			local j = s % i + 1
			list[i], list[j] = list[j], list[i]
		end
		local got = 0
		for pass = 1, 2 do
			for _, x in list do
				if got >= want then
					break
				end
				if not table.find(out, x) and (pass == 2 or not stats[x.stat]) then
					table.insert(out, x)
					stats[x.stat] = true
					got += 1
				end
			end
		end
	end
	return out
end

--- A mission's progress after one more match with `st` (its stats).
function Missions.step(x: Mission, progress: number, st: { [string]: number }): number
	local v = tonumber(st[x.stat]) or 0
	if v ~= v or v <= 0 then
		return progress
	end
	if x.mode == "best" then
		return math.max(progress, v)
	end
	return progress + v
end

--- A match's mission stats: from its result (Data/Stars.Result: in solo, the sanitized report) and, in a
--- public match, what the server measured besides (`extra`: Stars.Tracker's counts). Whole numbers, never
--- negative.
function Missions.stats(r: any, extra: { [string]: number }?): { [string]: number }
	local st: { [string]: number } = {}
	if type(r) ~= "table" or r.spawned ~= true then
		return st
	end
	local minutes = math.max(tonumber(r.minutes) or 0, 0)
	-- (a match left early counts its minutes, not as a match played: as Data/Stars' "played" line)
	local stayed = r.left ~= true
	st.matches = if stayed then 1 else nil
	st.minutes = math.floor(minutes)
	st.survive = math.floor(minutes)
	local field = math.max(tonumber(r.field) or 1, 1)
	local place = tonumber(r.place) or field
	if r.won == true then
		st.wins = 1
	end
	if r.left ~= true then
		for _, n in { 3, 5, 10 } do
			if place <= n and field > n then
				st["top" .. n] = 1
			end
		end
	end
	-- the peak land as a share of the map: shares are fair shares (the map's land / the field)
	st.land = math.floor(math.max(tonumber(r.shares) or 0, 0) / field * 100)
	st.kills = math.floor(math.max(tonumber(r.kills) or 0, 0))
	if extra ~= nil then
		st.public = if stayed then 1 else nil
		if r.won == true then
			st.pwins = 1
		end
		for k, v in extra do
			if type(k) == "string" and type(v) == "number" and v == v and v > 0 then
				st[k] = math.floor(v)
			end
		end
	end
	return st
end

--- Only the stats a solo match may count (SOLO_STATS).
function Missions.solo_only(st: { [string]: number }): { [string]: number }
	local out: { [string]: number } = {}
	for k, v in st do
		if Missions.SOLO_STATS[k] then
			out[k] = v
		end
	end
	return out
end

return Missions
