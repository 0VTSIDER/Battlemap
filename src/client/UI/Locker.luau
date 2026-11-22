--!nonstrict
-- The Locker (2026-09-29; 2026-11-03: no more crates; the Stars store; 2026-11-04: reworked): a modal from
-- the title.
--   head        LOCKER, "N of M owned", the player's Stars big in the top right corner, close.
--   preview     on the left: the player's avatar (its frame and badge on it) over their name in their font,
--               and under it a patch of territory in a random colour (a press picks another) wearing their
--               pattern. Hovering a card (a press on touch) previews that item there instead, owned or not.
--   grid        Avatars / Frames / Badges / Fonts / Territory tabs: a section per rarity, Common first, each
--               under its name in the rarity's colour (white, green, blue, purple, orange); every item's name
--               in its rarity's colour; owned bright, the rest dimmed. Press an owned one to wear it, "None"
--               to wear nothing (not for avatars: one is always worn). A rank frame (Data/Ranks) is worn
--               while the player's tier reaches it ("REACH GOLD" below it). An exclusive skin
--               (Cosmetics.exclusives) shows only to its owner, in its own section first.
--   store       an item for sale (Data/Store.price) shows its price with a star: the first press arms it
--               ("BUY?"), the second buys it (Session.buy; the server wears it at once).
--   Get Stars   a list: each offer's title, what it gives under it, its Robux price on the right.
-- Signals: closed.
local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local Loc = UITheme.core("Loc")
local L = Loc.t
local Signal = UITheme.core("Signal")

local IS_ROBLOX = typeof(game) == "Instance"
local function shared(name: string): any
	if IS_ROBLOX then
		return require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data[name]) :: any
	end
	return (require :: any)("../../shared/Data/" .. name)
end
local Cosmetics = shared("Cosmetics")
local Store = shared("Store")
local SkinPreviews: any = (function()
	local ok, m = pcall(function()
		if IS_ROBLOX then
			return require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Assets.SkinPreviews)
		end
		return (require :: any)("../../shared/Assets/SkinPreviews")
	end)
	return if ok and type(m) == "table" then m else {}
end)()

local Locker = W.class(W.Control)

Locker.TABS = {
	{ "locker.avatars", "icon" },
	{ "locker.frames", "frame" },
	{ "locker.badges", "badge" },
	{ "locker.fonts", "font" },
	{ "locker.territory", "skin" },
	{ "locker.get_stars", "stars" },
}
Locker.SKIN_CARD = Vector2.new(116, 128)
--- a Get Stars row's height (its width: the list's)
Locker.OFFER_ROW_H = 74
Locker.GRID_SIZE = Vector2.new(720, 430)
--- the preview column's width (phones: PREVIEW_W_PHONE)
Locker.PREVIEW_W = 210
Locker.PREVIEW_W_PHONE = 128
--- the colour the grid's skin cards are previewed in (Assets/SkinPreviews is drawn in it)
Locker.PREVIEW_COLOR = Color3.fromRGB(64, 132, 230)
--- the territory preview's colours: one at random each time the Locker opens, the next on a press
Locker.TERRITORY_COLORS = {
	Color3.fromRGB(64, 132, 230),
	Color3.fromRGB(222, 72, 72),
	Color3.fromRGB(60, 178, 96),
	Color3.fromRGB(238, 146, 46),
	Color3.fromRGB(150, 90, 220),
	Color3.fromRGB(36, 176, 184),
	Color3.fromRGB(226, 196, 52),
	Color3.fromRGB(226, 96, 170),
}
--- the territory preview's size in map tiles (a skin with several colours: twice it, its pattern is larger)
Locker.TERRITORY_TILES = 40

local FONT = Font.fromId(12187365977, Enum.FontWeight.Bold)
local FONT_M = Font.fromId(12187365977, Enum.FontWeight.Medium)
local FONT_H = Font.fromId(12187365977, Enum.FontWeight.Heavy)
local GOLD = Color3.fromRGB(255, 200, 61)
local DIM = Color3.fromRGB(150, 158, 180)

