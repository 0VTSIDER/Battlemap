--!strict
-- Roblox platform badges (shared/Data/PlatformBadges; BadgeService): awarded once per player, never
-- blocking gameplay. Each (player, badge) asks Roblox at most once a session when it goes well:
-- UserHasBadgeAsync first, then AwardBadge, and the answer is cached until PlayerRemoving, so a player who
-- has a badge never triggers another call. Every call is pcall'd in its own thread (Studio and unpublished
-- places fail them: a failure is retried on a later trigger, at most MAX_TRIES times a session).
--
--   PlatformBadges.configure(deps)        { service? = a BadgeService, spawn? = fn(f), log? = fn(text) }
--   PlatformBadges.joined(player)         PlayerAdded: WELCOME
--   PlatformBadges.public_result(player, result)   a result this server measured (Data/Stars.Tracker)
--   PlatformBadges.solo_result(player, r, real_minutes)   a sanitized solo report (server/Rewards) and the
--                                         minutes the match really lasted by the server's clock
--   PlatformBadges.pass_xp(player, xp)    the player's Battle Pass XP (every inventory sent)
--   PlatformBadges.release(player)        PlayerRemoving
local IS_ROBLOX = typeof(game) == "Instance"
local Shared: any = if IS_ROBLOX then (game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap") else nil
local Ids: any = if IS_ROBLOX then require(Shared.Data.PlatformBadges) else require("../shared/Data/PlatformBadges")
local BattlePass: any = if IS_ROBLOX then require(Shared.Data.BattlePass) else require("../shared/Data/BattlePass")

--- BadgeService errors to the log (once each kind a server).
local DebugLogPlatformBadges = false

local PlatformBadges = {}

--- Failed checks / awards one badge may have per player per session before it is left alone (tries).
PlatformBadges.MAX_TRIES = 3

type Entry = { owned: { [number]: boolean }, busy: { [number]: boolean }, tries: { [number]: number } }

local deps: { [string]: any } = {}
local players: { [any]: Entry } = {}
local logged: { [string]: boolean } = {}

function PlatformBadges.configure(d: { [string]: any })
	for k, v in d do
		deps[k] = v
	end
end

--- Tests: forget everyone (and what was logged).
function PlatformBadges.reset()
	table.clear(players)
	table.clear(logged)
end

local function service(): any
	if deps.service ~= nil then
		return deps.service
	end
	if not IS_ROBLOX then
		return nil
	end
	local ok, s = pcall(function()
		return (game :: any):GetService("BadgeService")
	end)
	return if ok then s else nil
end

local function log_once(what: string, err: any)
	if not DebugLogPlatformBadges or logged[what] then
		return
	end
	logged[what] = true
	local text = string.format("[PlatformBadges] %s failed: %s", what, tostring(err))
	if deps.log then
		pcall(deps.log, text)
	elseif IS_ROBLOX then
		warn(text)
	end
end

local function failed(e: Entry, id: number, what: string, err: any)
	e.busy[id] = nil
	e.tries[id] = (e.tries[id] or 0) + 1
	log_once(what, err)
end

--- Asks Roblox about badge `id` for `player` and awards it when missing (in its own thread).
function PlatformBadges.award(player: any, id: number)
	local e = players[player]
	if e == nil or type(id) ~= "number" or id <= 0 then
		return
	end
	if e.owned[id] or e.busy[id] or (e.tries[id] or 0) >= PlatformBadges.MAX_TRIES then
		return
	end
	e.busy[id] = true
	local spawn = deps.spawn or task.spawn
	spawn(function()
		local svc = service()
		local uid = if typeof(player) == "Instance" or type(player) == "table" then (player :: any).UserId else nil
		if svc == nil or type(uid) ~= "number" then
			e.busy[id] = nil
			e.tries[id] = PlatformBadges.MAX_TRIES
			log_once("BadgeService", "unavailable")
			return
		end
		local ok, has = pcall(svc.UserHasBadgeAsync, svc, uid, id)
		if players[player] ~= e then
			return -- (left meanwhile)
		end
		if not ok then
			failed(e, id, "UserHasBadgeAsync", has)
			return
		end
		if has == true then
			e.busy[id] = nil
			e.owned[id] = true
			return
		end
		local ok2, res = pcall(svc.AwardBadge, svc, uid, id)
		if players[player] ~= e then
			return
		end
		if ok2 and res == true then
			e.busy[id] = nil
			e.owned[id] = true
		else
			failed(e, id, "AwardBadge", if ok2 then "returned " .. tostring(res) else res)
		end
	end)
end

function PlatformBadges.joined(player: any)
	if players[player] == nil then
		players[player] = { owned = {}, busy = {}, tries = {} }
	end
	PlatformBadges.award(player, Ids.WELCOME)
end

function PlatformBadges.release(player: any)
	players[player] = nil
end

--- A result this server measured itself (Data/Stars.Tracker: a public match).
function PlatformBadges.public_result(player: any, r: any)
	if type(r) ~= "table" or r.spawned ~= true then
		return
	end
	if r.won == true then
		PlatformBadges.award(player, Ids.FIRST_VICTORY)
	end
	if r.took == true then
		PlatformBadges.award(player, Ids.FIRST_CONQUEST)
	end
	-- (shares are fair shares of the land: field of them is all of it)
	local shares, field = tonumber(r.shares) or 0, math.max(tonumber(r.field) or 1, 1)
	if shares / field >= Ids.WorldPowerShare then
		PlatformBadges.award(player, Ids.WORLD_POWER)
	end
	local extra = r.extra
	if type(extra) == "table" and (tonumber(extra.ally) or 0) > 0 then
		PlatformBadges.award(player, Ids.ALLIANCE_MAKER)
	end
end

--- A solo match's sanitized report (Stars.sanitize) and the minutes it really lasted by the server's clock.
--- Only the win counts, bounded as the Battle Pass's win bonus is (BattlePass.BpSoloWinMinMinutes): its map
--- share, conquests and alliances are the client's word alone.
function PlatformBadges.solo_result(player: any, r: any, real_minutes: number)
	if type(r) ~= "table" or r.spawned ~= true then
		return
	end
	if r.won == true and r.left ~= true and (tonumber(real_minutes) or 0) >= BattlePass.BpSoloWinMinMinutes then
		PlatformBadges.award(player, Ids.FIRST_VICTORY)
	end
end

--- The player's Battle Pass XP (the season's, stored and owed).
function PlatformBadges.pass_xp(player: any, xp: any)
	if Ids.PASS_MASTER == 0 or type(xp) ~= "number" then
		return
	end
	if BattlePass.level(xp) >= Ids.PassMasterLevel then
		PlatformBadges.award(player, Ids.PASS_MASTER)
	end
end

return PlatformBadges
