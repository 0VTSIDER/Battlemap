--!nonstrict
-- The Battle Pass bar (2026-11-18) along the whole foot of the title screen, always there (TitleScreen places it
-- above the licence line): the level and the XP into it, then one line, its fill the season's progress, with a
-- milestone every BpMilestoneEvery levels: the free track's rewards on the line, the premium track's as a
-- quieter row under it (greyed until Premium is bought), each in its reward's rarity colour
-- (Cosmetics.RARITIES); desktop numbers the milestones over the line. Hovering a milestone (a mouse) or tapping
-- it (touch) shows its reward: picture, name, rarity, track (its own card, not the shared Tooltip). At the end:
-- PREMIUM (the offer, UI/BattlePassPanel; only where it can be bought, BattlePassView.premium_offered). The
-- daily missions are their own card (UI/MissionsCard).
-- Past level 100 (bonus levels) the line stays full: the level and the XP into it still count.
-- Signals: open_panel(page: "premium").
local UITheme = require("./UITheme")
local W = require("./Widgets")
local UICtx = require("./UICtx")
local View = require("./BattlePassView")
local Loc = UITheme.core("Loc")
local L = Loc.t
local Signal = UITheme.core("Signal")

local Bar = W.class(W.Control)

--- The bar's height (logical px), desktop / phones.
Bar.HEIGHT = 54
Bar.HEIGHT_COMPACT = 44
--- A reward card stays this long after a tap (touch).
Bar.TAP_SECONDS = 4.0
--- Milestone sizes (logical px): on the line a Stars one and an item one; the premium row's, smaller.
Bar.DOT = 12
Bar.DOT_ITEM = 16
Bar.DOT_PREMIUM = 8
Bar.DOT_PREMIUM_ITEM = 11

local FONT = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Bold)
local FONT_M = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Medium)
local GREY = Color3.fromRGB(110, 118, 140)

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

function Bar.new(c: any)
	local self = setmetatable({}, Bar.__mt)
	W.Control._init(self)
	self.ctx = c
	self.open_panel = Signal.new()
	self._dots = {} :: { any }
	self._tip_until = 0.0
	self._tip_dot = nil
	self:set_mouse_filter(W.MOUSE_IGNORE)
	local bg = W.Panel.new()
	bg:set_mouse_filter(W.MOUSE_IGNORE)
	bg:add_theme_stylebox_override("panel", UITheme.flat(UITheme.GLASS, UITheme.R_MD, UITheme.LINE_2, 1, 10.0, 4.0))
	bg:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:add_child(bg)
	self._bg = bg
	local row = UITheme.hbox(10)
	row:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	row:set_mouse_filter(W.MOUSE_IGNORE)
	bg:add_child(row)
	self._row = row
	-- the level and the XP into it
	local lv = UITheme.vbox(0)
	lv.size_flags_vertical = W.SHRINK_CENTER
	self._level = UITheme.label("", 15, 800, UITheme.AMBER)
	self._xp = UITheme.label("", 11, 600, UITheme.TEXT_2)
	self._xp:set_tabular(true)
	lv:add_child(self._level)
	lv:add_child(self._xp)
	row:add_child(lv)
	self._lv_box = lv
	-- the track: the bar and its dots (raw frames, laid out on every resize)
	local track = W.Control.new()
	track.size_flags_horizontal = W.EXPAND_FILL
	track:set_min_size(Vector2.new(160, 40))
	track:set_mouse_filter(W.MOUSE_PASS)
	track.size_flags_vertical = W.SHRINK_CENTER
	row:add_child(track)
	self._track = track
	track._on_geometry = function(_t, w: number, h: number)
		self:_place(w, h)
	end
	self:_build_track()
	-- Premium, at the end
	self._premium = UITheme.button(L("bp.premium"), "GlassButton", "crown", 36.0)
	self._premium:set_font_size(12)
	self._premium.size_flags_vertical = W.SHRINK_CENTER
	self._premium:add_theme_color_override("font_color", UITheme.GOLD)
	self._premium:add_theme_color_override("font_hover_color", UITheme.GOLD)
	self._premium:add_theme_color_override("icon_normal_color", UITheme.GOLD)
	self._premium:add_theme_color_override("icon_hover_color", UITheme.GOLD)
	self._premium.pressed:Connect(function()
		self.open_panel:Fire("premium")
	end)
	row:add_child(self._premium)
	self:_build_card()
	self:set_process(true)
	self:refresh()
	return self
