--!nonstrict
-- Today's daily missions (2026-11-18; Data/Missions), always open on the right of the title screen (TitleScreen
-- places it): the five (2 easy, 2 medium, 1 hard), each with its difficulty (colour and label), its text ("Public
-- matches only" under one a solo match can't count), its progress and its XP, and the time until the next
-- day's. Phones: a narrower card, the XP under the difficulty, the progress as the bar alone.
-- (Its own rows, not BattlePassPanel's: the window and the card change apart.)
local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local View = require("./BattlePassView")
local Loc = UITheme.core("Loc")
local L = Loc.t

local Card = W.class(W.Control)

--- The card's width (logical px), desktop / phones.
Card.WIDTH = 360
Card.WIDTH_COMPACT = 270

local function make(class: string, props: { [string]: any }, parent: Instance?): any
	local i = Instance.new(class)
	for k, v in props do
		(i :: any)[k] = v
	end
	if parent ~= nil then
		i.Parent = parent
	end
	return i
end

--- A thin progress bar: `frac` 0..1 in `color`, `h` px tall.
local function progress(frac: number, color: Color3, h: number): any
	local c = W.Control.new()
	c:set_mouse_filter(W.MOUSE_IGNORE)
	c:set_min_size(Vector2.new(40, h))
	c.size_flags_horizontal = W.EXPAND_FILL
	local rail = make("Frame", { BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1) }, c.gui)
	make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, rail)
	c:_part(rail, "BackgroundTransparency", 0.1)
	local fill = make("Frame", { BorderSizePixel = 0, BackgroundColor3 = color, Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1) }, rail)
	make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, fill)
	c:_part(fill, "BackgroundTransparency", if frac > 0 then 1.0 else 0.0)
	return c
end

function Card.new(c: any)
	local self = setmetatable({}, Card.__mt)
	W.Control._init(self)
	self.ctx = c
	self._tick = 0.0
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self._panel = GlassPanel.new(14.0, 12.0, 14, true, 18)
	self._panel:set_mouse_filter(W.MOUSE_IGNORE)
	-- (sized to its rows: Card._fit)
	self._panel.anchor_left, self._panel.anchor_top, self._panel.anchor_right, self._panel.anchor_bottom = 0, 0, 0, 0
	self._panel.grow_horizontal = W.GROW_END
	self._panel.grow_vertical = W.GROW_END
	self:add_child(self._panel)
	local v = UITheme.vbox(6)
	self._v = v
	self._panel:add_child(v)
	local head = UITheme.hbox(8)
	self._cap = UITheme.caption(L("bp.daily_missions"), 11, UITheme.CYAN)
	self._cap.size_flags_horizontal = W.EXPAND_FILL
	self._cap.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._cap)
	self._reset = UITheme.label("", 11, 600, UITheme.TEXT_3)
	self._reset.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._reset)
	v:add_child(head)
	self._list = UITheme.vbox(4)
	v:add_child(self._list)
	self:set_process(true)
	return self
end