local function c3(hex: number): Color3
	return Color3.fromRGB((hex // 65536) % 256, (hex // 256) % 256, hex % 256)
end

local function amber(): Color3
	return UITheme.color3(UITheme.to_rgba(UITheme.AMBER))
end

--- 12345 -> "12,345"
local function commas(n: number): string
	local s = tostring(math.floor(n))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end
Locker.commas = commas

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

-- ---------------------------------------------------------------------------------------------
-- Territory pictures
-- ---------------------------------------------------------------------------------------------

--- The pixels of `skin` (nil: a plain fill) over a territory of colour `c`, the way the map draws it
--- (MapSurface: fill alpha 150, secondary Cosmetics.SECONDARY_ALPHA, a darker edge), n x n tiles over sand.
--- `shape`: a rounded patch of land with its border; otherwise the whole square, edged.
local function territory_pixels(skin: any, c: Color3, n: number, shape: boolean): buffer
	local mask, mw, mh
	if skin ~= nil then
		mask, mw, mh = Cosmetics.mask(skin)
	end
	local r, g, b = c.R, c.G, c.B
	local sr, sg, sb = r, g, b
	if skin ~= nil then
		sr, sg, sb = Cosmetics.secondary(skin, r, g, b)
	end
	local tr, tg, tb = 221 / 255, 205 / 255, 160 / 255
	local a1, a2 = 150 / 255, Cosmetics.SECONDARY_ALPHA / 255
	local half = (n - 1) / 2
	local function inside(x: number, y: number): boolean
		if not shape then
			return x >= 0 and y >= 0 and x < n and y < n
		end
		local dx, dy = x - half, y - half
		local th = math.atan2(dy, dx)
		local rad = half * (0.86 + 0.08 * math.sin(th * 3 + 0.7) + 0.05 * math.cos(th * 5))
		return dx * dx + dy * dy <= rad * rad
	end
	local buf = buffer.create(n * n * 4)
	for y = 0, n - 1 do
		for x = 0, n - 1 do
			local cr, cg, cb, a = tr, tg, tb, 0
			if inside(x, y) then
				if not inside(x - 1, y) or not inside(x + 1, y) or not inside(x, y - 1) or not inside(x, y + 1) then
					cr, cg, cb, a = r * 0.875, g * 0.875, b * 0.875, 1
				elseif skin ~= nil then
					local mx = bit32.rshift(x, skin.scale or 0) % mw
					local my = bit32.rshift(y, skin.scale or 0) % mh
					local k = buffer.readu8(mask, my * mw + mx)
					local kr, kg, kb
					if skin.colors ~= nil and k ~= 0 then
						kr, kg, kb = Cosmetics.color(skin, k)
					end
					if kr ~= nil then
						cr, cg, cb, a = kr, kg :: number, kb :: number, Cosmetics.skin_alpha(skin) / 255
					elseif k ~= 0 and skin.colors == nil then
						cr, cg, cb, a = sr, sg, sb, a2
					else
						cr, cg, cb, a = r, g, b, a1
					end
				else
					cr, cg, cb, a = r, g, b, a1
				end
			end
			local k = (y * n + x) * 4
			buffer.writeu8(buf, k, math.floor((tr * (1 - a) + cr * a) * 255 + 0.5))
			buffer.writeu8(buf, k + 1, math.floor((tg * (1 - a) + cg * a) * 255 + 0.5))
			buffer.writeu8(buf, k + 2, math.floor((tb * (1 - a) + cb * a) * 255 + 0.5))
			buffer.writeu8(buf, k + 3, 255)
		end
	end
	return buf
end
Locker.territory_pixels = territory_pixels

--- An EditableImage of those pixels, or nil (not on Roblox, or no EditableImage budget left: phones).
local function territory_image(skin: any, c: Color3, n: number, shape: boolean): any
	if not IS_ROBLOX then
		return nil
	end
	local ok, img = pcall(function()
		return game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(n, n) })
	end)
	if not ok or img == nil then
		return nil
	end
	local buf = territory_pixels(skin, c, n, shape)
	local wrote = pcall(function()
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(n, n), buf)
	end)
	if not wrote then
		pcall(function()
			img:Destroy()
		end)
		return nil
	end
	return img
end

-- A grid card's skin preview: in PREVIEW_COLOR, cached per skin (when the uploaded atlas lacks it).
local previews: { [string]: any } = {}
local function skin_preview(skin: any): any
	local cached = previews[skin.id]
	if cached ~= nil then
		return cached or nil
	end
	local n = if skin.colors ~= nil then 48 else 24
	local img = territory_image(skin, Locker.PREVIEW_COLOR, n, false)
	previews[skin.id] = img or false
	return img
end

