--!nocheck
-- The phone tray's widths (client/UI/TrayFit): one row while it fits, the slots narrowing first, else
-- two rows sized for the longer one. Run: .bin/lune run tests/tray_fit.luau
require("./prelude")
local TrayFit = require("../src/client/UI/TrayFit")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

expect(TrayFit.need(10, 60, 8) == 10 * 68 + TrayFit.CHROME, "a row's width: its slots and the chrome")

-- one row
do
	local f = TrayFit.fit(1000, 11, 6)
	expect(f.slot_w == 60 and f.sep == 8 and not f.two_rows, "room for all: full slots")
	f = TrayFit.fit(733, 11, 6)
	expect(f.slot_w == 58 and f.sep == 5 and not f.two_rows, "an iPhone's 733: slots of 58")
	expect(TrayFit.need(11, f.slot_w, f.sep) <= 733, "  and it fits")
	f = TrayFit.fit(682, 11, 6)
	expect(f.slot_w == 54 and not f.two_rows, "682: the narrowest slots still fit")
	f = TrayFit.fit(681, 11, 6)
	expect(f.two_rows and f.slot_w == 60 and f.sep == 8, "681: two rows, full slots again")
end

-- every slot (ten, and the Arsenal's eight): two rows on a phone, each one that fits
do
	local f = TrayFit.fit(733, 18, 10)
	expect(f.two_rows, "18 slots on an iPhone: two rows")
	expect(TrayFit.need(10, f.slot_w, f.sep) <= 733, "  the longer row fits")
	f = TrayFit.fit(667, 18, 10)
	expect(f.two_rows and f.slot_w < 60 and TrayFit.need(10, f.slot_w, f.sep) <= 667, "667: the rows narrow to fit")
	f = TrayFit.fit(1300, 18, 10)
	expect(not f.two_rows and f.slot_w == 60, "a tablet: one row")
end

if fails > 0 then
	error(fails .. " tray fit checks failed")
end
print("tray_fit: all ok")
