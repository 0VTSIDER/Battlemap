--!strict
-- Robux purchases (developer products, shared/Data/Products). A purchase is a saved credit: Roblox's
-- ProcessReceipt adds it to the player's record in its own DataStore (only the server writes it —
-- the client's SETTING op can't touch it) and only then reports the purchase granted, so Roblox
-- retries until it is stored and a receipt is never granted twice (its PurchaseId is kept). The game
-- spends a credit when the moment comes (Purchases.use); one bought after the moment passed stays
-- for the next time.
--
--   Purchases.configure(deps)     { datastore = DataStore, notify = fn(player, credits), log? }
--   Purchases.process_receipt(info) -> "granted" | "not_processed"   (a product's `count` credits)
--   Purchases.settle(player, max_s) -> record?  leaving for another server: the record once this
--                                 server's writes have landed (yields)
--   Purchases.lost                { payouts, stars, rp } that could not be stored after every retry
--   Purchases.take_stats() -> counts   this window's payouts, owed Stars and writes (and a fresh window)
--   Purchases.leave_owed(player) -> bool   Stars still owed to a leaving player go to MemoryStore (yields)
--   Purchases.load(player)        read the record (join; retried while Roblox refuses it); notify
--   Purchases.credits(player) -> { [kind]: number }
--   Purchases.use(player, kind) -> (ok, err?)   spend one (yields)
--   Purchases.release(player)     PlayerRemoving
--   Purchases.equip(player, slot, id | false, tier?) -> (ok, err?)   a Purchases.SLOTS slot; only owned
--                                 items, or a rank frame the player's rank tier `tier` unlocks
--   Purchases.inventory(player, tier?) -> { owned = { id }, equipped = { [slot]: id }, stars }
--   Purchases.add_stars(player, amount, bp?) -> (ok, balance, outcome?)   a match's Stars (Data/Stars) and its
--                                 Battle Pass part (Data/BattlePass: XP, mission stats) in the same write (yields)
--   Purchases.use_premium(player) -> (ok, err?)   spend a Battle Pass Premium credit on this season (yields)
--   Purchases.buy_item(player, id) -> (ok, err?)   buy a store item with Stars (Data/Store; yields)
--   Purchases.add_rp(player, delta, won, victims) -> (ok, rp)   a ranked match's Rank Points (Data/Ranks;
--                                 victims: the people's user ids it counts against the daily cap; yields)
--   Purchases.rp(player) -> rp     Purchases.hits(player, user_id) -> n (today's, against that person)
--   Purchases.worn_by_id(user_id) -> (equipped?, rp)   what anyone wears, on this server or not (the global
--                                 leaderboards' rows; yields: someone elsewhere is read from the store)
-- The Arsenal (Data/Arsenal) is every player's from the start (2026-11-03): nothing here.
-- The record: { credits = { kind = n }, receipts = { id }, owned = { [item] = true },
--   equipped = { skin = id?, flag = id? }, stars = n, stars_earned = n,
--   paid = bool, gifts = { [item] = true }, bp = the Battle Pass (Data/BattlePass.clean) }.
-- The Stars store (Data/Store; 2026-11-03): Purchases.buy_item takes an item's price in Stars and
-- owns it (and puts it on) in one write; Robux never buy an item.
-- Exclusive cosmetics (Cosmetics.exclusive_skins, made for particular players): every read of a
-- record for a player (clean(v, user_id)) owns what Cosmetics.granted(user_id) lists, and the first
-- time (not yet in `gifts`) puts it on; nobody else's record can hold one.
local IS_ROBLOX = typeof(game) == "Instance"
local Products: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Products)
	else require("../shared/Data/Products")
local Cosmetics: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Cosmetics)
	else require("../shared/Data/Cosmetics")
local Ranks: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Ranks)
	else require("../shared/Data/Ranks")
local Store: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Store)
	else require("../shared/Data/Store")
local BattlePass: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.BattlePass)
	else require("../shared/Data/BattlePass")

local Purchases = {}

Purchases.STORE = "BattlemapPurchases_v1"
--- Receipts remembered per player (a retried ProcessReceipt is always about a recent one).
Purchases.RECEIPTS_KEPT = 100
Purchases.MAX_CREDITS = 1000
Purchases.MAX_STARS = 1000000000
--- What a player can wear, one item each.
Purchases.SLOTS = { "skin", "badge", "icon", "font", "frame" }

type Record = {
	credits: { [string]: number },
	receipts: { string },
	owned: { [string]: boolean },
	equipped: { skin: string?, flag: string? },
	stars: number,
	stars_earned: number,
	--- the tutorial's Stars were paid (Data/Tutorial.STARS, once per player)
	tutorial_paid: boolean?,
	--- ever paid Robux (a record from before this field: it has receipts)
	paid: boolean,
	--- exclusive items already given (and put on once): Cosmetics.granted
	gifts: { [string]: boolean },
	rp: number,
	rp_matches: number,
	rp_wins: number,
	rp_day: number,
	rp_hits: { [string]: number },
	--- seconds played in matches (the playtime leaderboard, 2026-11-04): from the end of placement to
	--- being eliminated, leaving or winning
	play_s: number,
	--- the ids of the last PAYOUTS_KEPT Stars payouts stored (a payout tried again is stored once)
	payouts: { string },
	--- the Battle Pass (Data/BattlePass.Bp; rolled over to this month and day on every read)
	bp: any,
}

