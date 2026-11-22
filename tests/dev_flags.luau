--!nocheck
-- The dev switches' guard (shared/Data/DevFlags): they count in Studio and in any place but the live one,
-- so a dev build published to the live place by mistake runs with its diagnostics off.
-- Run: lune run tests/dev_flags.luau
local DevFlags = require("../src/shared/Data/DevFlags")

local failed = 0
local function expect(cond, what)
	if not cond then
		failed += 1
		print("FAIL: " .. what)
	end
end

local LIVE = DevFlags.LIVE_PLACE_ID
expect(LIVE == 93015372428640, "the live place id")
expect(DevFlags.allowed_in(true, LIVE), "Studio, the live place opened from Roblox: on")
expect(DevFlags.allowed_in(true, 0), "Studio, a local file: on")
expect(not DevFlags.allowed_in(false, LIVE), "a live server or client of the live place: off")
expect(DevFlags.allowed_in(false, 94923959139283), "a private test place's servers: on")
-- outside Roblox (this runtime) nothing is on
expect(not DevFlags.allowed(), "no game: off")
expect(not DevFlags.diag() and not DevFlags.reel() and DevFlags.harness() == nil, "no game: every switch off")

if failed > 0 then
	error(("dev_flags: %d failed"):format(failed))
end
print("dev_flags: all passed")
