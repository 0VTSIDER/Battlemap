#!/usr/bin/env python3
"""Starts the self-playing match for a screen recording (src/client/Dev/AdReel.luau) in the Studio that
has build/Battlemap.rbxl open: syncs the sources, starts a play session with the dev commands on
(workspace attribute BM_DIAG) and sends `reel`. The match then plays run after run, a title screen
between two, until `stop`.

Usage (Windows: PYTHONUTF8=1):
    .venv/Scripts/python tools/trailer/reel.py start     sync, play, start the reel
    .venv/Scripts/python tools/trailer/reel.py state     the shot it is on; this run's log; the last run's
    .venv/Scripts/python tools/trailer/reel.py stop      stop the reel and the play session
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import studio  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

DIAG = r'''
local p = game:GetService("Players").LocalPlayer
local t0 = os.clock()
while p:GetAttribute("af_mode") == nil and os.clock() - t0 < 40 do task.wait(0.2) end
p:SetAttribute("af_cmd_result", nil)
p:SetAttribute("af_cmd", "%s")
while p:GetAttribute("af_cmd_result") == nil and os.clock() - t0 < 50 do task.wait(0.05) end
return tostring(p:GetAttribute("af_cmd_result"))
'''

STATE = r'''
local p = game:GetService("Players").LocalPlayer
local vp = workspace.CurrentCamera.ViewportSize
return ("%s\nviewport %dx%d\nthis run: %s\nlast run: %s"):format(tostring(p:GetAttribute("af_reel")), vp.X, vp.Y,
	tostring(p:GetAttribute("af_reel_log")), tostring(p:GetAttribute("af_reel_last")))
'''


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd not in ("start", "state", "stop"):
        print(__doc__)
        sys.exit(1)
    if cmd == "start":
        # (the sync needs edit mode; its own Client, closed before this one opens)
        # (PYTHONUTF8: the sources are UTF-8, and Windows would read them as cp1252)
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "sync.py")], check=True, cwd=ROOT,
                       env=dict(os.environ, PYTHONUTF8="1"))
    c = studio.Client()
    try:
        sid = studio.pick_studio(c)

        def luau(code, ctx):
            return studio.text_of(c.call("execute_luau", {"studio_id": sid, "datamodel_type": ctx, "code": code}))

        if cmd == "start":
            print(luau('workspace:SetAttribute("BM_DIAG", true) return "dev commands on"', "Edit"))
            print(studio.text_of(c.call("start_stop_play", {"studio_id": sid, "is_start": True})))
            time.sleep(3.0)
            print(luau(DIAG % "reel", "Client"))
        elif cmd == "state":
            print(luau(STATE, "Client"))
        else:
            print(luau(DIAG % "reel stop", "Client"))
            time.sleep(1.5)
            print(studio.text_of(c.call("start_stop_play", {"studio_id": sid, "is_start": False})))
    finally:
        c.close()


if __name__ == "__main__":
    main()
