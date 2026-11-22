--!strict
-- The Robux prices the interface shows: Roblox's own for this player (MarketplaceService), never
-- the number in Data/Products once Roblox has answered. With Managed Pricing (dynamic pricing,
-- on since 2026-10-05) a product's price differs by region and while Roblox tests prices, and a
-- button that prints 49 beside a prompt that charges 20 loses the sale. Roblox asks for prices to be
-- read this way before it lets an experience opt in (it looks for hard-coded ones).
--
--   Prices.robux(key)  the price of Data/Products[key]: Roblox's, or the set one until it answers
--   Prices.fetch()     ask Roblox for every product's price (at most once every REFRESH_S)
--   Prices.pass_robux(key)   the price of game pass Data/Passes[key], the same way (fetched alongside)
--   Prices.changed     Signal(): a price arrived or moved
local UITheme = require("./UITheme")
local Signal = UITheme.core("Signal")

local IS_ROBLOX = typeof(game) == "Instance"
local Products: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Products)
	else (require :: any)("../../shared/Data/Products")
local Passes: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Passes)
	else (require :: any)("../../shared/Data/Passes")

local Prices = {}

--- A price is asked for again after this long (a price test starts or ends while a server is up).
Prices.REFRESH_S = 600
Prices.changed = Signal.new()

local known: { [string]: number } = {}
local asked_at = -1e9
local asking = false

function Prices.robux(key: string): number
	local p = Products[key]
	return known[key] or (if type(p) == "table" then tonumber(p.robux) or 0 else 0)
end

--- The price of game pass `key` (Data/Passes): Roblox's, or the set one until it answers.
function Prices.pass_robux(key: string): number
	local p = Passes[key]
	return known["pass:" .. key] or (if type(p) == "table" then tonumber(p.robux) or 0 else 0)
end

--- Roblox's price of product `key` is `robux` (fetch; tests).
function Prices.set(key: string, robux: number)
	if known[key] ~= robux then
		known[key] = robux
		Prices.changed:Fire()
	end
end

function Prices.fetch()
	if not IS_ROBLOX or asking or os.clock() - asked_at < Prices.REFRESH_S then
		return
	end
	asking = true
	task.spawn(function()
		local mps = game:GetService("MarketplaceService")
		local moved = false
		for key, p in Products do
			if type(p) == "table" and (tonumber(p.id) or 0) ~= 0 then
				local ok, info = pcall(function()
					return mps:GetProductInfo(p.id, Enum.InfoType.Product)
				end)
				if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
					if known[key] ~= info.PriceInRobux then
						known[key] = info.PriceInRobux
						moved = true
					end
				end
			end
		end
		for key, p in Passes do
			if type(p) == "table" and (tonumber(p.id) or 0) ~= 0 then
				local ok, info = pcall(function()
					return mps:GetProductInfo(p.id, Enum.InfoType.GamePass)
				end)
				if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
					if known["pass:" .. key] ~= info.PriceInRobux then
						known["pass:" .. key] = info.PriceInRobux
						moved = true
					end
				end
			end
		end
		asked_at = os.clock()
		asking = false
		if moved then
			Prices.changed:Fire()
		end
	end)
end

return Prices
