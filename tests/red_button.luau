--!nocheck
-- The Red Button in a public match (server/MatchServer on a real Sim, server/Purchases on a fake store):
-- no offer once the nation that eliminated you is gone; the credit is held at the launch and spent only
-- when the MIRV strikes a living target; a target that falls before the launch or the impact (or a match
-- that ends first) leaves it saved. Run: lune run tests/red_button.luau
require("./prelude")
local U = require("./net_util")
local Protocol = require("../src/shared/Net/Protocol")
local MatchServer = require("../src/server/MatchServer")
local Purchases = require("../src/server/Purchases")
local Products = require("../src/shared/Data/Products")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local Defs = require("../src/shared/Core/Defs")
U.use_zstd(Protocol)

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

-- a DataStore with UpdateAsync semantics (nil from the transform = no write)
local rows = {}
local writes = 0
local store = {}
function store:UpdateAsync(k, fn)
	local new = fn(rows[k])
	if new ~= nil then
		rows[k] = new
		writes += 1
	end
	return new
end
function store:GetAsync(k)
	return rows[k]
end
local players = {}
Purchases.configure({
	datastore = store,
	players = {
		GetPlayerByUserId = function(_, id)
			return players[id]
		end,
	},
})
Products.red_button.id = 777

local function credits(p): number
	return (rows["u" .. p.UserId] and rows["u" .. p.UserId].credits.red_button) or 0
end

local map = WorldMap.get("pangaea")
local readi32 = buffer.readi32

--- A public match with Alice (a buyer, user id `uid`) and Bob, played until Bob conquered Alice.
local function match(seed: number, uid: number)
	local P = { UserId = uid, Name = "Alice" .. uid, inbox = {} }
	players[uid] = P
	Purchases.load(P)
	local struck = {}
	local server = MatchServer.new({
		send = function(peer, op, ...)
			table.insert(peer.inbox, table.pack(op, ...))
		end,
		peers = function()
			return {}
		end,
		now_ms = function()
			return 0
		end,
		make_sim = function()
			return nil
		end,
		red_credits = function(peer)
			return Purchases.credits(peer).red_button or 0
		end,
		red_struck = function(peer)
			table.insert(struck, peer)
			Purchases.use(peer, "red_button")
		end,
	})
	local sim = Sim.new(map, { seed = seed, difficulty = 0, tribes = 4, max_humans = 4, time_limit_s = 2400, spawn_ticks = 30 })
	server._mp_sim = sim
	server._stage = "spawn"
	local msgs = {}
	local msg = sim.msg
	sim.msg = function(self, to, ty, key, args)
		table.insert(msgs, { to = to, key = key })
		return msg(self, to, ty, key, args)
	end
	local function join(peer, uid2)
		server._participants[peer] = { uid = uid2, key = peer.Name, name = peer.Name, owner = 0, active_msec = 0, spectator = false, voted = false }
		table.insert(server._order, peer)
		return server:_ensure_owner(peer)
	end
	local bob = { UserId = -2, Name = "Bob", inbox = {} }
	local a = join(P, tostring(uid))
	local b = join(bob, "-2")
	local r = seed
	local function rnd(n: number): number
		r = (r * 1103515245 + 12345) % 2147483648
		return r % n
	end
	for _, id in { a, b } do
		for _ = 1, 400 do
			local t = map:land_tile(rnd(map.land_count))
			if map:is_contestable(t) and readi32(sim.owner, t * 4) == 0 then
				sim:submit(id, { type = "spawn", tile = t })
				break
			end
		end
	end
	for _ = 1, 400 do
		server:_step_once()
		if sim.phase == Defs.PHASE_PLAYING and sim.o_spawned[a] == 1 and sim.o_spawned[b] == 1 then
			break
		end
	end
	for _ = 1, 20 do
		server:_step_once()
	end
	-- Bob takes all of Alice's land
	for t = 0, map.N - 1 do
		if readi32(sim.owner, t * 4) == a then
			sim:set_owner(t, b)
		end
	end
	for _ = 1, 3 do
		server:_step_once()
	end
	sim.o_killer[a] = b
	return {
		server = server,
		sim = sim,
		P = P,
		a = a,
		b = b,
		struck = struck,
		msgs = msgs,
	}
end

--- `who`'s nation loses all its land (to nobody) and is eliminated.
local function fall(m, who: number)
	local sim = m.sim
	for t = 0, map.N - 1 do
		if readi32(sim.owner, t * 4) == who then
			sim:set_owner(t, 0)
		end
	end
	sim:_process_eliminations()
end

--- Steps until the Red Button MIRV arrived (or the match ended); true when it did.
local function fly(m): boolean
	local sim = m.sim
	for _ = 1, 3000 do
		local any = false
		for _, n in sim.nukes do
			if n.red and not n.dead then
				any = true
			end
		end
		if not any then
			return true
		end
		m.server:_step_once()
	end
	return false
end

local function said(m, key: string): boolean
	for _, x in m.msgs do
		if x.to == m.a and x.key == key then
			return true
		end
	end
	return false
