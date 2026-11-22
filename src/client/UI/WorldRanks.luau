--!nonstrict
-- Leaderboards (2026-11-04): the global leaderboards (Data/Ranks, server/Ranks), a modal from the title, two
-- tabs: Rank Points (your tier and RP, then the top Ranks.SHOW_N) and Playtime (time played in matches, from
-- the end of placement to being eliminated, leaving or winning). Separate from a match's own leaderboard
-- (UI/Leaderboard), whose look the rows share (2026-11-05): medals for the first three, each player's avatar
-- picture with its frame and badge and their name in their name font (Data/Cosmetics; the server sends what
-- the rows on screen wear), the rank tier in its own column; your row in amber, among the top or pinned
-- below them (Ranks.board: an empty board puts you first).
-- Asks the server on open (Session.request_ranks) and shows what it answers (Session.ranks_changed).
-- Signals: closed.
local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local Loc = UITheme.core("Loc")
local L = Loc.t
local Signal = UITheme.core("Signal")

local IS_ROBLOX = typeof(game) == "Instance"
local Ranks: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Ranks)
	else (require :: any)("../../shared/Data/Ranks")
local Cosmetics: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Cosmetics)
	else (require :: any)("../../shared/Data/Cosmetics")

local WorldRanks = W.class(W.Control)

WorldRanks.LIST_SIZE = Vector2.new(560, 500)
WorldRanks.ROW_H = 38
WorldRanks.ROW_GAP = 3
WorldRanks.CAPTION_H = 22
--- the "···" above a pinned row
WorldRanks.PIN_SEP_H = 16

local FONT = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Bold)
local FONT_M = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Medium)
local FONT_X = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.ExtraBold)

--- The first three's medals: { face, rim, ribbon }.
WorldRanks.MEDALS = {
	{ 0xFFD24A, 0xB8860B, 0xE0484F },
	{ 0xE3E8EF, 0x8E99A8, 0x4A7BD8 },
	{ 0xE0955A, 0x8C5226, 0x3FAE6A },
}

