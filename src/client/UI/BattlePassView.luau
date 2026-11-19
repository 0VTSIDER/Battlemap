--!nonstrict
-- The Battle Pass on the client (2026-11-18): what the bar, the missions panel, the Premium offer and the
-- results screen read from the session's inventory (Session.inventory.bp: Data/BattlePass.view) and the
-- shared Data modules. Plain helpers, no widgets: UI/BattlePassBar, UI/BattlePassPanel, UI/GameOver.
local UITheme = require("./UITheme")
local UICtx = require("./UICtx")
local Loc = UITheme.core("Loc")
local L = Loc.t

local View = {}

local function data(name: string): any
	return UICtx.data(name)
end

local function c3(hex: number): Color3
	return Color3.fromRGB((hex // 65536) % 256, (hex // 256) % 256, hex % 256)
end
View.c3 = c3

--- The difficulty colours of the missions (easy, medium, hard).
View.DIFF_COLORS = { easy = UITheme.GREEN, medium = UITheme.CYAN, hard = UITheme.VIOLET }

--- The pass as the client knows it: the inventory's `bp` (or an empty one before it arrives), with its
--- clock (`now()`: the server's time then, plus the time since), level and today's missions.
function View.state(session: any): any
	local BP = data("BattlePass")
	local Missions = data("Missions")
	local inv = if session ~= nil then session.inventory else nil
	local v = if inv ~= nil then inv.bp else nil
	local clock = if inv ~= nil then inv.bp_clock or os.clock() else os.clock()
	local server_now = if v ~= nil and type(v.now) == "number" then v.now else os.time()
	local function now(): number
		return server_now + (os.clock() - clock)
	end
	local season = if v ~= nil and type(v.s) == "string" then v.s else BP.season_of(now())
	local xp = if v ~= nil then math.max(0, math.floor(tonumber(v.xp) or 0)) else 0
	local level, into, need = BP.progress(xp)
	local day = if v ~= nil and type(v.d) == "number" then v.d else BP.day_of(now())
	local uid = if typeof(game) == "Instance" then (game :: any):GetService("Players").LocalPlayer.UserId else 0
	local missions = {}
	for _, x in Missions.today(uid, day) do
		local done = v ~= nil and type(v.md) == "table" and v.md[x.id] == true
		local n = if v ~= nil and type(v.mp) == "table" then tonumber(v.mp[x.id]) or 0 else 0
		table.insert(missions, { m = x, n = if done then x.goal else math.min(n, x.goal), done = done })
	end
	return {
		loaded = v ~= nil,
		season = season,
		xp = xp,
		level = level,
		into = into,
		need = need,
		prem = v ~= nil and v.prem == true,
		day = day,
		ends = if v ~= nil and type(v.ends) == "number" then v.ends else BP.season_end(season),
		now = now,
		missions = missions,
	}
end

--- How many of today's missions are done.
function View.done_count(st: any): number
	local n = 0
	for _, m in st.missions do
		if m.done then
			n += 1
		end
	end
	return n
end

--- "5h 12m" (under an hour: "12m").
function View.fmt_left(secs: number): string
	local m = math.max(0, math.floor(secs / 60))
	local h = m // 60
	return if h > 0 then L("time.hm", { h = h, m = string.format("%02d", m % 60) }) else L("time.m", { m = m })
end

--- "12 days left in the season" / "Last day of the season".
function View.days_left_text(st: any): string
	local n = math.max(1, math.ceil((st.ends - st.now()) / 86400))
	return if n <= 1 then L("bp.day_left") else L("bp.days_left", { n = n })
end

--- The season's name (Data/Seasons; a month with no entry reruns one).
function View.season_name(season_id: string): string
	local s = data("Seasons").get(season_id)
	return if s ~= nil then L(s.name) else L("bp.battle_pass")
end

--- A mission's text, its goal formatted.
function View.mission_text(x: any): string
	local Missions = data("Missions")
	return L(Missions.key(x), { n = UICtx.commas(x.goal), k = Missions.place(x) or "" })
end

local KIND_KEYS = { badge = "bp.kind_badge", frame = "bp.kind_frame", icon = "bp.kind_icon", skin = "bp.kind_skin" }

--- A reward (BattlePass.reward) for show: { name, color (rarity), rarity (Cosmetics.RARITIES entry), kind
--- (a label: "Territory skin"... or nil for Stars), item (the catalog item or nil), stars }.
function View.reward_info(r: any): any
	local BP = data("BattlePass")
	local Cosmetics = data("Cosmetics")
	local rar = Cosmetics.rarity(BP.rarity(r))
	if r.kind == "item" then
		local it = Cosmetics.item(r.id)
		return {
			name = if it ~= nil then it.name else tostring(r.id),
			color = c3(rar.color),
			rarity = rar,
			kind = if it ~= nil and KIND_KEYS[it.kind] then L(KIND_KEYS[it.kind]) else nil,
			item = it,
		}
	end
	return {
		name = L("bp.reward_stars", { n = UICtx.commas(r.stars or 0) }),
		color = c3(rar.color),
		rarity = rar,
		stars = r.stars,
	}
end

--- Show reward `r`'s picture in ImageLabel `img`: the item (as the Locker shows it), or the Stars icon.
function View.show_reward(img: ImageLabel, r: any)
	local info = View.reward_info(r)
	if info.item ~= nil then
		img.ImageColor3 = Color3.new(1, 1, 1)
		UICtx.mod("Locker").show_item(img, info.item)
	else
		img.ImageRectOffset = Vector2.zero
		img.ImageRectSize = Vector2.zero
		img.Image = UITheme.icon("star") or ""
		img.ImageColor3 = UITheme.GOLD
	end
end

--- Can Premium be bought here: its product is made (Data/Products.bp_premium), or Studio (a test credit
--- through the dev diag's grant).
function View.premium_offered(): boolean
	local p = data("Products").bp_premium
	if p ~= nil and (p.id or 0) ~= 0 then
		return true
	end
	return typeof(game) == "Instance" and (game :: any):GetService("RunService"):IsStudio()
end

--- Buy Premium: Roblox's purchase prompt for the product (the server spends the credit on this season), or
--- in Studio, without a product, a test credit (server: studio_grant, BM_DIAG only).
function View.buy_premium(session: any)
	local p = data("Products").bp_premium
	if typeof(game) ~= "Instance" then
		return
	end
	if p ~= nil and (p.id or 0) ~= 0 then
		pcall(function()
			local mps = (game :: any):GetService("MarketplaceService")
			mps:PromptProductPurchase((game :: any):GetService("Players").LocalPlayer, p.id)
		end)
	elseif session ~= nil and type(session.use_credit) == "function" then
		session:use_credit("studio_grant:bp_premium")
	end
end

--- Premium's price in Robux (Roblox's, or the set one until it answers).
function View.premium_robux(): number
	local ok, n = pcall(function()
		return UICtx.mod("Prices").robux("bp_premium")
	end)
	if ok and type(n) == "number" then
		return n
	end
	local p = data("Products").bp_premium
	return if p ~= nil then p.robux or 0 else 0
end

return View
