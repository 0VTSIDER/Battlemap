--!strict
-- Robux game passes (shared/Data/Passes; 2026-11-04): who owns which, as Roblox says. Asked once a
-- join (retried a few times when Roblox doesn't answer), and set at once when a pass is bought here.
--
--   Passes.configure(deps)        { owns = fn(user_id, pass_id) -> boolean (yields), changed = fn(player), wait? }
--   Passes.load(player)           ask Roblox about every pass (join; yields)
--   Passes.bought(player, pass_id)   PromptGamePassPurchaseFinished with purchased = true
--   Passes.owns(player, key) -> boolean
--   Passes.owned(player) -> { [key]: true }   (the inventory's `passes`)
--   Passes.release(player)        PlayerRemoving
local IS_ROBLOX = typeof(game) == "Instance"
local Data: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Passes)
	else require("../shared/Data/Passes")

local Passes = {}

Passes.TRIES = 3

local deps: any = {}
local held: { [any]: { [string]: boolean } } = {}

function Passes.configure(d: any)
	for k, v in d do
		deps[k] = v
	end
end

function Passes.reset()
	table.clear(held)
	table.clear(deps)
end

local function key_of(pass_id: number): string?
	for k, p in Data do
		if p.id ~= 0 and p.id == pass_id then
			return k
		end
	end
	return nil
end

function Passes.load(player: any)
	local mine = held[player] or {}
	held[player] = mine
	local moved = false
	for k, p in Data do
		if p.id ~= 0 and not mine[k] then
			for try = 1, Passes.TRIES do
				local ok, yes = pcall(deps.owns, player.UserId, p.id)
				if ok then
					if yes == true then
						mine[k] = true
						moved = true
					end
					break
				end
				if deps.wait and try < Passes.TRIES then
					deps.wait(2 * try)
				end
			end
		end
	end
	if moved and deps.changed and held[player] == mine then
		deps.changed(player)
	end
end

function Passes.bought(player: any, pass_id: number)
	local k = key_of(pass_id)
	if k == nil then
		return
	end
	local mine = held[player] or {}
	held[player] = mine
	if not mine[k] then
		mine[k] = true
		if deps.changed then
			deps.changed(player)
		end
	end
end

function Passes.owns(player: any, key: string): boolean
	local mine = held[player]
	return mine ~= nil and mine[key] == true
end

function Passes.owned(player: any): { [string]: boolean }
	return table.clone(held[player] or {})
end

function Passes.release(player: any)
	held[player] = nil
end

return Passes
