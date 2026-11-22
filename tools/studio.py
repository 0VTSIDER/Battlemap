#!/usr/bin/env python3
"""Minimal MCP client for Roblox Studio's built-in StudioMCP proxy.

Usage:
  studio.py list                                  # list connected Studio instances
  studio.py tools                                 # list tool names
  studio.py call <tool> '<json args>'             # call a tool (studio_id auto-filled)
  studio.py luau <Edit|Server|Client> <file|->    # run Luau code from a file or stdin
  studio.py shot <out.png> [capture_id]           # screen capture to a PNG
  studio.py console                               # console output
  studio.py open-published                        # open the published place in Studio (for Open Cloud)

Environment:
  STUDIO_ID     target studio id (else: the instance whose name contains STUDIO_MATCH)
  STUDIO_MATCH  substring of the studio name to pick (default "battlemap.rbxl")
"""
import base64
import json
import os
import subprocess
import sys
import threading
import queue

import glob
import time


def _find_mcp():
    """StudioMCP: macOS app bundle, or on Windows the newest Roblox/Versions/*/StudioMCP.exe
    (the version folder changes with every Studio update)."""
    if sys.platform == "win32":
        found = glob.glob(os.path.join(os.environ.get("LOCALAPPDATA", ""), "Roblox", "Versions", "*", "StudioMCP.exe"))
        if found:
            return max(found, key=os.path.getmtime)
    return "/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP"


MCP = os.environ.get("STUDIO_MCP") or _find_mcp()
UNIVERSE_ID = "10774637528"
PLACE_ID = "93015372428640"


class Client:
    def __init__(self):
        self.p = subprocess.Popen([MCP, "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, bufsize=0)
        self.q = queue.Queue()
        self.next_id = 1
        threading.Thread(target=self._reader, daemon=True).start()
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "battlemap-cli", "version": "1.0"}})
        self.notify("notifications/initialized", {})

    def _reader(self):
        buf = b""
        while True:
            chunk = self.p.stdout.read(1 << 16)
            if not chunk:
                self.q.put(None)
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if line.strip():
                    try:
                        self.q.put(json.loads(line))
                    except json.JSONDecodeError:
                        pass

    def _send(self, obj):
        self.p.stdin.write((json.dumps(obj) + "\n").encode())
        self.p.stdin.flush()

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method, params, timeout=600):
        rid = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        while True:
            msg = self.q.get(timeout=timeout)
            if msg is None:
                raise RuntimeError("StudioMCP exited")
            if msg.get("id") == rid:
                if "error" in msg:
                    raise RuntimeError(json.dumps(msg["error"]))
                return msg["result"]

    def call(self, tool, args, timeout=600):
        return self.request("tools/call", {"name": tool, "arguments": args}, timeout)

    def close(self):
        try:
            self.p.stdin.close()
            self.p.terminate()
        except Exception:
            pass


def text_of(result):
    out = []
    for c in result.get("content", []):
        if c.get("type") == "text":
            out.append(c["text"])
    return "\n".join(out)


def pick_studio(c):
    if os.environ.get("STUDIO_ID"):
        return os.environ["STUDIO_ID"]
    # a fresh proxy sees no Studio for a few seconds, until Studio connects to it
    for _ in range(20):
        res = c.call("list_roblox_studios", {})
        txt = text_of(res)
        try:
            data = json.loads(txt)
        except json.JSONDecodeError:
            data = res.get("structuredContent") or {}
        studios = data.get("studios", data) if isinstance(data, dict) else data
        if studios:
            break
        time.sleep(1.0)
    match = os.environ.get("STUDIO_MATCH", "battlemap.rbxl").lower()
    for s in studios:
        name = s.get("name") or ""
        if match and match in name.lower():
            # Safety: never drive a published game (its name carries "(placeId: …)").
            if "placeId:" in name and not os.environ.get("STUDIO_ALLOW_PUBLISHED"):
                raise RuntimeError(f"refusing to target published place {name!r}")
            return s["id"]
    # No fallback to another instance: a wrong target could clobber someone else's place.
    raise RuntimeError(f"no Studio instance matches STUDIO_MATCH={match!r}; open: "
                       + ", ".join(repr(s.get("name")) for s in studios))


def published_studio(c):
    """The Studio with the published place open. Only for Open Cloud calls (tools/upload.py): MCP
    permissions are saved per published game, so a local .rbxl can't use them."""
    for _ in range(20):
        data = json.loads(text_of(c.call("list_roblox_studios", {})))
        for s in data.get("studios", []):
            if "placeId: " + PLACE_ID in (s.get("name") or ""):
                return s["id"]
        time.sleep(1.0)
    raise RuntimeError("the published place is not open in Studio: run tools/studio.py open-published")


def open_published():
    exe = os.path.join(os.path.dirname(MCP), "RobloxStudioBeta.exe")
    subprocess.Popen([exe, "-task", "EditPlace", "-placeId", PLACE_ID, "-universeId", UNIVERSE_ID])


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "open-published":
        open_published()
        return
    c = Client()
    try:
        if cmd == "list":
            print(text_of(c.call("list_roblox_studios", {})))
        elif cmd == "tools":
            res = c.request("tools/list", {})
            for t in res["tools"]:
                print(t["name"])
        elif cmd == "call":
            args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
            if "studio_id" not in args and sys.argv[2] != "list_roblox_studios":
                args["studio_id"] = pick_studio(c)
            res = c.call(sys.argv[2], args)
            print(text_of(res))
            for i, cont in enumerate(res.get("content", [])):
                if cont.get("type") == "image":
                    path = os.environ.get("STUDIO_IMG") or f"/tmp/studio_img_{os.getpid()}_{i}.png"
                    with open(path, "wb") as f:
                        f.write(base64.b64decode(cont["data"]))
                    print("image ->", path)
        elif cmd == "luau":
            dm = sys.argv[2]
            src = sys.stdin.read() if sys.argv[3] == "-" else open(sys.argv[3]).read()
            res = c.call("execute_luau", {"code": src, "datamodel_type": dm, "studio_id": pick_studio(c)})
            print(text_of(res))
            if res.get("isError"):
                sys.exit(2)
        elif cmd == "shot":
            out = sys.argv[2]
            args = {"studio_id": pick_studio(c), "capture_id": sys.argv[3] if len(sys.argv) > 3 else "cap"}
            res = c.call("screen_capture", args)
            saved = False
            for cont in res.get("content", []):
                if cont.get("type") == "image":
                    with open(out, "wb") as f:
                        f.write(base64.b64decode(cont["data"]))
                    saved = True
            print(("saved " + out) if saved else text_of(res))
        elif cmd == "console":
            print(text_of(c.call("get_console_output", {"studio_id": pick_studio(c)})))
        else:
            print("unknown command", cmd)
            sys.exit(1)
    finally:
        c.close()


if __name__ == "__main__":
    main()
