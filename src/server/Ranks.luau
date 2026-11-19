--!strict
-- The global leaderboard on the server (shared/Data/Ranks; 2026-11-04). A player's Rank Points live in
-- their purchases record (server/Purchases.add_rp); an OrderedDataStore mirrors them for the top list
-- (Roblox's ordered stores list the top only: nobody's exact place below it is known, so a frame is a
-- tier by RP, Grandmaster for the top list's first Ranks.TOP_N).
--
--   ServerRanks.configure(deps)   { ordered = OrderedDataStore, add_rp = fn(player, delta, won, victims) ->
--                                   (ok, rp), rp = fn(player) -> rp, hits = fn(player, uid) -> n,
--                                   name_of = fn(uid) -> string?, now = fn() -> s, log? }
--   ServerRanks.award(player, result, ctx)   a public match's result (MatchServer._rank_context; yields)
--   ServerRanks.top() -> { { uid, rp, name } }   the top list, read at most every TOP_REFRESH_S (yields)
--   ServerRanks.place(uid) -> number?          the user's place in the top list as last read
--   ServerRanks.tier_of(player) -> tier        their tier now (Data/Ranks.tier)
--   ServerRanks.remember(uid, rp)              a player's RP as loaded (their tier counts for whoever
--                                              eliminates them, even once they have left)
-- The playtime leaderboard (2026-11-04): seconds of match play (Purchases.add_playtime) mirrored to a
-- second ordered store (deps.ordered_time).
--   ServerRanks.played(player, total_s)        list the player's new total
--   ServerRanks.top_time() -> { { uid, secs, name } }   that board's top list (yields)
--   ServerRanks.time_place(uid) -> number?
local IS_ROBLOX = typeof(game) == "Instance"
local Ranks: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Ranks)
	else require("../shared/Data/Ranks")

local ServerRanks = {}

ServerRanks.TOP_REFRESH_S = 60
ServerRanks.STORE = "BattlemapRanks_v1"
ServerRanks.TIME_STORE = "BattlemapPlaytime_v1"

local deps: any = {}
--- user id -> RP (players seen on this server)
local known: { [number]: number } = {}
local top_list: { any } = {}
local top_place: { [number]: number } = {}
local top_at = -1e9
local reading = false
local time_list: { any } = {}
local time_place: { [number]: number } = {}
local time_at = -1e9
local time_reading = false

function ServerRanks.configure(d: any)
	for k, v in d do
		deps[k] = v
	end
end

function ServerRanks.reset()
	table.clear(deps)
	table.clear(known)
	table.clear(top_place)
	top_list = {}
	top_at = -1e9
	reading = false
	time_list = {}
	table.clear(time_place)
	time_at = -1e9
	time_reading = false
end

local function now(): number
	return if deps.now then deps.now() else os.clock()
end

local function log(text: string)
	if deps.log then
		deps.log("[Ranks] " .. text)
	end
end

function ServerRanks.remember(uid: number, rp: number)
	if type(uid) == "number" and uid > 0 then
		known[uid] = rp
	end
end

function ServerRanks.place(uid: number): number?
	return top_place[uid]
end

local function tier_by_uid(uid: number, rp: number?): any
	local r = rp or known[uid] or 0
	return Ranks.tier(r, top_place[uid])
end

function ServerRanks.tier_of(player: any): any
	local rp = if deps.rp then deps.rp(player) else 0
	return tier_by_uid(player.UserId, rp)
end

