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


def test_slow_growth_follows_the_game_speed_and_skips_food_into_production():
    cities = [
        {"name": "Slow", "food": {"perTurn": 1, "turnsToGrow": 30}},
        {"name": "Settling", "food": {"perTurn": 0, "intoProduction": True}},
    ]
    assert _texts(w.warnings({}, cities, {}, [], {}, None)) == ["Slow grows slowly (30 turns)."]
    assert w.warnings({}, cities, {}, [], {}, None, growth_percent=300) == [], "30 turns is normal on Marathon"


def test_decisions_and_vox_populi_city_unhappiness_are_reminded():
    cities = [{"name": "Ur", "happiness": 2, "unhappiness": 5}, {"name": "Kish", "happiness": 4, "unhappiness": 1}]
    decisions = {"freeTechs": 1, "citiesWithoutProduction": ["Babylon"]}
    texts = _texts(w.warnings({}, cities, {}, [], {}, None, decisions=decisions))
    assert "A free technology can be chosen." in texts
    assert "Babylon has nothing to build." in texts
    assert any(t.startswith("Ur is unhappy") for t in texts)
    assert not any(t.startswith("Kish") for t in texts), texts


def test_unmet_capitals_are_not_lumped_into_one_rival():
    victory = {
        "domination": {
            "capitalsNeeded": 4,
            "capitals": [{"civ": "you"}, {"civ": "unmet civilization"}, {"civ": "unmet civilization"}, {"civ": "unmet civilization"}],
        }
    }
    assert w.warnings({}, [], {}, [], victory, None) == [], "turn one is not a domination threat"
    victory["domination"]["capitals"] = [
        {"civ": "you"},
        {"civ": "Greece", "heldBy": "Persia"},
        {"civ": "Persia"},
        {"civ": "unmet civilization"},
    ]
    texts = _texts(w.warnings({}, [], {}, [], victory, None))
    assert texts == ["Persia holds 2 original capitals; 4 win."], texts


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_")]


def main():
    for t in TESTS:
        t()
        print(f"{t.__name__} ok")
    print(f"WARNINGS PASS ({len(TESTS)} tests)")


if __name__ == "__main__":
    main()
