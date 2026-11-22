--!nocheck
-- Daily missions (Data/Missions): the pool's size and mix, the day's pick (always 2 easy, 2 medium, 1 hard;
-- the same for a user and a day; never one twice), every mission's text, what solo matches may count, and
-- the public match's counts (Stars.Tracker: what each human built, launched, earned...). Run:
-- lune run tests/missions.luau
require("./prelude")
local Missions = require("../src/shared/Data/Missions")
local Strings = require("../src/shared/Data/Strings")
local Stars = require("../src/shared/Data/Stars")
local Defs = require("../src/shared/Core/Defs")
local Ev = require("../src/shared/Core/Ev")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

print("the pool")
local by = { easy = 0, medium = 0, hard = 0 }
local stats = {}
local no_text = {}
for _, x in Missions.POOL do
	by[x.diff] += 1
	stats[x.stat] = true
	if Strings.SOURCE[Missions.key(x)] == nil then
		table.insert(no_text, x.id)
	end
	expect(x.goal > 0 and (x.mode == "sum" or x.mode == "best"), x.id .. ": a goal and a mode")
end
expect(by.easy >= 15 and by.medium >= 15 and by.hard >= 10, ("at least 15 easy, 15 medium, 10 hard (%d, %d, %d)"):format(by.easy, by.medium, by.hard))
expect(#no_text == 0, "every mission has its text " .. table.concat(no_text, ", "))
local measurable = {
	matches = true, minutes = true, survive = true, wins = true, top3 = true, top5 = true, top10 = true, land = true,
	kills = true, public = true, pwins = true, tribes = true, city = true, port = true, factory = true, defense = true,
	sam = true, silo = true, warship = true, trade = true, nuke = true, mirv = true, airstrike = true, slug = true,
	intercept = true, ally = true, accept = true, gold = true, troops = true,
}
local unknown = {}
for s in stats do
	if not measurable[s] then
		table.insert(unknown, s)
	end
end
expect(#unknown == 0, "every stat is one the server measures " .. table.concat(unknown, ", "))
local kinds = 0
for _ in stats do
	kinds += 1
end
expect(kinds >= 20, "a broad mix: " .. kinds .. " different stats")

print("the day's pick")
local bad_mix, dupes, unstable = 0, 0, 0
local seen_ids = {}
for uid = 1, 400 do
	local u = uid * 7919 + 3
	for day = 20770, 20790 do
		local list = Missions.today(u, day)
		local n = { easy = 0, medium = 0, hard = 0 }
		local ids = {}
		for i, x in list do
			n[x.diff] += 1
			if ids[x.id] then
				dupes += 1
			end
			ids[x.id] = true
			seen_ids[x.id] = true
			-- easy first, then medium, then hard
			if i <= 2 and x.diff ~= "easy" or i > 2 and i <= 4 and x.diff ~= "medium" or i == 5 and x.diff ~= "hard" then
				bad_mix += 1
			end
		end
		if #list ~= Missions.BpDailyMissionCount or n.easy ~= 2 or n.medium ~= 2 or n.hard ~= 1 then
			bad_mix += 1
		end
		local again = Missions.today(u, day)
		for i = 1, #list do
			if again[i] ~= list[i] then
				unstable += 1
			end
		end
	end
end
expect(bad_mix == 0, "always 5: 2 easy, 2 medium, 1 hard, in that order")
expect(dupes == 0, "never the same mission twice in a day")
expect(unstable == 0, "the same for a user and a day, every time")
local covered = 0
for _ in seen_ids do
	covered += 1
end
expect(covered == #Missions.POOL, ("every mission comes up (%d of %d)"):format(covered, #Missions.POOL))
local a, b = Missions.today(12345, 20775), Missions.today(12345, 20776)
local same = 0
for i = 1, 5 do
	if a[i] == b[i] then
		same += 1
	end
end
expect(same < 5, "another day, other missions")
local big = Missions.today(9007199254740991, 20775)
expect(#big == 5, "a huge user id is fine")
local dup_stat = 0
for uid = 1, 200 do
	local st = {}
	for _, x in Missions.today(uid, 20775) do
		if st[x.stat] then
			dup_stat += 1
		end
		st[x.stat] = true
	end
end
expect(dup_stat == 0, "no two of a day count the same stat")

print("progress")
do
	local sum = Missions.get("cities3")
	local best = Missions.get("land25")
	expect(Missions.step(sum, 1, { city = 2 }) == 3, "sum: adds up over matches")
	expect(Missions.step(best, 20, { land = 12 }) == 20 and Missions.step(best, 20, { land = 31 }) == 31, "best: one match's best")
	expect(Missions.step(sum, 1, {}) == 1 and Missions.step(sum, 1, { city = -5 }) == 1, "nothing measured: unchanged")
end

print("a match's stats; what a solo match may count")
do
	local r = { spawned = true, left = false, won = true, minutes = 21.7, shares = 9, kills = 3, place = 1, field = 30 }
	local st = Missions.stats(r)
	expect(st.matches == 1 and st.minutes == 21 and st.survive == 21 and st.wins == 1 and st.kills == 3, "matches, minutes, survival, wins, conquests")
	expect(st.top3 == 1 and st.top5 == 1 and st.top10 == 1 and st.land == 30, "top 3 / 5 / 10, 30 % of the map")
	expect(st.public == nil and st.city == nil, "a solo result has no public counts")
	local pub = Missions.stats(r, { city = 4, gold = 1234567.8, troops = 210000 })
	expect(pub.public == 1 and pub.pwins == 1 and pub.city == 4 and pub.gold == 1234567, "a public match: its counts too")
	local solo = Missions.solo_only(pub)
	expect(solo.city == nil and solo.public == nil and solo.pwins == nil and solo.wins == 1 and solo.land == 30, "solo_only keeps what the solo report vouches for")
	local small = Missions.stats({ spawned = true, won = false, left = false, minutes = 5, shares = 1, kills = 0, place = 3, field = 3 })
	expect(small.top3 == nil, "third of three is not a top-3 finish")
	local left = Missions.stats({ spawned = true, won = false, left = true, minutes = 5, shares = 1, kills = 0, place = 1, field = 30 })
	expect(left.top3 == nil and left.matches == nil and left.minutes == 5, "leaving early: its minutes, not a match played nor placed")
	local left_pub = Missions.stats({ spawned = true, won = false, left = true, minutes = 2, shares = 1, kills = 0, place = 1, field = 30 }, { city = 1 })
	expect(left_pub.public == nil and left_pub.city == 1, "a public match left early: not a public match played (join, spawn, leave x3 is not 3)")
	expect(next(Missions.stats({ spawned = false })) == nil, "never spawned: nothing")
	expect(Missions.public_only(Missions.get("tribes5")) and not Missions.public_only(Missions.get("win1")), "public-only missions are the ones solo can't count")
	expect(Missions.place(Missions.get("top3x2")) == 3 and Missions.place(Missions.get("win1")) == nil, "a top-N mission names its place")
end

print("a public match's counts (Stars.Tracker)")
do
	local N = 8
	local sim = {
		phase = Defs.PHASE_PLAYING,
		tick = 100,
		owner_total = N,
		o_kind = {},
		o_alive = {},
		o_spawned = {},
		o_tiles = {},
		o_income = {},
		o_troops = {},
		map = { land_count = 1000 },
	}
	for i = 1, N do
		sim.o_kind[i] = if i == 6 then Defs.KIND_TRIBE elseif i <= 2 then Defs.KIND_HUMAN else Defs.KIND_NATION
		sim.o_alive[i] = 1
		sim.o_spawned[i] = 1
		sim.o_tiles[i] = 10
		sim.o_income[i] = 50
		sim.o_troops[i] = 1000
	end
	local tr = Stars.Tracker.new(sim)
	tr:watch(1)
	tr:watch(2)
	tr:step({})
	sim.o_troops[1] = 250000
	tr:step({
		{ Ev.STRUCT_ADD, 11, Defs.S_CITY, 1, 5 },
		{ Ev.STRUCT_ADD, 12, Defs.S_CITY, 1, 6 },
		{ Ev.STRUCT_ADD, 13, Defs.S_SAM, 1, 7 },
		{ Ev.STRUCT_ADD, 14, Defs.S_PORT, 2, 8 },
		{ Ev.UNIT_ADD, 21, Defs.U_WARSHIP, 1, {}, 0, 100, 0 },
		{ Ev.UNIT_ADD, 22, Defs.U_TRADE, 1, {}, 0, 100, 0 },
		{ Ev.NUKE, 31, Defs.N_ATOM, 1, 1, 2, 100, 50 },
		{ Ev.NUKE, 32, Defs.N_MIRV, 1, 1, 2, 100, 50 },
		{ Ev.NUKE, 33, Defs.N_AIRSTRIKE, 2, 1, 2, 100, 50 },
		{ Ev.NUKE, 34, Defs.N_SLUG, 2, 1, 2, 100, 50 },
		{ Ev.SAM_LAUNCH, 13, 99, 100, 120, true },
		{ Ev.SAM_LAUNCH, 13, 98, 100, 120, false },
		{ Ev.ALLY_REQ, 3, 1, 100 },
		{ Ev.ALLY, 1, 3, 9999 },
		{ Ev.ALLY_REQ, 2, 4, 100 },
		{ Ev.ALLY, 2, 4, 9999 },
		{ Ev.CONQUEST, 1, 5, 40000 },
		{ Ev.OWNER_OUT, 6, 1 },
	})
	local x1 = tr:result(1).extra
	local x2 = tr:result(2).extra
	expect(x1.city == 2 and x1.sam == 1 and x1.warship == 1 and x1.trade == 1, "built: cities, a SAM; a warship, a trade ship")
	expect(x1.nuke == 1 and x1.mirv == 1 and x2.airstrike == 1 and x2.slug == 1, "launched: a bomb, a MIRV; an air strike, a railgun shot")
	expect(x1.intercept == 1, "a SAM's hit counts for its owner (a miss doesn't)")
	expect(x1.ally == 1 and x1.accept == 1 and x2.ally == 1 and (x2.accept or 0) == 0, "alliances; who accepted a request")
	expect(x1.tribes == 1, "a tribe conquered")
	expect(math.floor(x1.gold) == 40000 + 10, "gold: income (50/s, two steps) and the conquest's")
	expect(x1.troops == 250000, "the most troops")
	expect(x2.city == nil and x2.port == 1, "each human counts their own")
	local st = Missions.stats(tr:result(1), x1)
	expect(st.public == 1 and st.city == 2 and st.mirv == 1, "as mission stats")
end

print(if fails == 0 then "missions: all passed" else ("missions: %d FAILED"):format(fails))
if fails > 0 then
	error("missions tests failed")
end
