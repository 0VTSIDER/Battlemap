--!nocheck
-- The Battle Pass (Data/BattlePass, Data/Seasons; server/Rewards and server/Purchases carry it): the season and
-- day clock, XP and levels (bonus levels past 100), the reward dots of both tracks, premium given back to
-- level 1, an owned item paid as Stars, the monthly reset (a match over midnight at the month's end, a player
-- back months later), solo farming earning nothing, and a match's XP riding on its Stars payout's write (a
-- failed write, a retried one: applied once). Run: lune run tests/battlepass.luau
require("./prelude")
local BP = require("../src/shared/Data/BattlePass")
local Seasons = require("../src/shared/Data/Seasons")
local Missions = require("../src/shared/Data/Missions")
local Cosmetics = require("../src/shared/Data/Cosmetics")
local Store = require("../src/shared/Data/Store")
local Products = require("../src/shared/Data/Products")
local Purchases = require("../src/server/Purchases")
local Rewards = require("../src/server/Rewards")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

-- (the pass's clock set to a given unix time: its dev offset)
local function at_time(t: number)
	BP.DebugBpClock = true
	BP.debug_offset_s = t - os.time()
end
local NOV18 = 1795003200 -- 2026-11-18 12:00 UTC
local DEC1 = 1796083200 -- 2026-12-01 00:00 UTC
local NOV30_LATE = 1796083140 -- 2026-11-30 23:59 UTC
local FEB2 = 1801526400 -- 2027-02-02 00:00 UTC
local JAN1 = 1798761600 -- 2027-01-01 00:00 UTC
local DEC31_LATE = JAN1 - 60 -- 2026-12-31 23:59 UTC

-- =============================================================================================
print("the clock: seasons are months, days are UTC days")
do
	expect(BP.season_of(NOV18) == "2026-11" and BP.season_of(JAN1) == "2027-01", "season ids YYYY-MM")
	-- (Founders lasts two months, Seasons.LENGTH_MONTHS: December 2026 is still "2026-11")
	expect(BP.season_of(NOV30_LATE) == "2026-11" and BP.season_of(DEC1) == "2026-11", "Founders runs on through December")
	expect(BP.season_of(JAN1 - 1) == "2026-11", "its last second is December's last")
	expect(BP.season_end("2026-11") == JAN1, "Founders ends on Jan 1 00:00 UTC")
	expect(Seasons.months("2026-11") == 2 and Seasons.months("2027-01") == 1, "a season is a month long unless it says more")
	expect(Seasons.of_month("2026-10") == "2026-10" and Seasons.of_month("2027-01") == "2027-01", "the months round it are their own")
	expect(BP.season_end("2026-12") == 1798761600, "December ends on Jan 1 (the year turns)")
	expect(BP.season_of(FEB2) == "2027-02" and BP.season_end("2027-02") == 1803859200, "February 2027: 28 days")
	expect(BP.season_end("2028-02") == 1835481600 and BP.season_of(1835481600 - 1) == "2028-02", "a leap February ends on Mar 1")
	expect(BP.day_of(NOV18) == 20775, "UTC days since 1970")
	expect(BP.days_left(NOV18) == 44 and BP.days_left(DEC31_LATE) == 1, "days left: 44 on Nov 18th, 1 on the last day")
	expect(BP.days_left(FEB2) == 27, "an ordinary month: 27 left on Feb 2nd")
end

-- =============================================================================================
print("XP and levels")
do
	expect(BP.level(0) == 0 and BP.level(249) == 0 and BP.level(250) == 1, "250 XP a level")
	local lv, into, need = BP.progress(25 * 250 + 40)
	expect(lv == 25 and into == 40 and need == 250, "level 25, 40 XP into it")
	expect(BP.level(100 * 250) == 100 and BP.level(113 * 250 + 1) == 113, "bonus levels past 100, no end")
	local win = { spawned = true, left = false, won = true, minutes = 20, shares = 3, kills = 2, place = 1, field = 30 }
	expect(BP.match_xp_public(win) == 200 + 300, "public: 10 a minute + 300 for the win")
	local long = table.clone(win)
	long.minutes = 90
	long.won = false
	expect(BP.match_xp_public(long) == 300, "public: the minutes pay at most 300")
	expect(BP.match_xp_solo(win, 20) == 120 + 100, "solo: 6 a server-clocked minute + 100 for the win")
	expect(BP.match_xp_solo(win, 2) == 12, "solo: no more minutes than the server's clock, no win bonus under 5 minutes")
	expect(BP.match_xp_public({ spawned = false }) == 0, "never spawned: nothing")
end

-- =============================================================================================
print("the reward dots of both tracks")
do
	local s = "2026-11"
	local season = Seasons.get(s)
	local function r(track, lv)
		return BP.reward(s, track, lv)
	end
	expect(r("free", 10).stars == 1000 and r("free", 20).stars == 1500 and r("free", 90).stars == 4000, "free Stars")
	expect(r("free", 30).id == season.badge and r("free", 60).id == season.frame and r("free", 100).id == season.avatar, "free items at 30, 60, 100")
	expect(r("free", 110).stars == 2000 and r("free", 250).stars == 2000, "bonus: 2,000 Stars every 10 levels past 100")
	expect(r("free", 15) == nil and r("premium", 15) == nil and r("free", 0) == nil, "dots every 10 levels only")
	expect(r("premium", 10).stars == 2000 and r("premium", 40).stars == 4000 and r("premium", 80).stars == 7000, "premium: twice the free Stars")
	expect(r("premium", 20).id == season.premium_skin and r("premium", 50).id == season.premium_frame and r("premium", 90).id == season.premium_avatar, "premium items at 20, 50, 90")
	expect(r("premium", 30).stars == 4000 and r("premium", 60).stars == 6000 and r("premium", 100).stars == 10000, "premium Stars where the free dot is an item")
	expect(r("premium", 110) == nil, "no premium dots past 100")
	expect(BP.rarity({ kind = "stars", stars = 1500 }) == "common" and BP.rarity({ kind = "stars", stars = 2000 }) == "uncommon" and BP.rarity({ kind = "stars", stars = 3000 }) == "rare", "Stars dots: common, uncommon, rare by amount")
	expect(BP.rarity(r("free", 30)) == "rare" and BP.rarity(r("free", 60)) == "epic" and BP.rarity(r("free", 100)) == "legendary", "badge rare, frame epic, avatar legendary")
end

-- =============================================================================================
print("the seasons' items: in the catalog, never sold, never a default")
do
	local missing, sold, wrong = {}, {}, {}
	for id, season in Seasons.LIST do
		for _, f in Seasons.FIELDS do
			local item = season[f]
			local it = Cosmetics.item(item)
			if it == nil then
				table.insert(missing, id .. "." .. f .. "=" .. tostring(item))
			else
				if Store.price(it) ~= nil or it.default or it.exclusive then
					table.insert(sold, item)
				end
				if it.season ~= id then
					table.insert(wrong, item .. " flagged " .. tostring(it.season))
				end
				local kind = ({ badge = "badge", frame = "frame", avatar = "icon", premium_skin = "skin", premium_frame = "frame", premium_avatar = "icon" })[f]
				if it.kind ~= kind then
					table.insert(wrong, item .. " is a " .. it.kind)
				end
			end
		end
	end
	expect(#missing == 0, "every season item is in the catalog " .. table.concat(missing, ", "))
	expect(#sold == 0, "none is for sale, a default or an exclusive " .. table.concat(sold, ", "))
	expect(#wrong == 0, "each flagged with its own season, of the right kind " .. table.concat(wrong, ", "))
	local flagged = 0
	for _, it in Cosmetics.all() do
		if it.season ~= nil then
			flagged += 1
			expect(Seasons.has_item(it.id), it.id .. " (flagged) is a season's reward")
		end
	end
	expect(flagged == 18, "18 season items in the catalog (" .. flagged .. ")")
	local feb, from = Seasons.get("2027-02")
	expect(from == "2027-01" and feb == Seasons.LIST["2027-01"], "a month with no entry reruns the last one before it")
	local _, first = Seasons.get("2020-01")
	expect(first == "2026-11", "before them all: the first")
	expect(Products.bp_premium ~= nil and Products.bp_premium.id == 3733223986 and Products.bp_premium.staging == 0 and Products.bp_premium.robux == 299, "Premium: product 3733223986, 299 Robux")
end

-- =============================================================================================
print("levels give their rewards; premium gives back to level 1; an owned item comes as Stars")
do
	local rec = { owned = {}, stars = 0, stars_earned = 0 }
	at_time(NOV18)
	local t = BP.now()
	local s = BP.season_of(t)
	local season = Seasons.get(s)
	rec.bp = BP.clean(nil, t)
	rec.bp.xp = 35 * 250 -- (as if earned)
	local out = BP.apply(rec, 1, { s = s, d = BP.day_of(t), xp = 0 }, t)
	expect(#out.grants == 3 and rec.stars == 2500 and rec.stars_earned == 2500, "levels 10, 20, 30: 1,000 + 1,500 Stars and the badge")
	expect(rec.owned[season.badge] == true and rec.bp.fl == 35, "the badge is owned; level 35 given")
	local again = BP.apply(rec, 1, { s = s, d = BP.day_of(t), xp = 0 }, t)
	expect(#again.grants == 0 and rec.stars == 2500, "nothing given twice")
	local ok, prem = BP.unlock_premium(rec, t)
	expect(ok and rec.bp.prem and #prem.grants == 3, "premium: the premium dots 10, 20, 30 at once")
	expect(rec.owned[season.premium_skin] == true and rec.stars == 2500 + 2000 + 4000, "the skin, and twice the Stars (not counted as earned)")
	expect(rec.stars_earned == 2500, "premium Stars were bought: not earned")
	expect(not BP.unlock_premium(rec, t), "a second unlock changes nothing")
	-- an item owned already: Stars by its rarity
	rec.owned[season.frame] = true
	rec.bp.xp = 60 * 250
	local o2 = BP.apply(rec, 1, { s = s, d = BP.day_of(t), xp = 0 }, t)
	local frame_grant = nil
	for _, g in o2.grants do
		if g.level == 60 and g.track == "free" then
			frame_grant = g
		end
	end
	expect(frame_grant ~= nil and frame_grant.owned and frame_grant.stars == BP.BpOwnedItemStars.epic, "the season frame, owned already: " .. BP.BpOwnedItemStars.epic .. " Stars instead")
	-- bonus levels
	rec.bp.xp = 120 * 250
	local o3 = BP.apply(rec, 1, { s = s, d = BP.day_of(t), xp = 0 }, t)
	local bonus = 0
	for _, g in o3.grants do
		if g.level > 100 then
			bonus += g.stars
			expect(g.track == "free", "a bonus dot is free")
		end
	end
	expect(bonus == 4000 and rec.bp.pl == 100, "levels 110 and 120: 2,000 Stars each; premium stops at 100")
end

-- =============================================================================================
print("the monthly reset (lazy, on read)")
do
	local t = NOV18
	local old = { s = "2026-10", xp = 9000, prem = true, fl = 36, pl = 36, d = 20700, mp = { play2 = 1 }, md = { play2 = true } }
	local bp = BP.clean(old, t)
	expect(bp.s == "2026-11" and bp.xp == 0 and not bp.prem and bp.fl == 0 and bp.pl == 0, "a new month: XP, level, premium start over")
	expect(next(bp.mp) == nil and next(bp.md) == nil, "and the missions")
	local back = BP.clean({ s = "2026-08", xp = 20000, prem = true }, t)
	expect(back.s == "2026-11" and back.xp == 0 and not back.prem, "back after 2+ months: the current season, from 0")
	local same = BP.clean({ s = "2026-11", xp = 700, prem = true, fl = 2, pl = 2, d = BP.day_of(t) - 1, mp = { play2 = 1 }, md = { win1 = true } }, t)
	expect(same.xp == 700 and same.prem and next(same.mp) == nil and next(same.md) == nil, "a new day: only the missions start over")
	-- the record reads it so: Purchases.clean on a stored record
	local rows = { u7 = { stars = 10, owned = { badge_founders_medal = true }, bp = { s = "2026-10", xp = 5000, prem = true } } }
	Purchases.reset()
	Purchases.configure({
		datastore = {
			GetAsync = function(_, k)
				return rows[k]
			end,
			UpdateAsync = function(_, k, fn)
				local v = fn(rows[k])
				if v ~= nil then
					rows[k] = v
				end
				return v
			end,
		},
		notify = function() end,
	})
	at_time(NOV18)
	local P = { UserId = 7 }
	Purchases.load(P)
	local view = Purchases.inventory(P).bp
	expect(view.s == "2026-11" and view.xp == 0 and view.prem == false, "a stored October pass reads as a fresh November one")
	expect(table.find(Purchases.inventory(P).owned, "badge_founders_medal") ~= nil, "items earned stay owned")
	Purchases.release(P)
end

-- =============================================================================================
print("a match over midnight at the month's end")
do
	local rec = { owned = {}, stars = 0, stars_earned = 0 }
	-- (the season's end: Founders, two months long, ends with December)
	rec.bp = BP.clean({ s = "2026-11", xp = 2000, d = BP.day_of(DEC31_LATE) }, DEC31_LATE)
	-- (its payout is made when it ends, after midnight: stamped with January, stored in January)
	local g = { s = BP.season_of(JAN1 + 60), d = BP.day_of(JAN1 + 60), xp = 300 }
	local out = BP.apply(rec, 1, g, JAN1 + 60)
	expect(rec.bp.s == "2027-01" and rec.bp.xp == 300 and out.xp == 300, "it counts in the new season, which starts from 0")
	-- a Founders payout stored only in January (owed, kept for later): its XP went with Founders
	local rec2 = { owned = {}, stars = 0, stars_earned = 0, bp = BP.clean({ s = "2026-11", xp = 2000 }, DEC31_LATE) }
	local out2 = BP.apply(rec2, 1, { s = "2026-11", d = BP.day_of(DEC31_LATE), xp = 300 }, JAN1 + 60)
	expect(out2.xp == 0 and rec2.bp.xp == 0 and rec2.bp.s == "2027-01", "a Founders payout stored in January adds nothing to January")
	-- the month's turn inside the season: nothing starts over on Dec 1
	local rec4 = { owned = {}, stars = 0, stars_earned = 0, bp = BP.clean({ s = "2026-11", xp = 2000, prem = true }, NOV30_LATE) }
	local out4 = BP.apply(rec4, 1, { s = BP.season_of(DEC1 + 60), d = BP.day_of(DEC1 + 60), xp = 300 }, DEC1 + 60)
	expect(rec4.bp.s == "2026-11" and rec4.bp.xp == 2300 and rec4.bp.prem and out4.xp == 300, "Dec 1: the pass, its XP and premium carry on")
	-- a payout from yesterday: its XP counts, its mission progress doesn't
	local t = NOV18
	local rec3 = { owned = {}, stars = 0, stars_earned = 0, bp = BP.clean(nil, t) }
	local today = Missions.today(1, BP.day_of(t))
	local st = { [today[1].stat] = today[1].goal }
	local out3 = BP.apply(rec3, 1, { s = "2026-11", d = BP.day_of(t) - 1, xp = 100, st = st }, t)
	expect(out3.xp == 100 and #out3.missions == 0, "yesterday's match: its XP, none of today's missions")
end

-- =============================================================================================
print("missions complete in the payout and add their XP")
do
	local t = NOV18
	local rec = { owned = {}, stars = 0, stars_earned = 0, bp = BP.clean(nil, t) }
	local today = Missions.today(42, BP.day_of(t))
	local x = today[5]
	local st = { [x.stat] = x.goal }
	local out = BP.apply(rec, 42, { s = "2026-11", d = BP.day_of(t), xp = 50, st = st }, t)
	expect(table.find(out.missions, x.id) ~= nil and rec.bp.md[x.id] == true, "the hard mission is done")
	expect(out.xp >= 50 + BP.BpMissionXp.hard, "its 250 XP with the match's 50")
	local again = BP.apply(rec, 42, { s = "2026-11", d = BP.day_of(t), xp = 0, st = st }, t)
	expect(table.find(again.missions, x.id) == nil, "done once a day")
end

-- =============================================================================================
-- the scheduler and the store of tests/owed_stars.luau
local clock = 0.0
local seq = 0
local queue = {}
local function at(when, co, args)
	seq += 1
	table.insert(queue, { at = when, seq = seq, co = co, args = args or table.pack() })
end
local function spawn(fn, ...)
	at(clock, coroutine.create(fn), table.pack(...))
end
local function wait(s)
	at(clock + s, coroutine.running())
	coroutine.yield()
end
local function run(until_t)
	while true do
		table.sort(queue, function(a, b)
			return a.at < b.at or (a.at == b.at and a.seq < b.seq)
		end)
		local nxt = queue[1]
		if nxt == nil or nxt.at > until_t then
			clock = math.max(clock, until_t)
			return
		end
		table.remove(queue, 1)
		clock = math.max(clock, nxt.at)
		local ok, err = coroutine.resume(nxt.co, table.unpack(nxt.args, 1, nxt.args.n))
		if not ok then
			error(err)
		end
	end
end
local function go(fn)
	local out = table.pack()
	spawn(function()
		out = table.pack(fn())
	end)
	run(clock + 0.5)
	return table.unpack(out, 1, out.n)
end
local rows = {}
local refuse, ambiguous, updates = 0, 0, 0
local store = {
	GetAsync = function(_, k)
		return rows[k]
	end,
	UpdateAsync = function(_, k, fn)
		updates += 1
		wait(0.2)
		if refuse > 0 then
			refuse -= 1
			error("DataStoreService: StandardWriteGameServerThrottled: request queue was full. API: UpdateAsync", 0)
		end
		local v = fn(rows[k])
		if v ~= nil then
			rows[k] = v
		end
		if ambiguous > 0 then
			ambiguous -= 1
			error("DataStoreService: InternalServerError. API: UpdateAsync", 0)
		end
		return v
	end,
}
local mem = {}
local owed_map = {
	GetAsync = function(_, k)
		return mem[k]
	end,
	UpdateAsync = function(_, k, fn)
		mem[k] = fn(mem[k])
		return mem[k]
	end,
}
local sent = {}
Purchases.reset()
Purchases.configure({ datastore = store, owed_map = owed_map, spawn = spawn, wait = wait, notify = function() end, arrived = function()
	return nil
end, players = { GetPlayerByUserId = function(_, uid)
	return nil
end } })
Rewards.reset()
Rewards.configure({
	add_stars = Purchases.add_stars,
	double = function()
		return false
	end,
	send = function(p, payload)
		table.insert(sent, payload)
	end,
	now = function()
		return clock
	end,
})
at_time(NOV18)

print("solo farming earns nothing")
do
	local P = { UserId = 301 }
	rows.u301 = { stars = 0 }
	go(function()
		Purchases.load(P)
	end)
	local fake = { spawned = true, left = false, won = true, minutes = 30, shares = 40, kills = 9, place = 1, field = 40 }
	local before = updates
	Rewards.solo_started(P, "solo2")
	local paid = go(function()
		return Rewards.solo_result(P, fake)
	end)
	expect(paid == 0 and updates == before, "started and claimed at once: no Stars, no write")
	expect(rows.u301.bp == nil or (rows.u301.bp.xp or 0) == 0, "and no XP")
	-- claimed every 10 s (the gap rule): never faster than the server's clock
	for _ = 1, 6 do
		run(clock + 10.5)
		go(function()
			return Rewards.solo_result(P, fake)
		end)
	end
	local xp = if rows.u301.bp then rows.u301.bp.xp else 0
	expect(xp <= BP.BpXpPerMinuteSolo + 1, "a minute of 10-second claims: at most a minute's XP (" .. xp .. ")")
	local m = rows.u301.bp and rows.u301.bp.mp or {}
	expect(next(m) == nil and next(rows.u301.bp and rows.u301.bp.md or {}) == nil, "no mission progress from them (a solo match needs 3 minutes)")
	Rewards.release(P)
	Purchases.release(P)
end

print("a solo match that lasted: XP by the server's clock, the solo missions, the win bonus")
do
	local P = { UserId = 302 }
	rows.u302 = { stars = 0 }
	go(function()
		Purchases.load(P)
	end)
	Rewards.solo_started(P, "solo1")
	run(clock + 12 * 60)
	table.clear(sent)
	go(function()
		return Rewards.solo_result(P, { spawned = true, left = false, won = true, minutes = 12, shares = 10, kills = 3, place = 1, field = 30 })
	end)
	local bp = rows.u302.bp
	expect(bp ~= nil and bp.xp >= 12 * 6 + 100, "12 minutes x 6 + the win's 100 (and any mission done): " .. tostring(bp and bp.xp))
	expect(sent[1] ~= nil and sent[1].bp ~= nil and sent[1].bp.xp == bp.xp, "the payout message carries the XP")
	local tribes = 0
	for id in bp.mp do
		local x = Missions.get(id)
		if x ~= nil and Missions.public_only(x) then
			tribes += 1
		end
	end
	expect(tribes == 0, "no progress on a public-only mission from a solo match")
	Rewards.release(P)
	Purchases.release(P)
end

print("XP rides on the payout's write and applies once")
do
	local P = { UserId = 303 }
	rows.u303 = { stars = 100 }
	go(function()
		Purchases.load(P)
	end)
	local g = { s = "2026-11", d = BP.day_of(BP.now()), xp = 200 }
	local w0 = updates
	local ok, bal, out = go(function()
		return Purchases.add_stars(P, 50, g)
	end)
	expect(ok and bal == 150 and rows.u303.bp.xp == 200 and updates - w0 == 1, "Stars and XP in one write")
	expect(out ~= nil and out.xp == 200 and out.from == 0 and out.to == 200, "its outcome")
	-- a failed write: owed, the XP with it, stored once by a retry
	refuse = 2
	go(function()
		return Purchases.add_stars(P, 10, g)
	end)
	expect(rows.u303.bp.xp == 200 and Purchases.inventory(P).bp.xp == 400, "the write failed: not stored, shown")
	run(clock + 200)
	expect(rows.u303.bp.xp == 400 and rows.u303.stars == 160, "a retry stored it, Stars and XP")
	-- a write stored but answered with an error: its retry finds the payout's id
	ambiguous = 1
	go(function()
		return Purchases.add_stars(P, 10, g)
	end)
	run(clock + 200)
	expect(rows.u303.bp.xp == 600 and rows.u303.stars == 170, "stored once, not twice (XP 600)")
	-- a payout of no Stars still carries XP
	go(function()
		return Purchases.add_stars(P, 0, g)
	end)
	expect(rows.u303.bp.xp == 800 and rows.u303.stars == 170, "no Stars: the XP alone")
	-- leaving while owed: MemoryStore keeps the XP too, the next server stores it
	refuse = 100
	go(function()
		return Purchases.add_stars(P, 5, g)
	end)
	Purchases.release(P)
	run(clock + 40)
	refuse = 0
	expect(type(mem.u303) == "table" and mem.u303[1] ~= nil and mem.u303[1].bp ~= nil and mem.u303[1].bp.xp == 200, "kept in MemoryStore with its XP")
	local P2 = { UserId = 303 }
	go(function()
		Purchases.load(P2)
	end)
	run(clock + 5)
	expect(rows.u303.bp.xp == 1000 and rows.u303.stars == 175, "the next server stores it")
	Purchases.release(P2)
end

print("Premium: a credit, spent on this season at once")
do
	local P = { UserId = 304 }
	rows.u304 = { stars = 0, bp = { s = "2026-11", xp = 25 * 250, fl = 25, d = BP.day_of(BP.now()) } }
	Purchases.configure({ players = { GetPlayerByUserId = function(_, uid)
		return if uid == 304 then P else nil
	end } })
	go(function()
		Purchases.load(P)
	end)
	go(function()
		return Purchases.grant(304, "bp_premium", "receipt-1")
	end)
	run(clock + 2)
	local season = Seasons.get("2026-11")
	expect(rows.u304.bp.prem == true and (rows.u304.credits.bp_premium or 0) == 0, "bought: premium this season, the credit spent")
	expect(rows.u304.owned[season.premium_skin] == true and rows.u304.stars == 2000, "levels 10 and 20 of premium at once (2,000 Stars, the skin)")
	go(function()
		return Purchases.grant(304, "bp_premium", "receipt-2")
	end)
	run(clock + 2)
	expect(rows.u304.credits.bp_premium == 1, "a second one this season is kept for a later season")
	-- next season (Founders ends with December) the kept credit goes on the new one
	at_time(JAN1 + 3600)
	Purchases.release(P)
	local P2 = { UserId = 304 }
	Purchases.configure({ players = { GetPlayerByUserId = function(_, uid)
		return if uid == 304 then P2 else nil
	end } })
	go(function()
		Purchases.load(P2)
	end)
	run(clock + 2)
	expect(rows.u304.bp.s == "2027-01" and rows.u304.bp.prem == true and rows.u304.credits.bp_premium == 0, "January: the kept credit unlocks it")
	Purchases.release(P2)
	at_time(NOV18)
end

BP.DebugBpClock = false
BP.debug_offset_s = 0
print(if fails == 0 then "battlepass: all passed" else ("battlepass: %d FAILED"):format(fails))
if fails > 0 then
	error("battlepass tests failed")
end
