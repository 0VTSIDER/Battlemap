--!nonstrict
-- The Red Button, 50 Robux (2026-11-04; replaced the Takeover offer): a fallen player fires one MIRV at
-- the nation that eliminated them, from their old spawn tile (Sim.red_button). Offered on the
-- ELIMINATED screen and the spectating pill while that nation still holds land and the match is still
-- being played; once per match. A press pauses a solo match, then uses a saved credit or opens
-- Roblox's purchase prompt; the server stores the purchase as a credit (server/Purchases). The MIRV
-- launches on a credit held (solo: here, Session.red_button; a public match: on its server,
-- MatchServer.press_red_button), and the credit is spent only when it strikes a living target
-- (Sim.take_red_outcomes). A purchase whose moment passed, a target that fell before the launch or
-- the impact, or a match that ended first: the credit stays saved for the next time.
--
-- UIRoot drives it: tick() once a second, on_credits() / on_result() from the session, refresh()
-- when the ELIMINATED screen opens; pending() pauses the solo match.
local UICtx = require("./UICtx")
local L = (UICtx :: any).core("Loc").t

local RedButton = {}
RedButton.__index = RedButton

RedButton.KIND = "red_button"
--- Seconds to wait for the stored purchase / the spend before giving up (the credit stays saved).
RedButton.CREDIT_WAIT_S = 30
--- Roblox's prompt left open this long without an answer: give up (the match unpauses).
RedButton.PROMPT_WAIT_S = 180

local IS_ROBLOX = typeof(game) == "Instance"
local products_mod: any = nil
local function products(): any
	if products_mod == nil then
		products_mod = {}
		if IS_ROBLOX then
			local ok, m = pcall(function()
				return require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Battlemap").Data.Products)
			end)
			if ok and type(m) == "table" then
				products_mod = m
			end
		end
	end
	return products_mod
end

local prices_mod: any = nil
local function Prices(): any
	if prices_mod == nil then
		prices_mod = require("./Prices") :: any
	end
	return prices_mod
end

function RedButton.new(ui: any)
	local self = setmetatable({}, RedButton)
	self.ui = ui
	self.ctx = ui.ctx
	--- { target, phase = "prompt" | "credit" | "using", since }
	self._pending = nil
	--- the match state each milestone was reported for (once per match)
	self._offer_for = nil
	self._click_for = nil
	--- the match state the button was already pressed in (once per match)
	self._used_for = nil
	self._shown_key = ""
	if IS_ROBLOX then
		local mps = game:GetService("MarketplaceService")
		self._conn = mps.PromptProductPurchaseFinished:Connect(
			function(user_id: number, product_id: number, purchased: boolean)
				self:_on_prompt_done(user_id, product_id, purchased)
			end
		)
	end
	return self
end

function RedButton.product_id(self): number
	if self._preview_id ~= nil then
		return self._preview_id -- (dev diagnostics: preview the priced offer before the product exists)
	end
	local p = products()[RedButton.KIND]
	return if type(p) == "table" then (tonumber(p.id) or 0) else 0
end

--- Roblox's price for this player (UI/Prices), the set one until it answers.
function RedButton.price(_self): number
	local p = products()[RedButton.KIND]
	if type(p) ~= "table" then
		return 50
	end
	Prices().fetch()
	local r = Prices().robux(RedButton.KIND)
	return if r > 0 then r else (tonumber(p.robux) or 50)
end

--- Red Buttons bought and not used yet.
function RedButton.saved(self): number
	local s = self.ctx.session
	local c = if s ~= nil then s.credits else nil
	return if type(c) == "table" then (tonumber(c[RedButton.KIND]) or 0) else 0
end

function RedButton.pending(self): boolean
	return self._pending ~= nil
end

--- The nation the player could press the Red Button on now (0: no offer).
function RedButton.target(self): number
	local ctx = self.ctx
	local m = ctx:mode()
	if (m ~= UICtx.MODE_SOLO and m ~= UICtx.MODE_MULTI) or not ctx:in_match() or ctx.state == nil then
		return 0
	end
	if self._used_for == ctx.state then
		return 0
	end
	local st = self.ui._stats
	local k = if st ~= nil then (tonumber(st.killer) or 0) else 0
	if st == nil or not st.elim or k == 0 then
		return 0
	end
	if self:product_id() == 0 and self:saved() <= 0 then
		return 0
	end
	local s = ctx.session
	if s == nil or type(s.can_red_button) ~= "function" or not s:can_red_button(k) then
		return 0
	end
	return k
end

function RedButton._report(self, kind: string)
	local t = self.ui.telemetry
	if t ~= nil and type(t._send) == "function" then
		t:_send(kind)
	end
end

function RedButton._notice(self, text: string, severity: number?)
	self.ui:_on_notice(text, severity or 0)
end

