--!strict
-- The dev switches (workspace attributes BM_DIAG, BM_REEL, BM_DEV) and where they count: in Studio, and in
-- any place that is not the live Battlemap place. A dev build was published to the live place by mistake
-- (2026-11-22): it carried the Dev folders and BM_DIAG = true, so the public game ran its diagnostics and
-- skipped the tutorial. Read here, the switches are off there whatever the place file holds, and such a
-- build runs as a release does. (A private test place has another place id: the switches work there.)
local DevFlags = {}

--- The live Battlemap place (experience 10774637528).
DevFlags.LIVE_PLACE_ID = 93015372428640

--- Whether dev switches count for a server or client in this place. `is_studio`: RunService:IsStudio().
function DevFlags.allowed_in(is_studio: boolean, place_id: number): boolean
	return is_studio or place_id ~= DevFlags.LIVE_PLACE_ID
end

--- Whether dev switches count here. False outside Roblox (the tests' runtime).
function DevFlags.allowed(): boolean
	if typeof(game) ~= "Instance" then
		return false
	end
	local g = game :: any
	return DevFlags.allowed_in(g:GetService("RunService"):IsStudio(), g.PlaceId)
end

local function attribute(name: string): any
	if not DevFlags.allowed() then
		return nil
	end
	return (workspace :: any):GetAttribute(name)
end

--- BM_DIAG: the dev diagnostics (Dev/SessionDiag, client and server).
function DevFlags.diag(): boolean
	return attribute("BM_DIAG") == true
end

--- BM_REEL: the self-playing match for a screen recording (Dev/AdReel).
function DevFlags.reel(): boolean
	return attribute("BM_REEL") == true
end

--- BM_DEV: the name of the Dev harness module to run in place of the game, or nil.
function DevFlags.harness(): string?
	local v = attribute("BM_DEV")
	return if type(v) == "string" and v ~= "" then v else nil
end

return DevFlags
