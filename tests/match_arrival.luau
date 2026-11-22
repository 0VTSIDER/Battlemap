-- Arriving on a public match's own server: the server's first LOBBY (kind "match") can reach the
-- client before Main has asked for the title world. The client must join the match once, after that,
-- and stay in it (it used to join, then leave on start_title: "0 / 50 players", back to the title).
-- Run: lune run tests/match_arrival.luau
require("./prelude")
local U = require("./net_util")
local Protocol = require("../src/shared/Net/Protocol")
local MatchServer = require("../src/server/MatchServer")
local Session = require("../src/client/Session")
local FakeSim = require("./net_fakesim")
U.use_zstd(Protocol)

local CORE = {
	GameState = require("../src/shared/Core/GameState"),
	WorldMap = require("../src/shared/Core/WorldMap"),
}
local OP = Protocol.OP
local check = U.check
local clock_ms = 0
local hello: { any } = {}
local left = 0

local function make_sim(cfg)
	cfg.over_at = 600
	return FakeSim.new(cfg)
end

local server = MatchServer.new({
	make_sim = make_sim,
	-- a public lobby's server: the match starts 5 s from now, 3 seats
	lobby = {
		countdown = function(): number?
			return math.max(0, 5 - clock_ms / 1000)
		end,
		info = function(): any
			return { map_id = nil, max = 3 }
		end,
		-- (no bot fill: the stand-in Sim has no bot players)
		on_start = function(_humans: number): number
			return 0
		end,
		bot_names = function(n: number): { string }
			local out = {}
			for i = 1, n do
				out[i] = "Bot " .. i
			end
			return out
		end,
		on_over = function() end,
	},
	send = function(peer, op, ...)
		table.insert(peer.inbox, table.pack(op, ...))
	end,
	peers = function()
		return hello
	end,
	now_ms = function()
		return clock_ms
	end,
	log = function() end,
	seed = function()
		return 42
	end,
})

local clients = {}
local function make_client(name: string, uid: string, spectate: boolean?)
	local peer = { inbox = {}, handler = nil :: any, session = nil :: any }
	local session = Session.new({
		now = function()
			return clock_ms / 1000
		end,
		mobile = false,
		warn = function(text)
			print("    [warn] " .. text)
		end,
		display_name = function()
			return name
		end,
		require_core = function(n)
			if n == "Sim" then
				return {
					new = function(_map, cfg)
						return make_sim(cfg)
					end,
				}
			end
			return CORE[n]
		end,
		net = {
			connected = true,
			send = function(op, ...)
				if op == OP.HELLO then
					table.insert(hello, peer)
					server:_send(peer, OP.LOBBY, server:lobby_info(peer))
					return
				end
				if op == OP.LEAVE then
					left += 1
				end
				-- (ServerMain: a hub's Watch teleport marks the player a spectator)
				server:on_client(peer, { uid = uid, name = name, spectate = spectate == true }, op, ...)
			end,
			listen = function(fn)
				peer.handler = fn
			end,
		},
	})
	session.threaded = false
	peer.session = session
	table.insert(clients, peer)
	return peer
end

local function pump(seconds: number)
	for _ = 1, math.max(1, math.round(seconds / 0.1)) do
		clock_ms += 100
		server:process(0.1)
		for _, c in clients do
			local inbox = c.inbox
			c.inbox = {}
			for _, m in inbox do
				c.handler(table.unpack(m, 1, m.n))
			end
			c.session:process(0.1)
		end
	end
end

local peer = make_client("Alice", "u1")
local session = peer.session

print("the server's LOBBY arrives before the client's first start_title")
session.env.net.send(OP.HELLO)
pump(0.3)
check(session.lobby.kind == "match", "the lobby info says this is a match server")
check(session.mode ~= Session.MODE_MULTI and server:participant_count() == 0, "no join before the client booted")

print("Main asks for the title world")
session:start_title()
pump(1.5) -- (the server sends its lobby info every second)
check(left == 0, "start_title leaves no match")
check(session.mode == Session.MODE_MULTI, "the client joined the match")
check(server:participant(peer) ~= nil and server:stage() == "lobby", "the server has the player in its waiting room")
check(session.lobby.in_match == true and #session.lobby.players >= 1, "the waiting room lists the player")

print("the match starts and the player is in it")
pump(6.0)
check(server:stage() == "spawn" or server:stage() == "playing", "the match started: " .. server:stage())
check(session.state ~= nil and session.state_mode == Session.MODE_MULTI, "the client has the match's state")
check(left == 0, "and never left")

print("a spectator arrives on the running match (a hub's Watch teleport), LOBBY first again")
local W = make_client("Wanda", "u2", true)
W.session.env.net.send(OP.HELLO)
pump(0.3)
check(server:participant(W) == nil, "no join before the spectator's client booted")
W.session:start_title()
pump(2.5)
check(left == 0, "the spectator's start_title leaves no match")
local wp = server:participant(W)
check(wp ~= nil and wp.spectator == true, "the server has them as a spectator")
check(W.session.mode == Session.MODE_MULTI and W.session.lobby.spectating == true, "the client is watching")
check(W.session.state ~= nil and W.session.state_mode == Session.MODE_MULTI, "and has the match's state")
check(W.session.state.local_owner == 0, "with no nation of its own")
check(server:participant(peer) ~= nil, "the player is still in the match")

if U.failures() > 0 then
	error(U.failures() .. " failures")
end
print("match_arrival ok")
