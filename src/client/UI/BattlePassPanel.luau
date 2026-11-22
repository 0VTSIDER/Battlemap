--!nonstrict
-- The Battle Pass window (2026-11-18), a modal over the title (from the bar: UI/BattlePassBar): the season, its
-- days left, the level, and two pages:
--   missions  today's daily missions (Data/Missions: 2 easy, 2 medium, 1 hard): each one's difficulty (colour
--             and label), text ("Public matches only" under one a solo match can't count), progress and XP,
--             and the time until the next day's missions
--   premium   the offer (Data/Products.bp_premium): its Robux price, the days left, what it unlocks (the
--             season's premium skin, frame and avatar; twice the Stars; what is reached already comes at once)
-- Signals: closed.
local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local View = require("./BattlePassView")
local Loc = UITheme.core("Loc")
local L = Loc.t
local Signal = UITheme.core("Signal")

local Panel = W.class(W.Control)

--- The page area (logical px), desktop.
Panel.PAGE_SIZE = Vector2.new(560, 420)

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

--- A thin progress bar (a W control drawing two raw frames): `frac` 0..1 in `color`.
local function progress(frac: number, color: Color3, h: number): any
	local c = W.Control.new()
	c:set_mouse_filter(W.MOUSE_IGNORE)
	c:set_min_size(Vector2.new(60, h))
	c.size_flags_horizontal = W.EXPAND_FILL
	local rail = make("Frame", { BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1) }, c.gui)
	make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, rail)
	c:_part(rail, "BackgroundTransparency", 0.1)
	local fill = make("Frame", {
		BorderSizePixel = 0,
		BackgroundColor3 = color,
		Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1),
	}, rail)
	make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, fill)
	c:_part(fill, "BackgroundTransparency", if frac > 0 then 1.0 else 0.0)
	return c
end

function Panel.new(c: any)
	local self = setmetatable({}, Panel.__mt)
	W.Control._init(self)
	self.ctx = c
	self.closed = Signal.new()
	self.is_open = false
	self._page = "missions"
	self._tick = 0.0
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
	-- the head: the season, its days left, close
	local head = UITheme.hbox(12)
	head:add_child(UITheme.icon_rect("crown", 18.0, UITheme.AMBER))
	local names = UITheme.vbox(0)
	names.size_flags_horizontal = W.EXPAND_FILL
	self._caption = UITheme.caption(L("bp.battle_pass"), 11, UITheme.AMBER)
	names:add_child(self._caption)
	self._title = UITheme.label("", 20, 800, UITheme.TEXT, 2)
	names:add_child(self._title)
	head:add_child(names)
	self._days = UITheme.label("", 12, 600, UITheme.TEXT_2)
	self._days.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._days)
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
	self._close_btn = close
	head:add_child(close)
	v:add_child(head)
	-- the level
	local lr = UITheme.hbox(10)
	self._level = UITheme.label("", 14, 800, UITheme.AMBER)
	self._level.size_flags_vertical = W.SHRINK_CENTER
	lr:add_child(self._level)
	self._lv_host = UITheme.hbox(0)
	self._lv_host.size_flags_horizontal = W.EXPAND_FILL
	self._lv_host.size_flags_vertical = W.SHRINK_CENTER
	lr:add_child(self._lv_host)
	self._xp = UITheme.label("", 12, 600, UITheme.TEXT_2)
	self._xp:set_tabular(true)
	self._xp.size_flags_vertical = W.SHRINK_CENTER
	lr:add_child(self._xp)
	v:add_child(lr)
	-- the pages
	local tabs = UITheme.hbox(6)
	self._tabs = {}
	for _, t in { { L("bp.tab_missions"), "missions" }, { L("bp.tab_premium"), "premium" } } do
		local chip = UITheme.button(t[1], "ChipButton", "", 32.0)
		chip.toggle_mode = true
		chip:set_font_size(12)
		chip.pressed:Connect(function()
			self:show_page(t[2])
		end)
		self._tabs[t[2]] = chip
		tabs:add_child(chip)
	end
	v:add_child(tabs)
	local host = UITheme.vbox(8)
	host:set_min_size(Panel.PAGE_SIZE)
	self._host = host
	v:add_child(host)
	self._foot = UITheme.label("", 12, 600, UITheme.TEXT_2)
	self._foot:set_alignment(W.ALIGN_CENTER)
	v:add_child(self._foot)
	self:set_process(true)
	return self
