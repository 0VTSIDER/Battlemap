#!/usr/bin/env python3
"""The one way assets reach Roblox: Open Cloud through Studio's MCP, no API key.

Usage:
  .venv/Scripts/python tools/upload.py <file> [...]    # prints JSON {path: "rbxassetid://id"}
  (as a module) upload.upload_asset(path, name=..., description=...) -> asset id
                upload.upload_images([paths]) -> {abs path: uri}

Needs the published place open in Studio (studio.py open-published) with the Publish & manage assets
permission on. Only files inside paths.EXPORTS (assets/exports) or, for the original art (paths.PRIVATE_PREFIXES),
paths.PRIVATE_EXPORTS can be uploaded; both are approved upload folders. Each upload is permanent,
so the ledger (paths.LEDGER: one entry per file with its hash, id, name, licence and moderation state) skips
anything already up: a file is uploaded again only when its bytes change, and identical bytes reuse the same
id. Run tools/ledger.py check after uploading.

Names: `name`, else bm_<folders>_<file> from the path inside exports (UI/icons/check.png ->
bm_ui_icons_check). Roblox keeps at most 50 characters.
"""
import hashlib
import json
import os
import re
import sys
import tempfile
import time

try:
    import fcntl
except ImportError:  # Windows
    fcntl = None
    import msvcrt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger as ledger_tool  # noqa: E402
import paths  # noqa: E402
import studio  # noqa: E402

CREATOR = {"userId": "11217351242"}
LOCK = os.path.join(tempfile.gettempdir(), "battlemap_upload.lock")
TYPES = {".png": "Image", ".jpg": "Image", ".jpeg": "Image", ".bmp": "Image", ".tga": "Image",
         ".ogg": "Audio", ".mp3": "Audio", ".wav": "Audio", ".flac": "Audio",
         ".glb": "Model", ".gltf": "Model", ".fbx": "Model", ".rbxm": "Model", ".rbxmx": "Model"}
MAX_TRIES = 8


class UploadError(RuntimeError):
    pass


class _Lock:
    def __enter__(self):
        self.f = open(LOCK, "w")
        if fcntl:
            fcntl.flock(self.f, fcntl.LOCK_EX)
        else:
            msvcrt.locking(self.f.fileno(), msvcrt.LK_LOCK, 1)

    def __exit__(self, *a):
        self.f.close()


def load_ledger():
    if not os.path.exists(paths.LEDGER):
        return {}
    with open(paths.LEDGER, encoding="utf-8") as f:
        return json.load(f)


def save_ledger(ledger):
    tmp = paths.LEDGER + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(ledger, f, indent=1, sort_keys=True)
    os.replace(tmp, paths.LEDGER)


def rel_path(path):
    """`path` inside exports (assets/exports, or the private exports for private art), with forward slashes;
    refuses anything elsewhere, and private art outside the private exports (or the reverse)."""
    for root, private in ((paths.EXPORTS, False), (paths.PRIVATE_EXPORTS, True)):
        try:
            rel = os.path.relpath(os.path.abspath(path), os.path.abspath(root)).replace("\\", "/")
        except ValueError:  # (another drive)
            continue
        if rel == ".." or rel.startswith("../") or os.path.isabs(rel):
            continue
        if paths.is_private(rel) != private:
            want = paths.PRIVATE_EXPORTS if paths.is_private(rel) else paths.EXPORTS
            raise UploadError(f"{path}: {rel} belongs in {want} (paths.PRIVATE_PREFIXES)")
        return rel
    raise UploadError(f"{path} is not inside {paths.EXPORTS} or {paths.PRIVATE_EXPORTS}: put finished files there")


def default_name(rel):
    parts = rel.lower().rsplit(".", 1)[0].split("/")
    if len(parts) > 1 and parts[-1].startswith(parts[-2] + "_"):
        parts.pop(-2)  # Flags/flags_1 -> bm_flags_1
    return re.sub(r"[^a-z0-9_]+", "_", "bm_" + "_".join(parts))[:50]


