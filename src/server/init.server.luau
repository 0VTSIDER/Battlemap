-- Battlemap server entry. Owned by the Session/Main agent (see PORT.md §Ownership).
-- Dev harness hook: workspace attribute BM_DEV runs src/server/Dev/<BM_DEV>.luau if it exists.
-- (Data/DevFlags reads it as off in the live place.)
local DevFlags = require(game:GetService("ReplicatedStorage"):WaitForChild("Battlemap"):WaitForChild("Data"):WaitForChild("DevFlags")) :: any
local dev = DevFlags.harness()
if dev ~= nil then
	local mod = script:FindFirstChild("Dev") and script.Dev:FindFirstChild(dev)
	if mod then
		print("[Battlemap] server dev harness:", dev)
		require(mod)
		return
	end
end
local Server = script:FindFirstChild("ServerMain")
if Server then
	require(Server).start()
else
	print("[Battlemap] server boot (ServerMain not yet written)")
end
