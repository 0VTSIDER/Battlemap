--!nonstrict
-- The map for the UI: the replicated registry (Data/MapList, one row: World) plus World's uploaded
-- thumbnail (the public-match card shows it). Falls back to the built-in map when the registry is
-- missing.
local RS = game:GetService("ReplicatedStorage")

local UIMaps = {}

UIMaps.DEFAULT_ID = "world"
--- World's thumbnail (rendered and uploaded by tools/assets/make_map_thumbs.py; Map/thumbs/world.png).
UIMaps.WORLD_THUMB = "rbxassetid://84787460719789"

local _entries: { any }? = nil
local _by_id: { [string]: any } = {}

--- Registry ids compare case- and punctuation-insensitively.
local function norm(id: string): string
	return string.lower((string.gsub(id, "[^%w]", "")))
end
UIMaps.norm = norm

local function find(folder: Instance?, name: string): any
	local m = folder and folder:FindFirstChild(name)
	if m and m:IsA("ModuleScript") then
		local ok, v = pcall(require, m)
		if ok then
			return v
		end
	end
	return nil
end

--- { {id, name, width, height, thumb}, ... }
function UIMaps.entries(): { any }
	if _entries ~= nil then
		return _entries
	end
	local root = RS:FindFirstChild("Battlemap")
	local list = find(root and root:FindFirstChild("Data"), "MapList")
	local out = {}
	local rows = if type(list) == "table" then (list.maps or list) else nil
	if type(rows) == "table" then
		for _, m in rows do
			if type(m) == "table" and m.id ~= nil then
				local e = {
					id = m.id,
					name = m.name or m.id,
					width = m.width,
					height = m.height,
					thumb = if norm(m.id) == UIMaps.DEFAULT_ID then UIMaps.WORLD_THUMB else nil,
				}
				table.insert(out, e)
				_by_id[norm(m.id)] = e
			end
		end
	end
	if #out == 0 then
		local e = {
			id = UIMaps.DEFAULT_ID,
			name = "World",
			thumb = UIMaps.WORLD_THUMB,
		}
		table.insert(out, e)
		_by_id[norm(e.id)] = e
	end
	_entries = out
	return out
end

function UIMaps.get(id: string?): any
	UIMaps.entries()
	local key = id or UIMaps.DEFAULT_ID
	-- a public match's smaller build ("world@80") shows as its map
	key = string.match(key, "^(.-)@%d+$") or key
	return _by_id[norm(key)]
end

function UIMaps.name_of(id: string?): string
	local e = UIMaps.get(id)
	return if e then e.name else "World"
end

--- A valid map id for `id` (the default when unknown).
function UIMaps.valid(id: string?): string
	local e = UIMaps.get(id)
	if e then
		return e.id
	end
	local first = UIMaps.entries()[1]
	return if first then first.id else UIMaps.DEFAULT_ID
end

return UIMaps
