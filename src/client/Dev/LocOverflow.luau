--!nonstrict
-- Dev only (src/client/Dev: release.project.json ignores the folder). Previews the UI in another
-- language and scans it for text that does not fit. SessionDiag commands (BM_DIAG):
--   lang <code|en|off> [desk|phone|wide]
--                               Loc's translator from ReplicatedStorage.BattlemapDevLoc (the translations
--                               CSV, mapped in default.project.json only), then the UI is rebuilt (on the
--                               title only). "en": the English source through the same recording
--                               translator; "off": the player's own translator back. desk (default): a
--                               1200 x 675 px frame = the 1600 x 900 logical layout of any 16:9 desktop;
--                               phone: a touch device in an 844 x 390 point frame; wide: Studio's view.
--   overflow [screen]           scans the visible UI: one line per problem
--   loctour                     visits every screen reachable from the title and a solo match and scans
--                               each; runs in the background: LocalPlayer attributes af_loc_state
--                               ("running <step>" / "done") and af_loc_report (the report)
-- A problem line: screen | kind | key | "text" | need/have px | where.
--   kinds: ellipsis / clipped (text wider than a box that cuts it), spill (wider than its box, drawn
--   past it), wrap-tall (wrapped text taller than its box), offscreen, outside (out of the styled box
--   it sits in: a card, a panel, a button), overlap (two texts in the same box cross).
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

--- Log lines (Output) for this tool.
local DebugLogLocOverflow = false

local client = script.Parent.Parent
local Loc = require(RS:WaitForChild("Battlemap"):WaitForChild("Core"):WaitForChild("Loc")) :: any
local Strings = require(RS.Battlemap:WaitForChild("Data"):WaitForChild("Strings")) :: any
local W = require(client:WaitForChild("UI"):WaitForChild("Widgets")) :: any
local UITheme = require(client.UI:WaitForChild("UITheme")) :: any

local M = {}

--- Tolerance (logical px) before a size difference counts.
local TOL = 1.0
--- The phone frame (points, landscape iPhone 14).
local PHONE = Vector2.new(844, 390)
--- The desktop frame (render px): scale 0.75, so the 1600 x 900 logical layout every 16:9 desktop gets.
local DESK = Vector2.new(1200, 675)

local function log(...)
	if DebugLogLocOverflow then
		print("[LocOverflow]", ...)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Translator + reverse lookup
-- ---------------------------------------------------------------------------------------------

M.locale = "en"
--- Keys drawn smaller by the shrink-to-fit (Widgets Label._fit_fs) in the scans since the last tour start.
M.shrunk = {}
local values: { [string]: string } = {}
local seen: { [string]: string } = {}
local patterns: { any }? = nil
local english: { [string]: string } = {}
for k, v in Strings.SOURCE do
	english[v] = english[v] or k
	english[Loc.upper(v)] = english[Loc.upper(v)] or k
end

local function load_values(code: string): (boolean, string)
	table.clear(values)
	table.clear(seen)
	patterns = nil
	if code == "en" then
		for k, v in Strings.SOURCE do
			values[k] = v
		end
		return true, "en"
	end
	local tbl = RS:FindFirstChild("BattlemapDevLoc")
	if tbl == nil then
		return false, "no ReplicatedStorage.BattlemapDevLoc (dev build only)"
	end
	local n = 0
	for _, e in tbl:GetEntries() do
		local v = e.Values and e.Values[code]
		if type(v) == "string" and v ~= "" then
			values[e.Key] = v
			n += 1
		end
	end
	return n > 0, ("%d entries for %s"):format(n, code)
end

local function make_translator(code: string): any
	local tr = { LocaleId = code }
	function tr.FormatByKey(_self: any, key: string, args: any): string
		local s = values[key]
		if s == nil then
			error("no entry for " .. tostring(key))
		end
		if args ~= nil then
			s = (string.gsub(s, "{([%w_]+)}", function(name: string): string?
				local v = args[name]
				return if v == nil then nil else tostring(v)
			end))
		end
		for _, t in { s, Loc.upper(s) } do
			local had = seen[t]
			if had == nil then
				seen[t] = key
			elseif had ~= key and not string.find("," .. had .. ",", "," .. key .. ",", 1, true) then
				seen[t] = had .. "," .. key
			end
		end
		return s
	end
	return tr
end

