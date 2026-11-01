"""One-stop health check for a Civ V Access session, game running or not.

Reports, in order:
  - installed mod version and install state
  - whether this repo's bridge files match what is deployed in the game
  - whether the game is running and whether it is the foreground window
  - what the proxy believes about focus (keep-focus drops all keys while
    it thinks the game is in the background)
  - the latest errors and warnings in Lua.log
  - whether the MCP bridge answers (only inside a game, after the load
    screen)

Used through civ5_cli.py diagnose. Windows only.
"""

import csv
import ctypes
import hashlib
import io
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, HERE)

import civ5_paths  # noqa: E402

# Repo files that our local bridge additions deploy into the game.
DEPLOYED_FILES = [
    "CivVAccess_Boot.lua",
    "CivVAccess_QueryCities.lua",
    "CivVAccess_QueryEmpire.lua",
    "CivVAccess_QueryTech.lua",
    "CivVAccess_QueryTurn.lua",
    "CivVAccess_QueryDiplo.lua",
    "CivVAccess_QueryGame.lua",
    "CivVAccess_Rpc.lua",
    "CivVAccess_UnitActionMenu.lua",
    "CivVAccess_BridgeCore.lua",
    "CivVAccess_BridgeCity.lua",
    "CivVAccess_BridgeTech.lua",
    "CivVAccess_BridgeUnit.lua",
]

LUA_PROBLEM = re.compile(r"runtime error|syntax error|stack traceback|\[ERROR\]|\[WARN\]", re.IGNORECASE)
# Errors the maintainer documents as harmless (docs/llm-docs/cp-vp-support.md):
# stock Vox Populi probes for a loader file no component ships.
KNOWN_NOISE = re.compile(r"VPUI_loader")


def _sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def _game_processes():
    out = subprocess.run(
        ["tasklist", "/FO", "CSV", "/NH"], capture_output=True, text=True, errors="replace"
    ).stdout
    procs = {}
    for row in csv.reader(io.StringIO(out)):
        if len(row) >= 2 and row[0].lower().startswith("civilizationv"):
            procs[int(row[1])] = row[0]
    return procs


def _foreground():
    user32 = ctypes.windll.user32
    hwnd = user32.GetForegroundWindow()
    if not hwnd:
        return None, ""
    length = user32.GetWindowTextLengthW(hwnd)
    buf = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buf, length + 1)
    pid = ctypes.c_ulong()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return pid.value, buf.value


def _last_match(lines, pattern):
    rx = re.compile(pattern)
    for line in reversed(lines):
        m = rx.search(line)
        if m:
            return m
    return None


def _read_lines(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def check_install(game_dir, out):
    manifest = os.path.join(game_dir, "Assets", "DLC", "DLC_CivVAccess", "CivVAccess.install.json")
    if not os.path.exists(manifest):
        out.append("mod: NOT INSTALLED (no install manifest)")
        return False
    with open(manifest, "r", encoding="utf-8-sig") as f:
        m = json.load(f)
    out.append(f"mod: Civ V Access {m.get('mod_version')}, profile {m.get('profile')}, "
               f"state {m.get('variant', 'vanilla')}")
    return True


def check_deployed(game_dir, out):
    src = os.path.join(REPO, "src", "dlc", "UI", "InGame")
    dst = os.path.join(game_dir, "Assets", "DLC", "DLC_CivVAccess", "UI", "InGame")
    stale = []
    for name in DEPLOYED_FILES:
        a, b = os.path.join(src, name), os.path.join(dst, name)
        if not os.path.exists(b):
            stale.append(f"{name} (missing)")
        elif _sha(a) != _sha(b):
            stale.append(f"{name} (differs)")
    if stale:
        out.append("bridge extensions: NOT up to date in the game: " + ", ".join(stale))
        out.append("  fix: copy them from src\\dlc\\UI\\InGame into the game's DLC_CivVAccess\\UI\\InGame")
    else:
        out.append("bridge extensions: deployed and identical to the repo")


def check_focus(game_dir, out):
    procs = _game_processes()
    if not procs:
        out.append("game: not running")
        return False
    names = ", ".join(f"{n} (pid {p})" for p, n in procs.items())
    fg_pid, fg_title = _foreground()
    in_front = fg_pid in procs
    out.append(f"game: running: {names}; foreground window: '{fg_title}'"
               + (" (the game)" if in_front else " (not the game)"))

    log = os.path.join(game_dir, "proxy_debug.log")
    if not os.path.exists(log):
        out.append("proxy log: missing")
        return True
    lines = _read_lines(log)
    focus = _last_match(lines, r"(?:focus_event_proc|install_focus_hook).*focused=(\d)")
    keep = _last_match(lines, r"lp_set_keep_focus: (\d)")
    usable = _last_match(lines, r"keepfocus: window usable=(\d)")
    mod_focused = focus is not None and focus.group(1) == "1"
    keep_on = keep is not None and keep.group(1) == "1"
    windowed = usable is not None and usable.group(1) == "1"
    out.append(f"proxy: thinks game focused={int(mod_focused)}, keep-running-in-background="
               f"{int(keep_on)}, windowed={int(windowed)}")
    if in_front and not mod_focused and keep_on and windowed:
        out.append("  PROBLEM: the game is in front but the mod thinks it is not, so every key is")
        out.append("  dropped. Fix: Alt+Tab to another window and back to the game.")
    return True


def check_lua_log(out, limit=12):
    path = os.path.join(civ5_paths.civ5_docs_dir(), "Logs", "Lua.log")
    if not os.path.exists(path):
        out.append("Lua.log: missing (is LoggingEnabled=1 in config.ini?)")
        return
    lines = _read_lines(path)
    problems = [ln for ln in lines if LUA_PROBLEM.search(ln)]
    noise = [ln for ln in problems if KNOWN_NOISE.search(ln)]
    problems = [ln for ln in problems if not KNOWN_NOISE.search(ln)]
    errors = [ln for ln in problems if not re.search(r"\[WARN\]", ln)]
    out.append(f"Lua.log: {len(lines)} lines, {len(errors)} error lines, "
               f"{len(problems) - len(errors)} warnings"
               + (f" ({len(noise)} known harmless VP lines skipped)" if noise else ""))
    for ln in problems[-limit:]:
        out.append("  " + ln.strip()[:300])


def check_bridge(out):
    import civ5_access_mcp as server

    envelope = server.game_query("ping", timeout=3)
    if envelope is None:
        out.append("bridge: no answer (normal in the menus or on the load screen)")
    elif envelope.get("ok"):
        d = envelope.get("data", {})
        out.append(f"bridge: answering. {d.get('civilization')}, {d.get('era')}, "
                   f"turn {envelope.get('turn')}")
    else:
        out.append(f"bridge: answered with an error: {envelope.get('error')}")


def diagnose():
    out = []
    game_dir = civ5_paths.find_game_dir()
    if check_install(game_dir, out):
        check_deployed(game_dir, out)
    running = check_focus(game_dir, out)
    check_lua_log(out)
    if running:
        check_bridge(out)
    return "\n".join(out)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    print(diagnose())
