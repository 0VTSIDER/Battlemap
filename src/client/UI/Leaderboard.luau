--!nonstrict
-- Port of scripts/ui/leaderboard.gd (UILeaderboard)
-- Right-side leaderboard: top 10 by land share with colour, name, land % and troops. Your own row
-- is pinned when you are outside the top 10; allies and traitors are marked. Clicking a row focuses
-- the camera on that nation. On phones it collapses into a rank pill. Game admins see a person icon on
-- real players' rows, and every real player outside the top is pinned below it (one click away).
--
-- Every match starts with the board closed (close_for_match): the pill (the status pill on phones)
-- opens it, and it stays as the player leaves it until the match ends (since 2026-10-09).
-- Until then a desktop started open and remembered the player's
-- last choice in the saved settings (leaderboard_open_desktop / _touch: old records keep the keys,
-- nothing reads them); a report of the same week: the logs on the left-hand side blocked parts of the
-- map.
--
-- Signals: toggled(open). Members: panel, _pill, expanded, user_hidden, pill_enabled.
-- Methods: set_open(on), toggle(), close_for_match(), apply_layout(top), place_pill_left_of(rect),
-- bottom_edge(), my_rank(), mark_dirty(), refresh(); per frame update(dt).

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local Loc = UITheme.core("Loc")
local L = Loc.t
local Cosmetics: any = if typeof(game) == "Instance"
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Cosmetics)
	else (require :: any)("../../shared/Data/Cosmetics")
local Signal = UITheme.core("Signal")

local Leaderboard = W.class(W.Control)

Leaderboard.ROWS = 10
--- Game admins: real players outside the top rows pinned below them (desktop / phones).
Leaderboard.ADMIN_PINS = 8
Leaderboard.ADMIN_PINS_COMPACT = 3
--- Phones: the board is a peek (opened from the status pill) that folds itself away again.
Leaderboard.PEEK_SECONDS = 8.0

local function msec(): number
	return os.clock() * 1000.0
end

-- ---------------------------------------------------------------------------------------------
-- Row
-- ---------------------------------------------------------------------------------------------

local Row = W.class(W.Button)
Leaderboard.Row = Row