--- Reading a player's record when they join: GetAsync attempts and the waits between them. Roblox
--- throttles DataStore reads now and then ("TooManyRequests ... API: GetAsync", 37 in a day on the
--- error report of 2026-10-05). The load used to give up after one attempt, and that player then
--- had none of their unlocks, Stars or cosmetics for the whole session.
Purchases.LOAD_ATTEMPTS = 5
Purchases.LOAD_BACKOFF = { 1, 3, 6, 10 }
--- After those the session goes on without the record, and the read is tried again every
--- LOAD_RETRY_S, LOAD_RETRIES more times, while the player stays.
Purchases.LOAD_RETRY_S = 20
Purchases.LOAD_RETRIES = 30
--- Stars and Rank Points that could not be stored at all: Stars owed (below) and then not even kept in
--- MemoryStore; Rank Points after every write failed, DsGate's retries included.
Purchases.lost = { payouts = 0, stars = 0, rp = 0 }
--- Stars payouts whose write failed are owed, not lost (2026-11-13: Roblox refused so many writes to
--- the Purchases store that match payouts failed every retry and were dropped). An owed payout keeps
--- its id and goes with the player's next write to their record (any write: an equip, a purchase, the
--- next payout), is tried again over OWED_RETRY_S while they stay, and is kept in MemoryStore when they
--- leave (deps.owed_map, OWED_HOLD_S): the next server they join pays it. The record keeps the ids of
--- its last PAYOUTS_KEPT payouts, so one is never stored twice.
Purchases.OWED_RETRY_S = { 15, 30, 60, 120 }
Purchases.OWED_HOLD_S = 45 * 24 * 3600
Purchases.PAYOUTS_KEPT = 50
--- One write at a time to a record from this server: a second write to the same key within Roblox's
--- cooldown waits in Roblox's queue, and a full queue (30) drops every other player's writes too (the
--- error report's "DataStore request was added to queue ... Key = u<player>"). A write waits at most
--- this long for the one before it.
Purchases.KEY_WAIT_S = 30
--- Counts for the server's report (Purchases.take_stats).
Purchases.stats = { payouts = 0, owed_new = 0, owed_paid = 0, owed_kept = 0, writes = 0, write_fails = 0, skipped = 0 }

local deps: { [string]: any } = {}
local cache: { [any]: { [string]: number } } = {}
--- the player's items (the record's owned / equipped / Stars), as last read or written
local inv: { [any]: any } = {}
--- player -> the load that is still trying to read their record (a token: a newer load, a write
--- that brought the record, or leaving ends it)
local loading: { [any]: any } = {}
--- user id -> { at, eq }: what someone not on this server wears (Purchases.worn_by_id)
local worn_cache: { [number]: { at: number, eq: any, rp: number } } = {}
--- player -> their whole record as last read or written (handed to the next server: Purchases.settle)
local records: { [any]: Record } = {}
--- user id -> this server's writes to their record still in flight
local busy: { [number]: number } = {}
--- user id -> a write failed since the record was last read or written: what this server holds may
--- not be what is stored (Purchases.use keeps a spend before it is stored)
local doubt: { [number]: boolean } = {}
--- user id -> Stars payouts not stored yet: { id, stars, tutorial?, m? (also in MemoryStore) }
local owed: { [number]: { any } } = {}
--- user id -> a retry of their owed payouts is under way
local retrying: { [number]: boolean } = {}
--- user id -> writes to their record in this report's window (the most to one record is reported)
local key_writes: { [number]: number } = {}
--- players who left (a write landing after that doesn't bring their entry back)
local left: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
--- (defined after clean: the owed payouts folded into a record)
local fold_owed: (any, number, { any }) -> any
--- payout id -> { uid, out }: what a payout's Battle Pass part did when it was stored (BattlePass.apply's
--- Outcome), for the match's payout message (Purchases.add_stars)
local bp_outcomes: { [string]: any } = {}
--- The Battle Pass Premium credit (Data/Products.bp_premium).
Purchases.PREMIUM = "bp_premium"

--- What is left of `list` without the entries whose ids are in `ids`.
local function without(list: { any }?, ids: { [string]: boolean }): { any }?
	if list == nil then
		return nil
	end
	local out = {}
	for _, e in list do
		if not ids[e.id] then
			table.insert(out, e)
		end
	end
	return if #out > 0 then out else nil
end

--- `entries` were stored: off the owed list, and out of MemoryStore for those that were kept there.
local function owed_stored(user_id: number, entries: { any })
	local ids: { [string]: boolean } = {}
	local kept: { [string]: boolean } = {}
	local any_kept = false
	for _, e in entries do
		ids[e.id] = true
		if e.late then
			Purchases.stats.owed_paid += 1
		end
		if e.m then
			kept[e.id] = true
			any_kept = true
		end
	end
	owed[user_id] = without(owed[user_id], ids)
	local map = deps.owed_map
	if any_kept and map ~= nil then
		local spawn = deps.spawn or task.spawn
		spawn(function()
			pcall(function()
				map:UpdateAsync("u" .. tostring(user_id), function(old: any): any
					return without(if type(old) == "table" then old else nil, kept) or {}
				end, Purchases.OWED_HOLD_S)
			end)
		end)
	end
end

--- Yields (at most `max_s`, and only with deps.wait) while a write to `user_id`'s record is in flight.
local function writes_done(user_id: number, max_s: number)
	local waited = 0
	while busy[user_id] ~= nil and deps.wait ~= nil and waited < max_s do
		waited += 0.1
		deps.wait(0.1)
	end
end

--- Every write to a record: UpdateAsync on its key, one at a time per record from this server, counted
--- while in flight, and carrying the player's owed payouts. Errors as UpdateAsync does.
local function update(user_id: number, fn: (any) -> any): any
	if deps.wait ~= nil then
		local waited = 0
		while busy[user_id] ~= nil and waited < Purchases.KEY_WAIT_S do
			waited += 0.05
			deps.wait(0.05)
		end
	end
	busy[user_id] = (busy[user_id] or 0) + 1
	Purchases.stats.writes += 1
	key_writes[user_id] = (key_writes[user_id] or 0) + 1
	local due = owed[user_id]
	local pending = if due ~= nil and #due > 0 then table.clone(due) else nil
	local transform = fn
	if pending ~= nil then
		transform = function(old: any): any
			local base = fold_owed(old, user_id, pending)
			local v = fn(if base ~= nil then base else old)
			if v ~= nil then
				return v
			end
			return base
		end
	end
	local ok, res = pcall(function()
		return deps.datastore:UpdateAsync("u" .. tostring(user_id), transform)
	end)
	local n = (busy[user_id] or 1) - 1
	busy[user_id] = if n > 0 then n else nil
	if not ok then
		Purchases.stats.write_fails += 1
		doubt[user_id] = true
		error(res, 0)
	end
	doubt[user_id] = nil
	if pending ~= nil then
		owed_stored(user_id, pending)
	end
	return res
end
--- A record read for what its owner wears (Purchases.worn_by_id) is kept this long.
Purchases.WORN_TTL_S = 300

--- Stars owed to the player (not stored yet), for what they are shown.
local function owed_stars(user_id: number): number
	local n = 0
	for _, e in owed[user_id] or {} do
		n += e.stars
	end
	return n
end

--- A payout's id: unique enough within one player's last PAYOUTS_KEPT.
local function new_id(): string
	return string.format("%06x%06x", math.random(0, 0xFFFFFF), math.random(0, 0xFFFFFF))
end

function Purchases.configure(d: { [string]: any })
	for k, v in d do
		deps[k] = v
	end