end

function Panel.bind(self, s: any)
	if s == nil or self._bound == s then
		return
	end
	self._bound = s
	if s.inventory_changed then
		s.inventory_changed:Connect(function()
			if self.is_open then
				self:_rebuild()
			end
		end)
	end
end

--- Opens on page `page` ("missions" | "premium").
function Panel.open(self, page: string?)
	self._page = if page == "premium" and View.premium_offered() then "premium" else "missions"
	if self.is_open then
		self:_rebuild()
		return
	end
	self.is_open = true
	pcall(function()
		UICtx.mod("Prices").fetch()
	end)
	self:_rebuild()
	self:set_visible(true)
	self:apply_layout()
	self._panel:set_modulate_a(1.0)
	self._dim:set_modulate_a(0.0)
	W.fade(self._dim, 1.0, 0.2)
	UICtx.pop_in(self._panel, 0.0, 0.94, 0.3)
	self.ctx:sfx("open")
end

function Panel.show_page(self, page: string)
	self._page = page
	self:_rebuild()
	self:apply_layout()
end

function Panel.close(self)
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

function Panel._clear(self)
	for _, ch in self._host:get_children() do
		ch:queue_free()
	end
	for _, ch in self._lv_host:get_children() do
		ch:queue_free()
	end
end

function Panel._rebuild(self)
	self:_clear()
	local st = View.state(self.ctx.session)
	self._st = st
	self._title:set_text(View.season_name(st.season))
	self._days:set_text(View.days_left_text(st))
	self._level:set_text(L("bp.level", { n = st.level }))
	self._xp:set_text(L("bp.xp_progress", { x = UICtx.commas(st.into), need = UICtx.commas(st.need) }))
	self._lv_host:add_child(progress(st.into / math.max(st.need, 1), UITheme.AMBER, 8))
	local offered = View.premium_offered()
	self._tabs.premium:set_visible(offered)
	if not offered and self._page == "premium" then
		self._page = "missions"
	end
	for k, chip in self._tabs do
		chip:set_pressed_no_signal(k == self._page)
	end
	if self._page == "premium" then
		self:_premium_page(st)
	else
		self:_missions_page(st)
	end
	self:_refresh_foot()
end

