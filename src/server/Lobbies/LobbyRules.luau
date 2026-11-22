--!strict
-- Public-lobby rules: pure logic,
-- no services, so it runs in Lune tests and on the server.
--
-- A lobby is one upcoming public match on World: a player cap, a start time (wall clock, os.time()
-- seconds — every server shares it), and the reserved server that will run it. Hub servers (public
-- servers) list the open lobbies to their players and seat joiners in the soonest one with room
-- (Quick Play), then teleport them into its reserved server; the match server runs a countdown to the
-- start, then fills every empty player slot with a bot player and plays the match.
--   * TARGET joinable lobbies are kept open (more while the demand calls for them: missing_starts);
--     each starts within LOBBY_OPEN_S (90 s).
--   * A match starts FILL_S after its first seat is taken; joining closes JOIN_CLOSE_S before the
--     start (a teleport takes a few seconds).
--   * Player cap: 50 per million full-size land tiles x 1.5 (round to 5), clamped to [MIN_PLAYERS,
--     MAX_PLAYERS]: World hosts 50 (and never more than a server holds: max_players).

local LobbyRules = {}

--- The map every public match plays.
LobbyRules.WORLD_ID = "world"
--- Joinable lobbies kept open while demand is low.
LobbyRules.TARGET = 1
--- Public matches play their map at this % of its width and height (the full-size map feels huge);
--- tribes scale with the area (Sim.default_tribes).
LobbyRules.MAP_SCALE_PCT = 80
--- Every listed match starts within LOBBY_OPEN_S: a new lobby starts at least MIN_LEAD_S out, one
--- every LOBBY_INTERVAL_S (players leave long waits).
LobbyRules.LOBBY_OPEN_S = 90
LobbyRules.LOBBY_INTERVAL_S = 45
LobbyRules.MIN_LEAD_S = 45
--- Joins close this long before the start (FILL_S after the first seat, so joins stay open a while).
LobbyRules.JOIN_CLOSE_S = 3
--- Matchmaking: a match starts this long after its first seat was taken (s); other players join it
--- until JOIN_CLOSE_S before that, and the seats nobody took by then are bot players. The players in
--- the waiting room can vote to start sooner (MatchServer.VOTE_START_S; one alone may too).
--- (2026-11-23: 30, was 10: with the first player's teleport and boot the room was up about 6 s,
--- nobody else had time to join and no vote could pass.)
LobbyRules.FILL_S = 30
--- For this long after asking, a party (or a lone player: a group of 1) only takes a lobby holding groups of
--- its own size (or an empty one); then any lobby with room.
LobbyRules.SAME_SIZE_S = 4
LobbyRules.MIN_PLAYERS = 10
LobbyRules.MAX_PLAYERS = 50
LobbyRules.PLAYERS_PER_MILLION_LAND = 50 * 1.5
--- A lobby record lives this long past its start (the match server reads it on boot).
LobbyRules.RECORD_TTL_AFTER_START_S = 15 * 60
--- A running match's server refreshes its record (`beat`) this often; hubs list it as live (to watch)
--- only while the last beat is recent, so a crashed match server drops off the lists.
LobbyRules.LIVE_BEAT_S = 30
LobbyRules.LIVE_STALE_S = 100
--- Running matches listed to watch at most (most players first; the phone list shows them all).
LobbyRules.MAX_LIVE_LISTED = 8

export type Lobby = {
	id: string,
	map: string,
	map_name: string,
	max: number,
	starts: number, -- os.time() seconds
	created: number,
	players: number, -- humans in (or on their way to) the match server
	status: string, -- "open" | "started" | "closed"
	beat: number?, -- os.time() of the running match's last heartbeat
	code: string?, -- reserved-server access code (server-only; never sent to clients)
	psid: string?, -- reserved server's PrivateServerId
	seats: { [string]: number }?, -- the seat ledger: user id -> when its seat was taken (take)
	group: number?, -- the size of the groups seated so far while they are all one size (nil: empty or mixed)
	mixed: boolean?, -- groups of different sizes were seated
}

