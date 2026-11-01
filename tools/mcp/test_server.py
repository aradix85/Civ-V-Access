"""Offline checks for the MCP server's tool dispatch (no game needed).

Run: py tools/mcp/test_server.py
"""

import json
import os
import sys

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


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_")]


def main():
    for t in TESTS:
        t()
        print(f"{t.__name__} ok")
    print(f"SERVER PASS ({len(TESTS)} tests)")


if __name__ == "__main__":
    main()
