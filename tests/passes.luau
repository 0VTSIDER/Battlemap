--!nocheck
-- Robux offers (2026-11-04): a Star pack's receipt puts its Stars in the balance (once per receipt, not
-- as earned Stars), and game passes (server/Passes): asked on join, set when bought, 2x Stars doubling a
-- match's pay (server/Rewards). Run: lune run tests/passes.luau
require("./prelude")
local Products = require("../src/shared/Data/Products")
local PassData = require("../src/shared/Data/Passes")
local Purchases = require("../src/server/Purchases")
local Passes = require("../src/server/Passes")
local Rewards = require("../src/server/Rewards")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

-- Star packs
local last = 0
for _, key in { "stars_s", "stars_m", "stars_l", "stars_xl" } do
	local p = Products[key]
	expect(p ~= nil and p.grants == "stars:" .. p.stars and p.stars > last, key .. ": grants its Stars, more than the last")
	expect(p.stars / p.robux >= (Products.stars_s.stars / Products.stars_s.robux), key .. ": no worse a rate than the smallest")
	last = p.stars
end

local rows = {}
local ds = {}
function ds:UpdateAsync(k, fn)
	local v = fn(rows[k])
	if v ~= nil then
		rows[k] = v
	end
	return v
end
function ds:GetAsync(k)
	return rows[k]
end
local P = { UserId = 9, Name = "Whale" }
Purchases.reset()
Purchases.configure({
	datastore = ds,
	players = {
		GetPlayerByUserId = function(_, id)
			return if id == 9 then P else nil
		end,
	},
})
Purchases.load(P)
local before = Purchases.inventory(P).stars
Products.stars_m.id = 6660001
expect(Purchases.process_receipt({ PlayerId = 9, ProductId = 6660001, PurchaseId = "s1" }) == "granted", "a pack's receipt is granted")
expect(Purchases.inventory(P).stars == before + 22000, "... its Stars are in the balance")
expect((Purchases.credits(P)["stars:22000"] or 0) == 0, "... not as a credit")
expect((rows.u9.stars_earned or 0) == 0, "... nor as earned Stars")
expect(
	Purchases.process_receipt({ PlayerId = 9, ProductId = 6660001, PurchaseId = "s1" }) == "granted"
		and Purchases.inventory(P).stars == before + 22000,
	"the same receipt again: nothing more"
)

-- game passes
PassData.double_stars.id = 7770001
local owners = { [9] = true }
local changed = 0
Passes.reset()
Passes.configure({
	owns = function(uid, pid)
		return pid == 7770001 and owners[uid] == true
	end,
	changed = function()
		changed += 1
	end,
})
local Q = { UserId = 10 }
Passes.load(P)
Passes.load(Q)
expect(Passes.owns(P, "double_stars") and not Passes.owns(Q, "double_stars"), "join: Roblox says who owns 2x Stars")
expect(changed == 1, "... the owner's inventory goes out again")
Passes.bought(Q, 7770001)
expect(Passes.owns(Q, "double_stars") and Passes.owned(Q).double_stars == true, "bought here: owned at once")
Passes.bought(Q, 1234)
expect(changed == 2, "an unknown pass id changes nothing")
local flaky = 0
Passes.configure({
	owns = function()
		flaky += 1
		if flaky < 2 then
			error("HTTP 500")
		end
		return true
	end,
})
local R = { UserId = 11 }
Passes.load(R)
expect(Passes.owns(R, "double_stars") and flaky == 2, "Roblox failing once: asked again")
Passes.release(R)
expect(not Passes.owns(R, "double_stars"), "released on leaving")

-- 2x Stars doubles a match's pay
local paid = {}
Rewards.configure({
	add_stars = function(_p, n)
		table.insert(paid, n)
		return true, n
	end,
	double = function(p)
		return Passes.owns(p, "double_stars")
	end,
	send = function() end,
	now = function()
		return 0
	end,
})
local result = { spawned = true, minutes = 10, shares = 1, kills = 1, place = 1, field = 8, won = true, left = false }
local single = Rewards.pay({ UserId = 12 }, result, "public")
local double = Rewards.pay(P, result, "public")
expect(single > 0 and double == single * 2, ("2x Stars: %d, not %d"):format(double, single))

if fails > 0 then
	error(("passes: %d failed"):format(fails))
end
print("passes ok")