local function c3(hex: number): Color3
	return Color3.fromRGB((hex // 65536) % 256, (hex // 256) % 256, hex % 256)
end

local function commas(n: number): string
	local s = tostring(math.floor(n))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end

--- The columns of board `tab` ("rp" | "time"): name -> { x scale, x px, width scale, width px, align }.
local function columns(tab: string): { [string]: any }
	local L_, R_, C_ = Enum.TextXAlignment.Left, Enum.TextXAlignment.Right, Enum.TextXAlignment.Center
	if tab == "time" then
		return {
			place = { 0, 6, 0, 32, C_ },
			face = { 0, 48, 0, 26, L_ },
			name = { 0, 84, 0.7, -84, L_ },
			value = { 0.7, 0, 0.3, -12, R_ },
		}
	end
	return {
		place = { 0, 6, 0, 32, C_ },
		face = { 0, 48, 0, 26, L_ },
		name = { 0, 84, 0.54, -84, L_ },
		tier = { 0.54, 8, 0.24, -8, L_ },
		value = { 0.78, 0, 0.22, -12, R_ },
	}
end

function WorldRanks.new(c: any)
	local self = setmetatable({}, WorldRanks.__mt)
	W.Control._init(self)
	self.ctx = c
	self.closed = Signal.new()
	self.is_open = false
	self._rows = {}
	self._tab = "rp"
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:set_mouse_filter(W.MOUSE_STOP)
	self:set_visible(false)
	self._dim = W.ColorRect.new(UITheme.rgba(0.01, 0.015, 0.05, 0.78))
	self._dim:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self._dim.gui_input:Connect(function(e)
		if e.pressed and not self._panel:has_global_point(e.global_position) then
			self:close()
		end
	end)
	self:add_child(self._dim)
	self._panel = GlassPanel.new(22.0, 20.0, 18, true, 34)
	self._panel:set_tint(UITheme.rgba(0.045, 0.065, 0.13, 0.96))
	self:add_child(self._panel)
	local v = UITheme.vbox(10)
	self._v = v
	self._panel:add_child(v)
	local head = UITheme.hbox(12)
	head:add_child(UITheme.icon_rect("leaderboard", 18.0, UITheme.AMBER))
	local title = UITheme.label(L("worldranks.leaderboards"), 20, 800, UITheme.TEXT, 3)
	title.size_flags_vertical = W.SHRINK_CENTER
	title.size_flags_horizontal = W.EXPAND_FILL
	head:add_child(title)
	local close = W.Button.new("", "GhostButton")
	close:set_icon("close")
	close.expand_icon = true
	close:set_min_size(Vector2.new(34, 34))
	close:add_theme_constant_override("icon_max_width", 13)
	close:add_theme_stylebox_override("normal", UITheme.empty_box(8, 8))
	close:add_theme_stylebox_override("hover", UITheme.flat(UITheme.FILL, 8, UITheme.CLEAR, 0, 8, 8))
	close.size_flags_vertical = W.SHRINK_CENTER
	close.pressed:Connect(function()
		self:close()
	end)
	head:add_child(close)
	v:add_child(head)
	-- the two boards
	local tabs = UITheme.hbox(6)
	self._tabs = {}
	for _, t in { { L("worldranks.rank_points"), "rp" }, { L("worldranks.playtime"), "time" } } do
		local chip = UITheme.button(t[1], "ChipButton", "", 32.0)
		chip.toggle_mode = true
		chip:set_font_size(12)
		chip:set_pressed_no_signal(t[2] == self._tab)
		chip.pressed:Connect(function()
			self._tab = t[2]
			for k, ch in self._tabs do
				ch:set_pressed_no_signal(k == t[2])
			end
			self:_rebuild()
		end)
		self._tabs[t[2]] = chip
		tabs:add_child(chip)
	end
	v:add_child(tabs)
	-- you: tier, RP, ranked matches
	self._me = UITheme.label("", 14, 700, UITheme.AMBER)
	v:add_child(self._me)
	self._next = UITheme.label("", 12, 500, UITheme.TEXT_2)
	v:add_child(self._next)
	local host = W.Control.new()
	host:set_min_size(WorldRanks.LIST_SIZE)
	host:set_mouse_filter(W.MOUSE_PASS)
	self._host = host
	v:add_child(host)
	-- the column headings (filled by _rebuild: they change with the board)
	local caps = Instance.new("Frame")
	caps.Name = "Captions"
	caps.BackgroundTransparency = 1
	caps.ZIndex = 41
	caps.Parent = host.gui
	self._caps = caps
	local line = Instance.new("Frame")
	line.Name = "Divider"
	line.BorderSizePixel = 0
	line.BackgroundColor3 = Color3.new(1, 1, 1)
	line.ZIndex = 41
	line.Parent = host.gui
	host:_part(line, "BackgroundTransparency", 0.1)
	self._line = line
	local sf = Instance.new("ScrollingFrame")
	sf.Name = "RanksList"
	sf.BackgroundTransparency = 1
	sf.BorderSizePixel = 0
	sf.ScrollBarThickness = 6
	sf.ScrollBarImageColor3 = Color3.new(1, 1, 1)
	sf.ScrollBarImageTransparency = 0.6
	sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sf.CanvasSize = UDim2.new()
	sf.ScrollingDirection = Enum.ScrollingDirection.Y
	sf.ZIndex = 40
	sf.Parent = host.gui
	host:_part(sf, "ScrollBarImageTransparency", 0.4)
	self._sf = sf
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, WorldRanks.ROW_GAP)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Parent = sf
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = sf
	-- your row when you aren't among the top: always in sight below them
	local pin = Instance.new("Frame")
	pin.Name = "Pinned"
	pin.BackgroundTransparency = 1
	pin.AnchorPoint = Vector2.new(0, 1)
	pin.Position = UDim2.fromScale(0, 1)
	pin.ZIndex = 41
	pin.Visible = false
	pin.Parent = host.gui
	self._pin = pin
	self._foot = UITheme.label(L("worldranks.rank_points_come_from"), 11, 500, UITheme.TEXT_3)
	self._foot.autowrap = true
	v:add_child(self._foot)
	return self
end

function WorldRanks.bind(self, s: any)
	if s == nil or self._bound == s then
		return
	end
	self._bound = s
	if s.ranks_changed then
		s.ranks_changed:Connect(function()
			if self.is_open then
				self:_rebuild()
			end
		end)
	end
end

--- Every transparency under `root` follows the list's fade (as it is now).
function WorldRanks._fade_all(self, root: Instance)
	local host = self._host
	for _, d in { root, table.unpack(root:GetDescendants()) } do
		if d:IsA("TextLabel") then
			host:_part(d, "TextTransparency", 1 - d.TextTransparency)
		elseif d:IsA("ImageLabel") then
			host:_part(d, "ImageTransparency", 1 - d.ImageTransparency)
		elseif d:IsA("UIStroke") then
			host:_part(d, "Transparency", 1 - d.Transparency)
		end
		if d:IsA("GuiObject") and d.BackgroundTransparency < 1 then
			host:_part(d, "BackgroundTransparency", 1 - d.BackgroundTransparency)
		end
	end
end

local function text(parent: Instance, str: string, col: any, font: Font, size: number, color: Color3): TextLabel
	local s = UITheme.scale
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.FontFace = font
	l.TextSize = math.floor(size * s)
	l.TextColor3 = color
	l.TextXAlignment = col[5]
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Text = str
	l.Position = UDim2.new(col[1], math.floor(col[2] * s), 0, 0)
	l.Size = UDim2.new(col[3], math.floor(col[4] * s), 1, 0)
	l.ZIndex = 42
	l.Parent = parent
	return l
end

--- Place 1..3's medal (a coin on two ribbon tails) in column `col` of `parent`.
function WorldRanks._medal(self, parent: Instance, place: number, col: any)
	local s = UITheme.scale
	local m = WorldRanks.MEDALS[place]
	local box = Instance.new("Frame")
	box.Name = "Medal"
	box.BackgroundTransparency = 1
	box.Position = UDim2.new(col[1], math.floor(col[2] * s), 0, 0)
	box.Size = UDim2.new(col[3], math.floor(col[4] * s), 1, 0)
	box.ZIndex = 42
	box.Parent = parent
	local d = math.floor(22 * s)
	for k, rot in { -24, 24 } do
		local tail = Instance.new("Frame")
		tail.BorderSizePixel = 0
		tail.BackgroundColor3 = c3(m[3])
		tail.AnchorPoint = Vector2.new(0.5, 1)
		tail.Position = UDim2.new(0.5, math.floor((k == 1 and -4 or 4) * s), 0.5, math.floor(2 * s))
		tail.Size = UDim2.fromOffset(math.floor(6 * s), math.floor(14 * s))
		tail.Rotation = rot
		tail.ZIndex = 42
		tail.Parent = box
	end
	local coin = Instance.new("Frame")
	coin.BorderSizePixel = 0
	coin.BackgroundColor3 = Color3.new(1, 1, 1)
	coin.AnchorPoint = Vector2.new(0.5, 0.5)
	coin.Position = UDim2.new(0.5, 0, 0.5, math.floor(3 * s))
	coin.Size = UDim2.fromOffset(d, d)
	coin.ZIndex = 43
	coin.Parent = box
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0.5, 0)
	cc.Parent = coin
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(c3(m[1]), c3(m[2]))
	g.Rotation = 90
	g.Parent = coin
	local st = Instance.new("UIStroke")
	st.Color = c3(m[2])
	st.Thickness = math.max(1, math.floor(1.5 * s))
	st.Parent = coin
	local n = Instance.new("TextLabel")
	n.BackgroundTransparency = 1
	n.FontFace = FONT_X
	n.TextSize = math.floor(12 * s)
	n.TextColor3 = Color3.fromRGB(40, 30, 10)
	n.Text = tostring(place)
	n.Size = UDim2.fromScale(1, 1)
	n.ZIndex = 44
	n.Parent = coin