function Row.new(c: any)
	local self = setmetatable({}, Row.__mt)
	W.Control._init(self, "TextButton")
	W.Button._init_button(self, "", "GlassButton")
	local T = UITheme
	self.ctx = c
	self.owner_id = 0
	self.is_me = false
	self.flat = true
	self:set_min_size(Vector2.new(0, 28))
	for _, st in ipairs(W.BUTTON_STATES) do
		self:add_theme_stylebox_override(st, T.empty_box())
	end
	self._sv.inset = { 2, 1, 2, 1 }
	local h = T.hbox(8)
	h:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	h.offset_left = 10.0
	h.offset_right = -10.0
	self:add_child(h)
	self._h = h
	self.rank = T.label("1", 12, 600, T.TEXT_3)
	T.fix_width(self.rank, 26.0, W.ALIGN_RIGHT)
	self.rank.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(self.rank)
	self.sw = T.swatch(T.TEXT, 10.0, 3)
	h:add_child(self.sw)
	-- the owner's badge (Data/Cosmetics), when one is worn and there is no picture: left of the name
	local fimg = Instance.new("ImageLabel")
	fimg.BackgroundTransparency = 1
	fimg.ScaleType = Enum.ScaleType.Fit
	self._flag_img = fimg
	self.flag = W.wrap(fimg)
	self.flag:set_min_size(Vector2.new(16, 16))
	self.flag.size_flags_vertical = W.SHRINK_CENTER
	self.flag:set_mouse_filter(W.MOUSE_IGNORE)
	self.flag:set_visible(false)
	self._flag_id = ""
	h:add_child(self.flag)
	-- a person's Roblox head shot (the cosmetics map's `face`; 2026-10-04): a small profile picture
	-- next to each name
	local himg = Instance.new("ImageLabel")
	himg.BackgroundColor3 = Color3.fromRGB(40, 52, 82)
	himg.BorderSizePixel = 0
	local hc = Instance.new("UICorner")
	hc.CornerRadius = UDim.new(0.5, 0)
	hc.Parent = himg
	self._face_img = himg
	self._face_corner = hc
	-- (with a picture, the badge sits on its top-left corner instead)
	local bimg = Instance.new("ImageLabel")
	bimg.Name = "Badge"
	bimg.BackgroundTransparency = 1
	bimg.ScaleType = Enum.ScaleType.Fit
	bimg.AnchorPoint = Vector2.new(0, 0)
	bimg.Position = UDim2.fromScale(-0.22, -0.22)
	bimg.Size = UDim2.fromScale(0.5, 0.5)
	bimg.ZIndex = himg.ZIndex + 2
	bimg.Visible = false
	bimg.Parent = himg
	self._badge_img = bimg
	self._icon_id = ""
	self.face = W.wrap(himg)
	self.face:set_min_size(Vector2.new(20, 20))
	self.face.size_flags_vertical = W.SHRINK_CENTER
	self.face:set_mouse_filter(W.MOUSE_IGNORE)
	self.face:set_visible(false)
	self._face_id = 0
	h:add_child(self.face)
	self.name_l = T.label("", 13, 600)
	self.name_l.text_overrun_behavior = W.OVERRUN_ELLIPSIS
	self.name_l.size_flags_horizontal = W.EXPAND_FILL
	self.name_l:set_min_size(Vector2.new(40, 0))
	self.name_l.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(self.name_l)
	self.mark = T.icon_rect("alliance", 13.0, T.GREEN)
	self.mark.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(self.mark)
	-- game admins only: a person icon on real players' rows (Session.admin_bots; nobody else gets it)
	self.human = T.icon_rect("users", 13.0, T.CYAN)
	self.human.size_flags_vertical = W.SHRINK_CENTER
	self.human:set_visible(false)
	h:add_child(self.human)
	self.land = T.label("", 13, 700)
	T.fix_width(self.land, T.text_width("88.88%", 13, 700) + 2.0, W.ALIGN_RIGHT)
	self.land.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(self.land)
	self.troops = T.label("", 12, 500, T.TEXT_2)
	T.fix_width(self.troops, T.text_width("888.8K", 12, 500) + 2.0, W.ALIGN_RIGHT)
	self.troops.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(self.troops)
	self.mouse_entered:Connect(function()
		if self.ctx.touch then
			return
		end
		self.ctx:world_call("set_hover_owner", { self.owner_id })
		self:_redraw()
	end)
	self.mouse_exited:Connect(function()
		self.ctx:world_call("set_hover_owner", { 0 })
		self:_redraw()
	end)
	self.pressed:Connect(function()
		if self.owner_id ~= 0 then
			local ctx = self.ctx
			-- spectating (a watcher, or knocked out): Airship BedWars' switch sound
			local my = ctx:my()
			if ctx:me() == 0 or (my ~= nil and my.alive == false) then
				ctx:sfx("spectate_switch")
			end
			ctx:world_call("focus_owner", { self.owner_id })
		end
	end)
	return self
end