class Session:
    """One connection to the published place's Studio, retrying when Roblox rate-limits."""

    def __init__(self):
        self.c = studio.Client()
        self.sid = studio.published_studio(self.c)

    def close(self):
        self.c.close()

    def call(self, method, endpoint, **args):
        delay = 2.0
        for _ in range(MAX_TRIES):
            res = self.c.call("open_cloud_invoke", dict(method=method, endpoint=endpoint, studio_id=self.sid, **args))
            txt = studio.text_of(res)
            m = re.search(r"-> (\d{3})", txt.split("\n", 1)[0])
            code = int(m.group(1)) if m else 0
            if code == 429 or code >= 500:
                time.sleep(delay)
                delay = min(delay * 2, 60.0)
                continue
            if not 200 <= code < 300:
                raise UploadError(f"{method} {endpoint}: {txt[:600]}")
            return json.loads(txt.split("\n\n", 1)[1])
        raise UploadError(f"{method} {endpoint}: still failing after {MAX_TRIES} tries")

    def upload(self, path, asset_type, name, description):
        body = {"request": {"assetType": asset_type, "displayName": name[:50], "description": description,
                            "creationContext": {"creator": CREATOR}}}
        op = self.call("POST", "/assets/v1/assets", body=json.dumps(body),
                       files=[{"name": "fileContent", "path": os.path.abspath(path).replace("\\", "/")}],
                       scopes=["asset:read", "asset:write"])
        op_id = op.get("operationId") or op.get("path", "").split("/")[-1]
        delay = 1.0
        for _ in range(90):
            if op.get("done"):
                break
            time.sleep(delay)
            delay = min(delay * 1.5, 8.0)
            op = self.call("GET", f"/assets/v1/operations/{op_id}", scopes=["asset:read"])
        if not op.get("done") or "error" in op:
            raise UploadError(f"upload of {path} failed: {json.dumps(op)[:600]}")
        return op["response"]

    def state(self, asset_id):
        a = self.call("GET", f"/assets/v1/assets/{asset_id}?readMask=moderationResult,state,displayName",
                      scopes=["asset:read"])
        return (a.get("moderationResult") or {}).get("moderationState", "?")


def _upload_locked(session, ledger, path, asset_type, name, description):
    rel = rel_path(path)
    with open(path, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    entry = ledger.get(rel)
    if entry and entry["sha256"] == digest:
        return entry["id"]
    same = next((e for e in ledger.values() if e["sha256"] == digest), None)
    if same:
        ledger[rel] = dict(same)
        save_ledger(ledger)
        return same["id"]
    kind = asset_type or TYPES.get(os.path.splitext(path)[1].lower())
    if not kind:
        raise UploadError(f"{path}: no Roblox asset type for this file")
    label = name or default_name(rel)
    resp = session.upload(path, kind, label, description or f"Battlemap: {rel}")
    ledger[rel] = ledger_tool.fill_row(rel, {
        "sha256": digest, "id": str(resp["assetId"]), "name": label, "type": kind,
        "moderation": (resp.get("moderationResult") or {}).get("moderationState", "?"),
        "uploaded": time.strftime("%Y-%m-%d %H:%M:%S")})
    save_ledger(ledger)
    print(f"{rel}: rbxassetid://{resp['assetId']} {label} moderation={ledger[rel]['moderation']}", flush=True)
    return ledger[rel]["id"]


def upload_asset(path, asset_type=None, name=None, description=None):
    """Upload `path` unless the ledger already has these bytes; its asset id."""
    with _Lock():
        ledger = load_ledger()
        rel = rel_path(path)
        with open(path, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        if rel in ledger and ledger[rel]["sha256"] == digest:
            return ledger[rel]["id"]
        session = Session()
        try:
            return _upload_locked(session, ledger, path, asset_type, name, description)
        finally:
            session.close()


def upload_images(file_paths, description=None):
    """{abs path: "rbxassetid://id"} for every file, uploading only what the ledger lacks."""
    file_paths = [os.path.abspath(p) for p in file_paths]
    with _Lock():
        ledger = load_ledger()
        known = {e["sha256"]: e["id"] for e in ledger.values()}
        session = None
        result = {}
        try:
            for p in file_paths:
                with open(p, "rb") as f:
                    digest = hashlib.sha256(f.read()).hexdigest()
                if digest in known:
                    rel = rel_path(p)
                    if rel not in ledger or ledger[rel]["sha256"] != digest:
                        ledger[rel] = dict(next(e for e in ledger.values() if e["sha256"] == digest))
                        save_ledger(ledger)
                    result[p] = "rbxassetid://" + known[digest]
                    continue
                session = session or Session()
                aid = _upload_locked(session, ledger, p, None, None, description)
                known[digest] = aid
                result[p] = "rbxassetid://" + aid
        finally:
            if session:
                session.close()
    return result


def wait_approved(asset_ids, timeout_s=1800):
    """True once Roblox's moderation approves every id. Studio shows an image under review to its owner,
    but players get a blank, so a manifest should point at an asset only after this."""
    session = Session()
    try:
        t0 = time.time()
        while True:
            states = {a: session.state(a) for a in asset_ids}
            waiting = [a for a, s in states.items() if s != "Approved"]
            if not waiting:
                return True
            bad = [a for a in waiting if states[a] not in ("Reviewing", "Pending", "?")]
            if bad or time.time() - t0 > timeout_s:
                print("not approved:", ", ".join(f"{a} {states[a]}" for a in waiting))
                return False
            print(f"waiting for moderation: {len(waiting)} under review ({int(time.time() - t0)} s)", flush=True)
            time.sleep(20)
    finally:
        session.close()


if __name__ == "__main__":
    print(json.dumps(upload_images(sys.argv[1:]), indent=1))
