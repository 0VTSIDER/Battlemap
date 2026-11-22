--!nocheck
-- Robux purchases (server/Purchases.luau): a receipt becomes a stored credit before it is granted,
-- a retried receipt is granted again without a second credit, a store outage is "not processed"
-- (Roblox retries), credits are spent one at a time.
require("./prelude")
local Products = require("../src/shared/Data/Products")
local Purchases = require("../src/server/Purchases")
local Cosmetics = require("../src/shared/Data/Cosmetics")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

-- a DataStore with UpdateAsync / GetAsync semantics (nil from the transform = no write)
local rows = {}
local down = false
local store = {}
function store:UpdateAsync(k, fn)
	if down then
		error("DataStore request was throttled")
	end
	local new = fn(rows[k])
	if new ~= nil then
		rows[k] = new
	end
	return new
end
function store:GetAsync(k)
	if down then
		error("DataStore unavailable")
	end
	return rows[k]
end

local P = { UserId = 42, Name = "Buyer" }
local notified = {}
local bought = {}
Purchases.configure({
	datastore = store,
	players = {
		GetPlayerByUserId = function(_, id)
			return if id == 42 then P else nil
		end,
	},
	notify = function(p, credits)
		table.insert(notified, credits.red_button or 0)
	end,
	bought = function(p, kind)
		table.insert(bought, kind)
	end,
})

