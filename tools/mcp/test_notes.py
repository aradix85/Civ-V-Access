"""Offline checks for the per-game notes store (no game needed).

Run: py tools/mcp/test_notes.py
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import civ5_notes as notes_mod  # noqa: E402

INFO = {
    "civilization": "Babylon",
    "civilizationType": "CIVILIZATION_BABYLON",
    "leaderType": "LEADER_NEBUCHADNEZZAR",
    "mapScript": "Earth_Duel",
    "worldSize": "WORLDSIZE_HUGE",
    "startX": 40,
    "startY": 22,
    "turn": 12,
}


def _notes(base, **overrides):
    return notes_mod.GameNotes(base, dict(INFO, **overrides))


def test_key_ignores_turn_and_differs_per_start():
    a = notes_mod.game_key(INFO)
    assert a == notes_mod.game_key(dict(INFO, turn=200)), "same game, later turn"
    assert a != notes_mod.game_key(dict(INFO, startX=41)), "another start tile is another game"
    assert all(c.isalnum() or c in "_-" for c in a), a


def test_updates_persist_and_render_for_the_player():
    with tempfile.TemporaryDirectory() as base:
        n = _notes(base)
        n.update("set_strategy", text="Science first, no wars", victory_goal="science")
        n.update("add_standing_order", text="Keep a warrior in every city")
        n.update("set_directive", domain="production", text="Libraries before markets")
        data = _notes(base, turn=13).read()["notes"]
        assert data["strategy"]["victoryGoal"] == "science"
        assert data["standingOrders"][0]["text"] == "Keep a warrior in every city"
        assert data["standingOrders"][0]["since"] == 12
        with open(n.md_path, encoding="utf-8") as f:
            text = f.read()
        assert "Keep a warrior in every city" in text and "Libraries before markets" in text


def test_removing_by_id_and_unknown_id_fails_loudly():
    with tempfile.TemporaryDirectory() as base:
        n = _notes(base)
        n.update("add_standing_order", text="a")
        n.update("add_standing_order", text="b")
        n.update("remove_standing_order", item_id="1")
        assert [o["text"] for o in n.load()["standingOrders"]] == ["b"]
        try:
            n.update("remove_standing_order", item_id="7")
        except notes_mod.NotesError:
            pass
        else:
            raise AssertionError("removing a missing id must raise")


def test_reloaded_earlier_save_is_flagged():
    with tempfile.TemporaryDirectory() as base:
        _notes(base, turn=30).update("add_decision", text="Declared war on Assyria")
        result = _notes(base, turn=25).read()
        assert "reloadWarning" in result and "turn 25" in result["reloadWarning"]
        assert "reloadWarning" not in _notes(base, turn=31).read()


def test_turn_digest_replaces_same_turn_and_is_capped():
    with tempfile.TemporaryDirectory() as base:
        for turn in range(1, notes_mod.MAX_TURN_DIGESTS + 5):
            _notes(base, turn=turn).update("add_turn_digest", text=f"turn {turn}")
        n = _notes(base, turn=notes_mod.MAX_TURN_DIGESTS + 4)
        n.update("add_turn_digest", text="rewritten")
        digests = n.load()["turnDigests"]
        assert len(digests) == notes_mod.MAX_TURN_DIGESTS
        assert digests[-1]["text"] == "rewritten"
        assert [d["turn"] for d in digests].count(digests[-1]["turn"]) == 1


def test_journal_appends_and_reads_back():
    with tempfile.TemporaryDirectory() as base:
        n = _notes(base)
        n.journal("civ5_set_production", {"city": "Babylon"}, True, "Granary queued")
        n.journal("civ5_set_research", {"tech": "Writing"}, False, "already known")
        actions = n.recent_actions()
        assert [a["ok"] for a in actions] == [True, False]
        assert actions[0]["turn"] == 12


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_")]


def main():
    for t in TESTS:
        t()
        print(f"{t.__name__} ok")
    print(f"NOTES PASS ({len(TESTS)} tests)")


if __name__ == "__main__":
    main()
