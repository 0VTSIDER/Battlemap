--!strict
-- Lobby storage for LobbyDirectory / MatchHost:
--   LobbyStore.memory()  the live game: MemoryStoreService (shared by every server of the
--                        experience) — a sorted map of lobby records (sort key = start time), a
--                        hash map PrivateServerId -> lobby id, and a sorted map of short locks;
--   LobbyStore.localstore() one process only (Lune tests, Studio when MemoryStore is unavailable).
-- Both expose: list(), get(id), put(lobby, ttl_s), update(id, fn), remove(id), lock(name, ttl_s),
-- bind_psid(psid, id, ttl_s), lobby_for_psid(psid), take(spec), release(id, uids). All MemoryStore
-- calls yield and may throw (callers pcall).
local LobbyRules = require("./LobbyRules")

local LobbyStore = {}

LobbyStore.NAMESPACE = "battlemap_v1"
LobbyStore.LIST_LIMIT = 50

--- `take` over `update` (stores that can't search: MemoryStore, the local store): the spec's
--- candidates in order (or its one `id`), the first that fits gets the seats. Returns the record.
local function take_via_update(store: any, spec: LobbyRules.TakeSpec): any
	local ids = if spec.id ~= nil then { spec.id } else (spec.candidates or {})
	for _, id in ids do
		local got: any = nil
		store.update(id, function(v: any): any?
			-- (UpdateAsync may run this again on a newer record: only the last run counts)
			got = nil
			local l = LobbyRules.decode(v)
			if l == nil or not LobbyRules.fits(l, spec) then
				return nil
			end
			got = LobbyRules.seated(l, spec)
			return got
		end)
		if got ~= nil then
			return got
		end
	end
	return nil
end

--- `release` over `update`: the record after, and how many seats went back.
local function release_via_update(store: any, id: string, uids: { string }): (any, number)
	local n = 0
	local after: any = nil
	store.update(id, function(v: any): any?
		n = 0
		local l = LobbyRules.decode(v)
		if l == nil then
			return nil
		end
		local c, k = LobbyRules.released(l, uids)
		after = c
		n = k
		return if k > 0 then c else nil
	end)
	return after, n
end

--- MemoryStoreService-backed store (live servers).
--- `now`: the shared clock (SharedClock.now) — lock expiry times are compared across servers.
function LobbyStore.memory(job_id: string, now: (() -> number)?)
	local MSS = game:GetService("MemoryStoreService")
	return LobbyStore.memory_with(
		MSS:GetSortedMap(LobbyStore.NAMESPACE .. "_lobbies"),
		MSS:GetHashMap(LobbyStore.NAMESPACE .. "_psid"),
		MSS:GetSortedMap(LobbyStore.NAMESPACE .. "_locks"),
		job_id,
		now
	)
end

--- The memory store over given maps (tests pass fakes).
function LobbyStore.memory_with(lobbies: any, psids: any, locks: any, job_id: string, now: (() -> number)?)
	local clock = now or os.time
	local store = {}

	--- Both ends of the start-time order: the oldest records (running matches) and the newest (the
	--- open lobbies), so many live matches never push the open lobbies off the list.
	function store.list(): { any }
		local out = {}
		local seen = {}
		for _, dir in { Enum.SortDirection.Ascending, Enum.SortDirection.Descending } do
			local items = lobbies:GetRangeAsync(dir, LobbyStore.LIST_LIMIT)
			for _, it in items do
				if not seen[it.key] then
					seen[it.key] = true
					table.insert(out, it.value)
				end
			end
		end
		return out
	end

	function store.get(id: string): any
		return (lobbies:GetAsync(id))
	end

	function store.put(l: any, ttl_s: number)
		lobbies:SetAsync(l.id, l, math.floor(ttl_s), l.starts)
	end

	--- Atomic read-modify-write; `fn` returns the new record or nil (leave unchanged).
	function store.update(id: string, fn: (any) -> any): any
		return lobbies:UpdateAsync(id, function(old: any, _sort: any): (any, any)
			local new = fn(old)
			if new == nil then
				return nil
			end
			return new, new.starts
		end, 15 * 60)
	end

	function store.remove(id: string)
		lobbies:RemoveAsync(id)
	end

	--- A short lease: true when this server holds `name` now.
	function store.lock(name: string, ttl_s: number): boolean
		local got = false
		local now = clock()
		locks:UpdateAsync(name, function(old: any): any
			local exp = if type(old) == "table" then (tonumber(old.exp) or 0) else 0
			-- held, unless it claims to last far longer than any lease (a wrong clock wrote it)
			if type(old) == "table" and old.owner ~= job_id and exp > now and exp <= now + ttl_s + 60 then
				return nil
			end
			got = true
			return { owner = job_id, exp = now + ttl_s }
		end, ttl_s + 5)
		return got
	end

	function store.bind_psid(psid: string, id: string, ttl_s: number)
		psids:SetAsync(psid, id, math.floor(ttl_s))
	end

	function store.lobby_for_psid(psid: string): any
		local id = psids:GetAsync(psid)
		if type(id) ~= "string" then
			return nil
		end
		return (lobbies:GetAsync(id))
	end

	function store.take(spec: LobbyRules.TakeSpec): any
		return take_via_update(store, spec)
	end

	function store.release(id: string, uids: { string }): (any, number)
		return release_via_update(store, id, uids)
	end

	return store
end

--- In-process store with the same API (no expiry handling beyond the TTL timestamps).
function LobbyStore.localstore(now: (() -> number)?)
	local clock = now or os.time
	local rows: { [string]: { value: any, exp: number } } = {}
	local psid_rows: { [string]: string } = {}
	local lock_rows: { [string]: { owner: string, exp: number } } = {}
	local store = {}

	local function live(id: string): any
		local r = rows[id]
		if r == nil then
			return nil
		end
		if r.exp <= clock() then
			rows[id] = nil
			return nil
		end
		return table.clone(r.value)
	end

	function store.list(): { any }
		local out = {}
		for id in rows do
			local v = live(id)
			if v ~= nil then
				table.insert(out, v)
			end
		end
		table.sort(out, function(a, b)
			return a.starts < b.starts
		end)
		return out
	end

	function store.get(id: string): any
		return live(id)
	end

	function store.put(l: any, ttl_s: number)
		rows[l.id] = { value = table.clone(l), exp = clock() + ttl_s }
	end

	function store.update(id: string, fn: (any) -> any): any
		local new = fn(live(id))
		if new == nil then
			return nil
		end
		local exp = if rows[id] then rows[id].exp else clock() + 15 * 60
		rows[id] = { value = table.clone(new), exp = exp }
		return new
	end

	function store.remove(id: string)
		rows[id] = nil
	end

	function store.lock(name: string, ttl_s: number, owner: string?): boolean
		local who = owner or "local"
		local r = lock_rows[name]
		local t = clock()
		if r ~= nil and r.owner ~= who and r.exp > t and r.exp <= t + ttl_s + 60 then
			return false
		end
		lock_rows[name] = { owner = who, exp = clock() + ttl_s }
		return true
	end

	function store.bind_psid(psid: string, id: string, _ttl_s: number)
		psid_rows[psid] = id
	end

	function store.lobby_for_psid(psid: string): any
		local id = psid_rows[psid]
		return if id then live(id) else nil
	end

	function store.take(spec: LobbyRules.TakeSpec): any
		if spec.id == nil and spec.candidates == nil then
			-- (one process: the local store can search, as the service does)
			local ids = {}
			for _, v in store.list() do
				table.insert(ids, v.id)
			end
			spec = table.clone(spec)
			spec.candidates = ids
		end
		return take_via_update(store, spec)
	end

	function store.release(id: string, uids: { string }): (any, number)
		return release_via_update(store, id, uids)
	end

	return store
end

return LobbyStore
