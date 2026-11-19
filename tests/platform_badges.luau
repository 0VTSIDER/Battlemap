--!nocheck
-- Roblox platform badges (shared/Data/PlatformBadges, server/PlatformBadges) with a fake BadgeService:
-- each trigger awards once, an owned badge makes no AwardBadge call, a failing service never throws (and
-- is retried a bounded number of times), a made-up solo win or 50 % claim awards nothing (the real
-- server/Rewards path), and the tracker's "took land" (Data/Stars.Tracker) only from another owner.
-- Run: lune run tests/platform_badges.luau
local F = require("./simsys_fixture")
local Defs = F.Defs
local expect = F.expect
local Ids = require("../src/shared/Data/PlatformBadges")
local Badges = require("../src/server/PlatformBadges")
local Stars = require("../src/shared/Data/Stars")
local Rewards = require("../src/server/Rewards")
local BP = require("../src/shared/Data/BattlePass")

-- the fake BadgeService: who owns what, every call made, and a switch to make it fail
local svc = { owns = {}, has_calls = 0, award_calls = 0, fail = false, award_false = false }
local function key(uid, id)
	return tostring(uid) .. ":" .. tostring(id)
end
function svc:UserHasBadgeAsync(uid, id)
	self.has_calls += 1
	if self.fail then
		error("HTTP 403 (Forbidden): place not published", 0)
	end
	return self.owns[key(uid, id)] == true
end
function svc:AwardBadge(uid, id)
	self.award_calls += 1
	if self.fail then
		error("HTTP 500", 0)
	end
	if self.award_false then
		return false
	end
	self.owns[key(uid, id)] = true
	return true
end
local function calls()
	return svc.has_calls + svc.award_calls
end

-- spawn: run now (or, `deferred`, queue the threads to run later)
local deferred = false
local queue = {}
local function flush()
	local q = queue
	queue = {}
	for _, f in q do
		f()
	end
end
Badges.reset()
Badges.configure({
	service = svc,
	spawn = function(f)
		if deferred then
			table.insert(queue, f)
		else
			f()
		end
	end,
	log = function() end,
})

local function result(over)
	local r = { spawned = true, left = false, won = false, minutes = 10, shares = 1, kills = 0, place = 3, field = 10 }
	for k, v in over or {} do
		r[k] = v
	end
	return r
end

-- =============================================================================================
print("ids")
do
	expect(Ids.WELCOME == 3447005537128754 and Ids.FIRST_CONQUEST == 942900260678286, "WELCOME, FIRST_CONQUEST")
	expect(Ids.FIRST_VICTORY == 87283401912431 and Ids.WORLD_POWER == 2812531107923518, "FIRST_VICTORY, WORLD_POWER")
	expect(Ids.ALLIANCE_MAKER == 3105238883393897 and Ids.PASS_MASTER == 0, "ALLIANCE_MAKER; PASS_MASTER not created yet")
end

-- =============================================================================================
print("each trigger awards once")
do
	local P = { UserId = 1 }
	Badges.joined(P)
	expect(svc.owns[key(1, Ids.WELCOME)] and svc.award_calls == 1, "joining awards WELCOME")
	local c = calls()
	Badges.joined(P)
	expect(calls() == c, "a second join: no call (cached)")
	Badges.public_result(P, result({ won = true }))
	expect(svc.owns[key(1, Ids.FIRST_VICTORY)], "a public win: FIRST_VICTORY")
	expect(not svc.owns[key(1, Ids.WORLD_POWER)] and not svc.owns[key(1, Ids.FIRST_CONQUEST)], "and nothing else")
	Badges.public_result(P, result({ shares = 4.9 }))
	expect(not svc.owns[key(1, Ids.WORLD_POWER)], "49 % of the map: no WORLD_POWER")
	Badges.public_result(P, result({ shares = 5 }))
	expect(svc.owns[key(1, Ids.WORLD_POWER)], "50 % of the map at its peak: WORLD_POWER")
	Badges.public_result(P, result({ took = true }))
	expect(svc.owns[key(1, Ids.FIRST_CONQUEST)], "land taken: FIRST_CONQUEST")
	Badges.public_result(P, result({ extra = { ally = 1 } }))
	expect(svc.owns[key(1, Ids.ALLIANCE_MAKER)], "an alliance formed: ALLIANCE_MAKER")
	expect(svc.award_calls == 5, "five badges, five AwardBadge calls")
	c = calls()
	Badges.public_result(P, result({ won = true, shares = 10, took = true, extra = { ally = 3 } }))
	Badges.joined(P)
	expect(calls() == c, "every trigger again: no call at all")
	Badges.public_result(P, result({ spawned = false, won = true }))
	Badges.public_result(P, nil)
	expect(calls() == c, "never spawned / no result: nothing")
	Badges.release(P)