end

--- Tests: forget everyone.
function Purchases.reset()
	table.clear(records)
	table.clear(busy)
	table.clear(doubt)
	table.clear(owed)
	table.clear(retrying)
	table.clear(key_writes)
	table.clear(left)
	table.clear(bp_outcomes)
	Purchases.lost.payouts = 0
	Purchases.lost.stars = 0
	Purchases.lost.rp = 0
	table.clear(cache)
	table.clear(inv)
	table.clear(loading)
	table.clear(worn_cache)
	for k in Purchases.stats do
		Purchases.stats[k] = 0
	end
end

--- The credit kind a product grants (nil: not ours), and how many of it.
function Purchases.kind_of(product_id: number): (string?, number)
	for kind, p in Products do
		if p.id ~= 0 and p.id == product_id then
			return p.grants or kind, math.clamp(math.floor(tonumber(p.count) or 1), 1, 10)
		end
	end
	return nil, 0
end

local function key(user_id: number): string
	return "u" .. tostring(user_id)
end

--- Today's number (UTC days since 1970): the daily cap on hits against the same person.
local function today(): number
	return os.time() // 86400
end

--- The record's fields clean() reads and writes itself; any other field is a newer build's, carried as is.
local MANAGED = {
	credits = true,
	receipts = true,
	owned = true,
	equipped = true,
	stars = true,
	stars_earned = true,
	tutorial_paid = true,
	paid = true,
	gifts = true,
	rp = true,
	rp_matches = true,
	rp_wins = true,
	play_s = true,
	rp_day = true,
	rp_hits = true,
	payouts = true,
	bp = true,
}

--- The default avatar a player without one wears (Cosmetics.default_avatar).
function Purchases.default_avatar(user_id: number?): string?
	return Cosmetics.default_avatar(user_id)
end

local function clean(v: any, user_id: number?): Record
	local rec: Record = {
		credits = {},
		receipts = {},
		owned = {},
		equipped = {},
		stars = 0,
		stars_earned = 0,
		paid = false,
		gifts = {},
		rp = 0,
		rp_matches = 0,
		rp_wins = 0,
		rp_day = 0,
		rp_hits = {},
		play_s = 0,
		payouts = {},
	}
	if type(v) ~= "table" then
		v = {}
	end
	local function count(x: any): number
		local n = tonumber(x) or 0
		return if n ~= n then 0 else math.clamp(math.floor(n), 0, Purchases.MAX_STARS)
	end
	rec.stars = count(v.stars)
	rec.stars_earned = count(v.stars_earned)
	rec.tutorial_paid = if v.tutorial_paid == true then true else nil
	-- the global leaderboard (Data/Ranks): today's hits only (a new UTC day clears them)
	local function whole(x: any, top: number): number
		local n = tonumber(x) or 0
		return if n ~= n then 0 else math.clamp(math.floor(n), 0, top)
	end
	rec.rp = whole(v.rp, Ranks.MAX_RP)
	rec.rp_matches = whole(v.rp_matches, 1000000)
	rec.rp_wins = whole(v.rp_wins, 1000000)
	rec.play_s = whole(v.play_s, 1e10)
	rec.rp_day = whole(v.rp_day, 1000000)
	if rec.rp_day == today() and type(v.rp_hits) == "table" then
		for uid, n in v.rp_hits do
			if type(uid) == "string" and #uid <= 20 then
				rec.rp_hits[uid] = whole(n, 100)
			end
		end
	end
	if type(v.owned) == "table" then
		for id, on in v.owned do
			-- (an id this build doesn't know is kept: a newer build's item, or one taken out of the
			-- catalog. Never dropped: it was bought. Only an exclusive not made for this player goes.)
			local unknown = type(id) == "string" and #id <= 64 and Cosmetics.item(id) == nil
			if on == true and (unknown or Cosmetics.may_own(id, user_id)) then
				rec.owned[id] = true
			end
		end
	end
	if type(v.gifts) == "table" then
		for id, on in v.gifts do
			if on == true and type(id) == "string" then
				rec.gifts[id] = true
			end
		end
	end
	if type(v.equipped) == "table" then
		for slot, id in v.equipped do
			if type(slot) ~= "string" or type(id) ~= "string" then
				continue
			end
			local it = Cosmetics.item(id)
			-- (a rank frame is never owned: worn while the tier reaches it, Purchases.equipped)
			if not rec.owned[id] and not (it ~= nil and it.rank ~= nil) then
				continue
			end
			if it == nil or it.kind == slot then
				-- (an id this build doesn't know, in a slot it may not know: a newer build's, kept as is)
				rec.equipped[slot] = id
			end
		end
	end
	-- (made for this player, or the default avatars: always owned. An avatar is always worn (2026-11-04: no
	-- Roblox head shot): without one, a default picked for this player)
	local gifts = table.clone(Cosmetics.granted(user_id))
	for _, id in Cosmetics.DEFAULT_AVATARS do
		if Cosmetics.item(id) ~= nil then
			rec.owned[id] = true
			rec.gifts[id] = true
		end
	end
	local worn = rec.equipped.icon
	if worn == nil or (Cosmetics.item(worn) ~= nil and not rec.owned[worn]) then
		rec.equipped.icon = Purchases.default_avatar(user_id)
	end
	for _, id in gifts do
		local it = Cosmetics.item(id)
		if it ~= nil then
			rec.owned[id] = true
			if not rec.gifts[id] then
				rec.gifts[id] = true
				rec.equipped[it.kind] = id
			end
		end
	end
	if type(v.payouts) == "table" then
		for _, id in v.payouts do
			if type(id) == "string" and #id <= 24 then
				table.insert(rec.payouts, id)
			end
		end
	end
	if type(v.credits) == "table" then
		for k, n in v.credits do
			if type(k) == "string" and type(n) == "number" and n == n then
				rec.credits[k] = math.clamp(math.floor(n), 0, Purchases.MAX_CREDITS)
			end
		end
	end
	if type(v.receipts) == "table" then
		for _, r in v.receipts do
			if type(r) == "string" then
				table.insert(rec.receipts, r)
			end
		end
	end
	-- the Battle Pass: a new month starts it over, a new day its missions (Data/BattlePass)
	rec.bp = BattlePass.clean(v.bp, BattlePass.now())
	-- (a stored `paid` wins: Staging's "Replay as new player" sets it false with receipts kept)
	rec.paid = if type(v.paid) == "boolean" then v.paid else #rec.receipts > 0
	-- every field this build doesn't manage goes back as it came (a newer build's: during an update,
	-- old and new servers save the same records, and an old one must not erase what a new one added)
	for k, val in v do
		if type(k) == "string" and not MANAGED[k] then
			(rec :: any)[k] = val
		end
	end
	return rec
