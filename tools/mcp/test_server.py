"""Offline checks for the MCP server's tool dispatch (no game needed).

Run: py tools/mcp/test_server.py
"""

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import civ5_access_mcp as server  # noqa: E402

ORIGIN = {"x": 10, "y": 10, "mapWidth": 40, "mapHeight": 30, "wrapX": False}


def _with_fake_query(reply, fn):
    calls = []

    def fake_query(name, *args, timeout=None):
        calls.append((name, args))
        return json.loads(json.dumps(reply))

    original = server.game_query
    server.game_query = fake_query
    try:
        fn(calls)
    finally:
        server.game_query = original


def test_every_passthrough_tool_is_declared():
    declared = {t["name"] for t in server.TOOLS}
    for name in server.PASSTHROUGH_TOOLS:
        assert name in declared, name


def test_passthrough_relays_argument_and_converts_coordinates():
    reply = {
        "id": "x",
        "ok": True,
        "coordOrigin": ORIGIN,
        "data": {"cities": [{"name": "Rome", "x": 12, "y": 10}]},
    }

    def check(calls):
        text, is_error = server.call_tool("civ5_city_details", {"city": "Rome"})
        assert not is_error
        assert calls == [("city_details", ("Rome",))], calls
        city = json.loads(text)["data"]["cities"][0]
        assert (city["x"], city["y"]) == (2, 0), city
        server.call_tool("civ5_city_details", {})
        assert calls[-1] == ("city_details", ()), "an omitted argument is not sent"

    _with_fake_query(reply, check)


def test_passthrough_reports_query_failure_as_error():
    reply = {"id": "x", "ok": False, "error": "you have no city named Atlantis"}

    def check(_calls):
        text, is_error = server.call_tool("civ5_city_details", {"city": "Atlantis"})
        assert is_error
        assert "Atlantis" in text

    _with_fake_query(reply, check)


GAME_INFO = {
    "id": "g",
    "ok": True,
    "turn": 12,
    "coordOrigin": ORIGIN,
    "data": {
        "civilizationType": "CIVILIZATION_BABYLON",
        "leaderType": "LEADER_NEBUCHADNEZZAR",
        "mapScript": "Earth",
        "worldSize": "WORLDSIZE_HUGE",
        "startX": 10,
        "startY": 10,
        "turn": 12,
    },
}


def _with_fake_game(replies, fn):
    """Fake game answering game_info plus one scripted reply per action."""
    calls = []
    queue = list(replies)

    def fake_query(name, *args, timeout=None):
        calls.append((name, args))
        if name == "game_info":
            return json.loads(json.dumps(GAME_INFO))
        reply = queue.pop(0)
        return None if reply is None else json.loads(json.dumps(reply))

    original_query, original_dir = server.game_query, server.NOTES_DIR
    server.game_query = fake_query
    with tempfile.TemporaryDirectory() as base:
        server.NOTES_DIR = base
        try:
            fn(calls)
        finally:
            server.game_query = original_query
            server.NOTES_DIR = original_dir


def test_every_action_tool_is_declared():
    declared = {t["name"] for t in server.TOOLS}
    for name in server.ACTION_TOOLS:
        assert name in declared, name


def test_action_is_sent_for_the_current_turn_and_journaled():
    reply = {"id": "a", "ok": True, "data": {"city": "Babylon", "confirmed": True}}

    def check(calls):
        text, is_error = server.call_tool(
            "civ5_set_production", {"city": "Babylon", "item": "Granary"}
        )
        assert not is_error, text
        assert calls[-1] == ("set_production", (12, "Babylon", "Granary", "replace")), calls
        actions = json.loads(server.call_tool("civ5_game_notes", {})[0])["recentActions"]
        assert actions[-1]["tool"] == "civ5_set_production" and actions[-1]["ok"] is True

    _with_fake_game([reply], check)


def test_move_converts_player_coordinates_to_engine_tiles():
    reply = {"id": "a", "ok": True, "data": {"target": {"x": 12, "y": 9}}}

    def check(calls):
        text, _ = server.call_tool("civ5_unit_action", {"unit": 7, "action": "move", "x": 2.5, "y": -1})
        name, args = calls[-1]
        assert name == "unit_action" and args[:3] == (12, 7, "move"), calls
        ex, ey = server.geometry.engine_coords(ORIGIN, 2.5, -1)
        assert args[3:] == (ex, ey), args
        target = json.loads(text)["data"]["target"]
        assert (target["x"], target["y"]) == server.geometry.player_coords(ORIGIN, 12, 9)

    _with_fake_game([reply], check)


def test_action_without_reply_warns_against_retrying():
    def check(calls):
        text, is_error = server.call_tool("civ5_set_research", {"goal": "Writing"})
        assert is_error
        assert "before trying again" in text
        assert sum(1 for c in calls if c[0] == "set_research") == 1, "never retried"

    _with_fake_game([None], check)


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_")]


def main():
    for t in TESTS:
        t()
        print(f"{t.__name__} ok")
    print(f"SERVER PASS ({len(TESTS)} tests)")


if __name__ == "__main__":
    main()
