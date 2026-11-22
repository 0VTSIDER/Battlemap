--!nonstrict
-- Studio only (Dev: not published). A solo match that plays itself for a screen recording (ad images
-- and the experience's video, 2026-11-22): the orders go through the UI's send as clicks would, the
-- camera is moved shot by shot, and the match runs in real time (a time-lapse between shots:
-- Session.local_speed). Each shot waits on the game's state, not on a clock, so a run is the same
-- shots whatever the nations do. Shots, in order: the world, the start, the first expansion, growth
-- (time-lapse), building, an invasion, a hydrogen bomb (wide: launch and impact), a second (close on the
-- impact), a MIRV, the big picture. Then the title screen for TITLE_HOLD_S, and the next run starts from
-- another place: the recording can start and stop at any time; one run lies between two title screens.
--
--   SessionDiag: `reel` (start) | `reel stop` | `reel state`. Progress: LocalPlayer attribute af_reel.
--
-- Off camera the run sets the player's gold (ReelGold, during the growth time-lapse): the bombs' prices
-- are late-game ones. Everything shown is the game's own mechanics.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Core = game:GetService("ReplicatedStorage"):WaitForChild("Battlemap"):WaitForChild("Core")
local Defs = require(Core:WaitForChild("Defs")) :: any
local Rules = require(Core:WaitForChild("Rules")) :: any

local AdReel = {}

-- Tunables -----------------------------------------------------------------------------------------
AdReel.ReelMapId = "world" -- Data/MapList id
AdReel.ReelDifficulty = 0 -- 0 easy .. 2 hard (easy: the player must outlive the run)
--- Where each run starts (lat, lon in degrees); one a run, in turn.
AdReel.ReelStarts = {
	-- (open land: a start among nations has no free land to grow into)
	{ 62, 100 }, -- Siberia
	{ -25, 134 }, -- Australia
	{ 58, -108 }, -- Canada
	{ 21, 12 }, -- the Sahara
}
AdReel.ReelGold = 60000000 -- gold the player is set to during the growth time-lapse
AdReel.ReelHoldS = 4.0 -- s the camera stands still on a big moment (clean frames for the images)
AdReel.ReelWorldHoldS = 3.0 -- s on the whole map before the start
AdReel.ReelExpandLiveS = 8.0 -- s of the first expansion at normal speed
AdReel.ReelExpandRatio = 0.35 -- share of troops in each expansion order
AdReel.ReelGrowSpeed = 5.0 -- x: the growth time-lapse
AdReel.ReelGrowMaxS = 30.0 -- s the growth time-lapse lasts at most
AdReel.ReelGrowTiles = 9000 -- tiles the player's land grows to before building
AdReel.ReelTradeSpeed = 3.0 -- x: trains and trade ships after building
AdReel.ReelTradeS = 8.0 -- s of that
AdReel.ReelInvadeRatio = 0.7 -- share of troops in the invasion
AdReel.ReelInvadeLiveS = 5.0 -- s of the invasion at normal speed
AdReel.ReelInvadeFastS = 7.0 -- s more at ReelInvadeSpeed
AdReel.ReelInvadeSpeed = 2.0 -- x
AdReel.ReelFlightSpeed = 3.0 -- x: a bomb's flight, until ReelFlightLiveTicks before it lands
AdReel.ReelFlightLiveTicks = 45 -- ticks (10 a second) of flight shown at normal speed before impact
AdReel.ReelNukeMinTiles = 80 -- tiles: the wide bomb shot's target is at least this far from the silo
AdReel.ReelNukeMaxTiles = 420 -- tiles: and at most this far (launch and impact both on screen)
AdReel.ReelWorldSpeed = 5.0 -- x: the big picture's time-lapse
AdReel.ReelWorldS = 12.0 -- s of that
AdReel.ReelTitleHoldS = 8.0 -- s of title screen between runs
AdReel.ReelAlly = true -- ask a neighbour for an alliance before building (its toast, its colours)

local state = nil :: any -- { main, stop, beat, run, conn }

local ABORT = "reel: stopped"
local DEAD = "reel: the player fell"

local function publish(text: string)
	local s = state
	if s == nil then
		return
	end
	s.beat = text
	table.insert(s.log, ("%.0f [%s]"):format(os.clock() - s.t0, text))
	Players.LocalPlayer:SetAttribute("af_reel_log", table.concat(s.log, "; "))
	Players.LocalPlayer:SetAttribute("af_reel", ("run %d | %s | %.0f s"):format(s.run, text, os.clock() - s.t0))
end

--- A line for the run's log (af_reel_log: what each shot did, for a check without the picture).
local function note(text: string)
	local s = state
	if s == nil then
		return
	end
	table.insert(s.log, ("%.0f %s"):format(os.clock() - s.t0, text))
	Players.LocalPlayer:SetAttribute("af_reel_log", table.concat(s.log, "; "))
end

local function st(): any
	return state.main.session.state
end

local function me(): any
	local s = st()
	return if s ~= nil and s.local_owner ~= 0 then s.owners[s.local_owner] else nil
end

--- Stops the shot (error) when the reel was stopped, or the player fell after the start.
local function check()
	local s = state
	if s == nil or s.stop then
		error(ABORT, 0)
	end
	if s.started then
		local o = me()
		if o == nil or not o.alive then
			error(DEAD, 0)
		end
	end
end

local function wait_s(secs: number)
	local t0 = os.clock()
	while os.clock() - t0 < secs do
		check()
		task.wait(0.05)
	end
	check()
end

--- Waits for pred() (polled), at most `timeout` s. False when it never came true.
local function wait_until(pred: () -> boolean, timeout: number): boolean
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		check()
		if pred() then
			return true
		end
		task.wait(0.05)
	end
	return pred()
end

local function speed(x: number)
	state.main.session.local_speed = x
end

local function rig(): any
	return state.main.world.rig
end

local function send(intent: { [string]: any })
	local ui = state.main.ui
	if ui ~= nil and ui.ctx ~= nil then
		ui.ctx:send(intent)
	else
		state.main.session:send_intent(intent)
	end
end

--- The zoom (px a tile) at which `tiles` tiles span the screen's height.
local function fit(tiles: number): number
	local r = rig()
	return r:clamp_scale(r:viewport_size().Y / math.max(tiles, 1))
end

--- The zoom at which a box of du x dv tiles (plus a margin on each side) is on screen.
local function fit_box(du: number, dv: number, margin: number): number
	local r = rig()
	local vp = r:viewport_size()
	return r:clamp_scale(math.min(vp.X / (du + margin * 2), vp.Y / (dv + margin * 2)))
end

local function cam(u: number, v: number, scale: number, secs: number)
	local r = rig()
	r.attract = false
	r:focus(u, v, scale, secs)
end

local function uv(tile: number): (number, number)
	local W = st().map.W
	return tile % W + 0.5, tile // W + 0.5
end

--- The middle of an owner's land and its rough reach (tiles).
local function land_of(o: any): (number, number, number)
	local n = math.max(o.tiles, 1)
	return o.cx / n + 0.5, o.cy / n + 0.5, math.sqrt(n)
end

--- Calls fn(tile, x, y) for every tile in the box round the player's land (not the whole map: a scan of
--- it is a hitch in the recording). fn returns true to stop.
local function scan_mine(fn: (number, number, number) -> boolean?)
	local s = st()
	local o = me()
	if s == nil or o == nil then
		return
	end
	local map = s.map
	local W, H = map.W, map.H
	local cu, cv, reach = land_of(o)
	local r = math.floor(reach * 2.5 + 24)
	local x0, x1 = math.max(0, math.floor(cu) - r), math.min(W - 1, math.floor(cu) + r)
	local y0, y1 = math.max(0, math.floor(cv) - r), math.min(H - 1, math.floor(cv) + r)
	local id = o.id
	for y = y0, y1 do
		local row = y * W
		for x = x0, x1 do
			local t = row + x
			if s:tile_owner(t) == id and fn(t, x, y) then
				return
			end
		end
	end
