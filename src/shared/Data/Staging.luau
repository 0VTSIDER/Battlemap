--!strict
-- The Battlemap Staging experience (2026-10-04: a separate game to test changes in before they go to
-- prod): its universe id, for what differs there (Data/Products' ids, the game menu's
-- "Replay as new player").
local Staging = {}

--- Battlemap Staging's universe id.
Staging.UNIVERSE = 0

--- True in the Battlemap Staging experience.
function Staging.here(): boolean
	return Staging.UNIVERSE ~= 0 and typeof(game) == "Instance" and (game :: any).GameId == Staging.UNIVERSE
end

return Staging