end

--- The record `old` with the owed payouts `entries` stored on it (each once: its id is kept), or nil
--- when every one of them is stored already. A tutorial's Stars are paid once whatever the id.
fold_owed = function(old: any, user_id: number, entries: { any }): any
	local rec = clean(old, user_id)
	local changed = false
	for _, e in entries do
		-- (the tutorial's Stars come once, whatever their id)
		if not table.find(rec.payouts, e.id) and not (e.tutorial and rec.tutorial_paid) then
			rec.stars = math.min(rec.stars + e.stars, Purchases.MAX_STARS)
			rec.stars_earned = math.min(rec.stars_earned + e.stars, Purchases.MAX_STARS)
			if e.tutorial then
				rec.tutorial_paid = true
			end
			if e.bp ~= nil then
				-- (the match's Battle Pass XP and mission stats, in the same write: Data/BattlePass)
				bp_outcomes[e.id] = { uid = user_id, out = BattlePass.apply(rec, user_id, e.bp, BattlePass.now()) }
			end
			table.insert(rec.payouts, e.id)
			changed = true
		end
	end
	while #rec.payouts > Purchases.PAYOUTS_KEPT do
		table.remove(rec.payouts, 1)
	end
	return if changed then rec else nil
end

--- What a write error was, in a word (for the warning the error report counts).
local function reason(err: any): string
	local text = tostring(err)
	for _, word in { "TooManyRequests", "InternalServerError", "ServiceUnavailable", "Throttled", "queue was full" } do
		if string.find(text, word, 1, true) then
			return word
		end
	end
	return "other"
end

local function log(text: string)
	if deps.log then
		deps.log("[Purchases] " .. text)
	end
end

--- Owed Stars that could not even be kept for later (MemoryStore refused them): lost. The server log has
--- who and how many; the warning is worded the same each time so the error report counts them by kind
--- and reason.
local function stars_lost(user_id: number, amount: number, what: string, err: any)
	Purchases.lost.payouts += 1
	Purchases.lost.stars += amount
	log(string.format("could not pay %d %s Stars to %d: %s", amount, what, user_id, tostring(err)))
	if deps.warn then
		deps.warn(string.format("[Purchases] %s Stars lost after every retry (%s)", what, reason(err)))
	end
end

local function player_by_id(user_id: number): any
	local ps = deps.players
	if ps == nil then
		return nil
	end
	local ok, p = pcall(function()
		return ps:GetPlayerByUserId(user_id)
	end)
	return if ok then p else nil
end

local function remember(player: any, rec: Record)
	if left[player] then
		return -- (a write that landed after they left)
	end
	loading[player] = nil -- (the record is here: a load still retrying has nothing left to do)
	records[player] = rec
	cache[player] = rec.credits
	inv[player] = {
		owned = rec.owned,
		equipped = rec.equipped,
		stars = rec.stars,
		stars_earned = rec.stars_earned,
		paid = rec.paid,
		rp = rec.rp,
		rp_matches = rec.rp_matches,
		rp_wins = rec.rp_wins,
		rp_hits = if rec.rp_day == today() then rec.rp_hits else {},
		play_s = rec.play_s,
		bp = rec.bp,
	}
end

--- The record to judge a request by without writing (2026-11-13: a player's credit requests, at their
--- 2-a-second cap, each wrote to the record even with nothing to spend). The record as last read or
--- written, when nothing can have changed it meanwhile: loaded, no write of ours in flight (a purchase
--- landing) or in doubt. Nil: write, and judge inside the write.
local function settled_record(player: any): Record?
	local uid = player.UserId
	if loading[player] ~= nil or busy[uid] ~= nil or doubt[uid] then
		return nil
	end
	return records[player]
end

local function notify(player: any)
	if player ~= nil and deps.notify then
		pcall(deps.notify, player, table.clone(cache[player] or {}))
	end
	if player ~= nil and deps.inventory then
		pcall(deps.inventory, player, Purchases.inventory(player))
	end
end

--- A rank frame worn below its tier comes off (back to no frame): taken out of `eq` now, and off the record
--- (once: `unequipping` while that write is on its way).
local unequipping: { [any]: boolean } = {}
local function drop_locked(player: any, eq: { [string]: any }, tier_id: any)
	local f = eq.frame
	local it = if f ~= nil then Cosmetics.item(f) else nil
	if it ~= nil and it.rank ~= nil and not Cosmetics.rank_unlocked(it, tier_id) then
		eq.frame = nil
		if not unequipping[player] then
			unequipping[player] = true
			coroutine.wrap(function()
				pcall(Purchases.equip, player, "frame", false)
				unequipping[player] = nil
			end)()
		end
	end
end

--- The player's Battle Pass as the client is shown it (BattlePass.view): as stored, with the passes of
--- payouts still owed added (shown, not stored yet), rolled over to this month and day.
function Purchases.battle_pass(player: any): any
	local t = BattlePass.now()
	local i = inv[player]
	local rec: any = { bp = BattlePass.clean(if i ~= nil then i.bp else nil, t), owned = {}, stars = 0, stars_earned = 0 }
	if i ~= nil then
		for _, e in owed[player.UserId] or {} do
			if e.bp ~= nil then
				rec.owned = table.clone(i.owned)
				BattlePass.apply(rec, player.UserId, e.bp, t)
			end
		end
	end
	return BattlePass.view(rec.bp, t)
end

--- The player's items for the client: owned ids (list), equipped, Stars, the Battle Pass.
function Purchases.inventory(player: any, tier_id: any): any
	local i = inv[player]
	local owned = {}
	if i ~= nil then
		for id in i.owned do
			table.insert(owned, id)
		end
		table.sort(owned)
	end
	local eq = if i ~= nil then table.clone(i.equipped) else {}
	if tier_id ~= nil then
		drop_locked(player, eq, tier_id)
	end
	return {
		owned = owned,
		equipped = eq,
		-- (with Stars owed: paid, not stored yet)
		stars = (if i ~= nil then i.stars else 0) + owed_stars(player.UserId),
		rp = if i ~= nil then i.rp else 0,
		rp_matches = if i ~= nil then i.rp_matches else 0,
		rp_wins = if i ~= nil then i.rp_wins else 0,
		play_s = if i ~= nil then i.play_s else 0,
		bp = Purchases.battle_pass(player),
	}
end

--- Adds `seconds` of match play (the playtime leaderboard). Yields. (ok, the new total in seconds).
function Purchases.add_playtime(player: any, seconds: number): (boolean, number)
	local d = math.floor(tonumber(seconds) or 0)
	local i = inv[player]
	if d ~= d or d <= 0 then
		return false, if i ~= nil then i.play_s else 0
	end
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			local rec = clean(old, player.UserId)
			rec.play_s = math.min(rec.play_s + d, 1e10)
			stored = rec
			return rec
		end)
	end)
	if not ok or stored == nil then
		log("could not add " .. tostring(d) .. " s of play to " .. tostring(player.UserId) .. ": " .. tostring(err))
		return false, if i ~= nil then i.play_s else 0
	end
	remember(player, stored :: Record)
	return true, (stored :: Record).play_s
