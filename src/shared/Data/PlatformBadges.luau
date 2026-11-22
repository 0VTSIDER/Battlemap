--!strict
-- Roblox platform badges (BadgeService; Creator Dashboard > Engagement > Badges): awarded by
-- server/PlatformBadges. Not the Locker's cosmetic badges (Assets/Catalog/Badges): these are Roblox's own,
-- shown on the player's profile. Ids are permanent; 0 = not created yet (never awarded). In Battlemap
-- Staging (Data/Staging) every id is 0: these badges belong to the main experience.
--
--   WELCOME          the first join
--   FIRST_CONQUEST   land taken from another nation, player, bot or tribe (public matches)
--   FIRST_VICTORY    a match won (public: the server's Sim; solo: the server-clocked bound of the win bonus)
--   WORLD_POWER      WorldPowerShare of the map's land held at once (public matches)
--   ALLIANCE_MAKER   an alliance formed (public matches)
--   PASS_MASTER      Battle Pass level PassMasterLevel (any season)
export type BadgeId = number

local PlatformBadges = {}

PlatformBadges.WELCOME = 3447005537128754 :: BadgeId
PlatformBadges.FIRST_CONQUEST = 942900260678286 :: BadgeId
PlatformBadges.FIRST_VICTORY = 87283401912431 :: BadgeId
PlatformBadges.WORLD_POWER = 2812531107923518 :: BadgeId
PlatformBadges.ALLIANCE_MAKER = 3105238883393897 :: BadgeId
PlatformBadges.PASS_MASTER = 0 :: BadgeId -- (not created yet)

--- The share of the map's land WORLD_POWER needs at its peak (0..1 of the land).
PlatformBadges.WorldPowerShare = 0.5
--- The Battle Pass level PASS_MASTER needs (levels).
PlatformBadges.PassMasterLevel = 100

local Staging: any = if typeof(game) == "Instance"
	then require((script :: any).Parent.Staging)
	else (require :: any)("./Staging")

if Staging.here() then
	PlatformBadges.WELCOME = 0
	PlatformBadges.FIRST_CONQUEST = 0
	PlatformBadges.FIRST_VICTORY = 0
	PlatformBadges.WORLD_POWER = 0
	PlatformBadges.ALLIANCE_MAKER = 0
	PlatformBadges.PASS_MASTER = 0
end

return PlatformBadges