--- One mission row: difficulty chip, text (and "Public matches only"), progress, XP.
function Panel._mission_row(self, m: any)
	local BP = UICtx.data("BattlePass")
	local Missions = UICtx.data("Missions")
	local x = m.m
	local col = View.DIFF_COLORS[x.diff] or UITheme.TEXT_2
	-- (phones: a tighter row, so the five fit a 390 pt screen)
	local cp = self.ctx.compact
	local row = W.Panel.new()
	row:set_mouse_filter(W.MOUSE_IGNORE)
	row:add_theme_stylebox_override(
		"panel",
		UITheme.flat(
			if m.done then UITheme.c(UITheme.GREEN, 0.08) else UITheme.FILL,
			UITheme.R_MD,
			if m.done then UITheme.c(UITheme.GREEN, 0.4) else UITheme.LINE,
			1,
			if cp then 10.0 else 12.0,
			if cp then 3.0 else 8.0
		)
	)
	local h = UITheme.hbox(if cp then 8 else 12)
	row:add_child(h)
	local chip = W.Panel.new()
	chip:set_mouse_filter(W.MOUSE_IGNORE)
	chip:add_theme_stylebox_override("panel", UITheme.flat(UITheme.c(col, 0.16), 999, UITheme.c(col, 0.6), 1, 8.0, 2.0))
	chip.size_flags_vertical = W.SHRINK_CENTER
	chip:set_min_size(Vector2.new(if cp then 62 else 74, 0))
	local cl = UITheme.label(Loc.upper(L("bp.diff." .. x.diff)), 10, 800, col, 1)
	cl:set_alignment(W.ALIGN_CENTER)
	chip:add_child(cl)
	h:add_child(chip)
	local mid = UITheme.vbox(if cp then 1 else 3)
	mid.size_flags_horizontal = W.EXPAND_FILL
	local text = UITheme.label(View.mission_text(x), if cp then 12 else 14, 600, if m.done then UITheme.TEXT_2 else UITheme.TEXT)
	text:set_autowrap(true)
	text.size_flags_horizontal = W.EXPAND_FILL
	mid:add_child(text)
	if Missions.public_only(x) then
		mid:add_child(UITheme.label(L("bp.public_only"), if cp then 10 else 11, 600, UITheme.TEXT_3))
	end
	mid:add_child(progress(m.n / math.max(x.goal, 1), if m.done then UITheme.GREEN else col, if cp then 4 else 6))
	h:add_child(mid)
	local right = UITheme.vbox(2)
	right.size_flags_vertical = W.SHRINK_CENTER
	right:set_min_size(Vector2.new(84, 0))
	local xp = UITheme.label(L("bp.xp_gain", { n = BP.BpMissionXp[x.diff] or 0 }), if cp then 12 else 13, 800, UITheme.GOLD)
	xp:set_alignment(W.ALIGN_RIGHT)
	right:add_child(xp)
	local n = UITheme.label(
		if m.done then L("bp.done") else UICtx.commas(m.n) .. " / " .. UICtx.commas(x.goal),
		11,
		700,
		if m.done then UITheme.GREEN else UITheme.TEXT_2
	)
	n:set_alignment(W.ALIGN_RIGHT)
	n:set_tabular(true)
	right:add_child(n)
	h:add_child(right)
	return row
end

function Panel._missions_page(self, st: any)
	if not self.ctx.compact then
		self._host:add_child(UITheme.caption(L("bp.daily_missions"), 11, UITheme.CYAN))
	end
	for _, m in st.missions do
		self._host:add_child(self:_mission_row(m))
	end
end