local function esc(s: string): string
	return (string.gsub(s, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function build_patterns()
	local out = {}
	local function add(tpl: string, key: string)
		if not string.find(tpl, "{", 1, true) then
			return
		end
		local lit = string.gsub(tpl, "{[%w_]+}", "")
		if #lit < 3 then
			return
		end
		local p = esc(tpl)
		p = string.gsub(p, "{([%w_]+)}", ".-")
		table.insert(out, { "^" .. p .. "$", key, #lit })
		local u = string.gsub(esc(Loc.upper(tpl)), "{([%w_]+)}", ".-")
		table.insert(out, { "^" .. u .. "$", key, #lit })
	end
	for k, v in values do
		add(v, k)
	end
	for k, v in Strings.SOURCE do
		add(v, k)
	end
	table.sort(out, function(a, b)
		return a[3] > b[3]
	end)
	patterns = out
end

--- The string key a shown text came from ("?" when none matches; "~key" when only part of it is).
function M.key_of(text: string): string
	local k = seen[text] or english[text]
	if k ~= nil then
		return k
	end
	for kk, v in values do
		if v == text or Loc.upper(v) == text then
			return kk
		end
	end
	if patterns == nil then
		build_patterns()
	end
	for _, p in patterns :: any do
		if string.find(text, p[1]) then
			return p[2]
		end
	end
	-- a part of it: the longest plain template found inside the text
	local best, bl = nil, 3
	for kk, v in values do
		if #v > bl and not string.find(v, "{", 1, true) and string.find(text, v, 1, true) then
			best, bl = kk, #v
		end
	end
	return if best then "~" .. best else "?"
end

-- ---------------------------------------------------------------------------------------------
-- Language switch (UI rebuild)
-- ---------------------------------------------------------------------------------------------

M.phone = false
--- "desk" (1600 x 900 logical), "phone" or "wide" (Studio's own game view)
M.view = "wide"

local function rebuild(Main: any, view: string)
	local phone = view == "phone"
	local old = Main.ui
	local UIRoot = require(client.UI:WaitForChild("UIRoot")) :: any
	local keep = {}
	for _, k in { "screen_changed", "music_toggled", "labels_toggled", "leaderboard_toggled", "help_toggled" } do
		keep[k] = old[k]
	end
	local tp = old.topbar_provider
	old:destroy()
	local u = UIRoot.new(if phone then { touch_device = true } else nil)
	for k, s in keep do
		u[k] = s
	end
	u.topbar_provider = tp
	Main.ui = u
	u:setup(Main.session, Main.world, Main.audio)
	if phone then
		u.root.gui.Size = UDim2.fromOffset(PHONE.X, PHONE.Y)
	elseif view == "desk" then
		u.root.gui.Size = UDim2.fromOffset(DESK.X, DESK.Y)
	end
	u.screen_changed:Fire(u:screen())
	M.phone = phone
	M.view = view
	task.wait(0.3)
end

--- lang <code|en|off> [desk|phone|wide]
function M.lang(Main: any, code: string?, view: any): string
	if type(view) ~= "string" then
		view = if view == true then "phone" else "desk"
	end
	code = string.lower(code or "en")
	local ui = Main.ui
	if ui ~= nil and ui:screen() ~= "title" and ui:screen() ~= "" then
		return "lang: go to the title first (screen " .. ui:screen() .. ")"
	end
	if code == "off" then
		M.locale = "off"
		Loc._set_translator(nil)
		Loc.init(5)
	else
		local ok, msg = load_values(code)
		if not ok then
			return "lang: " .. msg
		end
		M.locale = code
		Loc._set_translator(make_translator(code))
	end
	rebuild(Main, view)
	log("lang", code, view)
	return ("lang %s (%s): %s, ui rebuilt, vp %dx%d"):format(
		code,
		view,
		Loc.locale(),
		Main.ui.ctx.vp.X,
		Main.ui.ctx.vp.Y
	)
end

-- ---------------------------------------------------------------------------------------------
-- Scan
-- ---------------------------------------------------------------------------------------------

local function is_label(n: any): boolean
	return rawget(n, "_glyphs") ~= nil and type(n.text) == "string" and type(n._use_glyphs) == "function"
end

local function is_button(n: any): boolean
	return rawget(n, "_label") ~= nil and rawget(n, "_sv") ~= nil and type(n.text) == "string"
end

local function styled(n: any): boolean
	local sv = rawget(n, "_sv")
	if sv ~= nil and sv.style ~= nil and sv.style.kind ~= "empty" and not rawget(n, "flat") then
		return true
	end
	-- GlassPanel draws its own glass
	return rawget(n, "_shadow") ~= nil and rawget(n, "tint") ~= nil
end

local function where(n: any): string
	local names = {}
	local p = n
	while p ~= nil and #names < 3 do
		if type(p.name) == "string" and p.name ~= "" then
			table.insert(names, 1, p.name)
		end
		p = p.parent
	end
	return table.concat(names, "/")
end

local function short(s: string): string
	s = string.gsub(s, "\n", " / ")
	if utf8.len(s) and (utf8.len(s) :: number) > 48 then
		local cut = utf8.offset(s, 46)
		s = string.sub(s, 1, (cut or 47) - 1) .. "…"
	end
	return s
end

--- Text extent of a Label at its drawn size: width, height.
local function label_need(n: any): (number, number)
	local fs = rawget(n, "_fit_fs_now") or n.font_size
	if n.autowrap then
		return n.size.X, UITheme.wrapped_height(n.text, fs, n.weight, math.max(n.size.X, 1))
	end
	local lines = string.split(n.text, "\n")
	local glyphs = n:_use_glyphs()
	local w = 0
	for _, line in lines do
		w = math.max(w, UITheme.measure_text(line, fs, n.weight, n.spacing, glyphs and n.tabular))
	end
	return w, UITheme.line_height(fs) * #lines
end

local function rect_out(a: Rect, b: Rect): number
	return math.max(b.Min.X - a.Min.X, a.Max.X - b.Max.X, b.Min.Y - a.Min.Y, a.Max.Y - b.Max.Y)
end

--- Scans the live UI: a list of problem lines (screen tag first).
function M.scan(Main: any, tag: string?): { string }
	tag = tag or "?"
	local ui = Main.ui
	local out = {}
	local dedupe = {}
	local function add(kind: string, text: string, need: string, at: string)
		if M._names then
			for nm in M._names do
				if #nm >= 3 and string.find(text, nm, 1, true) then
					kind = "name:" .. kind
					break
				end
			end
		end
		local line = ("%s | %s | %s | \"%s\" | %s | %s"):format(tag, kind, M.key_of(text), short(text), need, at)
		if not dedupe[line] then
			dedupe[line] = true
			table.insert(out, line)
		end
	end
	-- player / nation names are not strings: listed apart (kind "name:...")
	local names = {}
	local lp = Players.LocalPlayer
	names[lp.DisplayName] = true
	names[lp.Name] = true
	local st = Main.session and Main.session.state
	if st ~= nil then
		pcall(function()
			for _, r in st:ranking() do
				names[st:owner_name(r.id)] = true
			end
		end)
	end
	M._names = names
	local root = ui.root
	local vp = root.vp
	local screen = Rect.new(0, 0, vp.X, vp.Y)
	local texts = {} -- {rect, panel, node, text}
	local label_guis = {}
	local hidden_guis = {}
	local floating = false
	local function walk(n: any, panel: any, scrolled: boolean)
		if n == nil or n._freed then
			return
		end
		if not n.visible or (n._eff_a or 1) < 0.05 then
			hidden_guis[n.gui] = true
			return
		end
		local gr = n:get_global_rect()
		if is_label(n) then
			label_guis[n.gui] = true
			if rawget(n, "_fit_fs_now") ~= nil and n.text ~= "" then
				M.shrunk[M.key_of(n.text)] = true
			end
			local txt = n.text
			if txt ~= nil and string.find(txt, "%S") and n.size.X > 0 then
				local nw, nh = label_need(n)
				local sz = n.size
				if not n.autowrap and nw > sz.X + TOL then
					local kind = if n.text_overrun_behavior ~= W.OVERRUN_NONE and not n:_use_glyphs()
						then "ellipsis"
						elseif n.clip_text then "clipped"
						else "spill"
					add(kind, txt, ("%d/%d"):format(math.ceil(nw), math.floor(sz.X)), where(n))
				elseif n.autowrap and nh > sz.Y + TOL then
					add("wrap-tall", txt, ("h %d/%d"):format(math.ceil(nh), math.floor(sz.Y)), where(n))
				end
				-- the drawn text's rect
				local dw = if n.clip_text or n.text_overrun_behavior ~= W.OVERRUN_NONE then math.min(nw, sz.X) else nw
				local dh = math.min(nh, math.max(sz.Y, nh))
				local x = gr.Min.X
				if not n.autowrap then
					if n.horizontal_alignment == W.ALIGN_CENTER then
						x += (sz.X - dw) * 0.5
					elseif n.horizontal_alignment == W.ALIGN_RIGHT then
						x += sz.X - dw
					end
				end
				local y = gr.Min.Y
				if n.vertical_alignment == W.VALIGN_CENTER then
					y += (sz.Y - dh) * 0.5
				elseif n.vertical_alignment == W.VALIGN_BOTTOM then
					y += sz.Y - dh
				end
				local tr = Rect.new(x, y, x + dw, y + dh)
				if not scrolled and not floating then
					if rect_out(tr, screen) > TOL then
						add("offscreen", txt, ("%dpx"):format(math.ceil(rect_out(tr, screen))), where(n))
					elseif panel ~= nil then
						local pr = panel:get_global_rect()
						local o = rect_out(Rect.new(tr.Min.X, gr.Min.Y, tr.Max.X, gr.Max.Y), pr)
						if o > TOL then
							add("outside", txt, ("%dpx of %s"):format(math.ceil(o), where(panel)), where(n))
						end
					end
				end
				table.insert(texts, { tr, panel, n, txt })
			end
		elseif is_button(n) and n.text ~= "" and not scrolled then
			if rect_out(gr, screen) > TOL then
				add("offscreen", n.text, ("%dpx"):format(math.ceil(rect_out(gr, screen))), where(n))
			elseif panel ~= nil then
				local o = rect_out(gr, panel:get_global_rect())
				if o > TOL then
					add("outside", n.text, ("%dpx of %s"):format(math.ceil(o), where(panel)), where(n))
				end
			end
		end
		local sub = if styled(n) and n.size.X > 0 then n else panel
		local sc = scrolled or rawget(n, "_canvas_offset") ~= nil or (n._canvas_offset ~= nil)
		-- the Floats layer: texts pinned to map tiles (off the screen when the tile is)
		local was = floating
		floating = floating or n.name == "Floats"
		for _, c in n.children do
			walk(c, sub, sc)
		end
		for _, c in n._internal do
			walk(c, sub, sc)
		end
		floating = was
	end
	walk(root, nil, false)
	-- sibling texts in the same box crossing
	for i = 1, #texts do
		local a = texts[i]
		for j = i + 1, #texts do
			local b = texts[j]
			if a[2] == b[2] then
				local ra, rb = a[1], b[1]
				local ox = math.min(ra.Max.X, rb.Max.X) - math.max(ra.Min.X, rb.Min.X)
				local oy = math.min(ra.Max.Y, rb.Max.Y) - math.max(ra.Min.Y, rb.Min.Y)
				if ox > 2 and oy > 2 then
					-- not a label over its own shadow / a node and its ancestor
					local p, related = a[3].parent, false
					while p ~= nil do
						if p == b[3] then
							related = true
						end
						p = p.parent
					end
					if not related and a[4] ~= b[4] then
						add("overlap", a[4], ("with \"%s\" (%dx%d)"):format(short(b[4]), ox, oy), where(a[3]))
					end
				end
			end
		end
	end
	-- native text (Locker cards, map picker rows...): what Roblox measured
	local s = UITheme.scale
	local rg = root.gui
	local sp, ss = rg.AbsolutePosition, rg.AbsoluteSize
	local scr = Rect.new(sp.X, sp.Y, sp.X + ss.X, sp.Y + ss.Y)
	local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	for _, d in (if pg then pg:GetDescendants() else {}) do
		if (d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox")) and not label_guis[d.Parent] then
			local t = (d :: any).Text
			if t ~= "" and string.find(t, "%S") and (d :: any).TextTransparency < 0.95 then
				-- visible all the way up, and where in a scroll frame
				local vis, scroll = true, nil
				local p: Instance? = d
				while p ~= nil and not p:IsA("PlayerGui") do
					if
						hidden_guis[p]
						or (p:IsA("GuiObject") and not (p :: any).Visible)
						or (p:IsA("LayerCollector") and not (p :: any).Enabled)
					then
						vis = false
						break
					elseif p:IsA("ScrollingFrame") and scroll == nil then
						scroll = p
					end
					p = p.Parent
				end
				local asz = (d :: any).AbsoluteSize
				if vis and asz.X > 0 and asz.Y > 0 then
					local ap = (d :: any).AbsolutePosition
					local r = Rect.new(ap.X, ap.Y, ap.X + asz.X, ap.Y + asz.Y)
					local in_view = true
					if scroll ~= nil then
						local q, z = scroll.AbsolutePosition, scroll.AbsoluteSize
						in_view = rect_out(r, Rect.new(q.X, q.Y, q.X + z.X, q.Y + z.Y)) <= 0
					end
					if in_view then
						local tb = (d :: any).TextBounds
						local at = d:GetFullName():match("([^%.]+%.[^%.]+)$") or d.Name
						local tl = TOL * s
						if (d :: any).TextScaled then
							if not (d :: any).TextFits then
								add("scaled-clip", t, "TextFits=false", "native " .. at)
							end
						elseif (d :: any).TextWrapped then
							if tb.Y > asz.Y + tl then
								add("wrap-tall", t, ("h %d/%d"):format(math.ceil(tb.Y / s), math.floor(asz.Y / s)), "native " .. at)
							end
						elseif tb.X > asz.X + tl then
							local kind = if (d :: any).TextTruncate ~= Enum.TextTruncate.None then "ellipsis" else "spill"
							add(kind, t, ("%d/%d"):format(math.ceil(tb.X / s), math.floor(asz.X / s)), "native " .. at)
						end
						if scroll == nil and pg ~= nil and d:IsDescendantOf(ui.gui) and rect_out(r, scr) > tl then
							add("offscreen", t, ("%dpx"):format(math.ceil(rect_out(r, scr) / s)), "native " .. at)
						end
					end
				end
			end
		end
	end
	return out
end

--- Visible texts still in English while another language is on (count, a few examples).
function M.untranslated(Main: any): (number, { string })
	if M.locale == "en" or M.locale == "off" then
		return 0, {}
	end
	local n, ex = 0, {}
	local function walk(c: any)
		if c == nil or not c.visible then
			return
		end
		if is_label(c) and c.text ~= "" then
			local k = english[c.text]
			if k ~= nil and values[k] ~= nil and values[k] ~= Strings.SOURCE[k] and Loc.upper(values[k]) ~= c.text then
				n += 1
				if #ex < 8 then
					table.insert(ex, k)
				end
			end
		end
		for _, x in c.children do
			walk(x)
		end
		for _, x in c._internal do
			walk(x)
		end
	end
	walk(Main.ui.root)
	return n, ex
end

-- ---------------------------------------------------------------------------------------------
-- The tour
-- ---------------------------------------------------------------------------------------------

local function wait_for(fn: () -> boolean, timeout: number): boolean
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		local ok, v = pcall(fn)
		if ok and v then
			return true
		end
		task.wait(0.2)
	end
	return false
end

local function free_tile(st: any): number
	local map = st.map
	local seed = os.clock() * 1000 // 1
	for k = 1, 40000 do
		local t = map:land_tile((seed + k * 7919) % map.land_count)
		if map:is_contestable(t) and st:tile_owner(t) == 0 and not map:is_coastal(t) then
			local ok = true
			for _, n in map:neighbors4(t) do
				if st:tile_owner(n) ~= 0 then
					ok = false
					break
				end
			end
			if ok then
				return t
			end
		end
	end
	return -1
end

local function other_tile(st: any, want_owner: boolean): number
	local me = st.local_owner
	local map = st.map
	for k = 0, map.land_count - 1, 7 do
		local t = map:land_tile(k)
		local o = st:tile_owner(t)
		if map:is_contestable(t) and o ~= me and (if want_owner then o ~= 0 else o == 0) then
			return t
		end
	end
	return -1
end

--- Runs the whole tour; returns the report.
function M.tour(Main: any): string
	local player = Players.LocalPlayer
	local session = Main.session
	local lines = {}
	local counts = {}
	local errs = {}
	local function ui()
		return Main.ui
	end
	local function scan(tag: string)
		player:SetAttribute("af_loc_state", "running " .. tag)
		task.wait(0.9) -- pop-ins and fades settle
		W.flush()
		local ok, res = pcall(M.scan, Main, tag)
		if not ok then
			table.insert(errs, tag .. ": scan error " .. tostring(res))
			return
		end
		counts[tag] = #res
		for _, l in res do
			table.insert(lines, l)
		end
	end
	local function close_all()
		local u = ui()
		for _, f in {
			function()
				u.locker:close()
			end,
			function()
				u.pause:close()
			end,
			function()
				u.world_ranks:close()
			end,
			function()
				if u.help.is_open then
					u:toggle_help()
				end
			end,
			function()
				u.next_match:close()
			end,
			function()
				u.pass:close()
			end,
			function()
				u.title._bp_bar:_hide_card()
			end,
		} do
			pcall(f)
		end
	end
	local function step(name: string, fn: () -> ())
		close_all()
		local ok, err = pcall(fn)
		if not ok then
			table.insert(errs, name .. ": " .. tostring(err))
		end
	end
	local t0 = os.clock()
	M.shrunk = {}
	-- the title and its windows
	step("title", function()
		if ui():screen() ~= "title" then
			session:start_title()
			wait_for(function()
				return ui():screen() == "title"
			end, 30)
		end
		scan("title")
	end)
	step("solo_menu", function()
		ui().title:open_solo_menu()
		scan("title.solo_menu")
		ui().title:close_solo_menu(true)
	end)
	step("party", function()
		local pp = ui().title._party
		local me = player
		local members = {}
		for i = 1, 8 do
			table.insert(members, {
				uid = if i == 1 then me.UserId else -i,
				name = if i == 1 then me.DisplayName else "Playername" .. i,
				leader = i == 1,
			})
		end
		pp:set_state({ members = members, max = 8, leader = true, invites = {} })
		pp._open = true
		pp:apply_layout()
		scan("party")
		local fakes = {}
		for i = 1, 30 do
			table.insert(fakes, { UserId = -i, DisplayName = "Player" .. i, Name = "Player" .. i })
		end
		local PP = require(client.UI:WaitForChild("PartyPanel")) :: any
		PP.fake_players = fakes
		pp:open_list()
		scan("party.invite")
		pp:close_list()
		PP.fake_players = nil
		pp._open = false
		pp:set_state(nil)
		pp:apply_layout()
	end)
	step("settings", function()
		ui():open_settings()
		scan("settings")
		ui().pause:close()
	end)
	step("locker", function()
		local Locker = require(client.UI:WaitForChild("Locker")) :: any
		ui():open_locker()
		for i = 1, #Locker.TABS do
			ui().locker._tab = i
			ui().locker:_rebuild()
			scan("locker." .. tostring(Locker.TABS[i][2] or i))
		end
		ui().locker:close()
	end)
	-- the Battle Pass: a reward dot's card on the title's bar (free, then premium), the window's two pages
	step("pass", function()
		local bar = ui().title._bp_bar
		for _, want in { { "free", 10 }, { "premium", 2 } } do
			for _, d in bar._dots do
				if d.track == want[1] and d.k == want[2] then
					bar:_show_card(d, true)
					bar._tip_until = os.clock() + 30
				end
			end
			scan("title.bp_card." .. want[1])
		end
		bar:_hide_card()
		ui():open_pass("missions")
		scan("pass.missions")
		if ui().pass._tabs.premium.visible then
			ui().pass:show_page("premium")
			scan("pass.premium")
		end
		ui().pass:close()
	end)
	step("ranks", function()
		local wr = ui().world_ranks
		ui():open_ranks()
		for _, t in { "rp", "time" } do
			if wr._tabs[t] ~= nil then
				wr._tab = t
				wr:_rebuild()
			end
			scan("ranks." .. t)
		end
		wr:close()
	end)
	step("help", function()
		ui():toggle_help()
		scan("help")
		for k = 1, 6 do
			ui().help:scroll_by(400)
			scan("help.scroll" .. k)
		end
		ui():toggle_help()
	end)
	step("next", function()
		ui():open_next_match("preview")
		scan("next.preview")
		ui().next_match:close()
	end)
	-- a solo match
	step("solo", function()
		ui():_on_play_solo(1)
		local ok = wait_for(function()
			return ui():screen() == "spawn" and not session:is_building() and session.state ~= nil
		end, 60)
		if not ok then
			error("no spawn screen")
		end
		task.wait(1.5)
		scan("spawn")
	end)
	step("play", function()
		local st = session.state
		session:send_intent({ type = "spawn", tile = free_tile(st) })
		local ok = wait_for(function()
			return ui():screen() == "play"
		end, 30)
		if not ok then
			error("no play screen")
		end
		task.wait(3)
		scan("hud")
	end)
	step("hud.menu", function()
		ui():open_pause_menu()
		scan("hud.game_menu")
		ui().pause:close()
	end)
	step("hud.board", function()
		ui():toggle_leaderboard()
		scan("hud.leaderboard")
		ui():toggle_leaderboard()
	end)
	step("hud.tray", function()
		if ui().bar.set_tray then
			ui().bar:set_tray(true)
			scan("hud.tray")
			ui().bar:set_tray(false)
		end
	end)
	step("hud.target", function()
		local st = session.state
		for _, want in { true, false } do
			local t = other_tile(st, want)
			if t >= 0 then
				ui().interact:on_click(t)
				scan(if want then "hud.target_nation" else "hud.target_land")
				ui().interact:cancel_aim(false)
				if ui().target_card.is_open then
					ui().target_card:hide_card()
				end
			end
		end
	end)
	step("hud.radial", function()
		local st = session.state
		local t = -1
		local map = st.map
		for k = 0, map.land_count - 1 do
			local x = map:land_tile(k)
			if st:tile_owner(x) == st.local_owner then
				t = x
				break
			end
		end
		local vp = ui().ctx.vp
		ui().interact:on_context(t, Vector2.new(vp.X * 0.5, vp.Y * 0.5))
		task.wait(0.5)
		local r = ui().radial
		if r.is_open then
			scan("hud.radial")
			for _, it in r.items do
				if it.sub ~= nil then
					local id = it.id
					r:_enter_sub(it)
					scan("hud.radial." .. tostring(id))
					break
				end
			end
			r:close(false)
		end
	end)
	step("tutorial", function()
		local tut = ui().tutorial
		local Data = require(RS.Battlemap.Data:WaitForChild("Tutorial")) :: any
		tut:begin()
		for i = 2, #Data.STEPS do
			tut._i = i
			tut:_say(i)
			scan("tutorial." .. tostring(Data.STEPS[i].id or i))
		end
		tut:stop("done")
		scan("tutorial.done")
		tut:_close()
	end)
	step("over", function()
		local st = session.state
		local sim = session:local_sim()
		local me = st.local_owner
		local killer = 0
		for _, r in st:ranking() do
			if r.id ~= me then
				killer = r.id
				break
			end
		end
		sim:_eliminate(me, killer)
		wait_for(function()
			return ui().over.is_open
		end, 10)
		task.wait(1.5)
		-- (with a Battle Pass XP pill, as a payout brings: Data/BattlePass)
		local award = table.clone(session.last_award or { lines = {}, total = 1440, balance = 4560, mode = "solo" })
		award.bp = { xp = 1250, from = 2400, to = 3650, missions = {}, grants = {} }
		ui().over:set_award(award)
		ui().over:apply_layout()
		scan("over")
		ui():open_next_match("first")
		scan("next.first")
		ui().next_match:close()
	end)
	step("back", function()
		session:start_title()
		wait_for(function()
			return ui():screen() == "title"
		end, 30)
	end)
	local un, ex = M.untranslated(Main)
	local head = {
		("# %s %s  vp %dx%d  scale %.2f  %d lines  %.0f s"):format(
			M.locale,
			M.view,
			ui().ctx.vp.X,
			ui().ctx.vp.Y,
			UITheme.scale,
			#lines,
			os.clock() - t0
		),
	}
	local cl = {}
	for k, v in counts do
		table.insert(cl, k .. "=" .. v)
	end
	table.sort(cl)
	table.insert(head, "# screens: " .. table.concat(cl, " "))
	if #errs > 0 then
		table.insert(head, "# errors: " .. table.concat(errs, " || "))
	end
	table.insert(head, ("# english text still shown (title only): %d %s"):format(un, table.concat(ex, ",")))
	local sk = {}
	for k in M.shrunk do
		table.insert(sk, k)
	end
	table.sort(sk)
	table.insert(head, ("# shrunk to fit: %d %s"):format(#sk, table.concat(sk, " ")))
	local rep = table.concat(head, "\n") .. "\n" .. table.concat(lines, "\n")
	log(rep)
	return rep
end

function M.start_tour(Main: any): string
	local player = Players.LocalPlayer
	player:SetAttribute("af_loc_state", "running")
	player:SetAttribute("af_loc_report", "")
	task.spawn(function()
		local ok, rep = pcall(M.tour, Main)
		player:SetAttribute("af_loc_report", if ok then rep else "tour error: " .. tostring(rep))
		player:SetAttribute("af_loc_state", "done")
	end)
	return "tour started"
end

return M
