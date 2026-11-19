--!nocheck
-- Localization: every key the code names exists in Data/Strings, the sources are well formed, Loc's
-- fallback / translator / reverse lookup / upper case work, and the CSV for the experience's
-- localization table is written to build/Localization.csv (upload it on the Creator Dashboard:
-- Localization > the experience's table > Upload CSV). Run: lune run tests/localization.luau
require("./prelude")
local fs = require("@lune/fs")
local process = require("@lune/process")
local Strings = require("../src/shared/Data/Strings")
local Loc = require("../src/shared/Core/Loc")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

-- the table
local n = #Strings.ORDER
expect(n > 500, ("%d strings"):format(n))
local bad_params, bad_format, empty = {}, {}, {}
for _, k in Strings.ORDER do
	local s = Strings.SOURCE[k]
	if s == "" then
		table.insert(empty, k)
	end
	for p in string.gmatch(s, "{([^}]*)}") do
		if not string.match(p, "^[%w_]+$") then
			table.insert(bad_params, k)
		end
	end
	-- a leftover string.format pattern (%s, %d, %02d...; "%" before a space or the end is a percent)
	if string.find(s, "%%[%-0-9.]*[sdfx]") and not string.find(s, "%%[%-0-9.]*[sdfx]%s") then
		table.insert(bad_format, k)
	elseif string.find(s, "%%[sd]") then
		table.insert(bad_format, k)
	end
end
expect(#empty == 0, "no empty source " .. table.concat(empty, ", "))
expect(#bad_params == 0, "parameters are {name} " .. table.concat(bad_params, ", "))
expect(#bad_format == 0, "no string.format patterns left " .. table.concat(bad_format, ", "))

-- every literal key the code names
local missing, used = {}, {}
local function scan(dir: string)
	for _, name in fs.readDir(dir) do
		local p = dir .. "/" .. name
		if fs.isDir(p) then
			scan(p)
		elseif string.sub(name, -5) == ".luau" and not string.find(p, "Data/Strings", 1, true) then
			local src = fs.readFile(p)
			for _, pat in { '[^%w_]L%("([%w_.%- ]+)"[,)]', 'Loc%.t%("([%w_.%- ]+)"[,)]', 'Loc%.ref%("([%w_.%- ]+)"[,)]', '[^%w_]LR%("([%w_.%- ]+)"[,)]' } do
				for k in string.gmatch(src, pat) do
					used[k] = true
					if Strings.SOURCE[k] == nil and not string.find(k, "%.$") then
						table.insert(missing, p .. ": " .. k)
					end
				end
			end
			-- keys passed as plain strings (self:msg(..., "msg.key"), tables of keys)
			for k in string.gmatch(src, '"([%a_]+%.[%w_.]+)"') do
				if Strings.SOURCE[k] ~= nil then
					used[k] = true
				end
			end
		end
	end
end
scan("src")
expect(#missing == 0, "every key in the code exists\n    " .. table.concat(missing, "\n    "))

-- keys no code names literally (built at run time: kind.*, data.*, team.*, help.s*, ".a" / ".lower")
local unused = {}
for _, k in Strings.ORDER do
	if not used[k] then
		local dynamic = string.match(k, "^data%.")
			or string.match(k, "^kind%.")
			or string.match(k, "^team%.")
			or string.match(k, "^rel%.")
			or string.match(k, "^help%.")
			or string.match(k, "^server%.")
			or string.match(k, "^struct%.")
			or string.match(k, "^nuke%.")
			or string.match(k, "^unit%.")
			or string.match(k, "^msg%.")
			or string.match(k, "%.tap$")
			or string.match(k, "%.click$")
		if not dynamic then
			table.insert(unused, k)
		end
	end
end
if #unused > 0 then
	print("  info keys not named in the code (check they are still used): " .. table.concat(unused, ", "))
end

-- English fallback (no translator: Lune, the server)
expect(Loc.t("msg.ally.formed", { who = "Bravo" }) == "You are now allied with Bravo", "fallback fills {who}")
expect(
	Loc.t("msg.gold", { item = Loc.ref("struct.city.a") }) == "Not enough gold for a City",
	"a Loc.ref argument is translated where it is inserted"
)
expect(Loc.t("msg.boat.landed") == "Your transport landed", "a plain key")
expect(Loc.text("Recruit") == "Recruit" and Loc.text("data.rank.recruit") == "Recruit", "Loc.text: English text or a key")
expect(Loc.text("Tap {who}, then tap again to attack", { who = "Bravo" }) == "Tap Bravo, then tap again to attack", "Loc.text fills args")
expect(Loc.text("some player name") == "some player name", "Loc.text: other text unchanged")

-- a translator: FormatByKey is asked by key, with the args already resolved
local asked = {}
Loc._set_translator({
	LocaleId = "pl-pl",
	FormatByKey = function(_, key, args)
		table.insert(asked, key)
		if key == "msg.boat.landed" then
			error("no entry")
		end
		if key == "struct.city.a" then
			return "Miasto"
		end
		return "PL:" .. key .. ":" .. tostring(args.who or args.item or "")
	end,
})
expect(Loc.t("msg.ally.formed", { who = "Bravo" }) == "PL:msg.ally.formed:Bravo", "the translator's text")
expect(Loc.t("msg.gold", { item = Loc.ref("struct.city.a") }) == "PL:msg.gold:Miasto", "a ref resolves through the translator")
expect(Loc.t("msg.boat.landed") == "Your transport landed", "a key it has no entry for: English")
local before = #asked
Loc.t("msg.boat.landed")
expect(#asked == before, "and it is not asked again")
expect(Loc.locale() == "pl-pl", "the locale")
Loc._set_translator(nil)

-- upper case beyond ASCII
expect(Loc.upper("zażółć gęślą jaźń") == "ZAŻÓŁĆ GĘŚLĄ JAŹŃ", "upper: Polish")
expect(Loc.upper("привет мир") == "ПРИВЕТ МИР", "upper: Russian")
expect(Loc.upper("ça déjà über") == "ÇA DÉJÀ ÜBER", "upper: French / German")
expect(Loc.upper("tiếng việt") == "TIẾNG VIỆT", "upper: Vietnamese")
expect(Loc.upper("Plain ASCII 80%") == "PLAIN ASCII 80%", "upper: ASCII")

-- the CSV (Key, Source, Context, Example): quoted fields, quotes doubled
local function q(s: string): string
	return '"' .. string.gsub(s, '"', '""') .. '"'
end
local rows = { "Key,Source,Context,Example" }
for _, k in Strings.ORDER do
	table.insert(rows, table.concat({ q(k), q(Strings.SOURCE[k]), q(""), q(Strings.NOTES[k] or "") }, ","))
end
if not fs.isDir("build") then
	fs.writeDir("build")
end
fs.writeFile("build/Localization.csv", table.concat(rows, "\r\n") .. "\r\n")
print(("  wrote build/Localization.csv (%d strings)"):format(n))

if fails > 0 then
	print(("%d FAILED"):format(fails))
	process.exit(1)
end
print("all passed")