end

--- One board row: `place` (nil: below the whole list), row `r` ({ uid, name, rp | secs, tier?, cz? }), in
--- `parent` at `order`; `mine` in amber.
function WorldRanks._row(self, parent: Instance, order: number, place: number?, r: any, mine: boolean)
	local s = UITheme.scale
	local T = UITheme
	local cols = columns(self._tab)
	local f = Instance.new("Frame")
	f.Name = "Row" .. order
	f.LayoutOrder = order
	f.BorderSizePixel = 0
	f.BackgroundColor3 = if mine then T.AMBER else Color3.new(1, 1, 1)
	f.BackgroundTransparency = if mine then 0.88 else (if order % 2 == 0 then 0.975 else 1)
	f.Size = UDim2.new(1, -math.floor(10 * s), 0, math.floor(WorldRanks.ROW_H * s))
	f.ZIndex = 41
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, math.floor(8 * s))
	corner.Parent = f
	if mine then
		local st = Instance.new("UIStroke")
		st.Color = T.AMBER
		st.Transparency = 0.6
		st.Thickness = 1
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = f
	end
	-- the place: a medal for the first three
	if place ~= nil and place <= 3 then
		self:_medal(f, place, cols.place)
	else
		local p = if place ~= nil then tostring(place) else tostring(Ranks.TOP_N) .. "+"
		text(f, p, cols.place, FONT, 13, if mine then T.AMBER_HI else T.TEXT_3)
	end
	-- the avatar picture: their icon (or head shot), frame and badge
	local cz = r.cz or { face = if (r.uid or 0) > 0 then r.uid else 0 }
	local fc = cols.face
	local d = math.floor(fc[4] * s)
	local img = Instance.new("ImageLabel")
	img.Name = "Avatar"
	img.BackgroundColor3 = Color3.fromRGB(40, 52, 82)
	img.BorderSizePixel = 0
	img.ScaleType = Enum.ScaleType.Fit
	img.AnchorPoint = Vector2.new(0, 0.5)
	img.Position = UDim2.new(fc[1], math.floor(fc[2] * s), 0.5, 0)
	img.Size = UDim2.fromOffset(d, d)
	img.ZIndex = 42
	img.Parent = f
	local ic = Instance.new("UICorner")
	ic.CornerRadius = UDim.new(0.5, 0)
	ic.Parent = img
	Cosmetics.dress_picture(img, cz)
	-- the name, in their name font
	local nm = text(
		f,
		r.name or "?",
		cols.name,
		Cosmetics.font_face(cz.font) or FONT,
		14,
		if mine then T.AMBER_HI else T.TEXT
	)
	nm.Name = "Name"
	if self._tab == "time" then
		text(f, WorldRanks.fmt_time(r.secs or 0), cols.value, FONT, 13, T.TEXT)
	else
		local t = Ranks.by_id(r.tier) or Ranks.TIERS[1]
		text(f, Loc.text(t.name), cols.tier, FONT_M, 13, c3(t.color))
		text(f, commas(r.rp or 0), cols.value, FONT, 13, T.TEXT)
	end
	f.Parent = parent
	self:_fade_all(f)
	table.insert(self._rows, f)
	return f
