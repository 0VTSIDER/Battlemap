--!strict
-- Every player-facing string, by key (English source; Loc.t translates). One module per area; keys
-- start with the area's prefix and are unique across all of them (checked here and by
-- tests/localization.luau, which also writes the CSV for the dashboard's localization table).
--
-- An entry is "text" or { text = "text", note = "for translators" } (the CSV's Example column). `{name}` is a
-- parameter (Loc.t's args): keep it, move it where the language needs it. Proper names (players,
-- nations, maps' places), numbers and the game's name are never in a source string.

local AREAS = {
	require("@self/Names"),
	require("@self/Sim"),
	require("@self/Hud"),
	require("@self/Title"),
	require("@self/Help"),
	require("@self/Menus"),
	require("@self/Data"),
	require("@self/Server"),
	require("@self/BattlePass"),
}

local Strings = {}
--- key -> English text
Strings.SOURCE = {} :: { [string]: string }
--- key -> note for translators
Strings.NOTES = {} :: { [string]: string }
--- keys in definition order (areas in AREAS order, keys sorted within an area)
Strings.ORDER = {} :: { string }

for _, area in AREAS do
	local keys = {}
	for k in area :: any do
		table.insert(keys, k)
	end
	table.sort(keys)
	for _, k in keys do
		assert(Strings.SOURCE[k] == nil, "duplicate string key " .. k)
		local v = (area :: any)[k]
		if type(v) == "table" then
			Strings.SOURCE[k] = v.text
			Strings.NOTES[k] = v.note
		else
			Strings.SOURCE[k] = v
		end
		table.insert(Strings.ORDER, k)
	end
end

return Strings
