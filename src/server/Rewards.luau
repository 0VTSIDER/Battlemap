--!strict
-- Stars for a match (shared/Data/Stars).
--
-- A public match runs on this server: MatchServer follows it (Stars.Tracker) and its results are paid
-- as they are (Rewards.pay). A solo match runs on the player's own device, so its result is the
-- client's word (OP.SOLO_RESULT): it is typed and bounded (Stars.sanitize), can't be longer than the
-- match really lasted on this server's clock (counted from the client's "match_start" report), and
-- never pays more than Stars.solo_cap of that real time. So a made-up report earns no faster than a
-- good player, and nothing at all without the time passing.
--
-- Each payout also carries the match's Battle Pass part (Data/BattlePass: its XP; Data/Missions: its mission
-- stats), stored in the same write: a public match's from what this server measured, a solo match's only by
-- the server's clock (BattlePass.match_xp_solo) and, for missions, only from a match that lasted
-- BpSoloMissionMinMinutes and only its SOLO_STATS. Starting a solo match and claiming at once earns nothing.
--
--   Rewards.configure(deps)          { add_stars = fn(player, n, bp) -> (ok, balance, outcome?), double = fn(player)
--                                      -> boolean, send = fn(player, payload), now = fn() -> s, log?,
--                                      played? = fn(player, minutes) (each result's minutes alive),
--                                      solo_checked? = fn(player, result, real_minutes) (each sanitized solo
--                                      result and its server-clocked minutes: server/PlatformBadges) }
--   Rewards.solo_started(player, mode)   the client's match_start ("solo0" / "solo1" / "solo2")
--   Rewards.solo_result(player, report)  OP.SOLO_RESULT (yields)
--   Rewards.pay(player, result, mode)    a result this server measured itself (yields)
--   Rewards.release(player)              PlayerRemoving
-- The payload sent to the client (OP.STARS): { lines = { { key, amount } }, total, balance, mode, bp? }
-- (bp: { xp, from, to, missions, grants } once stored, BattlePass.Outcome; { xp } while owed).
local IS_ROBLOX = typeof(game) == "Instance"
local Stars: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Stars)
	else require("../shared/Data/Stars")
local BattlePass: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.BattlePass)
	else require("../shared/Data/BattlePass")
local Missions: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Missions)
	else require("../shared/Data/Missions")

local Rewards = {}

--- Results one solo match may be paid for: its end, and one more for each life a takeover gave it.
Rewards.MAX_SOLO_PAYOUTS = 4
--- Slack on the real time a solo result may claim (the report's trip, the clock's grain), minutes.
Rewards.SLACK_MIN = 0.25
--- Seconds after a player's last solo payout (any match) before the next can be paid (2026-11-13): a
--- result sooner than that is not paid, and its time counts toward the next. Starting a match and
--- claiming its result at once, again and again, wrote to the player's record twice a second.
Rewards.SOLO_GAP_S = 10

type Solo = { mode: string, paid_at: number, payouts: number }

