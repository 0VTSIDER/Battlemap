--!strict
-- Robux game passes (Creator Dashboard → Monetization → Passes; 2026-11-04): one-time, permanent perks,
-- owned on Roblox's side (MarketplaceService:UserOwnsGamePassAsync), so nothing is stored for them.
-- `id` 0 = not created yet (the Locker shows it "not on sale"); `staging` replaces `id` in Battlemap
-- Staging (Data/Staging), as Data/Products does.
--
--   double_stars   every match's Stars doubled (server/Rewards). Stars only: never leaderboard points.
local PASSES: { [string]: any } = {
	double_stars = { id = 2068285992, robux = 199, staging = 0, name = "2x Stars", blurb = "Every match pays double, forever" },
}

local Staging: any = if typeof(game) == "Instance"
	then require((script :: any).Parent.Staging)
	else (require :: any)("./Staging")

if Staging.here() then
	for _, p in PASSES do
		p.id = p.staging or 0
	end
end

return PASSES