end

--- A free tile next to the player's land (an expansion order's target), or -1.
local function neutral_neighbor(): number
	local s = st()
	local map = s.map
	local found = -1
	scan_mine(function(t)
		for _, n in map:neighbors4(t) do
			if s:tile_owner(n) == 0 and map:is_contestable(n) then
				found = n
				return true
			end
		end
		return false
	end)
	return found
end

--- The owners on the player's border: { [id] = { n = border tiles, u, v = their sum, tiles = {..} } }.
local function neighbors(): { [number]: any }
	local s = st()
	local map = s.map
	local id = s.local_owner
	local out = {}
	scan_mine(function(t)
		for _, n in map:neighbors4(t) do
			local o = s:tile_owner(n)
			if o ~= 0 and o ~= id then
				local e = out[o]
				if e == nil then
					e = { n = 0, u = 0, v = 0, tiles = {} }
					out[o] = e
				end
				local nu, nv = uv(n)
				e.n += 1
				e.u += nu
				e.v += nv
				if #e.tiles < 4000 then
					table.insert(e.tiles, n)
				end
			end
		end
		return false
	end)
	return out
end

--- The free land tile nearest map point (u, v) with free land round it, or -1.
local function free_tile_near(u: number, v: number): number
	local s = st()
	local map = s.map
	local W, H = map.W, map.H
	local cu, cv = math.floor(u), math.floor(v)
	for r = 0, 160 do
		for dv = -r, r do
			for du = -r, r do
				if math.max(math.abs(du), math.abs(dv)) == r then
					local x, y = cu + du, cv + dv
					if x >= 2 and x < W - 2 and y >= 2 and y < H - 2 then
						local t = y * W + x
						if map:is_land(t) and map:is_contestable(t) and s:tile_owner(t) == 0 and not map:is_coastal(t) then
							local ok = true
							for _, n in map:neighbors4(t) do
								if s:tile_owner(n) ~= 0 or not map:is_land(n) then
									ok = false
									break
								end
							end
							if ok then
								return t
							end
						end
					end
				end
			end
		end
	end
	return -1
