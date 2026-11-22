-- A public match's waiting room as one player sees it on live: the real MatchHost behind MatchServer's
-- lobby hooks, a seat taken on a hub, a teleport and a boot, the client's JOIN (ServerMain: on_client,
-- then note_join). What the room shows each second until the match starts.
require("./prelude")
local U = require("./net_util")
local Protocol = require("../src/shared/Net/Protocol")
local MatchServer = require("../src/server/MatchServer")
local LobbyStore = require("../src/server/Lobbies/LobbyStore")
local LobbyRules = require("../src/server/Lobbies/LobbyRules")
local MatchHost = require("../src/server/Lobbies/MatchHost")
local FakeSim = require("./net_fakesim")
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

local T0 = 500000

--- A match server whose lobby is `lobby_starts_in` s from its start when the first seat is taken.
--- `humans` join `arrive_s` after the seat (teleport + boot).
local function make(opts: { [string]: any })
	local clock_ms = 0
	local function now(): number
		return T0 + math.floor(clock_ms / 1000)
	end
	local store = LobbyStore.localstore(now)
	local l: any = {
		id = "L1",
		map = "world",
		map_name = "World",
		max = 50,
		starts = T0 + (opts.lobby_starts_in or 60),
		created = T0 - 30,
		players = 0,
		status = "open",
		code = "c",
		psid = "PS1",
	}
	-- the hub seats the first player: the start moves to FILL_S from now
	l = LobbyRules.seated(l, LobbyRules.take_spec(1, { "u1" }, T0))
	store.put(l, 3000)
	store.bind_psid("PS1", "L1", 3000)
	local host = MatchHost.new({
		store = store,
		psid = "PS1",
		now = now,
		to_hub = function()
			return true
		end,
	})
	local peers = {}
	local server
	server = MatchServer.new({
		make_sim = function(cfg)
			local sim = FakeSim.new(cfg)
			sim.add_bot_players = function() end
			return sim
		end,
		send = function(peer, op, ...)
			table.insert(peer.inbox, table.pack(op, ...))
		end,
		peers = function()
			return peers
		end,
		now_ms = function()
			return clock_ms
		end,
		seed = function()
			return 3
		end,
		lobby = {
			countdown = function()
				return host:starts_in()
			end,
			info = function()
				return if host.lobby then { map_id = "onion", max = host.lobby.max } else nil
			end,
			on_start = function(humans)
				host:start(humans)
				return LobbyRules.bot_fill(50, humans)
			end,
			bot_names = function(n)
				local out = {}
				for i = 1, n do
					out[i] = "Bot" .. i
				end
				return out
			end,
			on_over = function() end,
			on_vote_start = function(sec)
				host:start_early(sec)
			end,
		},
	})
	local function run(seconds: number)
		for _ = 1, math.floor(seconds * 20 + 0.5) do
			clock_ms += 50
			host:tick(0.05)
			server:process(0.05)
		end
	end
	local function join(name: string)
		local p = { inbox = {}, name = name }
		table.insert(peers, p)
		host:set_present(#peers)
		return p,
			function()
				server:on_client(p, { uid = name, name = name }, Protocol.OP.JOIN)
				host:note_join()
			end
	end
	return server, host, run, join, function()
		return clock_ms / 1000
	end
end

--- Runs until the match starts; returns the room's readings each half second and when it started.
local function watch(server: any, run: (number) -> (), p: any, secs: () -> number, on_step: ((number, any) -> ())?)
	local rows = {}
	local started_at = nil
	for _ = 1, 400 do
		if server:stage() ~= "lobby" then
			started_at = secs()
			break
		end
		local info = server:lobby_info(p)
		table.insert(rows, { t = secs(), info = info })
		if on_step then
			on_step(secs(), info)
		end
		run(0.5)
	end
	return rows, started_at
end

-- one player alone, as on live: seat, 8 s of teleport and boot, the JOIN
do
	local server, _host, run, join, secs = make({})
	run(5)
	local p, send_join = join("A")
	run(3)
	send_join()
	local joined = secs()
	local rows, started_at = watch(server, run, p, secs)
	expect(started_at ~= nil, "the match starts")
	local start = started_at or 0
	print(string.format("  (lone player: joined at %.1f s, started at %.1f s)", joined, start))
	local worst = 0.0
	local vote_shown, vote_usable = false, false
	for _, r in rows do
		local left = start - r.t
		worst = math.max(worst, r.info.countdown_s - left)
		if r.info.vote_open ~= false then
			vote_shown = true
			if r.info.vote_players >= r.info.vote_min_players then
				vote_usable = true
			end
		end
		print(
			string.format(
				"    t=%.1f  starts in %.1f (really %.1f)  players=%d  vote_open=%s  vote_solo_in=%s  min=%d",
				r.t,
				r.info.countdown_s,
				left,
				#r.info.players,
				tostring(r.info.vote_open),
				tostring(r.info.vote_solo_in),
				r.info.vote_min_players
			)
		)
	end
	expect(worst <= 1.5, string.format("the countdown shown is never more than the wait left (%.1f s over)", worst))
	expect(vote_shown and vote_usable, "a lone player can vote to start while there is time to gain")
	expect(
		start - joined >= LobbyRules.FILL_S - 8 - 1,
		string.format("the room stays up until FILL_S after the seat (%.1f s after the join)", start - joined)
	)
	local solo_over = false
	for _, r in rows do
		if r.info.vote_solo_in ~= nil and r.info.vote_solo_in > r.info.countdown_s then
			solo_over = true
		end
	end
	expect(not solo_over, "no 'vote to start in' timer that runs past the match's own start")
end

-- two players in the room: can their vote start it any sooner?
do
	local server, _host, run, join, secs = make({})
	run(5)
	local a, ja = join("A")
	local b, jb = join("B")
	run(3)
	ja()
	jb()
	local info = server:lobby_info(a)
	local before = info.countdown_s
	print(string.format("  (two players: starts in %.1f s at the join; VOTE_START_S = %d)", before, MatchServer.VOTE_START_S))
	expect(
		info.vote_open == (before > MatchServer.VOTE_START_S),
		"the vote is offered only when it can bring the start forward (vote_open=" .. tostring(info.vote_open) .. ")"
	)
	server:on_client(a, { uid = "A", name = "A" }, Protocol.OP.VOTE_START)
	server:on_client(b, { uid = "B", name = "B" }, Protocol.OP.VOTE_START)
	local _, started_at = watch(server, run, a, secs)
	print(string.format("  (two players voted at once: started %.1f s after the join)", (started_at or 0) - 8))
	expect(
		before <= MatchServer.VOTE_START_S or (started_at or 0) - 8 <= MatchServer.VOTE_START_S + 1.5,
		"two players' votes start it in VOTE_START_S"
	)
end

-- a lone player votes: the match starts VOTE_START_S later, not at the end of the wait
do
	local server, _host, run, join, secs = make({})
	run(5)
	local p, send_join = join("A")
	run(3)
	send_join()
	run(1)
	server:on_client(p, { uid = "A", name = "A" }, Protocol.OP.VOTE_START)
	local voted = secs()
	expect(server:lobby_info(p).vote_started, "a lone vote passes at once")
	local _, started_at = watch(server, run, p, secs)
	expect(
		started_at ~= nil and started_at - voted <= MatchServer.VOTE_START_S + 1.5,
		string.format("and the match starts %.1f s after it", (started_at or 0) - voted)
	)
end

-- a second player who asks 20 s after the first still gets a seat in the same match
do
	local l: any = {
		id = "L2",
		map = "world",
		map_name = "World",
		max = 50,
		starts = T0 + 60,
		created = T0 - 30,
		players = 0,
		status = "open",
		code = "c",
		psid = "PS2",
	}
	l = LobbyRules.seated(l, LobbyRules.take_spec(1, { "u1" }, T0))
	expect(l.starts == T0 + LobbyRules.FILL_S, "the first seat sets the start FILL_S out")
	expect(LobbyRules.fits(l, LobbyRules.take_spec(1, { "u2" }, T0 + 20)), "a seat is still there 20 s later")
	expect(
		not LobbyRules.fits(l, LobbyRules.take_spec(1, { "u2" }, T0 + LobbyRules.FILL_S - LobbyRules.JOIN_CLOSE_S)),
		"and joins close JOIN_CLOSE_S before the start"
	)
end

-- a long wait (a lobby that has not been pulled in): the vote is offered and works
do
	local server, host, run, join, secs = make({})
	-- (as if FILL_S were long: the record's start is far out)
	run(1)
	host:lookup()
	host.lobby.starts = T0 + 60
	local a, ja = join("A")
	local b, jb = join("B")
	ja()
	jb()
	run(1)
	local info = server:lobby_info(a)
	expect(info.vote_open == true, "with a long wait the vote is offered")
	server:on_client(a, { uid = "A", name = "A" }, Protocol.OP.VOTE_START)
	server:on_client(b, { uid = "B", name = "B" }, Protocol.OP.VOTE_START)
	local voted = secs()
	local _, started_at = watch(server, run, a, secs)
	expect(
		started_at ~= nil and started_at - voted <= MatchServer.VOTE_START_S + 1.5,
		string.format("and a passed vote starts it in VOTE_START_S (%.1f s)", (started_at or 0) - voted)
	)
end

-- the lobby record is not known yet when the client joins (store lag): what does the room show?
do
	local server, host, run, join, secs = make({})
	local real_lookup = host.lookup
	host.lookup = function()
		return false
	end
	run(8)
	local p, send_join = join("A")
	send_join()
	local info = server:lobby_info(p)
	print(string.format("  (record unknown at the join: stage=%s, starts in %.0f s)", info.stage, info.countdown_s))
	expect(info.countdown_known == false, "an unknown start is not shown as a time")
	host.lookup = real_lookup
	run(3)
	info = server:lobby_info(p)
	expect(info.countdown_known ~= false and info.countdown_s <= LobbyRules.FILL_S, "once found, the real time left (" .. tostring(info.countdown_s) .. ")")
	local _ = secs
end

if fails > 0 then
	error(string.format("public_room: %d failure(s)", fails))
end
print("public_room: ok")