end

-- 1) the normal case: launched on a held credit, spent once when it strikes
local m = match(3, 501)
Purchases.grant(501, "red_button", "r-501-1")
Purchases.grant(501, "red_button", "r-501-2")
expect(m.sim.o_alive[m.a] == 0 and m.sim.o_alive[m.b] == 1, "Alice fell to Bob")
expect(m.server:can_red_button(m.P, m.b), "the Red Button is offered on Bob")
local ok, why = m.server:press_red_button(m.P, m.b)
expect(ok == true and why == nil, "pressed: launched")
expect(credits(m.P) == 2, "nothing is spent at the launch")
local ok2, why2 = m.server:press_red_button(m.P, m.b)
expect(not ok2 and why2 == "gone", "once per match")
expect(fly(m), "the MIRV arrived")
expect(#m.struck == 1 and m.struck[1] == m.P, "it struck a living target: one spend asked")
expect(credits(m.P) == 1, "exactly one credit spent")
local warheads = 0
for _, n in m.sim.nukes do
	if n.kind == Defs.N_WARHEAD and n.owner == m.a then
		warheads += 1
	end
end
expect(warheads > 0, "its warheads fly")
for _ = 1, 30 do
	m.server:_step_once()
end
expect(credits(m.P) == 1 and #m.struck == 1, "and no second spend later")

-- 2) the target already gone: no offer, nothing launches, the credit stays
local m2 = match(5, 502)
Purchases.grant(502, "red_button", "r-502-1")
fall(m2, m2.b)
expect(m2.sim.o_alive[m2.b] == 0, "Bob is eliminated too")
expect(not m2.server:can_red_button(m2.P, m2.b), "no Red Button on an eliminated nation")
expect(not m2.sim:can_red_button(m2.a, m2.b), "(the Sim says so: the client's offer reads it)")
local ok3, why3 = m2.server:press_red_button(m2.P, m2.b)
expect(not ok3 and why3 == "gone" and #m2.sim.nukes == 0, "a press is refused, nothing launches")
expect(credits(m2.P) == 1, "the credit is kept")

-- 3) bought while the target falls: the purchase lands after it fell, and stays saved
local m3 = match(7, 503)
expect(m3.server:can_red_button(m3.P, m3.b), "offered while Bob stands")
fall(m3, m3.b)
Purchases.grant(503, "red_button", "r-503-1")
local ok4, why4 = m3.server:press_red_button(m3.P, m3.b)
expect(not ok4 and why4 == "gone", "the press after the purchase finds Bob gone")
expect(credits(m3.P) == 1 and #m3.struck == 0, "the bought credit stays saved")

-- 4) the target falls in flight: no warheads, nothing spent, the player is told
local m4 = match(9, 504)
Purchases.grant(504, "red_button", "r-504-1")
expect(m4.server:press_red_button(m4.P, m4.b) == true, "launched")
m4.server:_step_once()
fall(m4, m4.b)
expect(fly(m4), "the MIRV arrived")
expect(#m4.struck == 0 and credits(m4.P) == 1, "the target fell before impact: the credit is kept")
local w4 = 0
for _, n in m4.sim.nukes do
	if n.kind == Defs.N_WARHEAD and n.owner == m4.a then
		w4 += 1
	end
end
expect(w4 == 0, "no warheads fall on whoever took the land")
expect(said(m4, "msg.red.kept"), "the player is told it is still saved")

-- 5) a match that ends with it in flight: nothing spent, the player is told
local m5 = match(11, 505)
Purchases.grant(505, "red_button", "r-505-1")
expect(m5.server:press_red_button(m5.P, m5.b) == true, "launched")
m5.sim:_game_over(m5.b, Defs.OVER_DOMINATION)
for _ = 1, 5 do
	m5.server:_step_once()
end
expect(#m5.struck == 0 and credits(m5.P) == 1, "the match ended first: the credit is kept")
expect(said(m5, "msg.red.kept_over"), "the player is told")

-- 5b) the player leaves before the impact: the strike still spends their credit (no free MIRV)
local m7 = match(15, 507)
Purchases.grant(507, "red_button", "r-507-1")
Purchases.grant(507, "red_button", "r-507-2")
expect(m7.server:press_red_button(m7.P, m7.b) == true, "launched")
Purchases.release(m7.P)
players[507] = nil
expect(fly(m7), "the MIRV arrived after they left")
expect(#m7.struck == 1 and credits(m7.P) == 1, "one credit spent though they left")

-- 6) no credit: no launch
local m6 = match(13, 506)
local ok6, why6 = m6.server:press_red_button(m6.P, m6.b)
expect(not ok6 and why6 == "no credit" and #m6.sim.nukes == 0, "no credit held: nothing launches")

-- 7) the Sim's outcome queue (solo: Session spends on a strike) is drained once
local q = m.sim:take_red_outcomes()
expect(#q == 0, "outcomes are handed over once")

if fails > 0 then
	error(fails .. " failures")
end
print("red_button: all passed")
