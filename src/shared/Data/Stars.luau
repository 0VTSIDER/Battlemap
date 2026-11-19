--!strict
-- Stars: the currency a match pays, spent in the Locker's store (Data/Store; 2026-10-04: an item is either
-- earned by playing or bought with Robux). The formula is Pixel Conquest's Money payout
-- (an average match pays an average seat about 1,000; about 3,300 an hour of play), line by line:
--
--   played     100                              not for a player who left early
--   survived   15 a minute alive
--   territory  30 x peak land in fair shares    (a share = the map's land / the nations and players)
--   conquests  54 a nation or player conquered  (tribes don't count: there are hundreds)
--   placed     14 a minute x place score        place score = (1 - (place - 1) / (field - 1))^2;
--                                               not for a player who left early
--   victory    18 a minute                      the winner
--
-- Every line is rounded to 5 (at least 5 when it pays at all). A player who never spawned gets
-- nothing. A solo match pays a share of this by difficulty (MODE_MULT: it runs on the player's own
-- device against the AI); 2x Stars (a game pass, Data/Passes) doubles the total.
--
--   Stars.payout(result, mode, double) -> { lines = { { key, amount } }, total }
--   Stars.sanitize(report, real_minutes) -> result   a client's solo report, made safe
--   Stars.solo_cap(real_minutes)                     the most a solo match of that length may pay
--   Stars.Tracker.new(sim)                           follows a running Sim for its humans' results (and, for
--                                                    the Battle Pass's daily missions, Data/Missions, what
--                                                    each one built, launched, earned...: result.extra)
local IS_ROBLOX = typeof(game) == "Instance"
local Core: any = if IS_ROBLOX then (game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Core else nil
local Defs: any = if IS_ROBLOX then require(Core.Defs) else require("../Core/Defs")
local Ev: any = if IS_ROBLOX then require(Core.Ev) else require("../Core/Ev")

local Stars = {}

Stars.NAME = "Stars"
Stars.FLOOR = 100
Stars.PER_MINUTE = 15
Stars.PER_SHARE = 30
Stars.PER_KILL = 54
Stars.PLACE_RATE = 14
Stars.WIN_RATE = 18
Stars.QUANTUM = 5
--- What a mode pays of the formula. Solo runs on the player's device against the AI: Relaxed,
--- Standard, Brutal.
Stars.MODE_MULT = { public = 1.0, solo0 = 0.4, solo1 = 0.7, solo2 = 1.0 }
--- A solo match's result is the client's word: its Stars never exceed this much per real minute
--- (the server's clock) plus the floor. Generous for an honest fast win, a ceiling for a made-up one.
Stars.SOLO_CAP_PER_MIN = 220
--- The floor in that cap grows over this many real minutes (2026-11-13): paid in full from the start, a
--- client could start a match and claim its result at once, again and again, for the floor each time
--- (up to ~12,000 Stars a minute at the 2-a-second request cap).
Stars.SOLO_FLOOR_MIN = 1.0
--- Sanity bounds for a result.
Stars.MAX_MINUTES = 240
Stars.MAX_KILLS = 200
Stars.MAX_FIELD = 1024

Stars.LINES = { "played", "survived", "territory", "conquests", "placed", "victory" }
Stars.LABELS = {
	played = "Match played",
	survived = "Time survived",
	territory = "Land held",
	conquests = "Nations conquered",
	placed = "Final place",
	victory = "Victory",
	double = "2x Stars",
}

export type Result = {
	spawned: boolean,
	left: boolean,
	won: boolean,
	minutes: number,
	shares: number,
	kills: number,
	place: number,
	field: number,
	--- a public match's mission counts (Stars.Tracker; Data/Missions.stats), nil in solo
	extra: { [string]: number }?,
	--- land taken from another nation, player, bot or tribe (Stars.Tracker: server/PlatformBadges), nil in solo
	took: boolean?,
}

local function quantum(x: number): number
	if x <= 0 then
		return 0
	end
	return math.max(Stars.QUANTUM, math.floor(x / Stars.QUANTUM + 0.5) * Stars.QUANTUM)
end

function Stars.place_score(place: number, field: number): number
	if field <= 1 then
		return 1
	end
	local s = math.clamp(1 - (place - 1) / (field - 1), 0, 1)
	return s * s
end

--- The Stars `r` pays in `mode` ("public" / "solo0".."solo2"); `double` = the player owns 2x Stars.
function Stars.payout(r: Result, mode: string?, double: boolean?): { lines: { { any } }, total: number }
	local lines: { { any } } = {}
	local total = 0
	if not r.spawned then
		return { lines = lines, total = 0 }
	end
	local mult = Stars.MODE_MULT[mode or "public"] or 1.0
	local minutes = math.clamp(r.minutes, 0, Stars.MAX_MINUTES)
	local function add(key: string, amount: number)
		local a = quantum(amount * mult)
		if a > 0 then
			table.insert(lines, { key, a })
			total += a
		end
	end
	if not r.left then
		add("played", Stars.FLOOR)
	end
	add("survived", Stars.PER_MINUTE * minutes)
	add("territory", Stars.PER_SHARE * math.max(r.shares, 0))
	add("conquests", Stars.PER_KILL * math.max(r.kills, 0))
	if not r.left then
		add("placed", Stars.PLACE_RATE * Stars.place_score(r.place, r.field) * minutes)
		if r.won then
			add("victory", Stars.WIN_RATE * minutes)
		end
	end
	if double and total > 0 then
		table.insert(lines, { "double", total })
		total *= 2
	end
	return { lines = lines, total = total }
end

--- The most a solo match that really lasted `real_minutes` may pay (before 2x Stars).
function Stars.solo_cap(real_minutes: number): number
	local m = math.max(real_minutes, 0)
	return math.floor(Stars.FLOOR * math.min(m / Stars.SOLO_FLOOR_MIN, 1) + Stars.SOLO_CAP_PER_MIN * m)
end

local function num(v: any, lo: number, hi: number): number
	if type(v) ~= "number" or v ~= v then
		return lo
	end
	return math.clamp(v, lo, hi)
end

--- A client's solo result made safe: every field typed and bounded, and no longer than the match
--- really lasted on the server's clock.
function Stars.sanitize(report: any, real_minutes: number): Result
	local rep = if type(report) == "table" then report else {}
	local field = math.floor(num(rep.field, 1, Stars.MAX_FIELD))
	return {
		spawned = rep.spawned == true,
		left = rep.left == true,
		won = rep.won == true and rep.left ~= true,
		minutes = num(rep.minutes, 0, math.min(Stars.MAX_MINUTES, math.max(real_minutes, 0))),
		shares = num(rep.shares, 0, field),
		kills = math.floor(num(rep.kills, 0, math.min(field, Stars.MAX_KILLS))),
		place = math.floor(num(rep.place, 1, field)),
		field = field,
	}
end

-- =============================================================================================
-- Tracker: a running Sim's results
-- =============================================================================================
-- Fed after every Sim step (step(delta.ev)): the peak land of each watched human, the nations and
-- players each one conquered, the order the field fell in. `field` = the nations and players that
-- took part (tribes are scenery).

local Tracker = {}
Tracker.__index = Tracker
Stars.Tracker = Tracker

local KIND_TRIBE = Defs.KIND_TRIBE
local PHASE_PLAYING = Defs.PHASE_PLAYING
local PHASE_OVER = Defs.PHASE_OVER
local TICKS_PER_MINUTE = Defs.TICK_RATE * 60

function Tracker.new(sim: any)
	local self = setmetatable({}, Tracker)
	self.sim = sim
	--- owner id -> { start, peak, kills, out_tick, place }
	self.seats = {} :: { [number]: any }
	self.field = 0
	--- nations and players still standing
	self.live = 0
	self._counted = false
	--- structure id -> its owner (whose SAM intercepted a missile), and alliance requests (from * 1024 + to)
	self._sid_owner = {} :: { [number]: number }
	self._asked = {} :: { [number]: boolean }
	--- each tile's owner as of the last step (a copy of sim.owner, kept from the steps' tiles) while a
	--- watched human has not taken land from another owner yet (Tracker._took); nil otherwise
	self._own = nil :: buffer?
	return self
end

--- Counts the field once the match is being played (nations and players with land).
function Tracker._count(self: any)
	local sim = self.sim
	if self._counted or sim.phase < PHASE_PLAYING then
		return
	end
	self._counted = true
	local n = 0
	for id = 1, sim.owner_total do
		if sim.o_kind[id] ~= KIND_TRIBE and sim.o_alive[id] == 1 and sim.o_spawned[id] == 1 then
			n += 1
		end
	end
	self.field = math.max(n, 1)
	self.live = n
	for _, seat in self.seats do
		seat.start = math.max(seat.start, sim.tick)
	end
end

--- Follow human `id` from now on (a second call keeps what it has).
function Tracker.watch(self: any, id: number)
	if id <= 0 or self.seats[id] ~= nil then
		return
	end
	local sim = self.sim
	self.seats[id] =
		{ start = sim.tick, peak = sim.o_tiles[id] or 0, kills = 0, victims = {}, out_tick = nil, place = nil, st = {} }
	if self._counted and sim.o_spawned[id] ~= 1 then
		-- a late joiner makes the field one bigger once it lands (see step)
		self.seats[id].late = true
	end
end

--- A takeover: the player who was `old` commands `new` from now on — a new life, counted from here
--- (the land it starts with is not the player's doing: the peak starts at 0 above it).
function Tracker.adopt(self: any, old: number, new: number)
	self.seats[old] = nil
	local sim = self.sim
	self.seats[new] = {
		start = sim.tick,
		peak = 0,
		base = sim.o_tiles[new] or 0,
		kills = 0,
		victims = {},
		out_tick = nil,
		place = nil,
		st = {},
		took = if self.seats[old] ~= nil then self.seats[old].took else nil,
	}
end

-- (the mission counts: Defs.STRUCT_NAMES of what is counted as built, and the munitions by kind)
local COUNTED_STRUCTS = { city = true, port = true, factory = true, defense = true, sam = true, silo = true }
local NUKE_STAT = {
	[Defs.N_ATOM] = "nuke",
	[Defs.N_HYDROGEN] = "nuke",
	[Defs.N_MEGA] = "nuke",
	[Defs.N_SCATTER] = "nuke",
	[Defs.N_MIRV] = "mirv",
	[Defs.N_AIRSTRIKE] = "airstrike",
	[Defs.N_SLUG] = "slug",
}

local function count(seat: any, key: string, n: number?)
	if seat ~= nil and seat.out_tick == nil then
		seat.st[key] = (seat.st[key] or 0) + (n or 1)
	end
end

--- A step's events, for the missions' counts of the watched humans.
function Tracker._mission_events(self: any, events: { { any } })
	local sim = self.sim
	local seats = self.seats
	for _, e in events do
		local k = e[1]
		if k == Ev.STRUCT_ADD then
			self._sid_owner[e[2]] = e[4]
			local name = Defs.STRUCT_NAMES[e[3]]
			if COUNTED_STRUCTS[name] then
				count(seats[e[4]], name)
			end
		elseif k == Ev.STRUCT_OWNER then
			self._sid_owner[e[2]] = e[3]
		elseif k == Ev.UNIT_ADD then
			if e[3] == Defs.U_WARSHIP then
				count(seats[e[4]], "warship")
			elseif e[3] == Defs.U_TRADE then
				count(seats[e[4]], "trade")
			end
		elseif k == Ev.NUKE then
			local stat = NUKE_STAT[e[3]]
			if stat ~= nil then
				count(seats[e[4]], stat)
			end
		elseif k == Ev.SAM_LAUNCH then
			if e[6] == true then
				count(seats[self._sid_owner[e[2]] or 0], "intercept")
			end
		elseif k == Ev.ALLY_REQ then
			self._asked[e[2] * 1024 + e[3]] = true
		elseif k == Ev.ALLY then
			local a, b = e[2], e[3]
			count(seats[a], "ally")
			count(seats[b], "ally")
			-- (who answered a request: the one it was made to)
			if self._asked[b * 1024 + a] then
				count(seats[a], "accept")
			end
			if self._asked[a * 1024 + b] then
				count(seats[b], "accept")
			end
			self._asked[a * 1024 + b] = nil
			self._asked[b * 1024 + a] = nil
		elseif k == Ev.CONQUEST or k == Ev.BONUS then
			-- (the gold a conquest took; a train's or a trade ship's gold at a stop)
			count(seats[e[2]], "gold", tonumber(e[4]) or 0)
		elseif k == Ev.OWNER_OUT then
			if sim.o_kind[e[2]] == KIND_TRIBE and e[3] ~= e[2] then
				count(seats[e[3]], "tribes")
			end
		end
	end
end

--- The step's tile changes (Sim delta `tiles`: tile * 1024 + new owner): a watched human that took a tile
--- from another owner (a nation, player, bot or tribe; not empty land) has `took` from then on. The tiles'
--- owners are only kept while someone still hasn't (a copy made then misses that one step).
function Tracker._took(self: any, tiles: { number }?)
	local seats = self.seats
	local want = false
	for _, seat in seats do
		if not seat.took and seat.out_tick == nil then
			want = true
			break
		end
	end
	local own = self._own
	local owner = self.sim.owner
	if not want or type(owner) ~= "buffer" or tiles == nil then
		self._own = nil
		return
	end
	if own == nil then
		own = buffer.create(buffer.len(owner))
		buffer.copy(own, 0, owner)
		self._own = own
		return
	end
	for _, v in tiles do
		local nw = v % 1024
		local t = (v - nw) // 1024
		local old = buffer.readi32(own, t * 4)
		buffer.writei32(own, t * 4, nw)
		if old ~= 0 and old ~= nw then
			local seat = seats[nw]
			if seat ~= nil and seat.out_tick == nil then
				seat.took = true
			end
		end
	end
end

--- After every Sim step, with the step's events and tile changes (the Sim delta's `ev` and `tiles`).
function Tracker.step(self: any, events: { { any } }?, tiles: { number }?)
	local sim = self.sim
	self:_count()
	if not self._counted then
		return
	end
	local o_tiles = sim.o_tiles
	for id, seat in self.seats do
		if seat.late and sim.o_spawned[id] == 1 then
			seat.late = nil
			seat.start = sim.tick
			self.field += 1
			self.live += 1
		end
		local t = (o_tiles[id] or 0) - (seat.base or 0)
		if t > seat.peak then
			seat.peak = t
		end
		-- (the missions: gold earned, the most troops)
		if seat.out_tick == nil then
			local st = seat.st
			local income = if sim.o_income ~= nil then tonumber(sim.o_income[id]) or 0 else 0
			if income > 0 then
				st.gold = (st.gold or 0) + income / Defs.TICK_RATE
			end
			local troops = if sim.o_troops ~= nil then tonumber(sim.o_troops[id]) or 0 else 0
			if troops > (st.troops or 0) then
				st.troops = troops
			end
		end
	end
	self:_took(tiles)
	if events == nil then
		return
	end
	self:_mission_events(events)
	for _, e in events do
		if e[1] == Ev.OWNER_OUT then
			local id, killer = e[2], e[3]
			if sim.o_kind[id] ~= KIND_TRIBE then
				local seat = self.seats[id]
				if seat ~= nil and seat.out_tick == nil then
					seat.out_tick = sim.tick
					seat.place = math.max(self.live, 1)
				end
				self.live = math.max(self.live - 1, 0)
				local ks = self.seats[killer]
				if ks ~= nil and killer ~= id then
					ks.kills += 1
					-- (who: the global leaderboard's points, Data/Ranks; an ally's fall counts for nothing)
					local friend = type(sim.allied) == "function" and sim:allied(killer, id) == true
					table.insert(ks.victims, { owner = id, friend = friend })
				end
			end
		end
	end
end

--- The nations and players `id` eliminated: { { owner, friend } } (friend: allied at the time).
function Tracker.victims(self: any, id: number): { any }
	local seat = self.seats[id]
	return if seat ~= nil then seat.victims else {}
end

--- True once `id`'s result is final (it fell, or the match is over).
function Tracker.final(self: any, id: number): boolean
	local seat = self.seats[id]
	return seat ~= nil and (seat.out_tick ~= nil or self.sim.phase == PHASE_OVER)
end

--- `id`'s result so far; `left` = the player is leaving a match that goes on.
function Tracker.result(self: any, id: number, left: boolean?): Result
	local sim = self.sim
	local seat = self.seats[id]
	if seat == nil or not self._counted or sim.o_spawned[id] ~= 1 then
		return {
			spawned = false,
			left = left == true,
			won = false,
			minutes = 0,
			shares = 0,
			kills = 0,
			place = 1,
			field = 1,
		}
	end
	local field = math.max(self.field, 1)
	local place = seat.place
	if place == nil then
		-- still standing: ranked by land among the nations and players still standing
		place = 1
		local mine = sim.o_tiles[id] or 0
		for o = 1, sim.owner_total do
			if o ~= id and sim.o_kind[o] ~= KIND_TRIBE and sim.o_alive[o] == 1 and (sim.o_tiles[o] or 0) > mine then
				place += 1
			end
		end
	end
	local land = if sim.map ~= nil then sim.map.land_count else 0
	local share = math.max(land, 1) / field
	local gone = left == true and seat.out_tick == nil and sim.phase ~= PHASE_OVER
	return {
		spawned = true,
		left = gone,
		won = not gone and sim.phase == PHASE_OVER and sim.winner == id,
		minutes = math.max(0, (seat.out_tick or sim.tick) - seat.start) / TICKS_PER_MINUTE,
		shares = seat.peak / share,
		kills = seat.kills,
		place = math.min(place, field),
		field = field,
		extra = table.clone(seat.st),
		took = seat.took == true,
	}
end

return Stars