function Panel._premium_page(self, st: any)
	local BP = UICtx.data("BattlePass")
	local host = self._host
	local t = UITheme.label(L("bp.premium_title"), if self.ctx.compact then 15 else 18, 800, UITheme.GOLD)
	host:add_child(t)
	host:add_child(UITheme.label(L("bp.premium_what"), 13, 600, UITheme.TEXT_2))
	-- the season's premium items, with their pictures (phones: side by side, the kind over the name)
	local cp = self.ctx.compact
	local items = if cp then UITheme.hbox(12) else nil
	if items ~= nil then
		host:add_child(items)
	end
	for _, level in { 20, 50, 90 } do
		local r = BP.reward(st.season, "premium", level)
		if r ~= nil then
			local info = View.reward_info(r)
			local line = UITheme.hbox(if cp then 6 else 10)
			local pic = W.Control.new()
			pic:set_mouse_filter(W.MOUSE_IGNORE)
			pic:set_min_size(if cp then Vector2.new(34, 34) else Vector2.new(44, 44))
			local img = make("ImageLabel", {
				BackgroundTransparency = 1,
				ScaleType = Enum.ScaleType.Fit,
				Size = UDim2.fromScale(1, 1),
			}, pic.gui)
			View.show_reward(img, r)
			pic:_part(img, "ImageTransparency", 1.0)
			line:add_child(pic)
			if cp then
				local col = UITheme.vbox(0)
				col.size_flags_vertical = W.SHRINK_CENTER
				col:add_child(UITheme.label(info.kind or "", 10, 600, UITheme.TEXT_2))
				col:add_child(UITheme.label(info.name, 12, 700, info.color))
				line:add_child(col)
				items:add_child(line)
			else
				local lab = UITheme.label(
					L("bp.premium_item", { kind = info.kind or "", name = info.name }) .. "  ·  " .. L("bp.level", { n = level }),
					14,
					700,
					info.color
				)
				lab.size_flags_vertical = W.SHRINK_CENTER
				line:add_child(lab)
				host:add_child(line)
			end
		end
	end
	host:add_child(UITheme.label(L("bp.premium_stars"), if cp then 12 else 13, 600, UITheme.TEXT))
	host:add_child(UITheme.label(L("bp.premium_now"), if cp then 12 else 13, 600, UITheme.TEXT))
	if not cp then
		-- (phones: the head shows the days left)
		host:add_child(UITheme.label(View.days_left_text(st), 12, 600, UITheme.TEXT_2))
	end
	if st.prem then
		host:add_child(UITheme.label(L("bp.premium_active"), 15, 800, UITheme.GREEN))
	else
		local buy = UITheme.button(
			L("bp.buy") .. "  " .. UICtx.commas(View.premium_robux()),
			"PrimaryButton",
			"robux",
			if cp then 42.0 else 52.0
		)
		buy:set_min_size(Vector2.new(220, if cp then 42 else 52))
		buy:set_font_size(if cp then 15 else 17)
		buy.size_flags_horizontal = W.SHRINK_CENTER
		buy.pressed:Connect(function()
			View.buy_premium(self.ctx.session)
		end)
		self._buy = buy
		host:add_child(buy)
	end
end

function Panel._refresh_foot(self)
	local st = self._st
	if st == nil then
		return
	end
	if self._page == "missions" then
		local next_day = (st.day + 1) * 86400
		self._foot:set_text(L("bp.new_missions_in", { t = View.fmt_left(next_day - st.now()) }))
	else
		self._foot:set_text("")
	end
	self._foot:set_visible(self._page == "missions")
	self._days:set_text(View.days_left_text(st))
end

function Panel._process(self, delta: number)
	if not self.is_open then
		return
	end
	self._tick += delta
	if self._tick >= 1.0 then
		self._tick = 0.0
		self:_refresh_foot()
	end
end

function Panel.apply_layout(self)
	local ctx = self.ctx
	local area = ctx:clear_rect()
	local compact = ctx.compact
	self._panel:set_padding(
		if compact then 12 else 22,
		if compact then 8 else 20,
		if compact then 12 else 22,
		if compact then 8 else 20
	)
	local gw = math.clamp(area.Width - 80, 300, Panel.PAGE_SIZE.X)
	self._host:set_min_size(Vector2.new(gw, 0))
	self._host:set_separation(if compact then 3 else 8)
	self._v:set_separation(if compact then 4 else 10)
	-- (phones: a lower head; the season's name says it is the Battle Pass)
	self._caption:set_visible(not compact)
	self._close_btn:set_min_size(if compact then Vector2.new(28, 28) else Vector2.new(34, 34))
	for _, chip in self._tabs do
		chip:set_min_size(Vector2.new(0, if compact then 28 else 32))
	end
	self._title:set_font_size(if compact then 16 else 20)
	-- (phones: the bar under the window shows the level)
	self._level:get_parent():set_visible(not compact)
	local sz = self._panel:get_combined_minimum_size()
	local p = area.Min + (Vector2.new(area.Width, area.Height) - sz) * 0.5
	local y = math.max(p.Y, area.Min.Y + 4.0)
	local rp = Vector2.new(math.floor(p.X + 0.5), math.floor(y + 0.5))
	self._panel:set_offsets(rp.X, rp.Y, rp.X, rp.Y)
	self._panel:reset_size()
end

return Panel