--- Show item `it` in ImageLabel `img` (a skin's preview, or an icon, frame or badge from its atlas).
local function show_item(img: ImageLabel, it: any)
	img.ImageRectOffset = Vector2.zero
	img.ImageRectSize = Vector2.zero
	img.ImageContent = Content.none
	img.Image = ""
	if it == nil then
		return
	end
	if it.kind == "icon" then
		img.ResampleMode = Enum.ResamplerMode.Default
		Cosmetics.show_icon(img, it)
	elseif it.kind == "badge" or it.kind == "frame" then
		img.ResampleMode = Enum.ResamplerMode.Default
		Cosmetics.show_atlas(img, it)
	elseif it.kind == "skin" then
		img.ResampleMode = Enum.ResamplerMode.Pixelated
		-- the uploaded atlas (Assets/SkinPreviews); a runtime EditableImage only without it (phones can
		-- run out of EditableImage budget: an Epic reveal card came out empty live, 2026-09-29)
		local cell = SkinPreviews.cells and SkinPreviews.cells[it.id]
		if cell ~= nil and SkinPreviews.image then
			img.Image = SkinPreviews.image
			img.ImageRectOffset = Vector2.new(cell[1], cell[2])
			img.ImageRectSize = Vector2.new(cell[3], cell[4])
			return
		end
		local ed = skin_preview(it)
		if ed ~= nil then
			img.ImageContent = Content.fromObject(ed)
		end
	end
end
Locker.show_item = show_item

--- The rarity sections in the grid's order: exclusives first, then Common up.
function Locker.section_order(): { string }
	local out = { "exclusive" }
	for _, r in Cosmetics.RARITIES do
		table.insert(out, r.id)
	end
	return out
end

-- ---------------------------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------------------------

function Locker.new(c: any)
	local self = setmetatable({}, Locker.__mt)
	W.Control._init(self)
	self.ctx = c
	self.closed = Signal.new()
	self.is_open = false
	self._tab = 1
	self._cards = {}
	self._peek = nil
	self._color_i = 1
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:set_mouse_filter(W.MOUSE_STOP)
	self:set_visible(false)
	self._dim = W.ColorRect.new(UITheme.rgba(0.01, 0.015, 0.05, 0.78))
	self._dim:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self._dim.gui_input:Connect(function(e)
		-- (a press on the window's own ground reaches the dim too: only one outside it closes)
		if e.pressed and not self._panel:has_global_point(e.global_position) then
			self:close()
		end
	end)
	self:add_child(self._dim)
	self._panel = GlassPanel.new(22.0, 20.0, 18, true, 34)
	self._panel:set_tint(UITheme.rgba(0.045, 0.065, 0.13, 0.96))
	self:add_child(self._panel)
	local v = UITheme.vbox(12)
	self._v = v
	self._panel:add_child(v)
	-- head: title, owned count, the Stars, close
	local head = UITheme.hbox(12)
	local title = UITheme.label(L("locker.locker"), 20, 800, UITheme.TEXT, 3)
	title.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(title)
	self._count = UITheme.label("", 13, 600, UITheme.TEXT_2)
	self._count.size_flags_horizontal = W.EXPAND_FILL
	self._count.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._count)
	local stars = UITheme.hbox(8)
	stars.size_flags_vertical = W.SHRINK_CENTER
	local star_ic = UITheme.icon_rect("star", 28.0, GOLD)
	star_ic.size_flags_vertical = W.SHRINK_CENTER
	stars:add_child(star_ic)
	self._stars = UITheme.label("0", 26, 800, GOLD, 1)
	self._stars.size_flags_vertical = W.SHRINK_CENTER
	stars:add_child(self._stars)
	head:add_child(stars)
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
	-- tabs
	local tabs = UITheme.hbox(6)
	self._tabs = {}
	for i, t in ipairs(Locker.TABS) do
		local chip = UITheme.button(L(t[1]), "ChipButton", "", 32.0)
		chip.toggle_mode = true
		chip:set_font_size(12)
		chip:set_pressed_no_signal(i == self._tab)
		chip.pressed:Connect(function()
			self._tab = i
			self._peek = nil
			self._armed = nil
			for j, ch in ipairs(self._tabs) do
				ch:set_pressed_no_signal(j == i)
			end
			self:_rebuild()
			self:_refresh_preview()
		end)
		table.insert(self._tabs, chip)
		tabs:add_child(chip)
	end
	v:add_child(tabs)
	-- body: the preview, then the grid
	local body = UITheme.hbox(14)
	v:add_child(body)
	local pv = W.Control.new()
	pv:set_mouse_filter(W.MOUSE_PASS)
	self._pv = pv
	body:add_child(pv)
	self:_build_preview()
	local host = W.Control.new()
	host:set_min_size(Locker.GRID_SIZE)
	host:set_mouse_filter(W.MOUSE_PASS)
	self._host = host
	body:add_child(host)
	local sf = make("ScrollingFrame", {
		Name = "LockerGrid",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Color3.new(1, 1, 1),
		ScrollBarImageTransparency = 0.6,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ZIndex = 40,
	}, host.gui)
	host:_part(sf, "ScrollBarImageTransparency", 0.4)
	self._sf = sf
	self._list = make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, sf)
	make("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingLeft = UDim.new(0, 2), PaddingBottom = UDim.new(0, 6) }, sf)
	return self
end

--- The session's inventory (UIRoot.setup, when the session exists): the grid follows it.
function Locker.bind(self, s: any)
	if s == nil or self._bound == s then
		return
	end
	self._bound = s
	if s.inventory_changed then
		s.inventory_changed:Connect(function()
			if self.is_open then
				self:_refresh_count()
				self:_rebuild()
				self:_refresh_preview()
			end
		end)
	end
	-- (Roblox's prices arriving: the Get Stars tab shows them)
	;(require("./Prices") :: any).changed:Connect(function()
		if self.is_open and Locker.TABS[self._tab][2] == "stars" then
			self:_rebuild()
		end
	end)
	if s.buy_result then
		s.buy_result:Connect(function(id: string, ok: boolean, _reason: string?)
			if self._armed == id then
				self._armed = nil
			end
			if self.is_open then
				self.ctx:sfx(if ok then "confirm" else "deny", if ok then 0.0 else -6.0)
				self:_rebuild()
			end
		end)
	end
end

--- "N of M owned" (the store's items; exclusives don't count), and the Stars in the corner.
function Locker._refresh_count(self)
	local inv = self:_inv()
	self._count:set_text(L("locker.n_owned", { n = Cosmetics.catalog_owned(inv.owned), total = #Cosmetics.all() }))
	self._stars:set_text(commas(tonumber(inv.stars) or 0))
end

function Locker._inv(self): any
	local s = self.ctx.session
	return if s ~= nil and s.inventory ~= nil then s.inventory else { owned = {}, equipped = {} }
end

function Locker._report(self, kind: string)
	local s = self.ctx.session
	if s ~= nil and type(s.report) == "function" then
		s:report(kind)
	end
end

function Locker._equipped(self, slot: string): string?
	local inv = self:_inv()
	local id = inv.equipped and inv.equipped[slot] or nil
	if id == nil and slot == "icon" then
		-- (an avatar is always worn: without a saved one, the default the server picks for this player)
		local uid = if IS_ROBLOX then (game:GetService("Players").LocalPlayer :: any).UserId else 0
		id = Cosmetics.default_avatar(uid)
	end
	return id
end

-- ---------------------------------------------------------------------------------------------
-- The preview (left)
-- ---------------------------------------------------------------------------------------------

function Locker._build_preview(self)
	local root = self._pv.gui
	local pv = self._pv
	local bg = make("Frame", {
		Name = "PreviewCard",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 40,
	}, root)
	make("UICorner", { CornerRadius = UDim.new(0, 12) }, bg)
	local stroke = make("UIStroke", { Color = Color3.new(1, 1, 1), ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, bg)
	pv:_part(bg, "BackgroundTransparency", 0.035)
	pv:_part(stroke, "Transparency", 0.08)
	self._pv_avatar = make("ImageLabel", {
		Name = "Avatar",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ScaleType = Enum.ScaleType.Fit,
		ZIndex = 42,
	}, root)
	make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, self._pv_avatar)
	pv:_part(self._pv_avatar, "ImageTransparency", 1.0)
	self._pv_name = make("TextLabel", {
		Name = "Name",
		BackgroundTransparency = 1,
		TextColor3 = Color3.new(1, 1, 1),
		TextScaled = true,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 42,
	}, root)
	make("UITextSizeConstraint", { MaxTextSize = 20 }, self._pv_name)
	pv:_part(self._pv_name, "TextTransparency", 1.0)
	self._pv_cap = make("TextLabel", {
		Name = "Caption",
		BackgroundTransparency = 1,
		FontFace = FONT,
		Text = L("locker.territory_2"),
		TextColor3 = DIM,
		ZIndex = 42,
	}, root)
	pv:_part(self._pv_cap, "TextTransparency", 1.0)
	local land = make("ImageButton", {
		Name = "Territory",
		BackgroundColor3 = Color3.fromRGB(221, 205, 160),
		AutoButtonColor = false,
		ScaleType = Enum.ScaleType.Stretch,
		ResampleMode = Enum.ResamplerMode.Pixelated,
		ZIndex = 42,
	}, root)
	make("UICorner", { CornerRadius = UDim.new(0, 10) }, land)
	pv:_part(land, "BackgroundTransparency", 1.0)
	pv:_part(land, "ImageTransparency", 1.0)
	land.Activated:Connect(function()
		-- another colour for the patch
		self._color_i = self._color_i % #Locker.TERRITORY_COLORS + 1
		self.ctx:sfx("click")
		self:_refresh_preview()
	end)
	self._pv_land = land
	self._pv_hint = make("TextLabel", {
		Name = "Hint",
		BackgroundTransparency = 1,
		FontFace = FONT_M,
		Text = if self.ctx.touch then L("locker.tap_to_change_colour") else L("locker.click_to_change_colour"),
		TextColor3 = DIM,
		ZIndex = 42,
	}, root)
	pv:_part(self._pv_hint, "TextTransparency", 0.8)
end

--- Places the preview's parts for a column `w` x `h` logical px.
function Locker._layout_preview(self, w: number, h: number)
	local s = UITheme.scale
	local pw, ph = w * s, h * s
	local pad = 12 * s
	local inner = pw - pad * 2
	-- the avatar: its frame (at most Cosmetics.FRAME_SCALE_MAX of it) and badge must fit the zone's width
	local zone = math.min(inner, ph * 0.42)
	local a = zone / (Cosmetics.FRAME_SCALE_MAX * 1.04)
	self._pv_avatar.Size = UDim2.fromOffset(a, a)
	self._pv_avatar.Position = UDim2.fromOffset(pw / 2, pad + zone / 2)
	local name_h = math.max(16 * s, zone * 0.16)
	self._pv_name.Position = UDim2.fromOffset(pad, pad + zone + 4 * s)
	self._pv_name.Size = UDim2.fromOffset(inner, name_h)
	local cap_y = pad + zone + name_h + 14 * s
	self._pv_cap.TextSize = math.floor(10 * s)
	self._pv_cap.Position = UDim2.fromOffset(pad, cap_y)
	self._pv_cap.Size = UDim2.fromOffset(inner, 12 * s)
	local hint_h = 12 * s
	local land_y = cap_y + 16 * s
	local side = math.max(20, math.min(inner, ph - land_y - pad - hint_h - 4 * s))
	self._pv_land.Size = UDim2.fromOffset(side, side)
	self._pv_land.Position = UDim2.fromOffset((pw - side) / 2, land_y)
	self._pv_hint.TextSize = math.floor(10 * s)
	self._pv_hint.Position = UDim2.fromOffset(pad, land_y + side + 4 * s)
	self._pv_hint.Size = UDim2.fromOffset(inner, hint_h)
end

--- What the preview wears in `slot`: the hovered item of that slot, else the equipped one.
function Locker._wearing(self, slot: string): any
	local pk = self._peek
	if pk ~= nil and pk.slot == slot then
		return pk.item -- (nil: "None")
	end
	return Cosmetics.item(self:_equipped(slot))
end

function Locker._refresh_preview(self)
	if self._pv_avatar == nil then
		return
	end
	local icon = self:_wearing("icon")
	if icon == nil then
		local uid = if IS_ROBLOX then (game:GetService("Players").LocalPlayer :: any).UserId else 0
		icon = Cosmetics.item(Cosmetics.default_avatar(uid))
	end
	local frame, badge = self:_wearing("frame"), self:_wearing("badge")
	Cosmetics.dress_picture(self._pv_avatar, {
		icon = if icon ~= nil then icon.id else nil,
		frame = if frame ~= nil then frame.id else nil,
		badge = if badge ~= nil then badge.id else nil,
	})
	local font = self:_wearing("font")
	self._pv_name.FontFace = (if font ~= nil then Cosmetics.font_face(font.id) else nil) or FONT
	self._pv_name.Text = self.ctx:username()
	-- the territory patch
	local skin = self:_wearing("skin")
	local color = Locker.TERRITORY_COLORS[self._color_i] or Locker.PREVIEW_COLOR
	local key = (if skin ~= nil then skin.id else "") .. "|" .. tostring(self._color_i)
	if key == self._land_key then
		return
	end
	self._land_key = key
	-- (drawn with frames, a run of same-coloured tiles each: no EditableImage, which a published
	-- experience may not allow and phones have little budget for; 2026-11-04)
	local land = self._pv_land
	local old = land:FindFirstChild("Tiles")
	if old ~= nil then
		old:Destroy()
	end
	local n = Locker.TERRITORY_TILES * (if skin ~= nil and skin.colors ~= nil then 2 else 1)
	local buf = territory_pixels(skin, color, n, true)
	local holder = make("Frame", {
		Name = "Tiles",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 43,
	})
	local sand = { 221, 205, 160 }
	for y = 0, n - 1 do
		local x = 0
		while x < n do
			local k = (y * n + x) * 4
			local r, g, b = buffer.readu8(buf, k), buffer.readu8(buf, k + 1), buffer.readu8(buf, k + 2)
			local x1 = x + 1
			while x1 < n do
				local k1 = (y * n + x1) * 4
				if buffer.readu8(buf, k1) ~= r or buffer.readu8(buf, k1 + 1) ~= g or buffer.readu8(buf, k1 + 2) ~= b then
					break
				end
				x1 += 1
			end
			if r ~= sand[1] or g ~= sand[2] or b ~= sand[3] then
				make("Frame", {
					BackgroundColor3 = Color3.fromRGB(r, g, b),
					BorderSizePixel = 0,
					Position = UDim2.fromScale(x / n, y / n),
					-- (a hair wider and taller: no seams between runs)
					Size = UDim2.new((x1 - x) / n, 1, 1 / n, 1),
					ZIndex = 43,
				}, holder)
			end
			x = x1
		end
	end
	holder.Parent = land
end

--- Hovering a card shows its item in the preview (`it` nil with a slot: "None"; no slot: back to what's worn).
function Locker._set_peek(self, slot: string?, it: any)
	local cur = self._peek
	if slot == nil then
		if cur == nil then
			return
		end
		self._peek = nil
	else
		if cur ~= nil and cur.slot == slot and cur.item == it then
			return
		end
		self._peek = { slot = slot, item = it }
	end
	self:_refresh_preview()
end

-- ---------------------------------------------------------------------------------------------
-- The grid
-- ---------------------------------------------------------------------------------------------

--- A price or a word under a card: a star (or Robux) icon before a number, or the text alone.
local function price_row(parent: Instance, icon: string?, text: string, color: Color3, size: number, z: number): (any, any, any)
	local row = make("Frame", { Name = "Price", BackgroundTransparency = 1, ZIndex = z }, parent)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, math.floor(size * 0.3)),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	local ic = nil
	local img = if icon ~= nil then UITheme.icon(icon) else nil
	if img ~= nil and img ~= "" then
		ic = make("ImageLabel", {
			BackgroundTransparency = 1,
			Image = img,
			ImageColor3 = color,
			Size = UDim2.fromOffset(size * 1.1, size * 1.1),
			LayoutOrder = 1,
			ZIndex = z,
		}, row)
	end
	local lab = make("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT,
		TextSize = size,
		TextColor3 = color,
		Text = if ic == nil and icon == "star" then text .. " STARS" elseif ic == nil and icon == "robux" then text .. " ROBUX" else text,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, size * 1.2),
		LayoutOrder = 2,
		ZIndex = z,
	}, row)
	return row, ic, lab
end

function Locker._card(self, it: any, order: number, slot: string, parent: Instance): TextButton
	local s = UITheme.scale
	local inv = self:_inv()
	-- (the default avatars are everyone's, even before the inventory arrives)
	local owned = it == nil or it.default == true or inv.owned[it.id] == true or Cosmetics.rank_unlocked(it, inv.tier)
	local rank_locked = it ~= nil and it.rank ~= nil and not owned
	local equipped = if it == nil then self:_equipped(slot) == nil else self:_equipped(slot) == it.id
	local rar = if it ~= nil then Cosmetics.rarity(it.rarity) else nil
	local price = if it ~= nil and not owned then Store.price(it) else nil
	local armed = price ~= nil and self._armed == it.id
	local afford = price ~= nil and (tonumber(inv.stars) or 0) >= price
	local host = self._host
	local b = make("TextButton", {
		Name = if it then it.id else "none",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		LayoutOrder = order,
		ZIndex = 41,
	}, nil)
	make("UICorner", { CornerRadius = UDim.new(0, math.floor(10 * s)) }, b)
	local stroke = make("UIStroke", {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = if equipped then amber() elseif armed then GOLD else Color3.new(1, 1, 1),
		Thickness = if equipped or armed then 2 else 1,
	}, b)
	local img = make("ImageLabel", {
		Name = "Preview",
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Fit,
		Position = UDim2.fromOffset(math.floor(10 * s), math.floor(10 * s)),
		Size = UDim2.new(1, -math.floor(20 * s), 1, -math.floor(46 * s)),
		ZIndex = 42,
	}, b)
	show_item(img, it)
	if slot == "font" then
		-- (a font shows the player's own name in it; None: the game's font)
		local pv = make("TextLabel", {
			Name = "FontPreview",
			BackgroundTransparency = 1,
			FontFace = (if it ~= nil then Cosmetics.font_face(it.id) else nil) or FONT,
			TextScaled = true,
			TextColor3 = Color3.new(1, 1, 1),
			Text = self.ctx:username(),
			Position = img.Position,
			Size = img.Size,
			ZIndex = 42,
		}, b)
		make("UITextSizeConstraint", { MaxTextSize = math.floor(26 * s) }, pv)
		host:_part(pv, "TextTransparency", if owned then 1.0 else 0.45)
	end
	local name = make("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT,
		TextSize = math.floor(12 * s),
		-- the name in its rarity's colour ("None": white)
		TextColor3 = if rar ~= nil then c3(rar.color) else Color3.new(1, 1, 1),
		TextTruncate = Enum.TextTruncate.AtEnd,
		-- (no font: the game's own, "Default")
		Text = if it then it.name elseif slot == "font" then L("locker.default") else L("locker.none"),
		Position = UDim2.new(0, math.floor(8 * s), 1, -math.floor(34 * s)),
		Size = UDim2.new(1, -math.floor(16 * s), 0, math.floor(16 * s)),
		ZIndex = 42,
	}, b)
	local sub_color = if equipped or armed
		then amber()
		elseif price ~= nil and afford then GOLD
		elseif price ~= nil then Color3.fromRGB(196, 170, 110)
		else DIM
	local sub_icon = if price ~= nil and not armed then "star" else nil
	local sub_text = if equipped
		then L("locker.wearing")
		elseif armed then L("locker.buy_for", { n = commas(price :: number) })
		elseif price ~= nil then commas(price)
		elseif rank_locked then L("locker.reach", { tier = Loc.upper(Loc.text(it.rank)) })
		elseif not owned and it.season ~= nil then L("bp.locker_pass")
		elseif not owned then L("locker.locked")
		else L("locker.owned")
	local row, ric, rlab = price_row(b, sub_icon, sub_text, sub_color, math.floor(10 * s), 42)
	row.Position = UDim2.new(0, math.floor(8 * s), 1, -math.floor(18 * s))
	row.Size = UDim2.new(1, -math.floor(16 * s), 0, math.floor(13 * s))
	host:_part(b, "BackgroundTransparency", if owned then 0.06 else 0.03)
	host:_part(stroke, "Transparency", if equipped or armed then 1.0 else 0.12)
	host:_part(img, "ImageTransparency", if owned then 1.0 else 0.3)
	host:_part(name, "TextTransparency", if owned then 1.0 else 0.5)
	host:_part(rlab, "TextTransparency", if owned or afford then 1.0 else 0.75)
	if ric ~= nil then
		host:_part(ric, "ImageTransparency", if afford then 1.0 else 0.75)
	end
	b.MouseEnter:Connect(function()
		host:_part(b, "BackgroundTransparency", 0.12)
		self:_set_peek(slot, it)
	end)
	b.MouseLeave:Connect(function()
		host:_part(b, "BackgroundTransparency", if owned then 0.06 else 0.03)
		local pk = self._peek
		if pk ~= nil and pk.slot == slot and pk.item == it then
			self:_set_peek(nil, nil)
		end
	end)
	b.Activated:Connect(function()
		local se = self.ctx.session
		if price ~= nil and afford and se ~= nil then
			-- the first press arms, the second buys
			if armed then
				self._armed = nil
				self.ctx:sfx("click")
				se:buy(it.id)
			else
				self._armed = it.id
				self.ctx:sfx("click")
				self:_rebuild()
				self:_set_peek(slot, it)
			end
			return
		end
		if not owned then
			-- (touch has no hover: a press on a locked one previews it)
			self:_set_peek(slot, it)
			self.ctx:sfx("deny", -6.0)
			return
		end
		if se ~= nil then
			self.ctx:sfx("click")
			self._peek = nil
			se:equip(slot, if it then it.id else false)
		end
	end)
	b.Parent = parent
	return b
end

--- A rarity's section: its name in the rarity's colour over a thin rule, then a grid of its cards.
--- Returns the section (in self._cards) and the grid frame the cards go in.
function Locker._section(self, rar: any, order: number): (Frame, Frame)
	local s = UITheme.scale
	local host = self._host
	local sec = make("Frame", {
		Name = "Section_" .. rar.id,
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -math.floor(12 * s), 0, 0),
		LayoutOrder = order,
		ZIndex = 41,
	}, self._sf)
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, math.floor(6 * s)) }, sec)
	make("UIPadding", { PaddingTop = UDim.new(0, if order > 1 then math.floor(10 * s) else 0) }, sec)
	local head = make("Frame", {
		Name = "Head",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, math.floor(18 * s)),
		LayoutOrder = 1,
		ZIndex = 41,
	}, sec)
	local col = c3(rar.color)
	local lab = make("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT_H,
		TextSize = math.floor(13 * s),
		TextColor3 = col,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = Loc.upper(Loc.text(rar.name)),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		ZIndex = 42,
	}, head)
	host:_part(lab, "TextTransparency", 1.0)
	local rule = make("Frame", {
		BackgroundColor3 = col,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.new(1, -math.floor((#rar.name * 10 + 14) * s), 0, 1),
		ZIndex = 42,
	}, head)
	host:_part(rule, "BackgroundTransparency", 0.25)
	local grid = make("Frame", {
		Name = "Grid",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = 2,
		ZIndex = 41,
	}, sec)
	local cell = Locker.SKIN_CARD * (if self.ctx.compact then 0.82 else 1)
	make("UIGridLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		CellSize = UDim2.fromOffset(math.floor(cell.X * s), math.floor(cell.Y * s)),
		CellPadding = UDim2.fromOffset(math.floor(8 * s), math.floor(8 * s)),
	}, grid)
	table.insert(self._cards, sec)
	return sec, grid
end

-- The Get Stars tab: game passes (Data/Passes) and Star packs (Data/Products `stars`), bought with Robux.
-- A row: its title big, what it gives under it, its price on the right. An offer whose product isn't made
-- yet (id 0) says "NOT ON SALE"; a pass already owned "OWNED".
--- `star`: a star after the title (a Star pack); `bonus`: the pack's bonus percent, in green after the blurb.
function Locker._offer_row(
	self,
	order: number,
	title: string,
	blurb: string,
	robux: number?,
	foot: string?,
	live: boolean,
	on_press: () -> (),
	star: boolean?,
	bonus: number?
)
	local s = UITheme.scale
	local host = self._host
	local b = make("TextButton", {
		Name = title,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		LayoutOrder = order,
		Size = UDim2.new(1, -math.floor(12 * s), 0, math.floor(Locker.OFFER_ROW_H * s)),
		ZIndex = 41,
	}, nil)
	make("UICorner", { CornerRadius = UDim.new(0, math.floor(12 * s)) }, b)
	local stroke = make("UIStroke", {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = if live then amber() else Color3.new(1, 1, 1),
	}, b)
	local pw = math.floor(150 * s)
	local function text(t: string, size: number, y: number, h: number, font: Font, color: Color3): TextLabel
		local l = make("TextLabel", {
			BackgroundTransparency = 1,
			FontFace = font,
			TextSize = math.floor(size * s),
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = t,
			Position = UDim2.fromOffset(math.floor(18 * s), math.floor(y * s)),
			Size = UDim2.new(1, -(pw + math.floor(30 * s)), 0, math.floor(h * s)),
			ZIndex = 42,
		}, b)
		host:_part(l, "TextTransparency", if live then 1.0 else 0.5)
		return l
	end
	local tl = text(title, 22, 12, 28, FONT_H, Color3.new(1, 1, 1))
	if star then
		-- the star right after the title's text, the amount in the star's gold (2026-11-04)
		tl.TextColor3 = GOLD
		tl.Size = UDim2.fromOffset(0, math.floor(28 * s))
		tl.AutomaticSize = Enum.AutomaticSize.X
		local sic = make("ImageLabel", {
			Name = "Star",
			BackgroundTransparency = 1,
			Image = UITheme.icon("star") or "",
			ImageColor3 = GOLD,
			AnchorPoint = Vector2.new(0, 0.5),
			Size = UDim2.fromOffset(math.floor(22 * s), math.floor(22 * s)),
			ZIndex = 42,
		}, b)
		host:_part(sic, "ImageTransparency", if live then 1.0 else 0.5)
		local function place()
			sic.Position = UDim2.fromOffset(math.floor(18 * s) + tl.AbsoluteSize.X + math.floor(6 * s), math.floor(26 * s))
		end
		tl:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
		place()
	end
	local bl = text(blurb, 13, 42, 18, FONT_M, Color3.fromRGB(170, 178, 200))
	if bonus ~= nil and bonus > 0 then
		bl.RichText = true
		bl.Text = string.format('%s  ·  <font color="#4CD964">%d%% bonus Stars</font>', blurb, bonus)
	end
	-- the price, right: the Robux icon and price in white, as Roblox shows them
	local row, ic, lab = price_row(
		b,
		if robux ~= nil then "robux" else nil,
		if robux ~= nil then commas(robux) else (foot or ""),
		if robux ~= nil then Color3.new(1, 1, 1) else DIM,
		math.floor((if robux ~= nil then 20 else 14) * s),
		42
	)
	row.AnchorPoint = Vector2.new(1, 0.5)
	row.Position = UDim2.new(1, -math.floor(18 * s), 0.5, 0)
	row.Size = UDim2.fromOffset(pw, math.floor(30 * s))
	row:FindFirstChildOfClass("UIListLayout").HorizontalAlignment = Enum.HorizontalAlignment.Right
	host:_part(lab, "TextTransparency", if live then 1.0 else 0.6)
	if ic ~= nil then
		host:_part(ic, "ImageTransparency", if live then 1.0 else 0.6)
	end
	host:_part(b, "BackgroundTransparency", 0.05)
	host:_part(stroke, "Transparency", if live then 0.45 else 0.12)
	b.MouseEnter:Connect(function()
		host:_part(b, "BackgroundTransparency", 0.1)
	end)
	b.MouseLeave:Connect(function()
		host:_part(b, "BackgroundTransparency", 0.05)
	end)
	b.Activated:Connect(function()
		if not live then
			self.ctx:sfx("deny", -6.0)
			return
		end
		self.ctx:sfx("click")
		on_press()
	end)
	b.Parent = self._sf
	table.insert(self._cards, b)
	return b
end

--- The extra Stars a pack gives over the smallest one's rate, in percent (0: none). `packs`: their keys.
function Locker.pack_bonus(Products: any, packs: { string }, key: string): number
	local base = nil
	for _, k in packs do
		local p = Products[k]
		local rate = p.stars / math.max(1, tonumber(p.robux) or 1)
		if base == nil or rate < base then
			base = rate
		end
	end
	local p = Products[key]
	if base == nil or p == nil then
		return 0
	end
	local rate = p.stars / math.max(1, tonumber(p.robux) or 1)
	return math.max(0, math.floor((rate / base - 1) * 100 + 0.5))
end

function Locker._offers(self)
	local Products = shared("Products")
	local Passes = shared("Passes")
	local Prices = require("./Prices") :: any
	Prices.fetch()
	local inv = self:_inv()
	local function prompt(kind: string, id: number)
		if not IS_ROBLOX then
			return
		end
		pcall(function()
			local mps = game:GetService("MarketplaceService")
			local me = game:GetService("Players").LocalPlayer
			if kind == "pass" then
				mps:PromptGamePassPurchase(me, id)
			else
				mps:PromptProductPurchase(me, id)
			end
		end)
	end
	local order = 0
	local pass_keys = {}
	for key in Passes do
		table.insert(pass_keys, key)
	end
	table.sort(pass_keys)
	for _, key in pass_keys do
		local p = Passes[key]
		order += 1
		local owned = inv.passes ~= nil and inv.passes[key] == true
		local live = p.id ~= 0 and not owned
		local robux = if live then Prices.pass_robux(key) else nil
		local foot = if owned then L("locker.owned") elseif p.id == 0 then L("locker.not_on_sale") else nil
		self:_offer_row(order, p.name, p.blurb, robux, foot, live, function()
			prompt("pass", p.id)
		end)
	end
	local packs = {}
	for key, p in Products do
		if type(p) == "table" and type(p.stars) == "number" then
			table.insert(packs, key)
		end
	end
	table.sort(packs, function(a, b)
		return Products[a].stars < Products[b].stars
	end)
	for _, key in packs do
		local p = Products[key]
		order += 1
		local live = p.id ~= 0
		local bonus = Locker.pack_bonus(Products, packs, key)
		self:_offer_row(
			order,
			commas(p.stars),
			L("locker.straight_into_your_balance"),
			if live then Prices.robux(key) else nil,
			if live then nil else L("locker.not_on_sale"),
			live,
			function()
				prompt("product", p.id)
			end,
			true,
			bonus
		)
	end
end

function Locker._clear(self)
	for _, b in self._cards do
		self._host:_drop_part(b)
		for _, d in b:GetDescendants() do
			self._host:_drop_part(d)
		end
		b:Destroy()
	end
	table.clear(self._cards)
end

function Locker._rebuild(self)
	self:_clear()
	local s = UITheme.scale
	local slot = Locker.TABS[self._tab][2]
	self._list.Padding = UDim.new(0, math.floor((if slot == "stars" then 8 else 4) * s))
	if slot == "stars" then
		self:_offers()
		return
	end
	local inv = self:_inv()
	-- every item of the tab by rarity (an exclusive only for whoever owns it: nobody else can get one)
	local by: { [string]: { any } } = {}
	local function put(it: any)
		local r = it.rarity or "common"
		by[r] = by[r] or {}
		table.insert(by[r], it)
	end
	-- (a Battle Pass season's item: shown once owned, or while its season runs; Data/Seasons)
	local season = nil
	pcall(function()
		local BP = UICtx.data("BattlePass")
		local bp = inv.bp
		season = if type(bp) == "table" and type(bp.s) == "string" then bp.s else BP.season_of(os.time())
	end)
	for _, it in Cosmetics.all() do
		if it.kind == slot and (it.season == nil or it.season == season or inv.owned[it.id] == true) then
			put(it)
		end
	end
	for _, it in Cosmetics.exclusives() do
		if it.kind == slot and inv.owned[it.id] == true then
			put(it)
		end
	end
	local function has(it: any): boolean
		return it.default == true or inv.owned[it.id] == true or Cosmetics.rank_unlocked(it, inv.tier)
	end
	local order = 0
	for _, rid in Locker.section_order() do
		local list = by[rid]
		-- ("None" heads the Common section; an avatar is always worn: no None for it)
		local none = rid == "common" and slot ~= "icon"
		if (list == nil or #list == 0) and not none then
			continue
		end
		list = list or {}
		-- owned first, then by name
		table.sort(list, function(a, b)
			local oa, ob = has(a), has(b)
			if oa ~= ob then
				return oa
			end
			return a.name < b.name
		end)
		order += 1
		local _, grid = self:_section(Cosmetics.rarity(rid), order)
		if none then
			self:_card(nil, 0, slot, grid)
		end
		for i, it in list do
			self:_card(it, i, slot, grid)
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- Open / close / layout
-- ---------------------------------------------------------------------------------------------

function Locker.open(self)
	if self.is_open then
		return
	end
	self.is_open = true
	self._peek = nil
	self._color_i = math.random(1, #Locker.TERRITORY_COLORS)
	self._land_key = nil
	self:_report("locker_opened")
	self:_refresh_count()
	self:set_visible(true)
	self:apply_layout()
	self:_refresh_preview()
	self._panel:set_modulate_a(1.0)
	self._dim:set_modulate_a(0.0)
	W.fade(self._dim, 1.0, 0.2)
	UICtx.pop_in(self._panel, 0.0, 0.94, 0.3)
	self.ctx:sfx("open")
end

function Locker.close(self)
	if not self.is_open then
		return
	end
	self.is_open = false
	self._armed = nil
	self._peek = nil
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

function Locker.apply_layout(self)
	local ctx = self.ctx
	local area = ctx:clear_rect()
	local compact = ctx.compact
	self._panel:set_padding(if compact then 14 else 22, if compact then 10 else 20, if compact then 14 else 22, if compact then 10 else 20)
	self._v:set_separation(if compact then 8 else 12)
	local pw = if compact then Locker.PREVIEW_W_PHONE else Locker.PREVIEW_W
	local gw = math.clamp(area.Width - 80 - pw - 14, 260, Locker.GRID_SIZE.X)
	local gh = math.clamp(area.Height - (if compact then 110 else 150), 120, Locker.GRID_SIZE.Y)
	self._host:set_min_size(Vector2.new(gw, gh))
	self._pv:set_min_size(Vector2.new(pw, gh))
	local over = self._panel:get_combined_minimum_size().Y - (area.Height - 4)
	if over > 0 then
		gh = math.max(100, gh - over)
		self._host:set_min_size(Vector2.new(gw, gh))
		self._pv:set_min_size(Vector2.new(pw, gh))
	end
	self:_layout_preview(pw, gh)
	if self.is_open then
		self:_rebuild()
	end
	self:_center()
end

function Locker._center(self)
	local ctx = self.ctx
	local area = ctx:clear_rect()
	local sz = self._panel:get_combined_minimum_size()
	local p = area.Min + (Vector2.new(area.Width, area.Height) - sz) * 0.5
	local y = math.max(p.Y, area.Min.Y + 4.0)
	local rp = Vector2.new(math.floor(p.X + 0.5), math.floor(y + 0.5))
	self._panel:set_offsets(rp.X, rp.Y, rp.X, rp.Y)
	self._panel:reset_size()
end

return Locker
