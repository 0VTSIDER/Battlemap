--!strict
-- Localized text. Every string a player reads is a key in Data/Strings (English source, `{name}`
-- parameters); `Loc.t(key, args)` returns it in the player's language.
--
-- How it reaches other languages: tests/localization.luau writes build/Localization.csv (Key, Source,
-- Context, Example) from Data/Strings; upload it to the experience's localization table (Creator
-- Dashboard > Localization > the table > Upload CSV) and auto-translation fills the languages. On the
-- client `Loc.init()` gets the player's Translator (LocalizationService:GetTranslatorForPlayerAsync) and
-- `t` asks it with FormatByKey; keys it has no entry for yet, and everything on the server / in Lune,
-- fall back to the English here. Text objects are created with AutoLocalize off (Widgets, UITheme):
-- automatic text capture would otherwise collect every name and number as a new source string.
--
-- Arguments: values are strings or numbers, inserted as they are (format numbers before: NumberFormat).
-- A value made by `Loc.ref(key, args)` is itself translated ("Not enough gold for {item}", item =
-- Loc.ref("struct.city.a")). Refs are plain strings, so Sim events carry them over the wire.
--
-- Scripts: Latin and Cyrillic (UITheme's measuring / letter-spaced paths). `Loc.upper` upper-cases
-- those scripts (string.upper only knows ASCII).

local Strings = require("../Data/Strings")
local Signal = require("./Signal")

local Loc = {}

--- Fires after the player's language changes (Roblox menu > Settings > Language). Screens built from
--- `t` refresh their texts on it (UIRoot rebuilds the open screen).
Loc.changed = Signal.new()

--- The English source of every key (Data/Strings).
Loc.STRINGS = Strings.SOURCE

local REF = "\1"

local translator: any = nil
--- Keys the translator has no entry for (FormatByKey failed): straight to English after the first miss.
local missing: { [string]: boolean } = {}
local cache: { [string]: string } = {}
local warned: { [string]: boolean } = {}

--- The locale in use ("en-us" before init / without a translator).
function Loc.locale(): string
	return if translator ~= nil then string.lower(translator.LocaleId) else "en-us"
end

--- A reference to `key` to pass as an argument value (translated where it is inserted).
function Loc.ref(key: string, args: { [string]: any }?): any
	if args == nil or next(args) == nil then
		return REF .. key
	end
	return { [REF] = key, args = args }
end

local resolve: (any) -> string

local function format(src: string, args: { [string]: any }?): string
	if args == nil then
		return src
	end
	return (string.gsub(src, "{([%w_]+)}", function(name: string): string?
		local v = (args :: any)[name]
		if v == nil then
			return nil
		end
		return resolve(v)
	end))
end

--- `key`'s text with `args` filled in, in the player's language (English fallback; an unknown key
--- shows as itself and warns once).
function Loc.t(key: string, args: { [string]: any }?): string
	local src = Strings.SOURCE[key]
	if src == nil then
		if not warned[key] then
			warned[key] = true
			warn("[Battlemap] no string for key " .. tostring(key))
		end
		return tostring(key)
	end
	local plain = args == nil or next(args :: any) == nil
	if plain then
		local c = cache[key]
		if c ~= nil then
			return c
		end
	end
	local out: string? = nil
	if translator ~= nil and not missing[key] then
		local fa: { [string]: any } = {}
		if args ~= nil then
			for k, v in args :: any do
				fa[k] = resolve(v)
			end
		end
		local ok, s = pcall(translator.FormatByKey, translator, key, fa)
		if ok and type(s) == "string" and s ~= "" then
			out = s
		else
			missing[key] = true
		end
	end
	if out == nil then
		out = format(src, args)
	end
	if plain then
		cache[key] = out :: string
	end
	return out :: string
end

resolve = function(v: any): string
	if type(v) == "string" then
		if string.sub(v, 1, 1) == REF then
			return Loc.t(string.sub(v, 2))
		end
		return v
	elseif type(v) == "table" and v[REF] ~= nil then
		return Loc.t(v[REF], v.args)
	end
	return tostring(v)
end



--- English text -> the first key with that exact source (data modules keep their English values).
local BY_TEXT: { [string]: string } = {}
for _, k in Strings.ORDER do
	local src = Strings.SOURCE[k]
	if BY_TEXT[src] == nil then
		BY_TEXT[src] = k
	end
end

--- Translates a value that is a key, a ref, or English text that has a key (data fields: Arsenal
--- titles, rank names, tutorial lines...). Other text is returned as it is, with `args` filled in.
function Loc.text(v: any, args: { [string]: any }?): string
	if type(v) == "string" then
		if Strings.SOURCE[v] ~= nil then
			return Loc.t(v, args)
		end
		local k = BY_TEXT[v]
		if k ~= nil then
			return Loc.t(k, args)
		end
		if string.sub(v, 1, 1) ~= REF then
			return format(v, args)
		end
	end
	return resolve(v)
end

-- Upper case for Latin-1, Latin Extended-A/B (common), Latin Extended Additional (Vietnamese),
-- Greek and Cyrillic; other characters stay as they are.
local function upper_cp(cp: number): number
	if cp < 128 then
		return if cp >= 97 and cp <= 122 then cp - 32 else cp
	elseif cp >= 0xE0 and cp <= 0xFE and cp ~= 0xF7 then
		return cp - 32
	elseif cp == 0xFF then
		return 0x178
	elseif cp >= 0x100 and cp <= 0x17F then
		if (cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17E) then
			return if cp % 2 == 0 then cp - 1 else cp
		elseif cp == 0x131 or cp == 0x138 or cp == 0x149 or cp == 0x17F or cp == 0x178 then
			return if cp == 0x131 then 0x49 else cp
		end
		return if cp % 2 == 1 then cp - 1 else cp
	elseif cp == 0x1A1 or cp == 0x1B0 then
		return cp - 1
	elseif cp >= 0x1EA0 and cp <= 0x1EFF then
		return if cp % 2 == 1 then cp - 1 else cp
	elseif cp >= 0x3B1 and cp <= 0x3C9 and cp ~= 0x3C2 then
		return cp - 32
	elseif cp >= 0x430 and cp <= 0x44F then
		return cp - 32
	elseif cp >= 0x450 and cp <= 0x45F then
		return cp - 80
	elseif cp >= 0x460 and cp <= 0x4FF then
		return if cp % 2 == 1 then cp - 1 else cp
	end
	return cp
end

--- `s` in upper case (UTF-8 aware for Latin and Cyrillic).
function Loc.upper(s: string): string
	if not string.find(s, "[\128-\255]") then
		return string.upper(s)
	end
	local ok, n = pcall(utf8.len, s)
	if not ok or n == nil then
		return string.upper(s)
	end
	local out = table.create(n :: number)
	for _, cp in utf8.codes(s) do
		table.insert(out, utf8.char(upper_cp(cp)))
	end
	return table.concat(out)
end

local started = false
local done = false
--- A caller stopped waiting before the translator came: Loc.changed fires when it does.
local waited_out = false

--- Our text is translated by key, never by automatic text capture: every GUI object under the
--- player's PlayerGui (and in the world) gets AutoLocalize off as it appears.
local function no_auto_localize(root: Instance)
	local function off(d: Instance)
		if d:IsA("GuiBase2d") then
			(d :: any).AutoLocalize = false
		end
	end
	for _, d in root:GetDescendants() do
		off(d)
	end
	root.DescendantAdded:Connect(off)
end

--- Client: gets the player's Translator and follows their language setting. The first call starts
--- it; every call waits up to `timeout` seconds (0: not at all) for it (English until it arrives).
function Loc.init(timeout: number?)
	if game == nil then
		return
	end
	local LocalizationService = game:GetService("LocalizationService")
	local Players = game:GetService("Players")
	if not started then
		started = true
		task.spawn(function()
			local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
			no_auto_localize(pg)
		end)
		task.spawn(function()
			for attempt = 1, 4 do
				local ok, tr = pcall(function()
					return LocalizationService:GetTranslatorForPlayerAsync(Players.LocalPlayer)
				end)
				if ok and tr ~= nil then
					translator = tr
					table.clear(cache)
					table.clear(missing)
					tr:GetPropertyChangedSignal("LocaleId"):Connect(function()
						table.clear(cache)
						table.clear(missing)
						Loc.changed:Fire(Loc.locale())
					end)
					if waited_out then
						Loc.changed:Fire(Loc.locale()) -- arrived after a caller stopped waiting
					end
					break
				end
				task.wait(attempt)
			end
			done = true
		end)
	end
	local t0 = os.clock()
	while translator == nil and not done and os.clock() - t0 < (timeout or 3) do
		task.wait()
	end
	if translator == nil and (timeout or 3) > 0 then
		waited_out = true
	end
end

--- Tests: use `tr` (anything with FormatByKey / LocaleId) as the translator, or nil for English.
function Loc._set_translator(tr: any)
	translator = tr
	table.clear(cache)
	table.clear(missing)
end

return Loc