end

-- =============================================================================================
print("an owned badge: one check, no AwardBadge")
do
	local P = { UserId = 2 }
	svc.owns[key(2, Ids.WELCOME)] = true
	svc.owns[key(2, Ids.FIRST_VICTORY)] = true
	local h, a = svc.has_calls, svc.award_calls
	Badges.joined(P)
	Badges.public_result(P, result({ won = true }))
	expect(svc.has_calls == h + 2 and svc.award_calls == a, "UserHasBadgeAsync once each, never AwardBadge")
	Badges.joined(P)
	Badges.public_result(P, result({ won = true }))
	expect(svc.has_calls == h + 2, "and no second check")
	Badges.release(P)
end

-- =============================================================================================
print("two triggers at once: one call")
do
	local P = { UserId = 3 }
	deferred = true
	Badges.joined(P)
	Badges.public_result(P, result({ won = true }))
	Badges.public_result(P, result({ won = true }))
	expect(#queue == 2, "one thread per badge (WELCOME, FIRST_VICTORY), not per trigger")
	local a = svc.award_calls
	flush()
	expect(svc.award_calls == a + 2, "each awarded once")
	-- a player who left before the answer came: nothing written for them
	local Q = { UserId = 4 }
	Badges.joined(Q)
	Badges.release(Q)
	flush()
	Badges.joined(Q)
	expect(#queue == 1, "the leaver's late answer didn't cache anything (a new session asks again)")
	flush()
	deferred = false
	Badges.release(P)
	Badges.release(Q)
end

-- =============================================================================================
print("a failing service doesn't throw")
do
	local P = { UserId = 5 }
	svc.fail = true
	local h = svc.has_calls
	local ok = pcall(function()
		for _ = 1, 10 do
			Badges.joined(P)
			Badges.public_result(P, result({ won = true }))
		end
	end)
	expect(ok, "no error escapes")
	expect(svc.has_calls - h == 2 * Badges.MAX_TRIES and svc.award_calls >= 0, "retried at most MAX_TRIES times a badge")
	svc.fail = false
	local c = calls()
	Badges.public_result(P, result({ won = true }))
	expect(calls() == c, "then left alone for the session")
	Badges.release(P)
	-- AwardBadge answering false (a disabled badge): no cache, bounded retries
	local Q = { UserId = 6 }
	svc.award_false = true
	ok = pcall(function()
		for _ = 1, 10 do
			Badges.joined(Q)
		end
	end)
	expect(ok and not svc.owns[key(6, Ids.WELCOME)], "AwardBadge false: not owned, no error")
	svc.award_false = false
	Badges.release(Q)
	-- a player never joined (no session): nothing
	local c2 = calls()
	Badges.public_result({ UserId = 7 }, result({ won = true }))
	Badges.award({ UserId = 7 }, 0)
	expect(calls() == c2, "no session or id 0: no call")
end

-- =============================================================================================
print("PASS_MASTER: only once its id is set, at level 100")
do
	local P = { UserId = 8 }
	svc.owns[key(8, Ids.WELCOME)] = true
	Badges.joined(P)
	local c = calls()
	Badges.pass_xp(P, 100 * BP.BpXpPerLevel)
	expect(calls() == c, "id 0: never asked")
	Ids.PASS_MASTER = 424242
	Badges.pass_xp(P, 100 * BP.BpXpPerLevel - 1)
	expect(calls() == c, "level 99: nothing")
	Badges.pass_xp(P, 100 * BP.BpXpPerLevel)
	expect(svc.owns[key(8, 424242)], "level 100: awarded")
	Ids.PASS_MASTER = 0
	Badges.release(P)
end

-- =============================================================================================
print("solo: only a server-clocked win")
do
	local clock = 1000
	Rewards.reset()
	Rewards.configure({
		add_stars = function()
			return true, 0, nil
		end,
		now = function()
			return clock
		end,
		solo_checked = Badges.solo_result,
	})
	local fake = { spawned = true, left = false, won = true, minutes = 60, shares = 40, kills = 39, place = 1, field = 40 }
	local P = { UserId = 9 }
	svc.owns[key(9, Ids.WELCOME)] = true
	Badges.joined(P)
	Rewards.solo_result(P, fake)
	expect(not svc.owns[key(9, Ids.FIRST_VICTORY)], "a result for no started match: nothing")
	Rewards.solo_started(P, "solo2")
	Rewards.solo_result(P, fake)
	expect(not svc.owns[key(9, Ids.FIRST_VICTORY)], "started and claimed won at once: nothing")
	clock += (BP.BpSoloWinMinMinutes - 1) * 60
	Rewards.solo_result(P, fake)
	expect(not svc.owns[key(9, Ids.FIRST_VICTORY)], "a win claimed under BpSoloWinMinMinutes: nothing")
	expect(not svc.owns[key(9, Ids.WORLD_POWER)], "the whole map claimed: no WORLD_POWER (public only)")
	expect(not svc.owns[key(9, Ids.FIRST_CONQUEST)] and not svc.owns[key(9, Ids.ALLIANCE_MAKER)], "no conquest or alliance badge from solo")
	clock += BP.BpSoloWinMinMinutes * 60
	Rewards.solo_result(P, fake)
	expect(svc.owns[key(9, Ids.FIRST_VICTORY)], "a win after BpSoloWinMinMinutes of the server's clock: FIRST_VICTORY")
	expect(not svc.owns[key(9, Ids.WORLD_POWER)], "and still no WORLD_POWER")
	Badges.release(P)
	Rewards.configure({ solo_checked = function() end })
	Rewards.reset()
end

-- =============================================================================================
print("the tracker: land taken from another owner")
do
	local sim = F.new_sim(1)
	local H = F.owner(sim, "Human", Defs.KIND_HUMAN, 0, 10000)
	local N1 = F.owner(sim, "N1", Defs.KIND_NATION, 0, 10000)
	local T1 = F.owner(sim, "Tribe", Defs.KIND_TRIBE, 0, 10000)
	F.claim(sim, H, 690, 100, 4)
	F.claim(sim, N1, 716, 100, 4)
	F.claim(sim, T1, 690, 130, 3)
	sim.winner = 0
	local tr = Stars.Tracker.new(sim)
	tr:watch(H)
	local function owner_of(t)
		return buffer.readi32(sim.owner, t * 4)
	end
	local function step()
		local tiles = sim.d_tiles
		sim.d_tiles = {}
		tr:step({}, tiles)
	end
	step()
	expect(tr:result(H).took == false, "nothing taken yet")
	-- empty land: not a conquest
	local empty = nil
	for t = 0, sim.N - 1 do
		if owner_of(t) == 0 and sim.map:is_land(t) then
			empty = t
			break
		end
	end
	if empty ~= nil then
		sim:set_owner(empty, H)
		step()
		expect(tr:result(H).took == false, "empty land: not taken from anyone")
	end
	-- a tile N1 held, then lost to H
	local n1_tile = F.tile(716, 100)
	expect(owner_of(n1_tile) == N1, "(N1 holds its centre)")
	sim:set_owner(n1_tile, H)
	step()
	expect(tr:result(H).took == true, "a tile of another nation: took")
	step()
	expect(tr._own == nil, "and the owners' copy is dropped (next step) once every watched human has taken land")
	-- a tribe's tile counts as well (a second human)
	local sim2 = F.new_sim(1)
	local H2 = F.owner(sim2, "Human", Defs.KIND_HUMAN, 0, 10000)
	local T2 = F.owner(sim2, "Tribe", Defs.KIND_TRIBE, 0, 10000)
	F.claim(sim2, H2, 690, 100, 4)
	F.claim(sim2, T2, 690, 130, 3)
	local tr2 = Stars.Tracker.new(sim2)
	tr2:watch(H2)
	sim2.d_tiles = {}
	tr2:step({}, {})
	sim2:set_owner(F.tile(690, 130), H2)
	local tiles = sim2.d_tiles
	sim2.d_tiles = {}
	tr2:step({}, tiles)
	expect(tr2:result(H2).took == true, "a tribe's tile: took")
end

-- =============================================================================================
print("the tracker in a public match: server/MatchServer on a real Sim")
do
	local Sim = require("../src/shared/Core/Sim")
	local MatchServer = require("../src/server/MatchServer")
	local WorldMap = require("../src/shared/Core/WorldMap")
	require("./fixtures/fixture_maps")
	require("./net_util").use_zstd(require("../src/shared/Net/Protocol"))
	local results = {}
	local server = MatchServer.new({
		send = function() end,
		peers = function()
			return {}
		end,
		now_ms = function()
			return 0
		end,
		make_sim = function()
			return nil
		end,
		on_result = function(peer, r)
			table.insert(results, { peer = peer, result = r })
		end,
	})
	local sim = Sim.new(
		WorldMap.get("onion"),
		{ seed = 5, difficulty = 0, tribes = 20, max_humans = 4, time_limit_s = 2400, spawn_ticks = 30 }
	)
	server._mp_sim = sim
	server._tracker = Stars.Tracker.new(sim)
	server._stage = "spawn"
	local peer = { name = "Alice", inbox = {} }
	server._participants[peer] =
		{ uid = "1", key = "Alice", name = "Alice", owner = 0, active_msec = 0, spectator = false, voted = false }
	table.insert(server._order, peer)
	local a = server:_ensure_owner(peer)
	local st = F.Defs
	local map = sim.map
	for i = 0, map.land_count - 1, 7 do
		local t = map:land_tile(i)
		if map:is_contestable(t) and buffer.readi32(sim.owner, t * 4) == 0 then
			sim:submit(a, { type = "spawn", tile = t })
			break
		end
	end
	for _ = 1, 400 do
		server:_step_once()
		if sim.phase == st.PHASE_PLAYING and sim.o_spawned[a] == 1 then
			break
		end
	end
	for _ = 1, 3 do
		server:_step_once()
	end
	expect(sim.phase == st.PHASE_PLAYING and sim.o_spawned[a] == 1, "(Alice spawned, the match is being played)")
	expect(server._tracker:result(a).took == false, "spawning and expanding into empty land: not taken")
	-- a tile of another owner (a nation or tribe) becomes Alice's: the Sim's own delta carries it
	local theirs = nil
	for t = 0, sim.N - 1 do
		local o = buffer.readi32(sim.owner, t * 4)
		if o ~= 0 and o ~= a then
			theirs = t
			break
		end
	end
	sim:set_owner(theirs, a)
	server:_step_once()
	expect(server._tracker:result(a).took == true, "a tile taken from another owner: took")
	sim.phase = st.PHASE_OVER
	sim.winner = a
	server:_step_once()
	local r = results[1] and results[1].result
	expect(r ~= nil and r.took == true and r.won == true, "and the paid result carries it (with the win)")
	local svc_calls = svc.award_calls
	local P = { UserId = 10 }
	svc.owns[key(10, Ids.WELCOME)] = true
	Badges.joined(P)
	Badges.public_result(P, r)
	expect(svc.owns[key(10, Ids.FIRST_CONQUEST)] and svc.owns[key(10, Ids.FIRST_VICTORY)], "FIRST_CONQUEST and FIRST_VICTORY from it")
	expect(svc.award_calls >= svc_calls + 2, "(awarded)")
	Badges.release(P)
end

F.finish("platform_badges")