--- The RED BUTTON button.
function RedButton.start(self)
	local target = self:target()
	if target == 0 or self._pending ~= nil then
		return
	end
	if self._click_for ~= self.ctx.state then
		self._click_for = self.ctx.state
		self:_report("red_button_click")
	end
	self._pending = { target = target, phase = "", since = os.clock() }
	self.ui:_update_pause()
	if self:saved() > 0 then
		self:_use()
	else
		local id = self:product_id()
		if id == 0 or not IS_ROBLOX then
			self:_cancel(nil)
			return
		end
		self._pending.phase = "prompt"
		local ok = pcall(function()
			local mps = game:GetService("MarketplaceService")
			mps:PromptProductPurchase(game:GetService("Players").LocalPlayer, id)
		end)
		if not ok then
			self:_cancel(L("shop.unavailable"))
			return
		end
	end
	self:refresh()
end

function RedButton._use(self)
	local p = self._pending
	if p == nil then
		return
	end
	local s = self.ctx.session
	if self.ctx:mode() ~= UICtx.MODE_MULTI then
		-- solo: launched here on the credit held (spent when it strikes: Session._red_outcomes). A
		-- target that fell meanwhile (the purchase took a while): nothing launches, nothing is spent.
		self._pending = nil
		if s ~= nil and s:red_button(p.target) then
			self._used_for = self.ctx.state
			self.ui:_on_red_button(p.target)
		else
			self:_notice(L("red.fallen_saved"), 1)
		end
		self.ui:_update_pause()
		self:refresh()
		return
	end
	-- a public match's server launches it itself (it needs the nation; MatchServer.press_red_button)
	p.phase = "using"
	p.since = os.clock()
	if s == nil or not s:use_credit(RedButton.KIND, p.target) then
		self:_cancel(L("common.no_server"))
	end
end

function RedButton._cancel(self, message: string?)
	self._pending = nil
	self.ui:_update_pause()
	if message ~= nil then
		self:_notice(message, 0)
	end
	self:refresh()
end

function RedButton._on_prompt_done(self, _user_id: number, product_id: number, purchased: boolean)
	local p = self._pending
	if p == nil or p.phase ~= "prompt" or product_id ~= self:product_id() then
		return
	end
	if not purchased then
		self:_cancel(nil)
		return
	end
	-- bought: the server stores it (a credit) and says so; then it is spent
	p.phase = "credit"
	p.since = os.clock()
	if self:saved() > 0 then
		self:_use()
	end
	self:refresh()
end

--- The session's credits changed (a purchase stored, a credit spent).
function RedButton.on_credits(self)
	local p = self._pending
	if p ~= nil and p.phase == "credit" and self:saved() > 0 then
		self:_use()
	end
	self:refresh()
end

--- The server's answer to a public match's press (use_credit with the target): launched, or not.
--- (A solo strike's spend answers too, with nothing pending: ignored.)
function RedButton.on_result(self, kind: string, ok: boolean, reason: string?)
	local p = self._pending
	if kind ~= RedButton.KIND or p == nil or p.phase ~= "using" then
		return
	end
	self._pending = nil
	if ok then
		self._used_for = self.ctx.state
		self.ui:_on_red_button(p.target)
	elseif reason == "gone" then
		self:_notice(L("red.fallen_saved"), 1)
	else
		self:_notice(L("red.failed"), 0)
	end
	self.ui:_update_pause()
	self:refresh()
end

--- Once a second: the offer's first showing (analytics), timeouts, the buttons.
function RedButton.tick(self)
	local p = self._pending
	if p ~= nil then
		local wait = if p.phase == "prompt" then RedButton.PROMPT_WAIT_S else RedButton.CREDIT_WAIT_S
		if os.clock() - p.since > wait then
			self:_cancel(
				if p.phase == "prompt" then nil else L("red.saved")
			)
		end
	end
	if self:target() ~= 0 and self._offer_for ~= self.ctx.state then
		self._offer_for = self.ctx.state
		self:_report("red_button_offer")
	end
	self:refresh()
end

--- Show / update the offer on the ELIMINATED screen and the spectating pill.
function RedButton.refresh(self)
	local target = self:target()
	local info = nil
	if target ~= 0 then
		local st = self.ctx.state
		local o = st:get_owner(target)
		info = {
			target = target,
			name = st:owner_name(target),
			color = if o ~= nil then o.color else nil,
			price = self:price(),
			saved = self:saved(),
			busy = self._pending ~= nil,
		}
	end
	local key = if info == nil
		then ""
		else string.format("%d|%s|%d|%s|%d", info.target, info.name, info.saved, tostring(info.busy), info.price)
	if key == self._shown_key then
		return
	end
	self._shown_key = key
	self.ui.over:set_red_button(info)
	self.ui:_set_spec_red_button(info)
end

return RedButton
