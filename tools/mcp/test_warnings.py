"""Offline checks for the briefing's warnings checklist (no game needed).

Run: py tools/mcp/test_warnings.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import civ5_warnings as w  # noqa: E402

ORIGIN = {"x": 10, "y": 10, "mapWidth": 40, "mapHeight": 30, "wrapX": True}


def _texts(found, level=None):
    return [x["text"] for x in found if level is None or x["level"] == level]


def test_enemy_near_city_counts_hex_distance_across_the_wrap():
    hostiles = {
        "yourCities": [{"name": "Babylon", "x": 0, "y": 10}],
        "hostileUnits": [
            {"name": "Warrior", "x": 39, "y": 10},  # one tile west, across the seam
            {"name": "Archer", "x": 5, "y": 10},  # five tiles east: too far
        ],
    }
    found = w.warnings({}, [], hostiles, [], {}, ORIGIN)
    texts = _texts(found, w.URGENT)
    assert len(texts) == 1 and "1 enemy unit" in texts[0] and "Warrior" in texts[0], found


def test_no_proximity_check_before_a_capital_exists():
    hostiles = {"yourCities": [{"name": "A", "x": 0, "y": 0}], "hostileUnits": [{"name": "W", "x": 0, "y": 1}]}
    assert w.warnings({}, [], hostiles, [], {}, None) == []


def test_bankruptcy_warns_with_turns_left_and_urgency_grows():
    soon = w.warnings({"gold": {"total": 30, "perTurn": -10}}, [], {}, [], {}, None)
    assert soon[0]["level"] == w.URGENT and "about 3 turns" in soon[0]["text"], soon
    later = w.warnings({"gold": {"total": 100, "perTurn": -10}}, [], {}, [], {}, None)
    assert later[0]["level"] == w.IMPORTANT, later
    assert w.warnings({"gold": {"total": 1000, "perTurn": -10}}, [], {}, [], {}, None) == [], "far off"


def test_results_are_ordered_most_urgent_first():
    cities = [
        {"name": "Slow", "food": {"perTurn": 1, "turnsToGrow": 30}},
        {"name": "Hungry", "food": {"perTurn": -2, "starving": True}},
    ]
    found = w.warnings({}, cities, {}, [{"needsOrders": True}], {}, None)
    assert [x["level"] for x in found] == [w.URGENT, w.INFO, w.INFO], found
    assert "Hungry" in found[0]["text"]


def test_rival_capitals_warn_without_naming_more_than_the_screen():
    victory = {
        "domination": {
            "capitalsNeeded": 4,
            "capitals": [
                {"civ": "you"},
                {"civ": "Greece", "heldBy": "unmet civilization"},
                {"civ": "unmet civilization"},
                {"civ": "Persia", "heldBy": "destroyed"},
            ],
        }
    }
    texts = _texts(w.warnings({}, [], {}, [], victory, None))
    assert texts == ["unmet civilization holds 2 of 4 original capitals."], texts


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_")]


def main():
    for t in TESTS:
        t()
        print(f"{t.__name__} ok")
    print(f"WARNINGS PASS ({len(TESTS)} tests)")


if __name__ == "__main__":
    main()