--- At least as wide as its contents (the anchored hbox adds nothing to the row's minimum by itself), so
--- the own row, with its picture and icons, never sticks out of a narrow (phone) panel.
function Row._get_minimum_size(self): Vector2
	local m = W.Button._get_minimum_size(self)
	local h = rawget(self, "_h")
	if h == nil then
		return m
	end
	return Vector2.new(math.max(m.X, h:get_combined_minimum_size().X + 20.0), m.Y)
end

function Row.set_row(self, o: any, r: number)
	local ctx = self.ctx
	local T = UITheme
	local s = ctx.state
	self.owner_id = o.id
	self.is_me = o.id == ctx:me()
	self.rank:set_text(tostring(r))
	T.set_swatch_color(self.sw, o.color)
	local cz = s.cosmetics and s.cosmetics[o.id]
	-- the avatar icon (or, wearing none, the head shot), the badge on its top-left corner
	local face = if cz ~= nil and cz.face ~= nil then cz.face else 0
	local icon_it = if cz ~= nil and cz.icon ~= nil then Cosmetics.item(cz.icon) else nil
	local icon_id = if icon_it ~= nil and icon_it.kind == "icon" then icon_it.id else ""
	local fid = if cz ~= nil and cz.badge ~= nil then cz.badge else ""
	if face ~= self._face_id or icon_id ~= self._icon_id or fid ~= self._flag_id then
		self._face_id = face
		self._icon_id = icon_id
		self._flag_id = fid
		local img = self._face_img
		img.ImageRectOffset = Vector2.zero
		img.ImageRectSize = Vector2.zero
		if icon_id ~= "" then
			Cosmetics.show_icon(img, icon_it)
			img.BackgroundTransparency = 1
		else
			img.Image = if face > 0 then Cosmetics.face_image(face) else ""
			img.BackgroundTransparency = 0
		end
		local pic = icon_id ~= "" or face > 0
		self.face:set_visible(pic)
		local it = if fid ~= "" then Cosmetics.item(fid) else nil
		local flag = it ~= nil and it.kind == "badge"
		for _, f in { self._flag_img, self._badge_img } do
			if flag then
				Cosmetics.show_atlas(f, it)
			end
		end
		self._badge_img.Visible = flag and pic
		self.flag:set_visible(flag and not pic)
	end
	local frame_id = if cz ~= nil and cz.frame ~= nil then cz.frame else ""
	if frame_id ~= self._frame_id then
		self._frame_id = frame_id
		Cosmetics.apply_frame(self._face_img, frame_id)
	end
	local font_id = if cz ~= nil and cz.font ~= nil then cz.font else ""
	if font_id ~= self._font_id then
		self._font_id = font_id
		self.name_l:set_font_face(Cosmetics.font_face(font_id))
	end
	self.name_l:set_text(o.name)
	self.land:set_text(T.fmt_pct(s:land_share(o.id)))
	self.troops:set_text(T.fmt_troops(o.troops))
	-- Threat context: a neighbour with over 3x our army reads red.
	local mine = ctx:my()
	local threat = mine ~= nil
		and not self.is_me
		and mine.troops > 0
		and o.troops > 3 * mine.troops
		and not s:are_allies(ctx:me(), o.id)
		and ctx.borders ~= nil
		and ctx.borders:borders_owner(o.id)
	T.set_font_color(self.troops, if threat then T.RED else T.TEXT_2)
	local ally = s:are_allies(ctx:me(), o.id)
	local traitor = s:is_traitor(o.id)
	self.mark:set_visible(ally or traitor)
	if traitor then
		self.mark:set_icon("betray")
		self.mark:set_color(T.RED)
	elseif ally then
		self.mark:set_icon("alliance")
		self.mark:set_color(T.GREEN)
	end
	local nc = T.TEXT
	if self.is_me then
		nc = T.AMBER_HI
	elseif traitor then
		nc = Color3.new(1.0, 0.7, 0.72)
	end
	T.set_font_color(self.name_l, nc)
	T.set_font_color(self.rank, if r == 1 then T.GOLD else T.TEXT_3)
	self.human:set_visible(Leaderboard.is_real_player(ctx, o))
	self:_redraw()
end

function Row._draw_state(self)
	self:_redraw()
end

function Row._draw(self)
	self:_redraw()
end

function Row._redraw(self)
	if self.ctx == nil then
		return
	end
	local T = UITheme
	if self.is_me then
		self._sv:set(T.flat(T.c(T.AMBER, 0.12), 7, T.c(T.AMBER, 0.35), 1))
	elseif self._hover and not self.ctx.touch then
		self._sv:set(T.flat(T.rgba(1, 1, 1, 0.07), 7))
	elseif self._sv.style ~= nil then
		self._sv:set(nil)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Leaderboard
-- ---------------------------------------------------------------------------------------------

--- Game admins only (Session.admin_bots): a real player, not a bot filling the lobby.
function Leaderboard.is_real_player(ctx: any, o: any): boolean
	local bots = if ctx.session ~= nil then ctx.session.admin_bots else nil
	return bots ~= nil and o.kind == UITheme.core("Defs").KIND_HUMAN and not bots[o.id]
end

function Leaderboard.new(c: any)
	local self = setmetatable({}, Leaderboard.__mt)
	W.Control._init(self)
	local T = UITheme
	self.ctx = c
	self.toggled = Signal.new()
	self.expanded = false
	self.user_hidden = false
	self._rows = {}
	self._accum = 0.0
	self._dirty = true
	self._opened_msec = 0
	self._layout_key = ""
	--- Phones: no separate rank pill (the status panel shows the rank and opens the board).
	self.pill_enabled = true
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self.panel = GlassPanel.new(8.0, 10.0, T.R_LG, true, 18)
	self:add_child(self.panel)
	local v = T.vbox(4)
	self.panel:add_child(v)

	self._header = T.hbox(8)
	local hm = W.Margin.new()
	hm:set_mouse_filter(W.MOUSE_IGNORE)
	hm:add_theme_constant_override("margin_left", 10)
	hm:add_theme_constant_override("margin_right", 4)
	hm:add_child(self._header)
	self._header:add_child(T.icon_rect("leaderboard", 14.0, T.AMBER))
	self._header:add_child(T.label(L("board.title"), 12, 800, T.TEXT, 2))
	local sp = W.Control.new()
	sp.size_flags_horizontal = W.EXPAND_FILL
	sp:set_mouse_filter(W.MOUSE_IGNORE)
	self._header:add_child(sp)
	self._count = T.label("", 11, 600, T.TEXT_3)
	-- (wide enough for the language's "888 alive", measured at the 12 px touch size; 64 px in English)
	T.fix_width(self._count, math.max(64.0, T.text_width(L("board.alive", { n = "888" }), 12, 600) + 2.0), W.ALIGN_RIGHT)
	self._header:add_child(self._count)
	local close = W.Button.new("", "GhostButton")
	close:set_icon("close")
	close.expand_icon = true
	close:set_min_size(Vector2.new(26, 26))
	close:add_theme_constant_override("icon_max_width", 11)
	close:add_theme_stylebox_override("normal", T.empty_box(6, 6))
	close:add_theme_stylebox_override("hover", T.flat(T.FILL, 6, T.CLEAR, 0, 6, 6))
	close.pressed:Connect(function()
		self:set_open(false)
	end)
	self._close = close
	self._header:add_child(close)
	v:add_child(hm)

	self._cols = T.hbox(8)
	local cm = W.Margin.new()
	cm:set_mouse_filter(W.MOUSE_IGNORE)
	cm:add_theme_constant_override("margin_left", 10)
	cm:add_theme_constant_override("margin_right", 10)
	cm:add_child(self._cols)
	local c1 = T.caption("#", 10)
	c1:set_min_size(Vector2.new(22, 0))
	c1.horizontal_alignment = W.ALIGN_RIGHT
	self._cols:add_child(c1)
	local c2 = T.caption(L("board.nation"), 10)
	c2.size_flags_horizontal = W.EXPAND_FILL
	c2:set_min_size(Vector2.new(18, 0))
	self._cols:add_child(c2)
	local c3 = T.caption(L("common.land"), 10)
	c3:set_min_size(Vector2.new(50, 0))
	c3.horizontal_alignment = W.ALIGN_RIGHT
	self._cols:add_child(c3)
	local c4 = T.caption(L("common.troops"), 10)
	c4:set_min_size(Vector2.new(46, 0))
	c4.horizontal_alignment = W.ALIGN_RIGHT
	self._cols:add_child(c4)
	v:add_child(cm)
	self._cols_margin = cm
	v:add_child(T.hdivider())

	self._list = T.vbox(0)
	v:add_child(self._list)
	for _ = 1, Leaderboard.ROWS do
		local r = Row.new(c)
		r.pressed:Connect(function()
			self._opened_msec = msec()
		end)
		table.insert(self._rows, r)
		self._list:add_child(r)
	end
	self._pin_sep = T.label("···", 12, 700, T.TEXT_3)
	self._pin_sep.horizontal_alignment = W.ALIGN_CENTER
	self._list:add_child(self._pin_sep)
	--- rows pinned below the top: yours, and (admins) real players; grown on demand
	self._pins = {}
	self._pin_more = T.label("", 11, 600, T.TEXT_3)
	self._pin_more.horizontal_alignment = W.ALIGN_CENTER
	self._pin_more:set_visible(false)
	self._list:add_child(self._pin_more)

	local pill = W.Button.new("", "GlassButton")
	pill:set_icon("leaderboard")
	pill:add_theme_constant_override("icon_max_width", 16)
	pill:set_min_size(Vector2.new(0, 40))
	pill:add_theme_stylebox_override("normal", T.flat(T.GLASS, 999, T.LINE, 1, 14, 6))
	pill:add_theme_stylebox_override("hover", T.flat(T.GLASS_RAISED, 999, T.LINE_2, 1, 14, 6))
	pill:add_theme_stylebox_override("pressed", T.flat(T.GLASS_RAISED, 999, T.LINE_2, 1, 14, 6))
	pill:add_theme_stylebox_override("hover_pressed", T.flat(T.GLASS_RAISED, 999, T.LINE_2, 1, 14, 6))
	pill:set_font_size(13)
	pill.pressed:Connect(function()
		self:set_open(true)
	end)
	self._pill = pill
	self:add_child(pill)
	pill:set_visible(false)
	return self
end

function Leaderboard.set_open(self, on: boolean)
	local ctx = self.ctx
	local was = self.expanded
	self.expanded = on
	self.user_hidden = not on
	self._opened_msec = msec()
	self:_apply_visibility()
	if on and not was then
		W.pop_in(self.panel, 0.0, 0.97, 0.3)
		ctx:sfx("open", -8.0)
	elseif not on and was then
		ctx:sfx("close", -8.0)
	end
	self:refresh()
	if on ~= was then
		self.toggled:Fire(on)
	end
end

function Leaderboard.toggle(self)
	self:set_open(not self.expanded)
end

--- A new match: the board is closed, without the sound or the signal of a player closing it.
function Leaderboard.close_for_match(self)
	self.expanded = false
	self.user_hidden = false
	self:_apply_visibility()
end

function Leaderboard._apply_visibility(self)
	self.panel:set_visible(self.expanded)
	self._pill:set_visible(not self.expanded and self.pill_enabled)
end

function Leaderboard.apply_layout(self, top: number)
	local ctx = self.ctx
	self.pill_enabled = not ctx.compact
	-- Phones never keep the board open (it is a peek): a screen that turns into one closes it. Other
	-- screens keep it as it is (closed since the match began, or as the player left it).
	local key = if ctx.compact then "compact" else (if ctx.touch then "touch" else "desktop")
	if key ~= self._layout_key then
		self._layout_key = key
		if ctx.compact then
			self.expanded = false
		end
	end
	local right = 12.0 + ctx.insets.z
	local w = if ctx.compact then 250.0 else 300.0
	for _, c in ipairs({ self.panel, self._pill }) do
		c.anchor_left, c.anchor_right, c.anchor_top, c.anchor_bottom = 1.0, 1.0, 0.0, 0.0
		c.grow_horizontal = W.GROW_BEGIN
		c.grow_vertical = W.GROW_END
		c.offset_left = -right
		c.offset_right = -right
		c.offset_top = top
		c.offset_bottom = top
	end
	self.panel:set_min_size(Vector2.new(w, 0))
	for _, r in ipairs(self._rows) do
		r:set_min_size(Vector2.new(0, if ctx.touch then 44 else 28))
	end
	for _, r in ipairs(self._pins) do
		r:set_min_size(Vector2.new(0, if ctx.touch then 44 else 28))
	end
	self._close:set_min_size(if ctx.touch then Vector2.new(44, 44) else Vector2.new(26, 26))
	self._pill:set_min_size(Vector2.new(170, if ctx.touch then 44 else 40))
	self._pill:set_clip_text(true)
	self._cols_margin:set_visible(not ctx.compact)
	self:_apply_visibility()
	self.panel:reset_size()
	self._pill:reset_size()
	self._dirty = true
end

--- Phones: put the collapsed rank pill to the left of `status` (same row) to save height.
function Leaderboard.place_pill_left_of(self, status: Rect)
	local ctx = self.ctx
	local p = self._pill
	local right_edge = ctx.vp.X - status.Min.X + 8.0
	p.anchor_left = 1.0
	p.anchor_right = 1.0
	p.offset_left = -right_edge
	p.offset_right = -right_edge
	p.offset_top = status.Min.Y + (status.Height - p:get_combined_minimum_size().Y) * 0.5
	p.offset_bottom = p.offset_top
	p:reset_size()
end

function Leaderboard.bottom_edge(self): number
	if self.panel.visible then
		return self.panel:get_rect().Max.Y
	end
	if self._pill.visible then
		return self._pill:get_rect().Max.Y
	end
	return -1.0
end

--- My rank (1-based) for other panels; 0 when unranked.
function Leaderboard.my_rank(self): number
	local ctx = self.ctx
	if ctx.state == nil or ctx:me() == 0 then
		return 0
	end
	return ctx:rank_of(ctx:me())
end

function Leaderboard.mark_dirty(self)
	self._dirty = true
end

function Leaderboard.refresh(self)
	local ctx = self.ctx
	self._dirty = false
	local s = ctx.state
	if s == nil then
		return
	end
	-- (2026-11-04: no HUMANS filter for admins any more: the board always ranks everyone)
	-- Closed (every match starts so): only the pill can show (not on a phone); the rows and the panel
	-- are filled when it opens (set_open). (2026-10-27: a closed board sorted the ranking, filled its
	-- hidden rows and laid its hidden panel out every second.)
	if not self.expanded then
		local me = ctx:me()
		self:_set_pill(if me ~= 0 then ctx:rank_of(me) else 0, ctx:leader())
		return
	end
	local ranking = s:ranking()
	local me = ctx:me()
	local shown = math.min(if not ctx.compact then Leaderboard.ROWS else 5, #ranking)
	local my_rank = -1
	for i, o in ipairs(ranking) do
		if o.id == me then
			my_rank = i
			break
		end
	end
	for i, r in ipairs(self._rows) do
		r:set_visible(i <= shown)
		if i <= shown then
			r:set_row(ranking[i], i)
		end
	end
	-- pinned below the top: your own row, and for admins the real players (up to a cap)
	local cap = if ctx.compact then Leaderboard.ADMIN_PINS_COMPACT else Leaderboard.ADMIN_PINS
	local pins, humans, more = {}, 0, 0
	for i = shown + 1, #ranking do
		local o = ranking[i]
		if o.id == me and me ~= 0 then
			table.insert(pins, i)
		elseif Leaderboard.is_real_player(ctx, o) then
			if humans < cap then
				humans += 1
				table.insert(pins, i)
			else
				more += 1
			end
		end
	end
	for j, i in ipairs(pins) do
		local r = self._pins[j]
		if r == nil then
			r = Row.new(ctx)
			r:set_min_size(Vector2.new(0, if ctx.touch then 44 else 28))
			r.pressed:Connect(function()
				self._opened_msec = msec()
			end)
			self._pins[j] = r
			self._list:add_child(r)
			self._list:move_child(self._pin_more, -1)
		end
		r:set_visible(true)
		r:set_row(ranking[i], i)
	end
	for j = #pins + 1, #self._pins do
		self._pins[j]:set_visible(false)
		self._pins[j].owner_id = 0
	end
	self._pin_sep:set_visible(#pins > 0)
	self._pin_more:set_visible(more > 0)
	if more > 0 then
		self._pin_more:set_text(L(if more == 1 then "board.more_human" else "board.more_humans", { n = more }))
	end

	self._count:set_text(L("board.alive", { n = #ranking }))
	self:_set_pill(my_rank, ranking[1])
	self.panel:reset_size()
end

--- The pill: my rank (`my_rank` > 0) and land, else the leader's name (cut to 10 characters) and
--- land. (Written when it changed: a button's text lays the HUD out again even when it is the same.)
function Leaderboard._set_pill(self, my_rank: number, leader: any)
	local ctx = self.ctx
	local T = UITheme
	local s = ctx.state
	local text = L("board.pill")
	if my_rank > 0 then
		text = string.format("#%d  ·  %s", my_rank, T.fmt_pct(s:land_share(ctx:me())))
	elseif leader ~= nil then
		local nm = leader.name
		if utf8.len(nm) and (utf8.len(nm) :: number) > 10 then
			local cut = utf8.offset(nm, 10)
			nm = string.sub(nm, 1, (cut or 10) - 1) .. "…"
		end
		text = string.format("%s  %s", nm, T.fmt_pct(s:land_share(leader.id)))
	end
	if text ~= self._pill.text then
		self._pill:set_text(text)
	end
end

--- Per frame (GDScript _process).
function Leaderboard.update(self, delta: number)
	local ctx = self.ctx
	if ctx.compact and self.expanded and msec() - self._opened_msec > Leaderboard.PEEK_SECONDS * 1000.0 then
		self:set_open(false)
	end
	self._accum += delta
	if self._accum >= 1.0 and self:is_visible_in_tree() and self._dirty then
		self._accum = 0.0
		self:refresh()
	end
end

return Leaderboard
