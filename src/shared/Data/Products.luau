--!strict
-- Robux developer products (Creator Dashboard → Monetization → Developer Products). `id` is the
-- product's id; 0 = not created yet (its offer stays hidden). Each purchase is a saved credit of kind
-- `grants` (default: the key), `count` of them (default 1) (server/Purchases.luau): bought credits are
-- never lost if the moment passes.
--
-- Product ids belong to one experience. `staging` is the same product in Battlemap Staging (2026-10-04:
-- a separate experience where a build is tested before it goes to prod); in that experience it
-- replaces `id`.
local PRODUCTS: { [string]: any } = {
	--- Solo / public: the Red Button, a MIRV at whoever eliminated you (2026-11-04; Sim.red_button). It
	--- is the former Takeover product (same id), renamed and repriced on the dashboard.
	red_button = { id = 3728168065, robux = 50, staging = 0 },
	--- Star packs (2026-11-04): Stars straight into the balance (Purchases.grant, "stars:<n>"), never
	--- leaderboard points. An average match pays about 1,000 Stars; the bigger packs give a bonus.
	stars_s = { id = 3728167865, robux = 49, staging = 0, stars = 10000, grants = "stars:10000" },
	stars_m = { id = 3728167934, robux = 99, staging = 0, stars = 22000, grants = "stars:22000" },
	stars_l = { id = 3728167979, robux = 249, staging = 0, stars = 60000, grants = "stars:60000" },
	stars_xl = { id = 3728168022, robux = 499, staging = 0, stars = 130000, grants = "stars:130000" },
	--- Battle Pass Premium (2026-11-18; Data/BattlePass): a credit, spent at once on the season running
	--- (server/Purchases.use_premium; one bought with premium already is kept for a later season). Not
	--- created on Roblox yet: its offer shows only in Studio until it is.
	bp_premium = { id = 3733223986, robux = 299, staging = 0 },
}

--- Battlemap Staging (Data/Staging): there every product is its `staging` one.
local Staging: any = if typeof(game) == "Instance"
	then require((script :: any).Parent.Staging)
	else (require :: any)("./Staging")

if Staging.here() then
	for _, p in PRODUCTS do
		p.id = p.staging or 0
	end
end

return PRODUCTS