-- ---------------------------------------------------------------------------------------------
-- Seats (Quick Play)
-- ---------------------------------------------------------------------------------------------
-- A player asks for a public match and the store seats them in the soonest lobby with room, in one
-- step (`take`): lobbies fill too fast for a player to pick one from a list. With no room anywhere
-- they wait in line on their hub until a seat is free. A lobby record keeps who holds its seats
-- (`seats`), so a seat whose player never arrives, or leaves the waiting room, is given back.

--- Seat-ledger entries a record keeps at most (the lobby service's MAX_SEATS).
LobbyRules.MAX_SEATS = 60
--- A seat whose player has not reached the match server this long after taking it is given back
--- (a teleport that failed after it began, a player who quit on the way).
LobbyRules.ARRIVE_S = 30

--- What `take` asks for: `n` seats for `uids` in the soonest open lobby with room that still takes
--- joins (`close_before`) and was not written with a wrong clock (`start_before`); `id`: only that
--- lobby; `candidates`: lobby ids to try in order, for stores that can't search (MemoryStore, the
--- local store).
export type TakeSpec = {
	n: number,
	uids: { string },
	at: number,
	close_before: number,
	start_before: number,
	id: string?,
	candidates: { string }?,
	same_size: boolean?, -- only lobbies whose groups are all `n` players (or empty): SAME_SIZE_S
}

function LobbyRules.take_spec(n: number, uids: { string }, now: number, id: string?): TakeSpec
	return {
		n = n,
		uids = uids,
		at = now,
		close_before = now + LobbyRules.JOIN_CLOSE_S,
		start_before = now + LobbyRules.MAX_AHEAD_S,
		id = id,
	}
end