--- A public match's result for `player` (ctx: MatchServer._rank_context). Returns the RP change, or nil
--- when the match isn't ranked.
function ServerRanks.award(player: any, result: any, ctx: any): number?
	if type(ctx) ~= "table" or deps.add_rp == nil then
		return nil
	end
	local mine = ServerRanks.tier_of(player)
	local victims, counted = {}, {}
	for _, v in (if type(ctx.victims) == "table" then ctx.victims else {}) :: { any } do
		if v.bot then
			table.insert(victims, { bot = true })
		elseif type(v.uid) == "number" and v.uid ~= player.UserId then
			local hits = if deps.hits then deps.hits(player, v.uid) else 0
			table.insert(victims, { tier = tier_by_uid(v.uid).index, hits = hits, friend = v.friend == true })
			if not v.friend then
				table.insert(counted, v.uid)
			end
		end
	end
	local pts = Ranks.points(result, { humans = ctx.humans, party = ctx.party, tier = mine.index, victims = victims })
	if pts == nil then
		return nil
	end
	local ok, rp = deps.add_rp(player, pts, result.won == true, counted)
	if not ok then
		return nil
	end
	ServerRanks.remember(player.UserId, rp)
	if deps.ordered ~= nil then
		local stored, err = pcall(function()
			deps.ordered:SetAsync(tostring(player.UserId), rp)
		end)
		if not stored then
			log("could not list " .. tostring(player.UserId) .. ": " .. tostring(err))
		end
	end
	log(string.format("%d %+d RP -> %d", player.UserId, pts, rp))
	return pts
end

--- The top list ({ uid, rp, name }, best first), read again at most every TOP_REFRESH_S. Yields.
function ServerRanks.top(): { any }
	if deps.ordered == nil or reading or now() - top_at < ServerRanks.TOP_REFRESH_S then
		return top_list
	end
	reading = true
	local ok, err = pcall(function()
		local pages = deps.ordered:GetSortedAsync(false, Ranks.TOP_N)
		local list = {}
		for _, row in pages:GetCurrentPage() do
			local uid = tonumber(row.key)
			if uid ~= nil then
				table.insert(list, { uid = uid, rp = math.floor(tonumber(row.value) or 0) })
			end
		end
		for _, r in list do
			local n = nil
			if deps.name_of then
				local got, v = pcall(deps.name_of, r.uid)
				n = if got and type(v) == "string" then v else nil
			end
			r.name = n or ("Player " .. r.uid)
		end
		top_list = list
		table.clear(top_place)
		for i, r in list do
			top_place[r.uid] = i
			known[r.uid] = r.rp
		end
	end)
	top_at = now()
	reading = false
	if not ok then
		log("could not read the top list: " .. tostring(err))
	end
	return top_list
end

function ServerRanks.time_place(uid: number): number?
	return time_place[uid]
end

--- Lists `player`'s playtime total (seconds) on the playtime board. Yields.
function ServerRanks.played(player: any, total_s: number)
	if deps.ordered_time == nil then
		return
	end
	local ok, err = pcall(function()
		deps.ordered_time:SetAsync(tostring(player.UserId), math.floor(total_s))
	end)
	if not ok then
		log("could not list the playtime of " .. tostring(player.UserId) .. ": " .. tostring(err))
	end
end

--- The playtime board's top list ({ uid, secs, name }, most first), read at most every TOP_REFRESH_S. Yields.
function ServerRanks.top_time(): { any }
	if deps.ordered_time == nil or time_reading or now() - time_at < ServerRanks.TOP_REFRESH_S then
		return time_list
	end
	time_reading = true
	local ok, err = pcall(function()
		local pages = deps.ordered_time:GetSortedAsync(false, Ranks.TOP_N)
		local list = {}
		for _, row in pages:GetCurrentPage() do
			local uid = tonumber(row.key)
			if uid ~= nil then
				table.insert(list, { uid = uid, secs = math.floor(tonumber(row.value) or 0) })
			end
		end
		for _, r in list do
			local n = nil
			if deps.name_of then
				local got, v = pcall(deps.name_of, r.uid)
				n = if got and type(v) == "string" then v else nil
			end
			r.name = n or ("Player " .. r.uid)
		end
		time_list = list
		table.clear(time_place)
		for i, r in list do
			time_place[r.uid] = i
		end
	end)
	time_at = now()
	time_reading = false
	if not ok then
		log("could not read the playtime list: " .. tostring(err))
	end
	return time_list
end

return ServerRanks