end

--- 12345 s -> "3h 25m" (under an hour: "25m"; under a minute: "0m").
function WorldRanks.fmt_time(secs: number): string
	local m = math.floor((tonumber(secs) or 0) / 60)
	local h = m // 60
	return if h > 0
		then L("time.hm", { h = h, m = string.format("%02d", m % 60) })
		else L("time.m", { m = m })
end

--- The column headings of the board on show.
function WorldRanks._captions(self)
	local s = UITheme.scale
	for _, ch in self._caps:GetChildren() do
		self._host:_drop_part(ch)
		ch:Destroy()
	end
	local cols = columns(self._tab)
	local function cap(str: string, col: any)
		local l = text(self._caps, str, col, FONT, 10, UITheme.TEXT_3)
		self._host:_part(l, "TextTransparency", 1.0)
	end
	cap("#", cols.place)
	-- (the player heading spans the picture and the name)
	local who = table.clone(cols.face)
	who[3], who[4] = cols.name[1] + cols.name[3], cols.name[2] + cols.name[4] - cols.face[2]
	cap(Loc.upper(L("worldranks.col_player")), who)
	if self._tab == "time" then
		cap(Loc.upper(L("worldranks.col_time")), cols.value)
	else
		cap(Loc.upper(L("worldranks.col_rank")), cols.tier)
		cap(Loc.upper(L("worldranks.col_rp")), cols.value)
	end
	local ch = math.floor(WorldRanks.CAPTION_H * s)
	self._caps.Size = UDim2.new(1, -math.floor(10 * s), 0, ch)
	self._caps.Position = UDim2.fromOffset(math.floor(5 * s), 0)
	self._line.Size = UDim2.new(1, -math.floor(10 * s), 0, 1)
	self._line.Position = UDim2.fromOffset(math.floor(5 * s), ch)