--- True when `l` can seat what `spec` asks for (the service's take compares the same).
function LobbyRules.fits(l: Lobby, spec: TakeSpec): boolean
	return l.status == "open"
		and l.starts > spec.close_before
		and l.starts <= spec.start_before
		and l.players + spec.n <= l.max
		and (spec.id == nil or spec.id == l.id)
		and (not spec.same_size or l.players == 0 or (not l.mixed and l.group == spec.n))
end

--- `l` with `spec`'s seats taken (a new table; `l` is left as it was).
function LobbyRules.seated(l: Lobby, spec: TakeSpec): Lobby
	local c = table.clone(l)
	local seats = if l.seats ~= nil then table.clone(l.seats) else {}
	local count = 0
	for _ in seats do
		count += 1
	end
	for _, u in spec.uids do
		if seats[u] == nil and count < LobbyRules.MAX_SEATS then
			seats[u] = spec.at
			count += 1
		end
	end
	if l.players == 0 then
		c.group, c.mixed = spec.n, nil
		-- (the first seat: the match starts FILL_S from now, bots in the seats nobody took by then)
		c.starts = math.min(l.starts, spec.at + LobbyRules.FILL_S)
	elseif c.group ~= spec.n then
		c.group, c.mixed = nil, true
	end
	c.players += spec.n
	c.seats = seats
	return c
end

--- `l` with the seats of `uids` given back (only seats in its ledger, and only while open): the new
--- record and how many went back (0: unchanged).
function LobbyRules.released(l: Lobby, uids: { string }): (Lobby, number)
	if l.status ~= "open" or l.seats == nil then
		return l, 0
	end
	local seats = table.clone(l.seats)
	local n = 0
	for _, u in uids do
		if seats[u] ~= nil then
			seats[u] = nil
			n += 1
		end
	end
	if n == 0 then
		return l, 0
	end
	local c = table.clone(l)
	c.seats = seats
	c.players = math.max(0, l.players - n)
	if c.players == 0 then
		c.group, c.mixed = nil, nil
	end
	return c, n
end

--- Seats of a waiting lobby to give back (MatchHost, before the start): of `l`'s ledger, those whose
--- player arrived and has left (`arrived` but not `present`), and those whose player has not arrived
--- ARRIVE_S after taking the seat.
function LobbyRules.lapsed_seats(l: Lobby, present: { [string]: boolean }, arrived: { [string]: boolean }, now: number): { string }
	local out = {}
	for u, at in l.seats or {} do
		if present[u] then
			continue
		end
		if arrived[u] or now - at >= LobbyRules.ARRIVE_S then
			table.insert(out, u)
		end
	end
	table.sort(out)
	return out
end

-- Demand: with more players joining than one lobby holds for long, more lobbies are kept open,
-- starting one after another, so a free seat is always there to take.

--- Seats taken lately over this many seconds measure the demand.
LobbyRules.DEMAND_WINDOW_S = 120
--- Free seats kept open: this many seconds of joins at the measured demand.
LobbyRules.FILL_AHEAD_S = 20
--- Joinable lobbies at most.
LobbyRules.MAX_OPEN = 4
--- Lobbies start at least this far apart (and at most LOBBY_INTERVAL_S).
LobbyRules.MIN_INTERVAL_S = 8

export type Demand = { rate: number, size: number }

--- The demand for lobbies: `rate` = seats taken a second (the players of the lobbies made in the
--- last DEMAND_WINDOW_S: seats taken so far while open, the humans who started a started one),
--- `size` = their average size. `window`: seconds the list covers (less when it holds only the
--- latest running matches).
function LobbyRules.demand(list: { Lobby }, now: number, window: number?): Demand
	local w = math.clamp(window or LobbyRules.DEMAND_WINDOW_S, 30, LobbyRules.DEMAND_WINDOW_S)
	local seats, sizes, n = 0, 0, 0
	for _, l in list do
		if l.created > now - w and l.created <= now then
			seats += math.min(l.players, l.max)
			sizes += l.max
			n += 1
		end
	end
	return { rate = seats / w, size = if n > 0 then sizes / n else LobbyRules.max_players(nil) }
end

local function round5(n: number): number
	return math.floor(n / 5 + 0.5) * 5
end

--- Player cap for a map with `land_tiles` land tiles at full resolution (`k_lin` = full-size tiles
--- per our tile: our land count * k_lin^2 = the full-size map's) x PLAYERS_PER_MILLION_LAND / 1e6, rounded
--- to 5, 10..50, and at most `server` (the most players a Roblox server of the place holds,
--- Players.MaxPlayers: a seat past it is a "GameFull" teleport). The map is played at MAP_SCALE_PCT.
function LobbyRules.max_players(land_tiles: number?, k_lin: number?, server: number?): number
	local full = LobbyRules.MAX_PLAYERS
	if land_tiles ~= nil and land_tiles > 0 then
		local k = k_lin or 1.0
		local src_land = land_tiles * k * k
		full = math.clamp(round5(src_land / 1e6 * LobbyRules.PLAYERS_PER_MILLION_LAND), LobbyRules.MIN_PLAYERS, LobbyRules.MAX_PLAYERS)
	end
	if type(server) == "number" and server >= LobbyRules.MIN_PLAYERS then
		full = math.min(full, math.floor(server))
	end
	return full
end

--- True while players may still join (open, not full, far enough from the start).
function LobbyRules.joinable(l: Lobby, now: number): boolean
	return l.status == "open" and l.players < l.max and now < l.starts - LobbyRules.JOIN_CLOSE_S
end

--- Start times of the lobbies to create now so that TARGET joinable lobbies exist: after the latest
--- joinable start (or now + MIN_LEAD_S), LOBBY_INTERVAL_S apart. A full lobby doesn't push the next
--- ones back (it is replaced at once, so the matches on offer keep up when players pour in), and no
--- start lands more than LOBBY_OPEN_S out (a later refresh makes it once it fits). A lobby within
--- half LOBBY_INTERVAL_S of its start no longer counts, so the next one is made before it closes
--- (JOIN_CLOSE_S): there is always one to join.
--- `demand` (LobbyRules.demand): more lobbies while the free seats of the joinable ones would last
--- less than FILL_AHEAD_S at that rate (MAX_OPEN at most), each starting about as long after the one
--- before as it takes to fill (MIN_INTERVAL_S..LOBBY_INTERVAL_S).
function LobbyRules.missing_starts(open: { Lobby }, now: number, demand: Demand?): { number }
	local joinable = 0
	local free = 0
	local latest = 0
	local cover = LobbyRules.LOBBY_INTERVAL_S / 2
	for _, l in open do
		if LobbyRules.joinable(l, now) then
			if l.starts - now > cover then
				joinable += 1
				free += l.max - l.players
			end
			if l.starts > latest then
				latest = l.starts
			end
		end
	end
	local want_free = 0
	local interval = LobbyRules.LOBBY_INTERVAL_S
	local size = LobbyRules.max_players(nil)
	if demand ~= nil and demand.rate > 0 then
		want_free = demand.rate * LobbyRules.FILL_AHEAD_S
		size = math.max(1, demand.size)
		interval = math.clamp(size / demand.rate, LobbyRules.MIN_INTERVAL_S, LobbyRules.LOBBY_INTERVAL_S)
	end
	local out = {}
	local next_start = math.max(now + LobbyRules.MIN_LEAD_S, latest + interval)
	local target = LobbyRules.TARGET
	while joinable < target or (free < want_free and joinable < math.max(target, LobbyRules.MAX_OPEN)) do
		if next_start > now + LobbyRules.LOBBY_OPEN_S then
			break
		end
		table.insert(out, next_start)
		joinable += 1
		free += size
		next_start += interval
	end
	return out
end

--- The map id a public match on `map` plays ("world@80").
function LobbyRules.match_map_id(map: string): string
	return if LobbyRules.MAP_SCALE_PCT < 100 then map .. "@" .. LobbyRules.MAP_SCALE_PCT else map
end

--- No lobby is ever scheduled further ahead than this (the open window, two intervals of queue
--- behind it, and slack). A record beyond it was written with a wrong clock: ignored by the hubs,
--- and its match server does not wait past it.
LobbyRules.MAX_AHEAD_S = LobbyRules.LOBBY_OPEN_S + 2 * LobbyRules.LOBBY_INTERVAL_S + 120

function LobbyRules.plausible(l: Lobby, now: number): boolean
	return l.starts <= now + LobbyRules.MAX_AHEAD_S
end

--- A running match anyone may watch (its server is alive and reachable).
function LobbyRules.watchable(l: Lobby, now: number): boolean
	return l.status == "started" and l.code ~= nil and (l.beat or l.starts) > now - LobbyRules.LIVE_STALE_S
end

--- What a client sees of a lobby (no access code / server id). Live matches: `live`, `elapsed`.
function LobbyRules.public_view(l: Lobby, now: number): { [string]: any }
	local live = l.status == "started"
	return {
		id = l.id,
		map = l.map,
		map_name = l.map_name,
		max = l.max,
		players = math.min(l.players, l.max),
		starts_in = math.max(0, l.starts - now),
		joinable = LobbyRules.joinable(l, now),
		live = live,
		elapsed = if live then math.max(0, now - l.starts) else 0,
		watchable = LobbyRules.watchable(l, now),
	}
end

--- Bot players to add at the start so the match has `max` players.
function LobbyRules.bot_fill(max: number, humans: number): number
	return math.max(0, max - humans)
end

--- Sanitises a lobby record read back from a store (anything a client could have left malformed);
--- nil when unusable.
function LobbyRules.decode(v: any): Lobby?
	if type(v) ~= "table" then
		return nil
	end
	if type(v.id) ~= "string" or type(v.map) ~= "string" or type(v.starts) ~= "number" or type(v.max) ~= "number" then
		return nil
	end
	-- the seat ledger (an empty one may come back as an array: Roblox writes {} as [])
	local seats = nil
	if type(v.seats) == "table" then
		seats = {}
		local n = 0
		for u, at in v.seats do
			if type(u) == "string" and #u <= 24 and type(at) == "number" and n < LobbyRules.MAX_SEATS then
				seats[u] = at
				n += 1
			end
		end
	end
	return {
		id = v.id,
		map = v.map,
		map_name = if type(v.map_name) == "string" then v.map_name else v.map,
		max = math.clamp(math.floor(v.max), 1, 200),
		starts = v.starts,
		created = if type(v.created) == "number" then v.created else v.starts,
		players = if type(v.players) == "number" then math.max(0, math.floor(v.players)) else 0,
		status = if v.status == "started" or v.status == "closed" then v.status else "open",
		beat = if type(v.beat) == "number" then v.beat else nil,
		code = if type(v.code) == "string" then v.code else nil,
		psid = if type(v.psid) == "string" then v.psid else nil,
		seats = seats,
		group = if type(v.group) == "number" then math.clamp(math.floor(v.group), 1, 200) else nil,
		mixed = if v.mixed == true then true else nil,
	}
end

return LobbyRules