end

--- The bar, its fill and the dots' frames and hit areas.
function Bar._build_track(self)
	local g = self._track.gui
	local host = self._track
	self._rail = make("Frame", { Name = "BpRail", BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = 20 }, g)
	make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, self._rail)
	host:_part(self._rail, "BackgroundTransparency", 0.22)
	self._fill = make("Frame", { Name = "BpFill", BorderSizePixel = 0, BackgroundColor3 = UITheme.AMBER, ZIndex = 21 }, self._rail)
	make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, self._fill)
	make("UIGradient", { Color = ColorSequence.new(UITheme.AMBER_LO, UITheme.AMBER_HI) }, self._fill)
	host:_part(self._fill, "BackgroundTransparency", 1.0)
	local BP = UICtx.data("BattlePass")
	local n = BP.BpMainLevels // BP.BpMilestoneEvery
	for _, track in { "free", "premium" } do
		for k = 1, n do
			local dot = make("Frame", { Name = "BpDot_" .. track .. k, BorderSizePixel = 0, ZIndex = 23 }, g)
			make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, dot)
			local stroke = make("UIStroke", { Thickness = 1, Color = Color3.new(1, 1, 1) }, dot)
			-- (a hit area bigger than the dot: a finger finds it)
			local hit = make("TextButton", {
				Name = "BpHit_" .. track .. k,
				Text = "",
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				ZIndex = 24,
			}, g)
			local num = nil
			if track == "free" then
				-- (desktop: the milestone's level over the line)
				num = make("TextLabel", {
					Name = "BpNum" .. k,
					BackgroundTransparency = 1,
					FontFace = FONT,
					Text = tostring(k * BP.BpMilestoneEvery),
					TextColor3 = UITheme.TEXT_3,
					AnchorPoint = Vector2.new(0.5, 0.5),
					AutomaticSize = Enum.AutomaticSize.XY,
					Size = UDim2.new(),
					ZIndex = 22,
				}, g)
				host:_part(num, "TextTransparency", 1.0)
			end
			local d = { track = track, k = k, level = k * BP.BpMilestoneEvery, dot = dot, stroke = stroke, hit = hit, num = num }
			hit.MouseEnter:Connect(function()
				if not self.ctx.touch then
					self:_show_card(d, false)
				end
			end)
			hit.MouseLeave:Connect(function()
				if not self.ctx.touch and self._tip_dot == d then
					self:_hide_card()
				end
			end)
			hit.Activated:Connect(function()
				self:_show_card(d, true)
			end)
			table.insert(self._dots, d)
		end
	end
end

--- The reward card (shown over a dot).
function Bar._build_card(self)
	local s = UITheme.scale
	local card = make("Frame", {
		Name = "BpRewardCard",
		BackgroundColor3 = UITheme.color3(UITheme.GLASS_SOLID),
		BackgroundTransparency = 0.04,
		BorderSizePixel = 0,
		AutomaticSize = Enum.AutomaticSize.XY,
		Visible = false,
		ZIndex = 60,
	}, self._track.gui)
	make("UICorner", { CornerRadius = UDim.new(0, 10) }, card)
	self._card_stroke = make("UIStroke", { Thickness = 1.5, Color = Color3.new(1, 1, 1) }, card)
	make("UIPadding", {
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 12),
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
	}, card)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, card)
	self._card_img = make("ImageLabel", {
		Name = "Picture",
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Fit,
		Size = UDim2.fromOffset(48, 48),
		LayoutOrder = 1,
		ZIndex = 61,
	}, card)
	local col = make("Frame", {
		Name = "Text",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		LayoutOrder = 2,
		ZIndex = 61,
	}, card)
	make("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, col)
	local function line(order: number, font: Font, size: number, color: Color3): TextLabel
		return make("TextLabel", {
			BackgroundTransparency = 1,
			FontFace = font,
			TextSize = size,
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Left,
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.new(),
			LayoutOrder = order,
			ZIndex = 62,
		}, col)
	end
	self._card_name = line(1, FONT, 15, UITheme.TEXT)
	self._card_kind = line(2, FONT_M, 12, UITheme.TEXT_2)
	self._card_where = line(3, FONT_M, 12, UITheme.TEXT_3)
	self._card_state = line(4, FONT, 12, UITheme.AMBER)
	self._card = card
	self._card_scale = s
end

--- Shows dot `d`'s reward card; `tapped`: it stays TAP_SECONDS.
function Bar._show_card(self, d: any, tapped: boolean)
	local st = self._st
	if st == nil then
		return
	end
	local BP = UICtx.data("BattlePass")
	local r = BP.reward(st.season, d.track, d.level)
	if r == nil then
		return
	end
	local info = View.reward_info(r)
	local s = UITheme.scale
	View.show_reward(self._card_img, r)
	self._card_img.Size = UDim2.fromOffset(math.floor(48 * s), math.floor(48 * s))
	self._card_name.Text = info.name
	self._card_name.TextColor3 = info.color
	self._card_kind.Text = Loc.text(info.rarity.name) .. (if info.kind ~= nil then "  ·  " .. info.kind else "")
	self._card_where.Text = L(if d.track == "premium" then "bp.track_premium" else "bp.track_free")
		.. "  ·  "
		.. L("bp.level", { n = d.level })
	local reached = st.level >= d.level
	if d.track == "premium" and not st.prem then
		self._card_state.Text = L("bp.needs_premium")
		self._card_state.TextColor3 = UITheme.GOLD
		self._card_state.Visible = true
	elseif reached then
		self._card_state.Text = L("bp.got")
		self._card_state.TextColor3 = UITheme.GREEN
		self._card_state.Visible = true
	else
		self._card_state.Visible = false
	end
	for _, t in { self._card_name, self._card_kind, self._card_where, self._card_state } do
		t.TextSize = math.floor((if t == self._card_name then 15 else 12) * s)
	end
	self._card_stroke.Color = info.color
	-- above the dot; the first and last dots' cards lean inwards (they stay on screen)
	local n = #self._dots // 2
	local ax = if d.k <= 2 then 0.15 elseif d.k >= n - 1 then 0.85 else 0.5
	self._card.AnchorPoint = Vector2.new(ax, 1)
	self._card.Position = UDim2.fromOffset(d.dot.Position.X.Offset, d.dot.Position.Y.Offset - math.floor(12 * s))
	self._card.Visible = true
	self._tip_dot = d
	self._tip_until = if tapped then os.clock() + Bar.TAP_SECONDS else math.huge
end

function Bar._hide_card(self)
	self._card.Visible = false
	self._tip_dot = nil
end

--- The track's frames at its size (w x h real px): desktop numbers over the line, the line, the premium row.
function Bar._place(self, w: number, h: number)
	local s = UITheme.scale
	local compact = self.ctx.compact
	local rail_h = math.max(3, math.floor(6 * s))
	local inset = math.floor(10 * s)
	local span = math.max(1, w - inset * 2)
	local rail_y = if compact then math.floor(h * 0.38) else math.floor(h * 0.5)
	local prem_y = if compact then math.floor(h * 0.82) else math.floor(h * 0.88)
	self._rail.Size = UDim2.fromOffset(span, rail_h)
	self._rail.Position = UDim2.fromOffset(inset, rail_y - math.floor(rail_h / 2))
	local hit_w = math.max(math.floor(span / 10), math.floor(22 * s))
	for _, d in self._dots do
		local x = inset + math.floor(span * d.k / 10)
		local y = if d.track == "free" then rail_y else prem_y
		d.dot.AnchorPoint = Vector2.new(0.5, 0.5)
		d.dot.Position = UDim2.fromOffset(x, y)
		d.hit.AnchorPoint = Vector2.new(0.5, 0.5)
		-- (the free milestone's hit area: the top down to between the rows; the premium one's: the rest)
		local mid = math.floor((rail_y + prem_y) / 2)
		if d.track == "free" then
			d.hit.Position = UDim2.fromOffset(x, math.floor(mid / 2))
			d.hit.Size = UDim2.fromOffset(hit_w, mid)
		else
			d.hit.Position = UDim2.fromOffset(x, math.floor((mid + h) / 2))
			d.hit.Size = UDim2.fromOffset(hit_w, h - mid)
		end
		if d.num ~= nil then
			d.num.Visible = not compact
			d.num.TextSize = math.floor(10 * s)
			d.num.Position = UDim2.fromOffset(x, math.floor(h * 0.14))
		end
	end
	self:_paint()
end

--- Colours: the fill, each dot (reached / not, premium bought / not).
function Bar._paint(self)
	local st = self._st
	if st == nil then
		return
	end
	local BP = UICtx.data("BattlePass")
	local s = UITheme.scale
	local frac = math.clamp((st.level + st.into / st.need) / BP.BpMainLevels, 0, 1)
	self._fill.Size = UDim2.fromScale(frac, 1)
	local host = self._track
	for _, d in self._dots do
		local r = BP.reward(st.season, d.track, d.level)
		local info = if r ~= nil then View.reward_info(r) else nil
		local item = r ~= nil and r.kind == "item"
		local px = math.floor(
			(if d.track == "free"
				then (if item then Bar.DOT_ITEM else Bar.DOT)
				else (if item then Bar.DOT_PREMIUM_ITEM else Bar.DOT_PREMIUM)) * s
		)
		d.dot.Size = UDim2.fromOffset(px, px)
		local locked = d.track == "premium" and not st.prem
		local reached = st.level >= d.level
		local col = if info ~= nil then info.color else GREY
		if locked then
			col = GREY:Lerp(col, 0.25)
		end
		d.dot.BackgroundColor3 = col
		d.stroke.Color = if reached and not locked then Color3.new(1, 1, 1) else col
		d.stroke.Thickness = if item then 2 else 1
		local quiet = d.track == "premium"
		host:_part(
			d.dot,
			"BackgroundTransparency",
			if reached and not locked then 1.0 elseif locked then 0.35 elseif quiet then 0.5 else 0.6
		)
		host:_part(d.stroke, "Transparency", if reached and not locked then 0.9 else 0.6)
	end
end

--- Reads the session's pass again (the inventory changed, a minute passed).
function Bar.refresh(self)
	local st = View.state(self.ctx.session)
	self._st = st
	self._level:set_text(L("bp.level_short", { n = st.level }))
	self._xp:set_text(L("bp.xp_progress", { x = UICtx.commas(st.into), need = UICtx.commas(st.need) }))
	local compact = self.ctx.compact
	self._premium:set_visible(View.premium_offered())
	self._premium:set_text(if compact then "" else L("bp.premium"))
	self._premium:set_icon(if st.prem then "check" else "crown")
	self:_paint()
end

function Bar.apply_layout(self)
	local ctx = self.ctx
	local compact = ctx.compact
	self:set_min_size(Vector2.new(0, if compact then Bar.HEIGHT_COMPACT else Bar.HEIGHT))
	self._level:set_font_size(if compact then 13 else 15)
	self._xp:set_font_size(if compact then 10 else 11)
	self._track:set_min_size(Vector2.new(if compact then 200 else 300, if compact then 38 else 46))
	self._premium:set_min_size(Vector2.new(if compact then 44 else 0, if compact then 34 else 36))
	self._premium:set_font_size(12)
	self:refresh()
end

function Bar._process(self, _delta: number)
	if self._tip_dot ~= nil and os.clock() > self._tip_until then
		self:_hide_card()
	end
end

return Bar