end

function WorldRanks._clear(self)
	for _, f in self._rows do
		self._host:_drop_part(f)
		for _, d in f:GetDescendants() do
			self._host:_drop_part(d)
		end
		f:Destroy()
	end
	table.clear(self._rows)
	for _, ch in self._pin:GetChildren() do
		self._host:_drop_part(ch)
		ch:Destroy()
	end
end

--- The rows of board `list` (key "rp" | "secs") with you (`me`), and your pinned row when you aren't
--- among them.
function WorldRanks._fill(self, list: { any }, me: any, key: string)
	local s = UITheme.scale
	local rows, pin = Ranks.board(list, me, key, Ranks.SHOW_N)
	for i, x in rows do
		local r = x.row
		if x.mine and r.cz == nil then
			r = table.clone(r)
			r.cz = me.cz
		end
		self:_row(self._sf, i, x.place, r, x.mine)
	end
	local row_h = math.floor(WorldRanks.ROW_H * s)
	local ch = math.floor(WorldRanks.CAPTION_H * s) + 1
	local pin_h = 0
	if pin ~= nil then
		pin_h = math.floor(WorldRanks.PIN_SEP_H * s) + row_h + math.floor(4 * s)
		local sep = Instance.new("TextLabel")
		sep.BackgroundTransparency = 1
		sep.FontFace = FONT
		sep.TextSize = math.floor(12 * s)
		sep.TextColor3 = UITheme.TEXT_3
		sep.Text = "···"
		sep.Size = UDim2.new(1, 0, 0, math.floor(WorldRanks.PIN_SEP_H * s))
		sep.ZIndex = 42
		sep.Parent = self._pin
		self._host:_part(sep, "TextTransparency", 1.0)
		local r = table.clone(pin.row)
		r.cz = r.cz or me.cz
		local f = self:_row(self._pin, 1, pin.place, r, true)
		f.AnchorPoint = Vector2.new(0.5, 1)
		f.Position = UDim2.new(0.5, 0, 1, 0)
	end
	self._pin.Visible = pin ~= nil
	self._pin.Size = UDim2.new(1, 0, 0, pin_h)
	self._sf.Position = UDim2.fromOffset(0, ch)
	self._sf.Size = UDim2.new(1, 0, 1, -(ch + pin_h))
end