Products.red_button.id = 777
Purchases.load(P)
expect(#notified == 1 and notified[1] == 0, "load: no credits, the client told")
expect(
	Purchases.process_receipt({ PlayerId = 42, ProductId = 999, PurchaseId = "r0" }) == "not_processed",
	"an unknown product is not processed"
)
expect(
	Purchases.process_receipt({ PlayerId = 42, ProductId = 777, PurchaseId = "r1" }) == "granted",
	"a Red Button receipt is granted"
)
expect(
	Purchases.credits(P).red_button == 1 and notified[#notified] == 1 and bought[1] == "red_button",
	"one credit, stored and told"
)
expect(
	Purchases.process_receipt({ PlayerId = 42, ProductId = 777, PurchaseId = "r1" }) == "granted",
	"the same receipt again (a retry) is granted"
)
expect(Purchases.credits(P).red_button == 1 and rows.u42.credits.red_button == 1, "... without a second credit")
down = true
expect(
	Purchases.process_receipt({ PlayerId = 42, ProductId = 777, PurchaseId = "r2" }) == "not_processed",
	"store down: not processed (Roblox retries)"
)
down = false
expect(
	Purchases.process_receipt({ PlayerId = 42, ProductId = 777, PurchaseId = "r2" }) == "granted"
		and Purchases.credits(P).red_button == 2,
	"the retry after the outage lands: 2 credits"
)
expect(
	Purchases.process_receipt({ PlayerId = 7, ProductId = 777, PurchaseId = "r3" }) == "granted"
		and rows.u7.credits.red_button == 1,
	"a buyer not on this server is still credited"
)
local ok1 = Purchases.use(P, "red_button")
local ok2 = Purchases.use(P, "red_button")
local ok3, why = Purchases.use(P, "red_button")
expect(ok1 and ok2 and not ok3 and why == "no credit", "two uses, the third refused (" .. tostring(why) .. ")")
expect(rows.u42.credits.red_button == 0 and notified[#notified] == 0, "stored 0, the client told")
local skipped0 = Purchases.take_stats().skipped
expect(skipped0 >= 1, "the third use wrote nothing (none to spend: the record held said so)")
Purchases.process_receipt({ PlayerId = 42, ProductId = 777, PurchaseId = "r-down" })
down = true
local ok4, why4 = Purchases.use(P, "red_button")
down = false
expect(
	not ok4 and string.find(why4, "store", 1, true) ~= nil and rows.u42.credits.red_button == 1,
	"store down: nothing spent (" .. tostring(why4) .. ")"
)
expect(not (Purchases.use(P, "nope")), "an unknown kind can't be spent")
for i = 1, Purchases.RECEIPTS_KEPT + 20 do
	Purchases.process_receipt({ PlayerId = 42, ProductId = 777, PurchaseId = "bulk" .. i })
end
expect(#rows.u42.receipts == Purchases.RECEIPTS_KEPT, "receipts kept are bounded (" .. #rows.u42.receipts .. ")")
Products.red_button.id = 0
expect(Purchases.kind_of(777) == nil, "a product not created yet (id 0) matches nothing")

-- owned items: only what the record owns can be worn, each in its own slot; junk is dropped on load
do
	local B = { UserId = 99, Name = "Wearer" }
	local inv_seen = nil
	Purchases.configure({
		players = {
			GetPlayerByUserId = function(_, id)
				return if id == 42 then P elseif id == 99 then B else nil
			end,
		},
		inventory = function(_p, i)
			inv_seen = i
		end,
	})
	rows.u99 = { owned = { skin_stripes = true, badge_us = true } }
	Purchases.load(B)
	-- (and the default avatars: everyone's)
	local defaults = #Cosmetics.DEFAULT_AVATARS
	expect(inv_seen ~= nil and #inv_seen.owned == 2 + defaults, "the client got the inventory")
	local okx, whyx = Purchases.equip(B, "skin", "skin_gilded")
	expect(not okx and whyx == "not owned", "an item not owned can't be equipped")
	expect(Purchases.equip(B, "skin", "skin_stripes") and rows.u99.equipped.skin == "skin_stripes", "equip an owned skin")
	expect(Purchases.equip(B, "badge", "badge_us") and rows.u99.equipped.badge == "badge_us", "equip an owned badge")
	expect(Purchases.equip(B, "badge", false) and rows.u99.equipped.badge == nil, "clear the badge slot")
	expect(not (Purchases.equip(B, "badge", "skin_stripes")), "a skin can't go in the badge slot")
	-- store down: nothing changes
	down = true
	local okd, whyd = Purchases.equip(B, "badge", "badge_us")
	down = false
	expect(not okd and string.find(whyd, "store", 1, true) ~= nil and rows.u99.equipped.badge == nil, "store down: nothing worn")
	-- junk in a stored record is dropped
	rows.u99.owned = { ["not_an_item"] = true, skin_stripes = true }
	rows.u99.equipped = { skin = "skin_gilded", badge = "badge_zz" }
	Purchases.load(B)
	local inv = Purchases.inventory(B)
	expect(
		#inv.owned == 2 + defaults and table.find(inv.owned, "not_an_item") ~= nil and inv.equipped.skin == nil and inv.equipped.badge == nil,
		"an unknown owned id is kept (a newer build's item); unowned ones are not worn"
	)
	-- rank frames: never owned, worn while the rank tier reaches them
	expect(not (Purchases.equip(B, "frame", "frame_gold", "silver")), "a rank frame above the tier can't be worn")
	expect(Purchases.equip(B, "frame", "frame_gold", "gold") and rows.u99.equipped.frame == "frame_gold", "a rank frame at the tier can")
	expect(Purchases.inventory(B, "gold").equipped.frame == "frame_gold", "worn while the tier holds")
	expect(Purchases.inventory(B, "silver").equipped.frame == nil, "off once the tier drops")
end

-- a record Roblox refuses to give at first (DataStore throttling): the load tries again
do
	local real_get = store.GetAsync
	local refuse = 0
	store.GetAsync = function(self, k)
		if refuse > 0 then
			refuse -= 1
			error("DataStoreService: TooManyRequests: Too many requests, try again later. API: GetAsync")
		end
		return real_get(self, k)
	end
	rows.u77 = { stars = 1234, credits = { red_button = 2 } }
	local C = { UserId = 77, Name = "Throttled" }
	local waits, told = {}, {}
	Purchases.configure({
		wait = function(s)
			table.insert(waits, s)
		end,
		notify = function(p, credits)
			if p == C then
				table.insert(told, credits.red_button or 0)
			end
		end,
	})
	-- refused three times, given on the fourth: nothing is missing, nobody is told of an empty record
	refuse = 3
	Purchases.load(C)
	expect(Purchases.stars(C) == 1234, "throttled 3 times: the record is read on the 4th try")
	expect(#waits == 3 and waits[1] == 1 and waits[2] == 3 and waits[3] == 6, "with the waits of LOAD_BACKOFF between")
	expect(#told == 1 and told[1] == 2, "the client is told once, of the real record")
	-- refused through every first attempt: the session starts empty, and the read goes on
	Purchases.release(C)
	table.clear(waits)
	table.clear(told)
	refuse = Purchases.LOAD_ATTEMPTS + 2
	Purchases.load(C)
	expect(Purchases.stars(C) == 1234, "refused 7 times: read on the 8th, in the background")
	expect(#told == 2 and told[1] == 0 and told[2] == 2, "the client is told of an empty record, then of the real one")
	expect(waits[#waits] == Purchases.LOAD_RETRY_S, "background tries are LOAD_RETRY_S apart")
	-- they leave while it is still trying: it stops
	Purchases.release(C)
	table.clear(told)
	refuse = 1000
	local gets = 0
	Purchases.configure({
		wait = function(_s)
			gets += 1
			if gets == 2 then
				Purchases.release(C)
			end
		end,
	})
	Purchases.load(C)
	expect(
		gets == 2 and refuse > 900 and Purchases.stars(C) == 0,
		"a player who left is not read for any more"
	)
	-- never given: it gives up after LOAD_ATTEMPTS + LOAD_RETRIES tries
	local n = 0
	Purchases.configure({
		wait = function(_s)
			n += 1
		end,
	})
	Purchases.load(C)
	expect(
		n == Purchases.LOAD_ATTEMPTS + Purchases.LOAD_RETRIES - 1,
		"refused for good: it gives up after every try is spent"
	)
	-- a write that goes through meanwhile brings the record: the load has nothing left to do
	Purchases.release(C)
	local wrote = false
	Purchases.configure({
		wait = function(_s)
			if not wrote then
				wrote = true
				store.GetAsync = real_get
				Purchases.add_stars(C, 10)
				store.GetAsync = function()
					error("still throttled")
				end
			end
		end,
	})
	Purchases.load(C)
	expect(
		wrote and Purchases.stars(C) == 1244,
		"a write that succeeds meanwhile brings the record"
	)
	store.GetAsync = real_get
	Purchases.configure({ wait = false })
end

-- Exclusive cosmetics (Cosmetics.exclusive_skins; 2026-10-18, Tie Dye for ilyannna): its owner owns
-- it whenever their record is read and wears it the first time; nobody else's record can hold it
do
	local F = { UserId = 58387889, Name = "ilyannna" }
	local X = { UserId = 81, Name = "Other" }
	local seen = {}
	Purchases.configure({
		players = {
			GetPlayerByUserId = function(_, id)
				return if id == F.UserId then F elseif id == X.UserId then X else nil
			end,
		},
		inventory = function(p, i)
			seen[p] = i
		end,
	})
	local fk = "u" .. F.UserId
	rows[fk] = { owned = { skin_stripes = true }, equipped = { skin = "skin_stripes" } }
	Purchases.load(F)
	local i = seen[F]
	expect(
		i ~= nil and table.find(i.owned, "tie_dye") ~= nil and i.equipped.skin == "tie_dye",
		"ilyannna's first join: tie_dye owned and worn (over the skin they had on)"
	)
	expect(Purchases.equipped(F) ~= nil and Purchases.equipped(F).skin == "tie_dye", "a match shows it on their land")
	expect(table.find(i.owned, "skin_stripes") ~= nil, "what they owned before stays")
	expect(
		Purchases.equip(F, "skin", "skin_stripes") and rows[fk].gifts.tie_dye == true and rows[fk].owned.tie_dye == true,
		"they change skin: the gift is saved with it"
	)
	Purchases.release(F)
	Purchases.load(F)
	expect(
		seen[F].equipped.skin == "skin_stripes" and table.find(seen[F].owned, "tie_dye") ~= nil,
		"the next join keeps their choice and still owns tie_dye"
	)
	expect(Purchases.equip(F, "skin", "tie_dye") and rows[fk].equipped.skin == "tie_dye", "they can put it back on")
	rows.u81 = { owned = { tie_dye = true, skin_stripes = true }, equipped = { skin = "tie_dye" } }
	Purchases.load(X)
	expect(
		table.find(seen[X].owned, "tie_dye") == nil and seen[X].equipped.skin == nil,
		"someone else's stored tie_dye is dropped"
	)
	local okx, whyx = Purchases.equip(X, "skin", "tie_dye")
	expect(not okx and whyx == "not owned", "and they can't equip it")
	expect(Purchases.equip(X, "skin", "skin_stripes") and rows.u81.owned.tie_dye == nil, "their next save drops it")
	rows[fk] = nil
	Purchases.release(F)
	Purchases.load(F)
	expect(seen[F].equipped.skin == "tie_dye", "no record at all yet: owned and worn too")
end

if fails > 0 then
	error(fails .. " failures")
end
print("purchases: all passed")