--- One mission row.
function Card._row(self, m: any): any
	local BP = UICtx.data("BattlePass")
	local Missions = UICtx.data("Missions")
	local cp = self.ctx.compact
	local x = m.m
	local col = View.DIFF_COLORS[x.diff] or UITheme.TEXT_2
	local row = W.Panel.new()
	row:set_mouse_filter(W.MOUSE_IGNORE)
	row:add_theme_stylebox_override(
		"panel",
		UITheme.flat(
			if m.done then UITheme.c(UITheme.GREEN, 0.08) else UITheme.FILL,
			UITheme.R_SM,
			if m.done then UITheme.c(UITheme.GREEN, 0.4) else UITheme.LINE,
			1,
			8.0,
			if cp then 3.0 else 5.0
		)
	)
	local h = UITheme.hbox(8)
	row:add_child(h)
	-- the difficulty (and, on phones, the XP under it)
	local left = UITheme.vbox(1)
	left.size_flags_vertical = W.SHRINK_CENTER
	local chip = W.Panel.new()
	chip:set_mouse_filter(W.MOUSE_IGNORE)
	chip:add_theme_stylebox_override("panel", UITheme.flat(UITheme.c(col, 0.16), 999, UITheme.c(col, 0.6), 1, 6.0, 1.0))
	chip:set_min_size(Vector2.new(if cp then 58 else 62, 0))
	local cl = UITheme.label(Loc.upper(L("bp.diff." .. x.diff)), 10, 800, col, 1)
	cl:set_alignment(W.ALIGN_CENTER)
	chip:add_child(cl)
	left:add_child(chip)
	local xp_text = L("bp.xp_gain", { n = BP.BpMissionXp[x.diff] or 0 })
	if cp then
		local xp = UITheme.label(xp_text, 11, 800, UITheme.GOLD)
		xp:set_alignment(W.ALIGN_CENTER)
		left:add_child(xp)
	end
	h:add_child(left)
	-- the text, public only, the progress
	local mid = UITheme.vbox(2)
	mid.size_flags_horizontal = W.EXPAND_FILL
	local text = View.mission_text(x)
	if cp and Missions.public_only(x) then
		text = text .. "  ·  " .. L("bp.public_only")
	end
	local t = UITheme.label(text, if cp then 11 else 13, 600, if m.done then UITheme.TEXT_2 else UITheme.TEXT)
	t:set_autowrap(true)
	t.size_flags_horizontal = W.EXPAND_FILL
	mid:add_child(t)
	if not cp and Missions.public_only(x) then
		mid:add_child(UITheme.label(L("bp.public_only"), 10, 600, UITheme.TEXT_3))
	end
	mid:add_child(progress(m.n / math.max(x.goal, 1), if m.done then UITheme.GREEN else col, if cp then 3 else 4))
	h:add_child(mid)
	if not cp then
		local right = UITheme.vbox(1)
		right.size_flags_vertical = W.SHRINK_CENTER
		right:set_min_size(Vector2.new(70, 0))
		local xp = UITheme.label(xp_text, 12, 800, UITheme.GOLD)
		xp:set_alignment(W.ALIGN_RIGHT)
		right:add_child(xp)
		local n = UITheme.label(
			if m.done then L("bp.done") else UICtx.commas(m.n) .. " / " .. UICtx.commas(x.goal),
			10,
			700,
			if m.done then UITheme.GREEN else UITheme.TEXT_2
		)
		n:set_alignment(W.ALIGN_RIGHT)
		n:set_tabular(true)
		right:add_child(n)
		h:add_child(right)
	elseif m.done then
		local ok = UITheme.icon_rect("check", 14.0, UITheme.GREEN)
		ok.size_flags_vertical = W.SHRINK_CENTER
		h:add_child(ok)
	end
	return row
end

--- Reads today's missions again (the inventory changed, the layout changed).
function Card.refresh(self)
	for _, ch in table.clone(self._list:get_children()) do
		self._list:remove_child(ch)
		ch:queue_free()
	end
	local st = View.state(self.ctx.session)
	self._st = st
	for _, m in st.missions do
		self._list:add_child(self:_row(m))
	end
	self:_refresh_timer()
	self:_fit()
	-- (again once laid out: wrapped texts know their width then)
	W.defer(function()
		self:_fit()
	end)
end

--- The card as tall as its rows.
function Card._fit(self)
	local p = self._panel
	p.offset_left, p.offset_top, p.offset_right, p.offset_bottom = 0, 0, 0, 0
	p:reset_size()
end

function Card._refresh_timer(self)
	local st = self._st
	if st == nil then
		return
	end
	local next_day = (st.day + 1) * 86400
	self._reset:set_text(L("bp.new_missions_in", { t = View.fmt_left(next_day - st.now()) }))
end

function Card.apply_layout(self)
	local cp = self.ctx.compact
	self._panel:set_padding(if cp then 8 else 14, if cp then 6 else 12, if cp then 8 else 14, if cp then 6 else 12)
	self._v:set_separation(if cp then 4 else 6)
	self._list:set_separation(if cp then 3 else 4)
	self._panel:set_min_size(Vector2.new(if cp then Card.WIDTH_COMPACT else Card.WIDTH, 0))
	self:refresh()
end

--- (a free control: its size is its card's)
function Card._get_minimum_size(self): Vector2
	return self._panel:get_combined_minimum_size()
end

function Card.width(self): number
	return if self.ctx.compact then Card.WIDTH_COMPACT else Card.WIDTH
end

function Card._process(self, delta: number)
	self._tick += delta
	if self._tick >= 1.0 then
		self._tick = 0.0
		self:_refresh_timer()
	end
end

return Card