end

--- The player's Rank Points (Data/Ranks), as loaded.
function Purchases.rp(player: any): number
	local i = inv[player]
	return if i ~= nil then i.rp else 0
end

--- Today's ranked hits by the player against `user_id` (Data/Ranks.HITS_PER_DAY).
function Purchases.hits(player: any, user_id: number): number
	local i = inv[player]
	return if i ~= nil then (i.rp_hits[tostring(user_id)] or 0) else 0
end

--- A ranked match's RP (Data/Ranks.points: negative for leaving; RP never goes below 0), the match
--- counted (and won), and each of `victims` (people's user ids) one more hit today. Yields.
function Purchases.add_rp(player: any, delta: number, won: boolean, victims: { number }?): (boolean, number)
	local d = math.floor(tonumber(delta) or 0)
	if d ~= d then
		return false, Purchases.rp(player)
	end
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			local rec = clean(old, player.UserId)
			rec.rp = math.clamp(rec.rp + d, 0, Ranks.MAX_RP)
			rec.rp_matches += 1
			if won then
				rec.rp_wins += 1
			end
			if rec.rp_day ~= today() then
				rec.rp_day = today()
				rec.rp_hits = {}
			end
			for _, uid in victims or {} do
				local k = tostring(uid)
				rec.rp_hits[k] = (rec.rp_hits[k] or 0) + 1
			end
			stored = rec
			return rec
		end)
	end)
	if not ok or stored == nil then
		Purchases.lost.rp += math.abs(d)
		log("could not add " .. tostring(d) .. " RP to " .. tostring(player.UserId) .. ": " .. tostring(err))
		if deps.warn then
			deps.warn(string.format("[Purchases] ranked RP lost after every retry (%s)", reason(err)))
		end
		return false, Purchases.rp(player)
	end
	remember(player, stored :: Record)
	notify(player)
	return true, (stored :: Record).rp
end

--- The player's Stars, with those owed (paid, not stored yet).
function Purchases.stars(player: any): number
	local i = inv[player]
	return (if i ~= nil then i.stars else 0) + owed_stars(player.UserId)
end

--- What the player shows in a match: { skin = id?, icon = id?, ... } (nil when nothing is equipped), at
--- rank tier `tier_id` (a rank frame it no longer reaches comes off).
function Purchases.equipped(player: any, tier_id: any): any
	local i = inv[player]
	if i == nil or next(i.equipped) == nil then
		return nil
	end
	local eq = table.clone(i.equipped)
	drop_locked(player, eq, tier_id)
	return eq
end

--- What user `user_id` wears ({ icon?, frame?, badge?, font?, skin? }; nil: unknown) and their Rank
--- Points (for the rank frame their tier still unlocks). A player on this server: as loaded; anyone
--- else: their record, read at most every WORN_TTL_S (yields).
function Purchases.worn_by_id(user_id: number): (any, number)
	if type(user_id) ~= "number" or user_id <= 0 then
		return nil, 0
	end
	local p = player_by_id(user_id)
	if p ~= nil and inv[p] ~= nil then
		return table.clone(inv[p].equipped), inv[p].rp or 0
	end
	local c = worn_cache[user_id]
	local t = os.clock()
	if c ~= nil and t - c.at < Purchases.WORN_TTL_S then
		return table.clone(c.eq), c.rp
	end
	if deps.datastore == nil then
		return nil, 0
	end
	local ok, v = pcall(function()
		return deps.datastore:GetAsync(key(user_id))
	end)
	if not ok then
		if c ~= nil then
			return table.clone(c.eq), c.rp
		end
		return nil, 0
	end
	local rec = clean(v, user_id)
	worn_cache[user_id] = { at = t, eq = rec.equipped, rp = rec.rp }
	return table.clone(rec.equipped), rec.rp
end

--- Roblox's ProcessReceipt: store the credit, then say granted (never before it is stored).
function Purchases.process_receipt(info: any): string
	local user_id = tonumber(info and info.PlayerId)
	local product = tonumber(info and info.ProductId)
	local receipt = if info and type(info.PurchaseId) == "string" then info.PurchaseId else nil
	local kind, n = nil, 1
	if product then
		kind, n = Purchases.kind_of(product)
	end
	if user_id == nil or kind == nil or receipt == nil then
		log("unknown receipt for product " .. tostring(product))
		return "not_processed"
	end
	return Purchases.grant(user_id, kind, receipt, n, tonumber(info.CurrencySpent))
end

--- Store `n` (default 1) `kind` credits for `user_id` under `receipt` (once per receipt). "granted" once
--- stored. `spent`: the Robux the receipt says were paid (Managed Pricing: not always the set price),
--- passed on to deps.bought.
function Purchases.grant(user_id: number, kind: string, receipt: string, n: number?, spent: number?): string
	local count = math.clamp(math.floor(n or 1), 1, 10)
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(user_id, function(old: any): any
			local rec = clean(old, user_id)
			if table.find(rec.receipts, receipt) then
				stored = rec -- granted before (a retry): nothing to add
				return nil
			end
			local pack = tonumber(string.match(kind, "^stars:(%d+)$"))
			if pack ~= nil then
				-- a Star pack: into the balance (not stars_earned: bought Stars never rank anyone)
				rec.stars = math.min(rec.stars + pack * count, Purchases.MAX_STARS)
			else
				rec.credits[kind] = math.min((rec.credits[kind] or 0) + count, Purchases.MAX_CREDITS)
			end
			table.insert(rec.receipts, receipt)
			while #rec.receipts > Purchases.RECEIPTS_KEPT do
				table.remove(rec.receipts, 1)
			end
			rec.paid = true
			stored = rec
			return rec
		end)
	end)
	if not ok or stored == nil then
		log("could not store receipt " .. receipt .. ": " .. tostring(err))
		return "not_processed"
	end
	local player = player_by_id(user_id)
	if player ~= nil then
		remember(player, stored :: Record)
		notify(player)
		if deps.bought then
			pcall(deps.bought, player, kind, count, spent)
		end
		if kind == Purchases.PREMIUM then
			-- (Battle Pass Premium: spent on the season running now)
			Purchases._spend_premium_soon(player)
		end
	end
	log(string.format("granted %s%s to %d (%s)", kind, if count > 1 then " x" .. count else "", user_id, receipt))
	return "granted"