local deps: { [string]: any } = {}
local solo: { [any]: Solo } = {}
local solo_paid: { [any]: number } = {} -- (when each player's last solo payout was made)

function Rewards.configure(d: { [string]: any })
	for k, v in d do
		deps[k] = v
	end
end

--- Tests: forget everyone.
function Rewards.reset()
	table.clear(solo)
	table.clear(solo_paid)
end

local function now(): number
	return if deps.now then deps.now() else os.clock()
end

--- The pass part of a payout (BattlePass.clean_gain's shape), stamped with the season and day now.
local function gain(xp: number, st: { [string]: number }?): any
	local t = BattlePass.now()
	return { s = BattlePass.season_of(t), d = BattlePass.day_of(t), xp = xp, st = st }
end

local function worth(g: any): boolean
	return g ~= nil and (g.xp > 0 or (g.st ~= nil and next(g.st) ~= nil))
end

local function deliver(player: any, lines: { { any } }, total: number, mode: string, g: any): number
	if total <= 0 and not worth(g) then
		return 0
	end
	local ok, balance, outcome = deps.add_stars(player, math.max(total, 0), if worth(g) then g else nil)
	if not ok then
		return 0
	end
	if deps.send then
		local bp = outcome
		if bp == nil and worth(g) then
			bp = { xp = g.xp } -- (owed for now: the match's own XP)
		end
		pcall(deps.send, player, { lines = lines, total = total, balance = balance, mode = mode, bp = bp })
	end
	if deps.log then
		deps.log(string.format("[Rewards] %s +%d Stars (%s)", tostring(player.UserId), total, mode))
	end
	return total
end

local function with_double(player: any, lines: { { any } }, total: number): ({ { any } }, number)
	if total > 0 and deps.double and deps.double(player) == true then
		table.insert(lines, { "double", total })
		total *= 2
	end
	return lines, total
end

--- A result this server measured itself (a public match). Returns the Stars paid.
--- The minutes `r` was played, to deps.played (the playtime leaderboard; 2026-11-04).
local function played(player: any, r: any)
	local mins = if type(r) == "table" and r.spawned == true then tonumber(r.minutes) or 0 else 0
	if mins > 0 and deps.played then
		task.spawn(deps.played, player, mins)
	end
end

function Rewards.pay(player: any, result: any, mode: string?): number
	local m = mode or "public"
	played(player, result)
	local p = Stars.payout(result, m, false)
	local lines, total = with_double(player, p.lines, p.total)
	-- (the pass: what this server measured; result.extra = Stars.Tracker's counts)
	local extra = if type(result) == "table" and type(result.extra) == "table" then result.extra else {}
	local st = Missions.stats(result, extra)
	local g = gain(BattlePass.match_xp_public(result), if next(st) ~= nil then st else nil)
	return deliver(player, lines, total, m, g)
end

function Rewards.solo_started(player: any, mode: any)
	if type(mode) ~= "string" or Stars.MODE_MULT[mode] == nil or mode == "public" then
		solo[player] = nil
		return
	end
	solo[player] = { mode = mode, paid_at = now(), payouts = 0 }
end

--- The client's result of the solo match it reported starting. Returns the Stars paid.
function Rewards.solo_result(player: any, report: any): number
	local m = solo[player]
	if m == nil or m.payouts >= Rewards.MAX_SOLO_PAYOUTS then
		return 0
	end
	local t = now()
	local last = solo_paid[player]
	if last ~= nil and t - last < Rewards.SOLO_GAP_S then
		return 0 -- (too soon after the last payout: not paid; its time counts toward the next)
	end
	local real = math.max(0, (t - m.paid_at) / 60)
	local r = Stars.sanitize(report, real + Rewards.SLACK_MIN)
	played(player, r)
	if deps.solo_checked then
		pcall(deps.solo_checked, player, r, real)
	end
	m.payouts += 1
	m.paid_at = t
	if r.left then
		solo[player] = nil -- the match is over for this player
	end
	local p = Stars.payout(r, m.mode, false)
	local lines, total = p.lines, p.total
	local cap = Stars.solo_cap(real)
	if total > cap then
		-- more than that much real time can pay: every line shrinks alike
		local k = cap / total
		total = 0
		for _, line in lines do
			line[2] = math.floor(line[2] * k / Stars.QUANTUM) * Stars.QUANTUM
			total += line[2]
		end
	end
	lines, total = with_double(player, lines, total)
	-- the pass: minutes by the server's clock only, missions only from a match that lasted
	local xp = BattlePass.match_xp_solo(r, real)
	local st = nil
	if real >= BattlePass.BpSoloMissionMinMinutes then
		local clocked = table.clone(r)
		clocked.minutes = math.min(r.minutes, real)
		st = Missions.solo_only(Missions.stats(clocked))
		if next(st) == nil then
			st = nil
		end
	end
	local g = gain(xp, st)
	if total > 0 or worth(g) then
		solo_paid[player] = t
	end
	return deliver(player, lines, total, m.mode, g)
end

function Rewards.release(player: any)
	solo[player] = nil
	solo_paid[player] = nil
end

return Rewards