function WorldRanks._rebuild(self)
	self:_clear()
	self:_captions()
	local s = self.ctx.session
	local data = if s ~= nil then s.ranks else nil
	if data == nil then
		self._me:set_text(L("worldranks.loading"))
		self._next:set_text("")
		self._pin.Visible = false
		return
	end
	local me = data.me or {}
	local my_uid = if IS_ROBLOX then game:GetService("Players").LocalPlayer.UserId else 0
	local my_name = me.name
	if my_name == nil and IS_ROBLOX then
		my_name = game:GetService("Players").LocalPlayer.Name
	end
	local my_cz = me.cz or { face = my_uid }
	self._foot:set_text(
		if self._tab == "time"
			then L("worldranks.playtime_counts_every_match")
			else L("worldranks.rank_points_come_from")
	)
	if self._tab == "time" then
		self._me:set_text(
			L("worldranks.you_played", { t = WorldRanks.fmt_time(me.play_s or 0) })
				.. (if me.time_place ~= nil then "  ·  #" .. me.time_place else "")
		)
		self._next:set_text(if #(data.top_time or {}) == 0 then L("worldranks.nobody_on_the_board") else "")
		self:_fill(data.top_time or {}, { uid = my_uid, name = my_name, secs = me.play_s or 0, cz = my_cz }, "secs")
		return
	end
	local t = Ranks.by_id(me.tier) or Ranks.TIERS[1]
	self._me:set_text(L("worldranks.you_rp", {
		tier = Loc.text(t.name),
		rp = commas(me.rp or 0),
		place = if me.place ~= nil then "  ·  #" .. me.place else "",
		n = me.matches or 0,
		won = me.wins or 0,
	}))
	-- the next tier up
	local up = nil
	for _, x in Ranks.TIERS do
		if x.id ~= "grandmaster" and x.rp > (me.rp or 0) then
			up = x
			break
		end
	end
	self._next:set_text(
		if up ~= nil
			then L("worldranks.rp_to", { rp = commas(up.rp - (me.rp or 0)), tier = Loc.text(up.name) })
			elseif t.id ~= "grandmaster" then L("worldranks.reach_top", { n = Ranks.TOP_N })
			else L("worldranks.gm_top", { n = Ranks.TOP_N })
	)
	if #(data.top or {}) == 0 then
		self._next:set_text(self._next.text .. "  ·  " .. L("worldranks.nobody_ranked"))
	end
	self:_fill(data.top or {}, { uid = my_uid, name = my_name, rp = me.rp or 0, tier = t.id, cz = my_cz }, "rp")
end

function WorldRanks.open(self)
	if self.is_open then
		return
	end
	self.is_open = true
	local s = self.ctx.session
	if s ~= nil and type(s.request_ranks) == "function" then
		s:request_ranks()
	end
	self:_rebuild()
	self:set_visible(true)
	self:apply_layout()
	self._panel:set_modulate_a(1.0)
	self._dim:set_modulate_a(0.0)
	W.fade(self._dim, 1.0, 0.2)
	UICtx.pop_in(self._panel, 0.0, 0.94, 0.3)
	self.ctx:sfx("open")
end

function WorldRanks.close(self)
	if not self.is_open then
		return
	end
	self.is_open = false
	self.ctx:sfx("close")
	local t = self:create_tween():set_parallel(true)
	t:tween_property(self._dim, "modulate:a", 0.0, 0.15)
	t:tween_property(self._panel, "modulate:a", 0.0, 0.15)
	t:chain():tween_callback(function()
		if not self.is_open then
			self:set_visible(false)
		end
	end)
	self.closed:Fire()
end

function WorldRanks.apply_layout(self)
	local ctx = self.ctx
	local area = ctx:clear_rect()
	local compact = ctx.compact
	self._foot:set_visible(not compact)
	self._panel:set_padding(
		if compact then 14 else 22,
		if compact then 10 else 20,
		if compact then 14 else 22,
		if compact then 10 else 20
	)
	local gw = math.clamp(area.Width - 80, 300, WorldRanks.LIST_SIZE.X)
	-- (compact: 152 leaves room for the pinned own row on a 390 px-tall phone; 140 put it 12 px off screen)
	local gh = math.clamp(area.Height - (if compact then 152 else 200), 160, WorldRanks.LIST_SIZE.Y)
	self._host:set_min_size(Vector2.new(gw, gh))
	self._foot:set_min_size(Vector2.new(gw, 0))
	local sz = self._panel:get_combined_minimum_size()
	local p = area.Min + (Vector2.new(area.Width, area.Height) - sz) * 0.5
	local y = math.max(p.Y, area.Min.Y + 4.0)
	local rp = Vector2.new(math.floor(p.X + 0.5), math.floor(y + 0.5))
	self._panel:set_offsets(rp.X, rp.Y, rp.X, rp.Y)
	self._panel:reset_size()
end

return WorldRanks