end

local function spawn_fn(): any
	return deps.spawn or (if IS_ROBLOX then task.spawn else nil)
end

--- One write that stores the player's owed payouts (update carries them). True when none are left.
local function pay_owed(player: any): boolean
	local uid = player.UserId
	if owed[uid] == nil then
		return true
	end
	local stored: Record? = nil
	local ok = pcall(function()
		update(uid, function(old: any): any
			stored = clean(old, uid)
			return nil
		end)
	end)
	if ok and stored ~= nil then
		remember(player, stored :: Record)
		notify(player)
	end
	return owed[uid] == nil
end

--- Tries the owed payouts again over OWED_RETRY_S while the player is here (until they are stored, or
--- the player leaves: their owed Stars go with them, Purchases.leave_owed).
local function retry_owed(player: any)
	local uid = player.UserId
	local spawn = spawn_fn()
	if retrying[uid] or deps.wait == nil or spawn == nil then
		return
	end
	retrying[uid] = true
	spawn(function()
		local i = 0
		while owed[uid] ~= nil do
			i += 1
			deps.wait(Purchases.OWED_RETRY_S[math.min(i, #Purchases.OWED_RETRY_S)])
			if owed[uid] == nil or left[player] then
				break
			end
			pay_owed(player)
		end
		retrying[uid] = nil
	end)
end

--- A joining player's owed Stars kept in MemoryStore by the server they left: owed here (and paid).
local function collect_owed(player: any)
	local map = deps.owed_map
	if map == nil then
		return
	end
	local uid = player.UserId
	local ok, v = pcall(function()
		return map:GetAsync("u" .. tostring(uid))
	end)
	if not ok or type(v) ~= "table" or left[player] then
		return
	end
	local list = owed[uid] or {}
	local have: { [string]: boolean } = {}
	for _, e in list do
		have[e.id] = true
	end
	for _, e in v do
		local n = if type(e) == "table" then math.floor(tonumber(e.stars) or 0) else 0
		-- (a payout of no Stars may still carry a match's Battle Pass XP: Data/BattlePass)
		local g = if type(e) == "table" then BattlePass.clean_gain(e.bp) else nil
		if
			type(e) == "table"
			and type(e.id) == "string"
			and #e.id <= 24
			and not have[e.id]
			and (n > 0 or g ~= nil)
			and n >= 0
			and n <= 1000000
		then
			table.insert(
				list,
				{ id = e.id, stars = n, tutorial = if e.tutorial == true then true else nil, bp = g, m = true, late = true }
			)
			have[e.id] = true
		end
	end
	if #list == 0 then
		return
	end
	owed[uid] = list
	notify(player)
	if not pay_owed(player) then
		retry_owed(player)
	end
end

--- Yields: LOAD_ATTEMPTS reads with LOAD_BACKOFF between them, then, with the session already going
--- on an empty record, more every LOAD_RETRY_S (deps.wait; without one, a single attempt).
--- A player teleported here by a server of ours comes with the record that server held when they left
--- (deps.arrived: server/Handoff); then nothing is read.
function Purchases.load(player: any)
	local token = {}
	left[player] = nil
	loading[player] = token
	local got: any = nil
	if deps.arrived then
		local ok, g = pcall(deps.arrived, player)
		got = if ok and type(g) == "table" then g else nil
		if loading[player] ~= token then
			return
		end
	end
	-- Stars owed from an earlier server: kept in MemoryStore (a handoff says whether there are any)
	local spawn = spawn_fn()
	if deps.owed_map ~= nil and spawn ~= nil and (got == nil or got.o == true) then
		spawn(collect_owed, player)
	end
	if got ~= nil and type(got.p) == "table" then
		remember(player, clean(got.p, player.UserId))
		notify(player)
		Purchases._spend_premium_soon(player)
		return
	end
	local wait = deps.wait
	local tries = 0
	while true do
		tries += 1
		local ok, v = pcall(function()
			return deps.datastore:GetAsync(key(player.UserId))
		end)
		if loading[player] ~= token then
			return -- (they left, a write brought the record, or another load began)
		end
		if ok then
			remember(player, clean(v, player.UserId))
			notify(player)
			Purchases._spend_premium_soon(player)
			return
		end
		local last = not wait or tries >= Purchases.LOAD_ATTEMPTS + Purchases.LOAD_RETRIES
		if tries == Purchases.LOAD_ATTEMPTS or (last and tries < Purchases.LOAD_ATTEMPTS) then
			cache[player] = cache[player] or {}
			log(
				"load failed for "
					.. tostring(player.UserId)
					.. ": "
					.. tostring(v)
					.. (if last then "" else " (trying again while they stay)")
			)
			notify(player)
		end
		if last then
			loading[player] = nil
			return
		end
		wait(if tries < Purchases.LOAD_ATTEMPTS then Purchases.LOAD_BACKOFF[tries] or 10 else Purchases.LOAD_RETRY_S)
	end
end

function Purchases.credits(player: any): { [string]: number }
	return table.clone(cache[player] or {})
end

--- Spend one `kind` credit (atomic on the stored record). Yields.
function Purchases.use(player: any, kind: string): (boolean, string?)
	if Products[kind] == nil then
		return false, "unknown product"
	end
	local known = settled_record(player)
	if known ~= nil and (known.credits[kind] or 0) <= 0 then
		Purchases.stats.skipped += 1
		return false, "no credit" -- (none to spend: nothing to write)
	end
	local spent = false
	local left: { [string]: number }? = nil
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			spent = false
			local rec = clean(old, player.UserId)
			left = rec.credits
			remember(player, rec)
			if (rec.credits[kind] or 0) <= 0 then
				return nil
			end
			rec.credits[kind] -= 1
			spent = true
			left = rec.credits
			return rec
		end)
	end)
	if not ok then
		return false, "store unavailable: " .. tostring(err)
	end
	if left ~= nil then
		cache[player] = left
	end
	notify(player)
	if not spent then
		return false, "no credit"
	end
	return true, nil
end

--- A player leaving: their owed Stars (if any) go to MemoryStore for the next server they join. Yields.
--- True when there were some and they were kept (a handoff tells the next server to look).
function Purchases.leave_owed(player: any): boolean
	local uid = player.UserId
	local entries = owed[uid]
	owed[uid] = nil
	if entries == nil then
		return false
	end
	local map = deps.owed_map
	local ok, err = false, "no MemoryStore"
	if map ~= nil then
		ok, err = pcall(function()
			map:UpdateAsync("u" .. tostring(uid), function(old: any): any
				local list = if type(old) == "table" then old else {}
				local have: { [string]: boolean } = {}
				for _, e in list do
					if type(e) == "table" then
						have[e.id] = true
					end
				end
				for _, e in entries do
					if not have[e.id] then
						table.insert(list, { id = e.id, stars = e.stars, tutorial = e.tutorial, bp = e.bp })
					end
				end
				return list
			end, Purchases.OWED_HOLD_S)
		end)
	end
	if ok then
		Purchases.stats.owed_kept += #entries
		return true
	end
	for _, e in entries do
		stars_lost(uid, e.stars, if e.tutorial then "tutorial" else "match", err)
	end
	return false
end

function Purchases.release(player: any)
	left[player] = true
	loading[player] = nil
	cache[player] = nil
	inv[player] = nil
	records[player] = nil
	doubt[player.UserId] = nil
	key_writes[player.UserId] = nil
	for id, o in bp_outcomes do
		if o.uid == player.UserId then
			bp_outcomes[id] = nil
		end
	end
	if owed[player.UserId] ~= nil then
		-- A payout's write may still be in flight (most often: they closed the game as their match
		-- ended). Wait for it, so only what it didn't store is kept for later: kept at once, payouts
		-- whose write then landed were kept too, and the next server showed them twice until its write.
		-- (A teleport of ours waited already: ServerMain settles before leave_owed.)
		local uid = player.UserId
		local function keep()
			writes_done(uid, Purchases.KEY_WAIT_S)
			Purchases.leave_owed(player)
		end
		local spawn = spawn_fn()
		if spawn ~= nil then
			spawn(keep)
		else
			keep()
		end
	end
end

--- This window's counts (and a fresh window): payouts, owed and stored late, kept for later, writes,
--- failed writes, writes skipped (nothing to change), and the most writes to one record.
function Purchases.take_stats(): { [string]: number }
	local out: { [string]: number } = table.clone(Purchases.stats)
	local most = 0
	for _, n in key_writes do
		most = math.max(most, n)
	end
	out.max_key = most
	out.lost = Purchases.lost.payouts
	out.lost_stars = Purchases.lost.stars
	for k in Purchases.stats do
		Purchases.stats[k] = 0
	end
	Purchases.lost.payouts, Purchases.lost.stars = 0, 0
	table.clear(key_writes)
	return out
end

--- A player leaving for another server of ours (server/Handoff): waits, at most `max_s`, for this
--- server's writes to their record to land (a match's Stars and Rank Points are often still being
--- stored), then returns the record as it now stands; nil when it isn't known for sure (never read,
--- still loading, a write that failed or hasn't landed): the next server reads the store. Yields.
--- Call before release.
function Purchases.settle(player: any, max_s: number): any
	local uid = player.UserId
	writes_done(uid, max_s)
	if busy[uid] ~= nil or doubt[uid] or loading[player] ~= nil or inv[player] == nil then
		return nil
	end
	return records[player]
