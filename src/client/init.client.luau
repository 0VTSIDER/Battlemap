-- Battlemap client entry. Owned by the Session/Main agent (see PORT.md §Ownership).
-- Dev harness hook: if workspace attribute BM_DEV is set (in a developer's own Studio place),
-- run src/client/Dev/<BM_DEV>.luau instead of the game. Never set BM_DEV in the shipped place.
local dev = workspace:GetAttribute("BM_DEV")
if type(dev) == "string" and dev ~= "" then
	local mod = script:FindFirstChild("Dev") and script.Dev:FindFirstChild(dev)
	if mod then
		print("[Battlemap] client dev harness:", dev)
		require(mod)
		return
	end
	warn("[Battlemap] BM_DEV harness not found on client:", dev)
end
local Main = script:FindFirstChild("Main")
if Main then
	require(Main).start()
else
	print("[Battlemap] client boot (Main not yet written)")
end