end

local function my_structs(kind: number): { any }
	local s = st()
	local out = {}
	for _, x in s.structures do
		if x.owner == s.local_owner and x.kind == kind then
			table.insert(out, x)
		end
	end
	table.sort(out, function(a, b)
		return a.sid < b.sid
	end)
	return out
end

local function built(kind: number): boolean
	local s = st()
	for _, x in my_structs(kind) do
		if x.active_tick <= s.tick then
			return true
		end
	end
	return false
end

--- Where the game's own placement rule lets the player build `kind` (room between structures, a coast
--- for a port): the such tile of the player's nearest (u, v), or -1.
local function site(kind: number, u: number, v: number): number
	local s = st()
	local map = s.map
	local port = kind == Defs.S_PORT
	local list = {}
	scan_mine(function(t, x, y)
		if if port then map:is_coastal(t) else (x % 4 == 0 and y % 4 == 0) then
			table.insert(list, { t = t, d = (x - u) * (x - u) + (y - v) * (y - v) })
		end
		return false
	end)
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	local name = Defs.STRUCT_NAMES[kind]
	for i = 1, math.min(#list, 400) do
		local p = Rules.placement(s, s.local_owner, name, list[i].t)
		if p.tile >= 0 and p.upgrade_sid == 0 and (p.reason == "" or p.reason == "gold") then
			return list[i].t
		end
	end
	return -1
end

--- Orders a structure at `tile` and waits for it to appear. The structure, or nil.
local function build(kind: number, tile: number): any
	if tile < 0 then
		return nil
	end
	local before = #my_structs(kind)
	send({ type = "build", kind = Defs.STRUCT_NAMES[kind], tile = tile })
	wait_until(function()
		return #my_structs(kind) > before
	end, 3)
	local list = my_structs(kind)
	note(("build %s %s"):format(Defs.STRUCT_NAMES[kind], if #list > before then "ok" else "refused"))
	return if #list > before then list[#list] else nil
end

--- The player's bombs of `kinds` still in flight.
local function my_nukes(kinds: { [number]: boolean }): { any }
	local s = st()
	local out = {}
	for _, n in s.nukes do
		if n.owner == s.local_owner and kinds[n.kind] then
			table.insert(out, n)
		end
	end
	return out
end

--- Fires `kind_name` at `tile` and shows its flight: a time-lapse until ReelFlightLiveTicks before it
--- lands, then normal speed to the impact (all of them, for a MIRV's warheads). False if nothing flew.
local function fire(kind_name: string, tile: number, kinds: { [number]: boolean }, timeout: number): boolean
	local s = st()
	local before = #my_nukes(kinds)
	-- (refused while the silo reloads: a time-lapse and another try, three in all)
	local flew = false
	for try = 1, 3 do
		send({ type = "nuke", kind = kind_name, tile = tile })
		flew = wait_until(function()
			return #my_nukes(kinds) > before
		end, 2)
		if flew then
			break
		end
		note(("fire %s refused (try %d)"):format(kind_name, try))
		speed(AdReel.ReelGrowSpeed)
		wait_s(2.5)
		speed(1.0)
	end
	if not flew then
		return false
	end
	note("fire " .. kind_name)
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		check()
		local left = -1
		for _, n in my_nukes(kinds) do
			left = math.max(left, n.launch_tick + n.flight_ticks - s.tick)
		end
		if left < 0 then
			break
		end
		speed(if left > AdReel.ReelFlightLiveTicks then AdReel.ReelFlightSpeed else 1.0)
		task.wait(0.05)
	end
	speed(1.0)
	note(("%s landed after %.0f s"):format(kind_name, os.clock() - t0))
	return true
end

--- A nation to bomb: the biggest whose land's middle is between `near` and `far` tiles from `from`
--- (and not across the map's seam); without one, the nearest. Never an ally, never `skip`.
local function bomb_target(from: number, near: number, far: number, skip: number?): any
	local s = st()
	local fu, fv = uv(from)
	local best, nearest, nd = nil, nil, math.huge
	for _, o in s:ranking() do
		if o.id ~= s.local_owner and o.id ~= skip and o.kind == Defs.KIND_NATION and not s:are_allies(s.local_owner, o.id) then
			local t = s:label_tile(o.id)
			if t >= 0 then
				local tu, tv = uv(t)
				local d = math.sqrt((tu - fu) ^ 2 + (tv - fv) ^ 2)
				if d >= near and d <= far and best == nil then
					best = { owner = o, tile = t, dist = d }
				end
				if d >= near * 0.5 and d < nd then
					nearest, nd = { owner = o, tile = t, dist = d }, d
				end
			end
		end
	end
	return best or nearest
end

-- The shots ------------------------------------------------------------------------------------------

local function shot_start(spot: { number })
	local s0 = state
	local session = s0.main.session
	publish("loading the match")
	session:start_solo(AdReel.ReelDifficulty, AdReel.ReelMapId)
	local ok = wait_until(function()
		local s = session.state
		return session.mode == 1 and not session:is_building() and s ~= nil and s.phase == Defs.PHASE_SPAWN and s.map ~= nil
	end, 90)
	if not ok then
		error("reel: the match did not start", 0)
	end
	speed(1.0)
	local r = rig()
	publish("the world")
	r.attract = false
	r._focus_active = false
	r:set_scale_immediate(r:min_scale())
	r:look_at(r.W * 0.5, r.H * 0.5)
	wait_s(AdReel.ReelWorldHoldS)

	publish("the start")
	local u, v = r:latlon_to_map(spot[1], spot[2])
	local tile = free_tile_near(u, v)
	if tile < 0 then
		error("reel: no free land at the start", 0)
	end
	u, v = uv(tile)
	cam(u, v, fit(64), 2.5)
	wait_s(3.2)
	send({ type = "spawn", tile = tile })
	if not wait_until(function()
		local o = me()
		return o ~= nil and o.spawned
	end, 10) then
		error("reel: the capital was not placed", 0)
	end
	s0.started = true
	if not wait_until(function()
		return st().phase == Defs.PHASE_PLAYING
	end, 40) then
		error("reel: the match did not begin", 0)
	end
end

local function expand()
	local t = neutral_neighbor()
	if t >= 0 then
		send({ type = "attack", tile = t, ratio = AdReel.ReelExpandRatio })
	end
end

local function shot_expand()
	publish("first expansion")
	local t0 = os.clock()
	while os.clock() - t0 < AdReel.ReelExpandLiveS do
		expand()
		wait_s(1.2)
	end
end

local function shot_grow()
	publish("growth (time-lapse)")
	local sim = state.main.session:local_sim()
	local s = st()
	speed(AdReel.ReelGrowSpeed)
	local t0 = os.clock()
	local k = 0
	while os.clock() - t0 < AdReel.ReelGrowMaxS and me().tiles < AdReel.ReelGrowTiles do
		expand()
		if k % 2 == 0 then
			local u, v, reach = land_of(me())
			cam(u, v, fit(reach * 3.4 + 44), 2.0)
		end
		if k == 2 and sim ~= nil then
			sim.o_gold[s.local_owner] = math.max(sim.o_gold[s.local_owner], AdReel.ReelGold)
		end
		k += 1
		wait_s(1.0)
	end
	if sim ~= nil then
		sim.o_gold[s.local_owner] = math.max(sim.o_gold[s.local_owner], AdReel.ReelGold)
	end
	speed(1.0)
end

--- Returns the silo (or nil): the bombs' launch site.
local function shot_build(): any
	publish("building")
	local s = st()
	local o = me()
	local cu, cv = uv(o.spawn_tile)
	-- the whole country in the shot, the capital's side of it
	local lu, lv, reach = land_of(o)
	cam((cu + lu) * 0.5, (cv + lv) * 0.5, fit(math.max(60, reach * 2.4 + 30)), 2.0)
	wait_s(2.4)
	if AdReel.ReelAlly then
		-- the neighbour with the shortest border (the longest is the one invaded)
		local pick, pn = 0, math.huge
		local count = 0
		for id, e in neighbors() do
			count += 1
			local other = s.owners[id]
			if other ~= nil and other.kind == Defs.KIND_NATION and e.n < pn then
				pick, pn = id, e.n
			end
		end
		if pick ~= 0 and count >= 2 then
			note("alliance asked of " .. s:owner_name(pick))
			send({ type = "ally_request", target = pick })
		end
	end
	-- (each where the game's placement rule has room, nearest the capital; the silo early: it takes
	-- the longest to build, and the bombs wait for it)
	local port = nil
	local silo = nil
	for _, kind in { Defs.S_CITY, Defs.S_SILO, Defs.S_FACTORY, Defs.S_PORT, Defs.S_DEFENSE, Defs.S_CITY } do
		local built_one = build(kind, site(kind, cu, cv))
		if kind == Defs.S_PORT then
			port = built_one
		elseif kind == Defs.S_SILO then
			silo = built_one
		end
		wait_s(0.9)
	end
	wait_until(function()
		return built(Defs.S_CITY) and built(Defs.S_FACTORY)
	end, 12)
	wait_s(AdReel.ReelHoldS)
	publish("trade (time-lapse)")
	if port ~= nil then
		local pu, pv = uv(port.tile)
		cam(pu, pv, fit(70), 2.0)
	end
	speed(AdReel.ReelTradeSpeed)
	wait_s(AdReel.ReelTradeS)
	speed(1.0)
	wait_s(AdReel.ReelHoldS - 1)
	return silo
end

--- Returns the owner invaded (0: none).
local function shot_invade(): number
	publish("invasion")
	local s = st()
	local pick, e, pn = 0, nil, 0
	for id, x in neighbors() do
		if not s:are_allies(s.local_owner, id) and not s:has_request(s.local_owner, id) and x.n > pn then
			pick, e, pn = id, x, x.n
		end
	end
	if pick == 0 or e == nil then
		note("nobody to invade")
		return 0
	end
	note(("invading %s over %d border tiles"):format(s:owner_name(pick), e.n))
	-- the border tile nearest the border's middle: the push starts there
	local mu, mv = e.u / e.n, e.v / e.n
	local tile, bd = e.tiles[1], math.huge
	for _, t in e.tiles do
		local tu, tv = uv(t)
		local d = (tu - mu) ^ 2 + (tv - mv) ^ 2
		if d < bd then
			tile, bd = t, d
		end
	end
	local tu, tv = uv(tile)
	cam(tu, tv, fit(58), 2.0)
	wait_s(3.0)
	send({ type = "attack", tile = tile, ratio = AdReel.ReelInvadeRatio })
	wait_s(AdReel.ReelInvadeLiveS)
	speed(AdReel.ReelInvadeSpeed)
	wait_s(AdReel.ReelInvadeFastS)
	speed(1.0)
	wait_s(AdReel.ReelHoldS - 1)
	return pick
end

local function wait_missile(silo: any)
	-- (a time-lapse until the silo is built and a missile is loaded: a launch refused says nothing)
	local s = st()
	speed(AdReel.ReelGrowSpeed)
	wait_until(function()
		if silo.active_tick > s.tick then
			return false
		end
		local loading = 0
		for _, shot in silo.shots or {} do
			if s.tick - shot < Rules.SILO_COOLDOWN_TICKS then
				loading += 1
			end
		end
		return loading < math.max(silo.level, 1)
	end, 30)
	speed(1.0)
	note(("silo level %d built %s"):format(silo.level, tostring(silo.active_tick <= s.tick)))
end

local HYDROGEN = { [Defs.N_HYDROGEN] = true }
local MIRV = { [Defs.N_MIRV] = true, [Defs.N_WARHEAD] = true }

local function shot_nukes(silo: any, invaded: number)
	local s = st()
	local su, sv = uv(silo.tile)
	local _, outer = Rules.for_map(s.map).nuke_radii(Defs.N_HYDROGEN) -- tiles

	publish("hydrogen bomb (launch and impact)")
	wait_missile(silo)
	local a = bomb_target(silo.tile, AdReel.ReelNukeMinTiles, AdReel.ReelNukeMaxTiles, invaded)
	if a ~= nil then
		note(("target %s at %.0f tiles"):format(a.owner.name, a.dist))
		local tu, tv = uv(a.tile)
		cam((su + tu) * 0.5, (sv + tv) * 0.5, fit_box(math.abs(tu - su), math.abs(tv - sv), outer + 30), 2.5)
		wait_s(3.5)
		fire("hydrogen", a.tile, HYDROGEN, 90)
		wait_s(AdReel.ReelHoldS)
	end

	publish("hydrogen bomb (close)")
	wait_missile(silo)
	local b = bomb_target(silo.tile, AdReel.ReelNukeMinTiles, AdReel.ReelNukeMaxTiles, if a ~= nil then a.owner.id else invaded)
		or a
	if b ~= nil then
		-- (its own land's middle moved if the first bomb fell on it: read again)
		local tile = s:label_tile(b.owner.id)
		tile = if tile >= 0 then tile else b.tile
		local tu, tv = uv(tile)
		cam(tu, tv, fit(outer * 3.4 + 40), 2.5)
		wait_s(3.5)
		fire("hydrogen", tile, HYDROGEN, 90)
		wait_s(AdReel.ReelHoldS)
	end

	publish("MIRV")
	wait_missile(silo)
	local leader = nil
	for _, o in s:ranking() do
		if o.id ~= s.local_owner and o.kind == Defs.KIND_NATION and not s:are_allies(s.local_owner, o.id) then
			leader = o
			break
		end
	end
	if leader ~= nil then
		local tile = s:label_tile(leader.id)
		if tile >= 0 then
			local lu, lv, reach = land_of(leader)
			local r = rig()
			cam(lu, lv, math.max(fit(reach * 2.4 + 60), r:min_scale() * 1.25), 3.0)
			wait_s(4.0)
			fire("mirv", tile, MIRV, 120)
			wait_s(AdReel.ReelHoldS)
		end
	end
end

local function shot_world()
	publish("the big picture (time-lapse)")
	local r = rig()
	cam(r.W * 0.5, r.H * 0.5, r:min_scale(), 3.5)
	wait_s(3.6)
	speed(AdReel.ReelWorldSpeed)
	wait_s(AdReel.ReelWorldS)
	speed(1.0)
	publish("the big picture (hold)")
	wait_s(AdReel.ReelHoldS)
end

local function run_once(spot: { number })
	state.started = false
	state.log = {}
	shot_start(spot)
	shot_expand()
	shot_grow()
	local silo = shot_build()
	local invaded = shot_invade()
	if silo ~= nil then
		shot_nukes(silo, invaded)
	end
	shot_world()
end

-- Start / stop ---------------------------------------------------------------------------------------

function AdReel.active(): boolean
	return state ~= nil
end

function AdReel.state(): string
	return if state then tostring(Players.LocalPlayer:GetAttribute("af_reel")) else "off"
end

function AdReel.stop()
	local s = state
	if s == nil then
		return
	end
	s.stop = true
end

local function cleanup(s: any)
	if s.conn ~= nil then
		s.conn:Disconnect()
	end
	UserInputService.MouseIconEnabled = true
	local main = s.main
	main.session.local_speed = 1.0
	if main.world ~= nil then
		main.world:set_input_enabled(true)
	end
	if main.ui ~= nil and main.ui.coach ~= nil then
		main.ui.coach.muted = false
	end
	Players.LocalPlayer:SetAttribute("af_reel", "off")
	state = nil
end

function AdReel.start(Main: any)
	if state ~= nil then
		return
	end
	local s = { main = Main, stop = false, beat = "", run = 0, t0 = os.clock(), started = false, log = {} }
	state = s
	-- nothing of the person at the desk on screen: no pointer, no map input (the UI's own gate turns the
	-- map's input back on as screens change: held off every frame)
	UserInputService.MouseIconEnabled = false
	s.conn = RunService.Heartbeat:Connect(function()
		local w = Main.world
		if w ~= nil and w.input_enabled then
			w:set_input_enabled(false)
		end
		-- (the coach's tip cards are for a player; a match's start turns them back on)
		local coach = Main.ui and Main.ui.coach
		if coach ~= nil and not coach.muted then
			coach.muted = true
			coach:clear()
		end
	end)
	task.spawn(function()
		while not s.stop do
			s.run += 1
			s.t0 = os.clock()
			local spot = AdReel.ReelStarts[(s.run - 1) % #AdReel.ReelStarts + 1]
			local ok, err = pcall(run_once, spot)
			s.started = false
			Main.session.local_speed = 1.0
			if s.stop then
				break
			end
			publish(if ok then "done: title screen" else "cut short (" .. tostring(err) .. "): title screen")
			Players.LocalPlayer:SetAttribute("af_reel_last", Players.LocalPlayer:GetAttribute("af_reel_log"))
			Main.session:start_title()
			local t0 = os.clock()
			while os.clock() - t0 < AdReel.ReelTitleHoldS and not s.stop do
				task.wait(0.1)
			end
		end
		cleanup(s)
	end)
end

return AdReel
