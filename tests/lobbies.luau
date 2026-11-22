--!nocheck
-- Public lobbies: LobbyRules (sizes, rotation, scheduling, bot fill), LobbyDirectory (two hubs
-- sharing one store: one creates, both list; joins reserve slots; failed teleports give slots back)
-- and MatchHost (lookup by reserved-server id, start time, started lobbies leave the lists).
require("./prelude")
local LobbyRules = require("../src/server/Lobbies/LobbyRules")
local LobbyStore = require("../src/server/Lobbies/LobbyStore")
local LobbyDirectory = require("../src/server/Lobbies/LobbyDirectory")
local MatchHost = require("../src/server/Lobbies/MatchHost")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------------------------
-- (seats: the land-based count x 1.5, 10..50, at most a server's size; since 2026-10-19 up to 50 per
-- lobby where the map supports it. It was that times MAP_SCALE_PCT's area.)
local function r5(n)
	return math.floor(n / 5 + 0.5) * 5
end
local function full(land)
	return math.clamp(r5(land * 75 / 1e6), 10, 50)
end
expect(LobbyRules.max_players(651569, 1) == 50, "World hosts " .. LobbyRules.max_players(651569, 1))
expect(LobbyRules.max_players(5000000, 1) == 50, "the biggest maps host 50: " .. LobbyRules.max_players(5000000, 1))
expect(LobbyRules.max_players(100000, 1) == 10, "tiny maps get the minimum")
expect(LobbyRules.max_players(400000, 1) == full(400000), "the land-based count x 1.5, rounded: " .. LobbyRules.max_players(400000, 1))
expect(LobbyRules.max_players(651569, 1, 30) == 30, "never more seats than a server holds (Max Visitor Count 30)")
expect(LobbyRules.max_players(651569, 1, 55) == 50 and LobbyRules.max_players(400000, 1, 55) == 30, "a bigger server: the map's own count")
expect(LobbyRules.max_players(651569, 1, 5) == 50, "a server size under MIN_PLAYERS is no cap (Studio's)")
-- a record decodes without the removed kinds; clients aren't told one
do
	local g = LobbyRules.decode({ id = "g", map = "world", starts = 1, max = 50, mode = "world" })
	expect(g ~= nil and g.max == 50 and (g :: any).mode == nil, "an old record's kind is dropped")
	expect(LobbyRules.public_view(g :: any, 0).mode == nil, "and clients see none")
	expect(LobbyRules.WORLD_ID == "world", "every public match plays World")
end
expect(LobbyRules.max_players(100000, 2) == LobbyRules.max_players(400000, 1), "our tiles count k_lin^2 full-size tiles")

local now = 1000
local open = {}
local starts = LobbyRules.missing_starts(open, now)
expect(#starts == LobbyRules.TARGET and starts[1] == now + LobbyRules.MIN_LEAD_S, "empty list -> target lobbies")
expect(starts[#starts] <= now + LobbyRules.LOBBY_OPEN_S, "every listed match starts within LOBBY_OPEN_S")
-- steady state: when the soonest starts, its replacement still starts within LOBBY_OPEN_S
do
	local t = starts[1]
	local nxt = LobbyRules.missing_starts({}, t)
	expect(#nxt == 1 and nxt[1] <= t + LobbyRules.LOBBY_OPEN_S, "a replacement starts within LOBBY_OPEN_S too")
end
-- lobbies leaving early (vote starts, fills) one after another never push the schedule past
-- LOBBY_OPEN_S, and there is always a joinable lobby
do
	local t = 7000
	local list = {}
	local worst, gaps = 0, 0
	local n = 0
	for step = 1, 200 do
		-- schedule what's missing
		for _, st in LobbyRules.missing_starts(list, t) do
			n += 1
			table.insert(list, { id = "v" .. n, starts = st, status = "open", players = 0, max = 30 })
			worst = math.max(worst, st - t)
		end
		local joinable = 0
		for _, lb in list do
			if LobbyRules.joinable(lb, t) then
				joinable += 1
			end
		end
		if joinable == 0 then
			gaps += 1
		end
		-- every 3rd step the soonest joinable lobby is vote-started (leaves at once)
		if step % 3 == 0 then
			local soonest = nil
			for _, lb in list do
				if LobbyRules.joinable(lb, t) and (soonest == nil or lb.starts < soonest.starts) then
					soonest = lb
				end
			end
			if soonest then
				soonest.status = "started"
			end
		end
		t += 3 -- a hub refresh
	end
	expect(worst <= LobbyRules.LOBBY_OPEN_S, "vote starts in a row: no lobby scheduled past " .. LobbyRules.LOBBY_OPEN_S .. " s (worst " .. worst .. " s)")
	expect(gaps == 0, "always a joinable lobby (" .. gaps .. " refreshes without)")
end
local l =
	{ id = "x", map = "a", map_name = "A", max = 10, starts = now + 30, created = now, players = 10, status = "open" }
expect(not LobbyRules.joinable(l, now), "a full lobby is not joinable")
l.players = 3
expect(
	LobbyRules.joinable(l, now) and not LobbyRules.joinable(l, now + 30 - LobbyRules.JOIN_CLOSE_S),
	"joins close before the start"
)
local view = LobbyRules.public_view(l, now)
expect(view.code == nil and view.starts_in == 30 and view.players == 3, "public view hides the access code")
expect(
	LobbyRules.decode({ id = 1 }) == nil
		and LobbyRules.decode({ id = "q", map = "m", starts = 5, max = 999 }).max == 200,
	"decode rejects / clamps"
)

-- ---------------------------------------------------------------------------------------------
-- Directory: two hubs, one store
-- ---------------------------------------------------------------------------------------------
local clock = 5000
local function tnow()
	return clock
end
local store = LobbyStore.localstore(tnow)
local reserved = 0
local sent = {}
local teleport_ok = true
local function make_hub(name)
	local s = setmetatable({}, { __index = store })
	s.lock = function(n, ttl)
		return store.lock(n, ttl, name)
	end
	return LobbyDirectory.new({
		store = s,
		teleport = {
			reserve = function()
				reserved += 1
				return "code" .. reserved, "psid" .. reserved
			end,
			send = function(players, code, data)
				if not teleport_ok then
					return false, "nope"
				end
				table.insert(sent, { players = players, code = code, data = data })
				return true
			end,
		},
		maps = function()
			return {
				{ id = "world", name = "World", weight = 3, land = 651569, k_lin = 1 },
				{ id = "pangaea", name = "Pangaea", weight = 1, land = 150000, k_lin = 1 },
			}
		end,
		now = tnow,
		rand = function()
			return 0.1
		end,
		new_id = (function()
			local n = 0
			return function()
				n += 1
				return "L" .. n
			end
		end)(),
	})
end
local hub1, hub2 = make_hub("hub1"), make_hub("hub2")
hub1:refresh()
hub2:refresh()
expect(
	#store.list() == 1,
	"the first hub creates World's lobby, the second (lock held) doesn't duplicate"
)
expect(#hub2:view() == 1, "both hubs list the same lobby")
local worlds = hub1:view()
expect(#worlds == 1 and worlds[1].map == "world", "World's own lobby is open, on World")
local first = worlds[1]
expect(first.map ~= nil and first.max == LobbyRules.max_players(if first.map == "world" then 651569 else 150000, 1), "lobby sized for its map")

local ok, msg = hub2:join("player1", first.id)
expect(
	ok and #sent == 1 and sent[1].code ~= nil and sent[1].data.lobby == first.id,
	"join teleports to the lobby's reserved server"
)
expect(store.get(first.id).players == 1, "join reserves a slot")
teleport_ok = false
ok, msg = hub1:join("player2", first.id)
expect(not ok and store.get(first.id).players == 1, "a failed teleport gives the slot back: " .. tostring(msg))
teleport_ok = true

-- the store refusing the reservation (hundreds joining at once): a few tries, then the join goes
-- ahead from this hub's list; a lobby it can't see stays an error
do
	local target = hub1:view()[1]
	local real_update = store.update
	local calls = 0
	store.update = function(...)
		calls += 1
		error("MemoryStoreService: Request was throttled")
	end
	local before = #sent
	local ok1, msg1 = hub1:join("flood1", target.id)
	store.update = real_update
	expect(ok1 and #sent == before + 1 and calls == LobbyDirectory.JOIN_TRIES, "store busy: retried, then joined from the list: " .. tostring(msg1))
	store.update = function()
		error("throttled")
	end
	local ok2, msg2 = hub1:join("flood2", "no-such-lobby")
	store.update = real_update
	expect(not ok2 and msg2 ~= nil, "an unknown lobby still fails: " .. tostring(msg2))
end

-- a lobby whose joins closed (the last JOIN_CLOSE_S before its start) leaves the list
do
	local v1 = hub1:view()[1]
	local rec = store.get(v1.id)
	local saved = clock
	clock = rec.starts - LobbyRules.JOIN_CLOSE_S + 1
	hub1:refresh()
	local listed = false
	for _, v in hub1:view() do
		if v.id == v1.id then
			listed = true
		end
	end
	expect(not listed and #hub1:view() >= 1, "a starting (no longer joinable) lobby is hidden; the next is listed")
	clock = saved
	hub1:refresh()
end

-- lobbies filling at once are replaced at once (not LOBBY_INTERVAL_S after the full ones)
do
	local t = 50000
	local full = {
		{ id = "f1", starts = t + 40, status = "open", players = 30, max = 30 },
		{ id = "f2", starts = t + 85, status = "open", players = 30, max = 30 },
	}
	local nxt = LobbyRules.missing_starts(full, t)
	expect(#nxt == LobbyRules.TARGET and nxt[1] == t + LobbyRules.MIN_LEAD_S, "full lobbies: new ones start in MIN_LEAD_S")
end

-- a hub refused the scheduler lock asks again only after LOCK_RETRY_S (8-16 s), not every refresh;
-- the holder renews at every refresh; once free, it is taken at the next due ask
do
	local held_by_other = true
	local asks = 0
	local s2 = setmetatable({}, { __index = LobbyStore.localstore(tnow) })
	s2.list = function()
		return {} -- (nothing open: this hub always wants lobbies made)
	end
	s2.lock = function(_n, _ttl)
		asks += 1
		return not held_by_other
	end
	local hub3 = LobbyDirectory.new({
		store = s2,
		teleport = {
			reserve = function()
				reserved += 1
				return "code" .. reserved, "psid" .. reserved
			end,
			send = function()
				return true
			end,
		},
		maps = function()
			return { { id = "world", name = "World", weight = 1, land = 651569, k_lin = 1 } }
		end,
		now = tnow,
		rand = function()
			return 0.1
		end,
		new_id = (function()
			local n = 0
			return function()
				n += 1
				return "B" .. n
			end
		end)(),
	})
	local t0 = clock
	for _ = 1, 20 do -- 60 s of refreshes, every REFRESH_S (3 s)
		hub3:refresh()
		clock += LobbyDirectory.REFRESH_S
	end
	local lo, hi = LobbyDirectory.LOCK_RETRY_S[1], LobbyDirectory.LOCK_RETRY_S[2]
	expect(
		asks >= math.floor(60 / (hi + LobbyDirectory.REFRESH_S)) and asks <= math.ceil(60 / lo) + 1,
		string.format("refused, a hub asks %d times in 60 s (every 8-16 s), not 20", asks)
	)
	-- the lock frees up: taken at the next due ask, at most LOCK_RETRY_S later
	held_by_other = false
	local freed = clock
	local got_at = nil
	asks = 0
	for _ = 1, 8 do
		local before = asks
		hub3:refresh()
		if got_at == nil and asks > before then
			got_at = clock
		end
		clock += LobbyDirectory.REFRESH_S
	end
	expect(got_at ~= nil and got_at - freed <= hi, "the free lock is taken within LOCK_RETRY_S")
	-- holding it, the hub renews at every refresh
	local renew_from = asks
	for _ = 1, 4 do
		hub3:refresh()
		clock += LobbyDirectory.REFRESH_S
	end
	expect(asks - renew_from == 4, "the holder renews at every refresh")
	clock = t0
end

print(if fails == 0 then "lobbies: all passed" else string.format("lobbies: %d FAILED", fails))
if fails > 0 then
	error("lobbies failed")
end
