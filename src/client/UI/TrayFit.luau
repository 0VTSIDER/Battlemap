--!strict
-- Widths in the phone tray's build row (CommandBar): one row wherever it can (2026-10-04: the build
-- menu was too big), so the slots narrow first, and only then does the tray take a second row
-- (builds over nukes; the Arsenal's structures with the builds, its munitions and call with the nukes).
--
-- Numbers only (no widgets): tests/tray_fit.luau.
local TrayFit = {}

--- A phone tray slot: its usual width, and the narrowest it gets.
TrayFit.SLOT_MAX = 60.0
TrayFit.SLOT_MIN = 54.0
--- Gap between slots: the usual one, and the one of a tight row.
TrayFit.SEP = 8.0
TrayFit.SEP_TIGHT = 5.0
--- What a row holds besides its slots: the divider before the nukes and the tray's padding.
TrayFit.CHROME = 33.0

--- The width a row of `slots` slots needs.
function TrayFit.need(slots: number, slot_w: number, sep: number): number
	return slots * (slot_w + sep) + TrayFit.CHROME
end

--- The narrowest slots (full, then tight, then a pixel at a time) that fit `slots` into `avail`, or nil.
local function narrow(avail: number, slots: number): (number?, number?)
	if TrayFit.need(slots, TrayFit.SLOT_MAX, TrayFit.SEP) <= avail then
		return TrayFit.SLOT_MAX, TrayFit.SEP
	end
	local slot_w, sep = TrayFit.SLOT_MAX, TrayFit.SEP_TIGHT
	while slot_w > TrayFit.SLOT_MIN and TrayFit.need(slots, slot_w, sep) > avail do
		slot_w -= 1
	end
	if TrayFit.need(slots, slot_w, sep) <= avail then
		return slot_w, sep
	end
	return nil, nil
end

--- The phone tray. `avail`: the width between the safe edges; `slots`: every build slot in one row;
--- `longest`: the slots of the longer of the two rows, should it take two.
--- Returns { slot_w, sep, two_rows }.
function TrayFit.fit(avail: number, slots: number, longest: number): { [string]: any }
	local slot_w, sep = narrow(avail, slots)
	if slot_w ~= nil then
		return { slot_w = slot_w, sep = sep, two_rows = false }
	end
	slot_w, sep = narrow(avail, longest)
	return { slot_w = slot_w or TrayFit.SLOT_MIN, sep = sep or TrayFit.SEP_TIGHT, two_rows = true }
end

return TrayFit
