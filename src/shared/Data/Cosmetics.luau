--!strict
-- Cosmetics (2026-09-29; 2026-11-03: no more crates; 2026-11-04: five rarities, catalogs built from folders).
--
-- Every catalog kind is generated into Assets/Catalog/<Kind>.luau by
-- tools/cosmetics/build.py from assets/sources/cosmetics/<kind>/<rarity>/ folders (rarity = the folder):
-- add, replace or retire an item there and rebuild; nothing here lists items.
--
--   icons   avatar icons (Catalog/Avatars): the round picture by your name on the map, the leaderboard and
--           the spawn screen in place of the Roblox head shot. The `default` ones (DEFAULT_AVATARS) are
--           everyone's from the start; a player always wears an avatar, a random default until they choose
--           (server/Purchases.default_avatar).
--   skins   territory patterns (Catalog/Skins): a mask tiled over your land (mask pixels are 2^scale tiles
--           wide). '#' = the secondary colour: your own colour lightened (tone > 0) or darkened (tone < 0),
--           or a fixed `accent`; a skin with `colors` draws '1'..'9', 'a'..'z' as colors[1..].
--   frames  rings around the avatar (Catalog/Frames). Rank frames (`rank` = a Data/Ranks tier id) are never
--           sold: worn while the player's tier reaches theirs (rank_unlocked), locked again below it.
--           Wearing none: no ring.
--   fonts   name fonts (Catalog/Fonts): Roblox's own font families (no licence needed), your name on the
--           map and the leaderboard. Wearing none: the game's font.
--   badges  small round pictures on the avatar's top-left corner (Catalog/Badges; beside the name without
--           a picture): every country's flag is a Common one. Wearing none: no badge.
-- Country flags themselves (Assets/Flags, public domain from Wikimedia Commons) are not items: country_flags()
-- (a nation's flag by its name, UI/GameOver).
--   exclusive skins (exclusive_skins) are made for particular players: never in the catalog
--           (Cosmetics.all() is the catalog; Cosmetics.exclusives() these).
-- Everything but the exclusives and the defaults is bought with Stars in the Locker (Data/Store).
local IS_ROBLOX = typeof(game) == "Instance"
local AssetsDir: any = if IS_ROBLOX
	then (game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap"):WaitForChild("Assets")
	else nil
local Flags: any = if IS_ROBLOX then require(AssetsDir.Flags) else require("../Assets/Flags")
local Avatars: any = if IS_ROBLOX
	then require(AssetsDir:WaitForChild("Catalog"):WaitForChild("Avatars"))
	else require("../Assets/Catalog/Avatars")
local Fonts: any = if IS_ROBLOX
	then require(AssetsDir:WaitForChild("Catalog"):WaitForChild("Fonts"))
	else require("../Assets/Catalog/Fonts")
local Skins: any = if IS_ROBLOX
	then require(AssetsDir:WaitForChild("Catalog"):WaitForChild("Skins"))
	else require("../Assets/Catalog/Skins")
local Badges: any = if IS_ROBLOX
	then require(AssetsDir:WaitForChild("Catalog"):WaitForChild("Badges"))
	else require("../Assets/Catalog/Badges")
local Frames: any = if IS_ROBLOX
	then require(AssetsDir:WaitForChild("Catalog"):WaitForChild("Frames"))
	else require("../Assets/Catalog/Frames")
local Ranks: any = if IS_ROBLOX then require(script.Parent.Ranks) else require("./Ranks")

local Cosmetics = {}

--- The rarities, lowest first (the Locker's order and its section per rarity; Data/Store prices each).
--- 2026-11-04: white, green, blue, purple, orange; an item's name in the Locker wears its rarity's colour.
Cosmetics.RARITIES = {
	{ id = "common", name = "Common", color = 0xF2F4F8 },
	{ id = "uncommon", name = "Uncommon", color = 0x4CD964 },
	{ id = "rare", name = "Rare", color = 0x4A90FF },
	{ id = "epic", name = "Epic", color = 0xB15CFF },
	{ id = "legendary", name = "Legendary", color = 0xFF8A1F },
}

--- The catalog's territory patterns and name fonts (generated lists; Cosmetics.item / all() resolve them).
Cosmetics.skins = Skins.items :: { any }
Cosmetics.fonts = Fonts.items :: { any }

--- Skins made for one player (2026-10-18: a custom background for the player @ilyannna, from a clip
--- of a Tie Dye pattern). Never in the catalog, never on a
--- bot player, not in the Locker's "N of M": the `owners` (Roblox user ids) own them (Purchases), and it
--- goes on the first time they join with it. Several colours: in `mask`, '.' is the owner's own fill and
--- '1'..'9', 'a'..'z' are colors[1..], drawn at `alpha`.
Cosmetics.exclusive_skins = {
	-- TIE_DYE_BEGIN (tools/assets/tie_dye.py writes this entry)
	{
		id = "tie_dye",
		name = "Tie Dye",
		owners = { 58387889 }, -- ilyannna
		scale = 0,
		alpha = 166,
		colors = { 0xD45881, 0xDA846A, 0xDEB077, 0x7FA88C, 0x6D91D5, 0xA467CF, 0xCFAADA },
		mask = {
			"71122334443333332211665576667776",
			"61122733333333332217655555666666",
			"67122222222233332216655555555556",
			"66172222222227322116555574444755",
			"56112227112222221166555444473445",
			"56711111111222711665555443333334",
			"45671111117271166755554433222233",
			"45566711172211665557444432211723",
			"44556671122211655444444322111123",
			"34455661722216754444433221666123",
			"74455661222216554447332716556123",
			"44455661223325544443322165541233",
			"44555611273344444447321665443334",
			"55556112233344447744321655744444",
			"55661122333334455544321665555755",
			"56611273333334455554322166655555",
			"66112333333344755554332711666555",
			"66123344444444555554433222116666",
			"61223444444455555554433332211666",
			"11233444445556665554444433321177",
			"72733444455666666554444444372111",
			"23337444756611166555444444332222",
			"33374444756711116655555544733223",
			"34444444556111111666755544733333",
			"44444444556111111176666574333337",
			"44444444556611111111176554433337",
			"74444445556611111177116654443333",
			"33334475555562117222211655553223",
			"27333475555432222222211665566122",
			"22233445555432222222711666661112",
			"11223745554433222222116666661111",
			"11127344444733322221166666671111",
		},
	},
	-- TIE_DYE_END
}

--- How an exclusive item shows in the Locker (not a catalog rarity).
Cosmetics.EXCLUSIVE = { id = "exclusive", name = "Exclusive", color = 0xFF6FD8 }


--- Alpha of the secondary tiles (the primary fill is MapSurface.TERRITORY_ALPHA, 150).
Cosmetics.SECONDARY_ALPHA = 190

type Item = { id: string, kind: string, name: string, rarity: string, [string]: any }

local items: { [string]: Item } = {}
local order: { Item } = {}
local function add(it: any)
	items[it.id] = it
	table.insert(order, it)
end
--- (an image kind's generated catalog: each item's atlas image and cell rect)
local function add_atlas_kind(kind: string, cat: any)
	local atlases = cat.atlases or {}
	for _, src in (cat.items or {}) :: { any } do
		local it: any = table.clone(src)
		it.kind = kind
		it.image = atlases[it.atlas or 1] or ""
		it.w = cat.cell
		it.h = cat.cell
		add(it)
	end
end
for _, s in Cosmetics.skins do
	local it: any = table.clone(s)
	it.kind = "skin"
	add(it)
end
add_atlas_kind("icon", Avatars)
add_atlas_kind("frame", Frames)
add_atlas_kind("badge", Badges)
for _, f in Cosmetics.fonts do
	local it: any = table.clone(f)
	it.kind = "font"
	add(it)
end

--- Everyone's avatar icons from the start (free, never sold: Catalog/Avatars' `default` ones); one of them
--- is worn until they choose another.
Cosmetics.DEFAULT_AVATARS = {} :: { string }
for _, it in order do
	if it.kind == "icon" and it.default then
		table.insert(Cosmetics.DEFAULT_AVATARS, it.id)
	end
end

--- The default avatar a player without one wears: a random one, the same for a user id every time
--- (nothing is saved until they choose, so the server's every read and the client must agree).
function Cosmetics.default_avatar(user_id: any): string?
	local list = Cosmetics.DEFAULT_AVATARS
	if #list == 0 then
		return nil
	end
	-- (a small hash kept under 2^53: exact for any user id)
	local u = math.floor(math.abs(tonumber(user_id) or 0))
	local p = 1000003
	local h = (u % p * 7919 + (u // p) % p * 104729 + 12345) % p
	return list[h % #list + 1]
end

-- (exclusives resolve by id like any item, but stay out of `order`: the catalog, bot players)
local exclusives: { Item } = {}
local granted: { [number]: { string } } = {}
for _, s in Cosmetics.exclusive_skins do
	local it: any = table.clone(s)
	it.kind = "skin"
	it.rarity = "exclusive"
	it.exclusive = true
	items[it.id] = it
	table.insert(exclusives, it)
	for _, uid in s.owners or {} do
		granted[uid] = granted[uid] or {}
		table.insert(granted[uid], it.id)
	end
end

function Cosmetics.item(id: any): Item?
	return if type(id) == "string" then items[id] else nil
end

--- Every catalog item (skins, avatars, frames, badges, fonts). Exclusives are not in it (Cosmetics.exclusives).
function Cosmetics.all(): { Item }
	return order
end

--- The items made for particular players (Cosmetics.exclusive_skins).
function Cosmetics.exclusives(): { Item }
	return exclusives
end

--- The exclusive item ids made for Roblox user `user_id` (empty for everyone else).
function Cosmetics.granted(user_id: any): { string }
	return if type(user_id) == "number" then (granted[user_id] or {}) else {}
end

--- May user `user_id` own item `id`? Any catalog item; an exclusive only for its owners.
function Cosmetics.may_own(id: any, user_id: any): boolean
	local it = Cosmetics.item(id)
	if it == nil then
		return false
	end
	if not it.exclusive then
		return true
	end
	for _, g in Cosmetics.granted(user_id) do
		if g == id then
			return true
		end
	end
	return false
end

--- How many store items (the catalog) a set of owned ids holds: the Locker's "N of M"
--- (exclusives don't count).
function Cosmetics.catalog_owned(owned: { [string]: any }): number
	local n = 0
	for id in owned do
		local it = items[id]
		if it ~= nil and not it.exclusive then
			n += 1
		end
	end
	return n
end

function Cosmetics.rarity(id: string): any
	if id == "exclusive" then
		return Cosmetics.EXCLUSIVE
	end
	for _, r in Cosmetics.RARITIES do
		if r.id == id then
			return r
		end
	end
	return Cosmetics.RARITIES[1]
end

local country_flags: { any }? = nil
--- Every country flag (Assets/Flags) as { code, name, image, x, y, w, h } (the rect in its atlas image).
function Cosmetics.country_flags(): { any }
	if country_flags == nil then
		local list = {}
		local a = Flags.atlases or {}
		for _, f in (Flags.flags or {}) :: { any } do
			local e = table.clone(f)
			e.image = a[f.atlas] or ""
			table.insert(list, e)
		end
		country_flags = list
	end
	return country_flags :: { any }
end

--- Show an atlas item (an icon, frame or badge: its image and cell) in ImageLabel `img`, or clear it.
function Cosmetics.show_atlas(img: any, it: any)
	if it == nil or it.image == nil or it.w == nil then
		img.Image = ""
		return
	end
	img.Image = it.image
	img.ImageRectOffset = Vector2.new(it.x, it.y)
	img.ImageRectSize = Vector2.new(it.w, it.h)
end

--- Is `it` a rank frame that rank tier `tier_id` (a Data/Ranks tier id) unlocks: theirs or a lower one's?
function Cosmetics.rank_unlocked(it: any, tier_id: any): boolean
	if type(it) ~= "table" or it.rank == nil then
		return false
	end
	local need, have = Ranks.by_id(it.rank), Ranks.by_id(tier_id)
	return need ~= nil and have ~= nil and have.index >= need.index
end

--- May someone owning `owned` ({ [id] = true }) at rank tier `tier_id` wear item `id`? Owned items, and
--- the rank frames their tier unlocks.
function Cosmetics.wearable(id: any, owned: { [string]: any }, tier_id: any): boolean
	local it = Cosmetics.item(id)
	if it == nil then
		return false
	end
	if it.rank ~= nil then
		return Cosmetics.rank_unlocked(it, tier_id)
	end
	return owned[it.id] == true
end

--- A frame's size around its avatar picture (the frame art's opening is 1 / FRAME_SCALE of it). A frame
--- whose art reaches further carries its own `scale` (Catalog/Frames; up to FRAME_SCALE_MAX).
Cosmetics.FRAME_SCALE = 1.5
Cosmetics.FRAME_SCALE_MAX = 1.8

--- Frame item `it`'s size around its avatar picture.
function Cosmetics.frame_scale(it: any): number
	local s = if type(it) == "table" then tonumber(it.scale) else nil
	return if s ~= nil and s > 0 then math.min(s, Cosmetics.FRAME_SCALE_MAX) else Cosmetics.FRAME_SCALE
end

--- Put frame item `id`'s ring around avatar picture `gui` (a GuiObject), or take it off (nil / not a frame).
function Cosmetics.apply_frame(gui: any, id: any)
	local it = Cosmetics.item(id)
	local ring = gui:FindFirstChild("BM_Frame")
	if it == nil or it.kind ~= "frame" or (it.image or "") == "" then
		if ring ~= nil then
			ring.Visible = false
		end
		return
	end
	if ring == nil then
		ring = Instance.new("ImageLabel")
		ring.Name = "BM_Frame"
		ring.BackgroundTransparency = 1
		ring.AnchorPoint = Vector2.new(0.5, 0.5)
		ring.Position = UDim2.fromScale(0.5, 0.5)
		ring.ScaleType = Enum.ScaleType.Fit
		ring.ZIndex = gui.ZIndex + 1
		ring.Parent = gui
	end
	local k = Cosmetics.frame_scale(it)
	ring.Size = UDim2.fromScale(k, k)
	ring.Image = it.image
	ring.ImageRectOffset = Vector2.new(it.x, it.y)
	ring.ImageRectSize = Vector2.new(it.w, it.h)
	ring.Visible = true
end

--- A badge's size on its avatar picture's top-left corner (Cosmetics.dress_picture; NameLayer, Leaderboard).
Cosmetics.BADGE_SCALE = 0.5

--- Dress avatar picture `img` (an ImageLabel) from a match's cosmetics entry `cz` (GameState.cosmetics):
--- their avatar icon (wearing none: their head shot, `face`), frame and badge. True when it shows a picture.
function Cosmetics.dress_picture(img: any, cz: any): boolean
	local icon = if cz ~= nil and cz.icon ~= nil then Cosmetics.item(cz.icon) else nil
	img.ImageRectOffset = Vector2.zero
	img.ImageRectSize = Vector2.zero
	local pic = false
	if icon ~= nil and icon.kind == "icon" then
		Cosmetics.show_icon(img, icon)
		img.BackgroundTransparency = 1
		pic = true
	else
		local face = if cz ~= nil and type(cz.face) == "number" then cz.face else 0
		img.Image = if face > 0 then Cosmetics.face_image(face) else ""
		pic = face > 0
	end
	Cosmetics.apply_frame(img, if cz ~= nil then cz.frame else nil)
	local badge = if cz ~= nil and cz.badge ~= nil then Cosmetics.item(cz.badge) else nil
	local b = img:FindFirstChild("BM_Badge")
	if badge ~= nil and badge.kind == "badge" then
		if b == nil then
			b = Instance.new("ImageLabel")
			b.Name = "BM_Badge"
			b.BackgroundTransparency = 1
			b.ScaleType = Enum.ScaleType.Fit
			b.Position = UDim2.fromScale(-0.22, -0.22)
			b.Size = UDim2.fromScale(Cosmetics.BADGE_SCALE, Cosmetics.BADGE_SCALE)
			b.ZIndex = img.ZIndex + 2
			b.Parent = img
		end
		Cosmetics.show_atlas(b, badge)
		b.Visible = true
	elseif b ~= nil then
		b.Visible = false
	end
	return pic
end

--- Show icon item `it` in ImageLabel `img` (or clear it): the atlas and its cell.
function Cosmetics.show_icon(img: any, it: any)
	if it == nil or it.kind ~= "icon" then
		img.Image = ""
		return
	end
	img.Image = it.image or ""
	img.ImageRectOffset = Vector2.new(it.x, it.y)
	img.ImageRectSize = Vector2.new(it.w, it.h)
end

local font_faces: { [string]: any } = {}
--- The Font a name wears for font item id `id` (nil: none, or not a font): bold where the family has it.
function Cosmetics.font_face(id: any): any
	local it = Cosmetics.item(id)
	if it == nil or it.kind ~= "font" then
		return nil
	end
	local f = font_faces[it.id]
	if f == nil then
		f = Font.new("rbxasset://fonts/families/" .. it.family .. ".json", Enum.FontWeight.Bold)
		font_faces[it.id] = f
	end
	return f
end

--- A player's Roblox head shot: the `face` of a match's cosmetics map is their user id (since
--- 2026-10-04 a little Roblox head picture shows next to each username).
function Cosmetics.face_image(user_id: number): string
	return string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48", user_id)
end

--- The colour number of mask character `ch`: 0 for the owner's own fill ('.' or anything unknown), 1 for
--- '#' (a two-tone skin's secondary), '1'..'9' -> 1..9 and 'a'..'z' -> 10..35 (a skin's `colors`).
local function mask_key(ch: string): number
	if ch == "#" then
		return 1
	end
	local b = string.byte(ch)
	if b >= 49 and b <= 57 then -- '1'..'9'
		return b - 48
	elseif b >= 97 and b <= 122 then -- 'a'..'z'
		return b - 87
	end
	return 0
end

--- A skin's mask as a buffer of w * h bytes for MapSurface: 0 = the owner's fill, 1 = a two-tone skin's
--- secondary, or k = colors[k] of a skin with `colors`.
function Cosmetics.mask(skin: any): (buffer, number, number)
	local rows = skin.mask
	local h = #rows
	local w = 0
	for _, row in rows do
		w = math.max(w, #row)
	end
	local b = buffer.create(w * h)
	for y, row in rows do
		for x = 1, #row do
			buffer.writeu8(b, (y - 1) * w + (x - 1), mask_key(string.sub(row, x, x)))
		end
	end
	return b, w, h
end

--- colors[k] of a skin with several colours as (r, g, b) floats (nil past its list, or a two-tone skin).
function Cosmetics.color(skin: any, k: number): (number?, number?, number?)
	local list = skin.colors
	local c = if type(list) == "table" then list[k] else nil
	if type(c) ~= "number" then
		return nil, nil, nil
	end
	return ((c // 65536) % 256) / 255, ((c // 256) % 256) / 255, (c % 256) / 255
end

--- The alpha (0..255) a skin's own colours are drawn at.
function Cosmetics.skin_alpha(skin: any): number
	return if type(skin.alpha) == "number" then skin.alpha else Cosmetics.SECONDARY_ALPHA
end

--- The secondary colour (r, g, b floats) of `skin` over a territory of colour (r, g, b).
function Cosmetics.secondary(skin: any, r: number, g: number, b: number): (number, number, number)
	local a = skin.accent
	if type(a) == "number" then
		return ((a // 65536) % 256) / 255, ((a // 256) % 256) / 255, (a % 256) / 255
	end
	local t = tonumber(skin.tone) or -0.2
	if t >= 0 then
		return r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t
	end
	return r * (1 + t), g * (1 + t), b * (1 + t)
end

return Cosmetics