end

--- Equip an owned item (or a rank frame rank tier `tier_id` unlocks) in its slot, or clear the slot (id
--- false). Yields.
function Purchases.equip(player: any, slot: string, id: any, tier_id: any): (boolean, string?)
	if not table.find(Purchases.SLOTS, slot) then
		return false, "bad slot"
	end
	if id == false and slot == "icon" then
		return false, "an avatar is always worn"
	end
	if id ~= false then
		local it = Cosmetics.item(id)
		if it == nil or it.kind ~= slot then
			return false, "unknown item"
		end
	end
	-- (nothing to write: already worn, or not theirs to wear)
	local known = records[player]
	if known ~= nil then
		if id ~= false and not Cosmetics.wearable(id, known.owned, tier_id) then
			Purchases.stats.skipped += 1
			return false, "not owned"
		end
		if known.equipped[slot] == (if id == false then nil else id) then
			Purchases.stats.skipped += 1
			return true, nil
		end
	end
	local done = false
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			done = false
			local rec = clean(old, player.UserId)
			stored = rec
			if id ~= false and not Cosmetics.wearable(id, rec.owned, tier_id) then
				return nil
			end
			rec.equipped[slot] = if id == false then nil else id
			done = true
			return rec
		end)
	end)
	if not ok then
		return false, "store unavailable: " .. tostring(err)
	end
	if stored ~= nil then
		remember(player, stored :: Record)
	end
	notify(player)
	return done, if done then nil else "not owned"
end

--- Pays `amount` Stars (a match's payout, Data/Stars). Yields. (ok, the new balance).
--- The Stars for finishing the tutorial (Data/Tutorial), once per player. True when they were paid now.
--- A payout `entry` ({ id, stars, tutorial? }): owed until stored, stored now if the store takes it.
--- Returns the record as stored, or nil when it is owed for now (tried again, kept when they leave).
local function pay(player: any, entry: any, what: string): Record?
	local uid = player.UserId
	Purchases.stats.payouts += 1
	local list = owed[uid] or {}
	table.insert(list, entry)
	owed[uid] = list
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(uid, function(old: any): any
			stored = clean(old, uid)
			return nil -- (update stores the owed payouts, this one with them)
		end)
	end)
	if ok and stored ~= nil then
		remember(player, stored :: Record)
		notify(player)
		return stored
	end
	for _, e in owed[uid] or {} do
		if not e.late then
			e.late = true
			Purchases.stats.owed_new += 1
		end
	end
	log(string.format("%d %s Stars for %d owed for now: %s", entry.stars, what, uid, tostring(err)))
	notify(player)
	retry_owed(player)
	return nil
end

