--!nocheck
-- Stars (shared/Data/Stars: the payout formula and the match tracker), the Arsenal catalogue
-- (shared/Data/Arsenal), the server's payouts (server/Rewards) and the saved Stars
-- (server/Purchases). Run: .bin/lune run tests/stars.luau
local F = require("./simsys_fixture")
local Defs, Ev = F.Defs, F.Ev
local expect, near = F.expect, F.near
local Stars = require("../src/shared/Data/Stars")
local Arsenal = require("../src/shared/Data/Arsenal")
local Purchases = require("../src/server/Purchases")
local Rewards = require("../src/server/Rewards")

local function line(p, key)
	for _, l in p.lines do
		if l[1] == key then
			return l[2]
		end
	end
	return 0
end

-- =============================================================================================
print("the payout formula")
do
	local win = { spawned = true, left = false, won = true, minutes = 20, shares = 8, kills = 3, place = 1, field = 72 }
	local p = Stars.payout(win, "public", false)
	expect(line(p, "played") == 100 and line(p, "survived") == 300, "100 for playing, 15 a minute")
	expect(line(p, "territory") == 240 and line(p, "conquests") == 160, "30 a share, 54 a conquest (rounded to 5)")
	expect(line(p, "placed") == 280 and line(p, "victory") == 360, "first place 14 a minute, the win 18 a minute")
	expect(p.total == 1440, "a 20-minute win pays 1,440")
	local d = Stars.payout(win, "public", true)
	expect(d.total == 2880 and line(d, "double") == 1440, "2x Stars doubles it, as its own line")
	local left = { spawned = true, left = true, won = false, minutes = 6, shares = 3, kills = 1, place = 5, field = 72 }
	local pl = Stars.payout(left, "public", false)
	expect(
		pl.total == 90 + 90 + 55 and line(pl, "played") == 0 and line(pl, "placed") == 0,
		"leaving early: no floor, no place"
	)
	local none = Stars.payout({
		spawned = false,
		left = false,
		won = false,
		minutes = 9,
		shares = 9,
		kills = 9,
		place = 1,
		field = 2,
	})
	expect(none.total == 0 and #none.lines == 0, "never spawned: nothing")
	expect(Stars.place_score(1, 72) == 1 and Stars.place_score(72, 72) == 0, "place score 1 for first, 0 for last")
	expect(near(Stars.place_score(36.5, 72), 0.25), "and squared in between")
	expect(Stars.place_score(1, 1) == 1, "alone: 1")
	local solo = Stars.payout(win, "solo0", false)
	expect(solo.total < p.total * 0.42 and solo.total > p.total * 0.38, "solo Relaxed pays 40 %")
	expect(Stars.payout(win, "solo2", false).total == p.total, "solo Brutal pays it all")
	local tiny = Stars.payout({
		spawned = true,
		left = true,
		won = false,
		minutes = 0.1,
		shares = 0.01,
		kills = 0,
		place = 3,
		field = 9,
	})
	expect(line(tiny, "survived") == 5 and line(tiny, "territory") == 5, "a line that pays at all pays at least 5")
	local total = 0
	for _, l in p.lines do
		total += l[2]
		expect(l[2] % 5 == 0, "line " .. l[1] .. " is a multiple of 5")
	end
	expect(total == p.total, "the lines add up to the total")
end

-- =============================================================================================
print("a client's solo report is made safe")
do
	local r = Stars.sanitize(
		{ spawned = true, won = true, minutes = 999, shares = 1e9, kills = 1e9, place = -4, field = 50 },
		10
	)
	expect(r.minutes == 10, "no longer than the match really lasted")
	expect(
		r.shares == 50 and r.kills == 50 and r.place == 1 and r.field == 50,
		"shares, kills and place within the field"
	)
	local j = Stars.sanitize(
		{ spawned = "yes", minutes = 0 / 0, shares = "lots", kills = {}, field = 1e12, left = true, won = true },
		5
	)
	expect(
		not j.spawned and j.minutes == 0 and j.shares == 0 and j.kills == 0 and j.field == Stars.MAX_FIELD,
		"junk becomes zero"
	)
	expect(j.left and not j.won, "a player who left did not win")
	local n = Stars.sanitize(nil, 5)
	expect(not n.spawned and Stars.payout(n).total == 0, "no report: nothing")
	expect(Stars.solo_cap(10) == 100 + 2200 and Stars.solo_cap(-3) == 0, "the solo cap grows with real time only")
	expect(
		Stars.solo_cap(0) == 0 and Stars.solo_cap(0.5) == 50 + 110 and Stars.solo_cap(1) == 100 + 220,
		"its floor grows over the first real minute"
	)
end

-- =============================================================================================
print("the tracker follows a Sim")
do
	local sim = F.new_sim(1)
	local H = F.owner(sim, "Human", Defs.KIND_HUMAN, 0, 10000)
	local N1 = F.owner(sim, "N1", Defs.KIND_NATION, 0, 10000)
	local N2 = F.owner(sim, "N2", Defs.KIND_NATION, 0, 10000)
	local T1 = F.owner(sim, "Tribe", Defs.KIND_TRIBE, 0, 10000)
	F.claim(sim, H, 690, 100, 6)
	F.claim(sim, N1, 716, 100, 10)
	F.claim(sim, N2, 760, 120, 4)
	F.claim(sim, T1, 690, 130, 3)
	sim.winner = 0
	local tr = Stars.Tracker.new(sim)
	tr:watch(H)
	tr:step({})
	expect(tr.field == 3 and tr.live == 3, "the field is the nations and players (not tribes)")
	local r0 = tr:result(H)
	expect(r0.spawned and r0.place == 2 and r0.kills == 0 and r0.field == 3, "second by land while N1 is bigger")
	local share = sim.map.land_count / 3
	expect(near(r0.shares, sim.o_tiles[H] / share, 1e-9), "shares = peak land over a fair share")
	-- H grows, then shrinks: the peak stays
	local peak_tiles = sim.o_tiles[H]
	F.claim(sim, H, 690, 100, 9)
	peak_tiles = sim.o_tiles[H]
	tr:step({})
	for _, t in sim:disk_tiles(F.tile(690, 100), 8, true) do
		sim:set_owner(t, 0)
	end
	tr:step({})
	expect(near(tr:result(H).shares, peak_tiles / share, 1e-9), "the peak is kept after losing land")
	-- H conquers N2 (a nation: counts) and the tribe (doesn't)
	sim.tick += 600
	tr:step({ { Ev.OWNER_OUT, N2, H }, { Ev.OWNER_OUT, T1, H } })
	local r1 = tr:result(H)
	expect(r1.kills == 1 and tr.live == 2, "a conquered nation counts, a tribe doesn't")
	expect(near(r1.minutes, 1.0, 1e-9), "minutes from the first playing tick")
	expect(not tr:final(H), "not final while it stands")
	-- leaving now: a partial result
	local rl = tr:result(H, true)
	expect(rl.left and not rl.won, "leaving a running match: left")
	-- H falls to N1: place 2 of 3, final
	sim.tick += 600
	sim.o_alive[H] = 0
	tr:step({ { Ev.OWNER_OUT, H, N1 } })
	local r2 = tr:result(H, true)
	expect(tr:final(H) and r2.place == 2 and not r2.left, "fell second to last: place 2, final (not 'left')")
	expect(near(r2.minutes, 2.0, 1e-9), "its minutes stop when it falls")
	sim.tick += 6000
	expect(near(tr:result(H).minutes, 2.0, 1e-9), "and stay stopped")
	-- a takeover: a new life on N1's land, which is not the player's doing
	tr:adopt(H, N1)
	sim.o_kind[N1] = Defs.KIND_HUMAN
	tr:step({})
	local r3 = tr:result(N1)
	expect(r3.minutes == 0 and r3.kills == 0 and r3.shares == 0, "a takeover starts a new life from nothing")
	F.claim(sim, N1, 716, 100, 12)
	sim.tick += 300
	tr:step({})
	expect(tr:result(N1).shares > 0, "land taken after it counts")
	sim.phase = Defs.PHASE_OVER
	sim.winner = N1
	local r4 = tr:result(N1, true)
	expect(r4.won and not r4.left and tr:final(N1), "the winner of a finished match")
	expect(not tr:result(999).spawned, "an owner never watched: not spawned")
end

-- =============================================================================================
print("the Arsenal catalogue")
do
	local seen, bits = {}, {}
	local ok = true
	local all = 0
	for _, it in Arsenal.ITEMS do
		if seen[it.key] or it.bit == 0 or bits[it.bit] or Defs.UNLOCK[it.key] ~= it.bit then
			ok = false
		end
		seen[it.key] = true
		bits[it.bit] = true
		all += it.bit
		if #it.perks ~= 2 or #it.tagline > 44 or #it.color ~= 2 or it.stars ~= nil or it.product ~= nil then
			ok = false
		end
	end
	expect(ok, "unique keys, the Sim's bits, two perks, a short tagline, no price")
	expect(#Arsenal.ITEMS == 6, "six units")
	expect(all == Defs.UNLOCK_ALL, "every player's mask holds them all")
	expect(Arsenal.item_for("airstrike") == Arsenal.item("airfield") and Arsenal.item_for("city") == nil, "item_for")
end

-- =============================================================================================
print("saved Stars")
local rows = {}
local down = false
local store = {}
function store:UpdateAsync(k, fn)
	if down then
		error("DataStore request was throttled")
	end
	local new = fn(rows[k])
	if new ~= nil then
		rows[k] = new
	end
	return new
end
function store:GetAsync(k)
	return rows[k]
end
local P = { UserId = 42, Name = "Buyer" }
local invs = {}
Purchases.reset()
Purchases.configure({
	datastore = store,
	players = {
		GetPlayerByUserId = function(_, id)
			return if id == 42 then P else nil
		end,
	},
	notify = function() end,
	inventory = function(_, inv)
		table.insert(invs, inv)
	end,
	bought = function() end,
	rng = {
		NextNumber = function()
			return 0.5
		end,
	},
})
do
	Purchases.load(P)
	expect(Purchases.stars(P) == 0, "a new player: no Stars")
	local ok, bal = Purchases.add_stars(P, 1234.9)
	expect(ok and bal == 1234 and Purchases.stars(P) == 1234, "Stars are paid whole")
	expect(invs[#invs].stars == 1234, "the client gets its inventory")
	expect(
		not Purchases.add_stars(P, -50) and not Purchases.add_stars(P, 0 / 0) and Purchases.stars(P) == 1234,
		"never a negative or NaN payout"
	)
	-- a store outage
	down = true
	local s0 = Purchases.stars(P)
	-- (owed until the store takes them: tests/owed_stars.luau)
	expect(Purchases.add_stars(P, 100) and Purchases.stars(P) == s0 + 100, "store down: the Stars are owed, and shown")
	down = false
	-- reload from the store: junk is dropped
	rows.u42.stars = "many"
	Purchases.reset()
	Purchases.load(P)
	expect(Purchases.stars(P) == 0, "a broken balance loads as 0")
end

-- =============================================================================================
print("the server's payouts")
do
	rows = {}
	Purchases.reset()
	Purchases.load(P)
	local clock = 1000
	local sent = {}
	local x2 = false
	Rewards.reset()
	Rewards.configure({
		add_stars = Purchases.add_stars,
		double = function(_)
			return x2
		end,
		send = function(_, payload)
			table.insert(sent, payload)
		end,
		now = function()
			return clock
		end,
	})
	local win = { spawned = true, left = false, won = true, minutes = 20, shares = 8, kills = 3, place = 1, field = 72 }
	expect(Rewards.pay(P, win, "public") == 1440 and Purchases.stars(P) == 1440, "a public result is paid as measured")
	expect(
		sent[1].total == 1440 and sent[1].balance == 1440 and sent[1].mode == "public" and #sent[1].lines == 6,
		"the client gets the breakdown and its balance"
	)
	-- solo: nothing without a started match
	expect(Rewards.solo_result(P, win) == 0, "a solo result without a started match pays nothing")
	Rewards.solo_started(P, "solo2")
	expect(Rewards.solo_result(P, win) == 0, "claimed at once: there was no time to earn it")
	local s0 = Purchases.stars(P)
	Rewards.solo_started(P, "solo2")
	clock += 20 * 60
	local paid = Rewards.solo_result(P, win)
	expect(paid == 1440 and Purchases.stars(P) == s0 + 1440, "a 20-minute solo Brutal win pays in full")
	Rewards.solo_started(P, "solo0")
	clock += 20 * 60
	local relaxed = Rewards.solo_result(P, win)
	expect(relaxed > 0.38 * 1440 and relaxed < 0.42 * 1440, "solo Relaxed pays 40 %")
	-- a made-up report can't beat the clock
	Rewards.solo_started(P, "solo2")
	clock += 60
	local fake =
		{ spawned = true, left = false, won = true, minutes = 200, shares = 500, kills = 500, place = 1, field = 500 }
	local got = Rewards.solo_result(P, fake)
	expect(got <= Stars.solo_cap(1) and got > 0, "a made-up win after a minute pays at most a minute's cap")
	local last = sent[#sent]
	local sum = 0
	for _, l in last.lines do
		sum += l[2]
	end
	expect(sum == last.total and last.total == got, "a capped payout's lines still add up")
	-- starting a match and claiming its result at once, again and again (2026-11-13: up to ~12,000
	-- Stars a minute, and two writes a second to the player's record)
	local farm0 = Purchases.stars(P)
	local farmed, paid_n = 0, 0
	for _ = 1, 120 do
		clock += 0.5
		Rewards.solo_started(P, "solo2")
		local s = Rewards.solo_result(P, { spawned = true, left = false, minutes = 0.2, shares = 0, kills = 0, place = 9, field = 60 })
		farmed += s
		if s > 0 then
			paid_n += 1
		end
	end
	expect(
		farmed <= Stars.solo_cap(1) and Purchases.stars(P) - farm0 == farmed,
		"a minute of starting and claiming at once pays at most a real minute's cap (" .. farmed .. ")"
	)
	expect(paid_n <= 60 / Rewards.SOLO_GAP_S, "and is paid at most once every " .. Rewards.SOLO_GAP_S .. " s (" .. paid_n .. ")")
	-- a second life's result soon after the first is not paid, and its time counts toward the next
	clock += 600
	Rewards.solo_started(P, "solo2")
	clock += 120
	local life1 = Rewards.solo_result(P, win)
	clock += 5
	local life2 = Rewards.solo_result(P, win)
	clock += 60
	local life3 = Rewards.solo_result(P, fake)
	expect(life1 > 0 and life2 == 0, "a result 5 s after the last payout: not paid")
	expect(
		life3 > Stars.solo_cap(1) - 5 and life3 <= Stars.solo_cap(65 / 60),
		"the next is paid for the time since the last payout (65 s): " .. life3
	)
	-- an honest short match still earns its share of the floor
	clock += 600
	Rewards.solo_started(P, "solo2")
	clock += 30
	local short = Rewards.solo_result(P, { spawned = true, left = false, minutes = 0.5, shares = 0, kills = 0, place = 30, field = 60 })
	expect(short >= 100 and short <= Stars.solo_cap(0.5), "a 30-second match lost: its floor and time are paid (" .. short .. ")")
	-- one match, a bounded number of results
	Rewards.solo_started(P, "solo2")
	local n = 0
	for _ = 1, 10 do
		clock += 600
		if Rewards.solo_result(P, win) > 0 then
			n += 1
		end
	end
	expect(n == Rewards.MAX_SOLO_PAYOUTS, "a match pays a bounded number of results")
	Rewards.solo_started(P, "solo2")
	clock += 600
	Rewards.solo_result(P, { spawned = true, left = true, minutes = 10, shares = 2, kills = 0, place = 9, field = 60 })
	clock += 600
	expect(Rewards.solo_result(P, win) == 0, "leaving ends the match: nothing more is paid")
	Rewards.solo_started(P, "public")
	clock += 600
	expect(Rewards.solo_result(P, win) == 0, "a public match is never paid on the client's word")
	-- 2x Stars
	x2 = true
	local b0 = Purchases.stars(P)
	expect(Rewards.pay(P, win, "public") == 2880 and Purchases.stars(P) == b0 + 2880, "2x Stars doubles a payout")
	expect(sent[#sent].lines[#sent[#sent].lines][1] == "double", "with its own line")
	expect(Rewards.pay(P, { spawned = false }, "public") == 0, "nothing for a player who never spawned")
end

F.finish("stars")