function Purchases.tutorial_bonus(player: any, amount: number): boolean
	local add = math.floor(tonumber(amount) or 0)
	if add ~= add or add <= 0 then
		return false
	end
	local known = records[player]
	if known ~= nil and known.tutorial_paid then
		Purchases.stats.skipped += 1
		return false -- (paid before: nothing to write)
	end
	local id = new_id()
	local stored = pay(player, { id = id, stars = add, tutorial = true }, "tutorial")
	return stored ~= nil and table.find(stored.payouts, id) ~= nil
end

--- Battlemap Staging's "Replay as new player": the tutorial's Stars can be earned again, as one who
--- never paid (Stars and cosmetics stay). `keep_owned` (a
--- game admin on production, 2026-10-27): one who paid is still one who paid.
function Purchases.reset_new_player(player: any, keep_owned: boolean?): boolean
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			local rec = clean(old, player.UserId)
			rec.tutorial_paid = nil
			if not keep_owned then
				rec.paid = false
			end
			stored = rec
			return rec
		end)
	end)
	if not ok or stored == nil then
		log("could not reset " .. tostring(player.UserId) .. ": " .. tostring(err))
		return false
	end
	remember(player, stored :: Record)
	notify(player)
	return true
end

--- A match's Stars and its Battle Pass part `bp` (Data/BattlePass.clean_gain: XP, mission stats; a match
--- that paid no Stars may still carry XP): stored now, or owed until they are (shown either way), in one
--- write under one payout id. Yields. (ok, the balance, the pass's Outcome when it was stored now).
function Purchases.add_stars(player: any, amount: number, bp: any): (boolean, number, any)
	local add = math.floor(tonumber(amount) or 0)
	local g = BattlePass.clean_gain(bp)
	if g ~= nil and g.xp <= 0 and (g.st == nil or next(g.st) == nil) then
		g = nil -- (nothing for the pass)
	end
	if add ~= add or add < 0 or (add == 0 and g == nil) then
		return false, Purchases.stars(player), nil
	end
	local id = new_id()
	pay(player, { id = id, stars = add, bp = g }, "match")
	local o = bp_outcomes[id]
	bp_outcomes[id] = nil
	return true, Purchases.stars(player), if o ~= nil then o.out else nil
end

--- Spends one Battle Pass Premium credit (Data/Products.bp_premium) on the season now running: premium for it
--- and every premium reward already reached, in one write. Someone with premium this season keeps the
--- credit (for a later season). Yields. (ok) or (false, "no credit" | "has premium" | "store unavailable: ...").
function Purchases.use_premium(player: any): (boolean, string?)
	local kind = Purchases.PREMIUM
	local known = settled_record(player)
	if known ~= nil then
		if (known.credits[kind] or 0) <= 0 then
			Purchases.stats.skipped += 1
			return false, "no credit"
		end
		if BattlePass.clean(known.bp, BattlePass.now()).prem then
			Purchases.stats.skipped += 1
			return false, "has premium"
		end
	end
	local done, why = false, "no credit"
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			done = false
			local rec = clean(old, player.UserId)
			stored = rec
			if (rec.credits[kind] or 0) <= 0 then
				why = "no credit"
				return nil
			end
			if not BattlePass.unlock_premium(rec, BattlePass.now()) then
				why = "has premium"
				return nil
			end
			rec.credits[kind] -= 1
			done = true
			return rec
		end)
	end)
	if not ok then
		return false, "store unavailable: " .. tostring(err)
	end
	if stored ~= nil then
		remember(player, stored :: Record)
	end
	notify(player)
	if not done then
		return false, why
	end
	log(string.format("%d unlocked Battle Pass Premium for %s", player.UserId, (stored :: any).bp.s))
	return true, nil
end

--- A Battle Pass Premium credit waiting (bought, or kept from a season that had premium already): spent on
--- this season when it has none (Purchases.use_premium, in its own thread).
local function spend_premium_soon(player: any)
	local i = cache[player]
	if i == nil or (i[Purchases.PREMIUM] or 0) <= 0 then
		return
	end
	local spawn = spawn_fn()
	if spawn ~= nil then
		spawn(Purchases.use_premium, player)
	end
end
Purchases._spend_premium_soon = spend_premium_soon

--- Dev diag only (Studio, BM_DIAG; server/ServerMain checks): one write where `fn(rec, user_id, now)`
--- changes the player's record (the Battle Pass diag commands). Yields. True when stored.
function Purchases.debug_write(player: any, fn: (any, number, number) -> ()): boolean
	local stored: Record? = nil
	local ok = pcall(function()
		update(player.UserId, function(old: any): any
			local rec = clean(old, player.UserId)
			fn(rec, player.UserId, BattlePass.now())
			stored = rec
			return rec
		end)
	end)
	if ok and stored ~= nil then
		remember(player, stored :: Record)
		notify(player)
	end
	return ok
end

--- Buy item `id` with Stars (Data/Store.price): one write takes the price, owns it and puts it on. Yields.
--- (ok) or (false, "unknown item" | "not for sale" | "owned" | "not enough" | "store unavailable: ...").
function Purchases.buy_item(player: any, id: any): (boolean, string?)
	local it = Cosmetics.item(id)
	if it == nil then
		return false, "unknown item"
	end
	local price = Store.price(it)
	if price == nil then
		return false, "not for sale"
	end
	local known = settled_record(player)
	if known ~= nil then
		-- (nothing to write: owned, or short even with the Stars owed to them, which the write would add)
		if known.owned[it.id] then
			Purchases.stats.skipped += 1
			return false, "owned"
		end
		if known.stars + owed_stars(player.UserId) < price then
			Purchases.stats.skipped += 1
			return false, "not enough"
		end
	end
	local why = "store unavailable"
	local done = false
	local stored: Record? = nil
	local ok, err = pcall(function()
		update(player.UserId, function(old: any): any
			done = false
			local rec = clean(old, player.UserId)
			stored = rec
			if rec.owned[it.id] then
				why = "owned"
				return nil
			end
			if rec.stars < price then
				why = "not enough"
				return nil
			end
			rec.stars -= price
			rec.owned[it.id] = true
			rec.equipped[it.kind] = it.id -- (chosen and paid for: worn at once)
			done = true
			return rec
		end)
	end)
	if not ok then
		return false, "store unavailable: " .. tostring(err)
	end
	if stored ~= nil then
		remember(player, stored :: Record)
	end
	notify(player)
	if not done then
		return false, why
	end
	log(string.format("%d bought %s for %d Stars", player.UserId, it.id, price))
	return true, nil
end

return Purchases
