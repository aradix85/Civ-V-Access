"""Per-game memory for the MCP bridge: the player's strategy, standing
orders, decisions, open questions and short turn digests, plus a journal of
every action the assistant carried out.

Why outside the game: the assistant starts each chat with no memory, and the
player's intent ("science, no wars", "keep a warrior in every city") is not
game state the engine stores anywhere. Game FACTS never go in here -- they
are always read live through the bridge; notes hold intent and history only.

Layout under Documents\\My Games\\Sid Meier's Civilization 5\\CivVAccess\\:
  notes\\<game key>.json   the notes (source of truth)
  notes\\<game key>.md     the same notes as plain text for the player to read
  notes\\<game key>.actions.jsonl   one line per executed action

The game key comes from setup fields that never change during a game (see
CivVAccess_QueryGame.lua), so one game keeps one notes file across saves,
reloads and sessions.

Structure adapted from civStation's StructuredStrategy (MIT,
github.com/minsing-jin/civStation): a victory goal, a short strategy text and
per-domain directives, with standing orders kept apart from one-off orders.
"""

import datetime
import json
import os
import re

# Domains a directive can steer; free text inside each.
DOMAINS = (
    "expansion",
    "production",
    "research",
    "policies",
    "religion",
    "military",
    "diplomacy",
    "economy",
)

# Caps keep the notes small enough to read at the start of every chat.
MAX_DECISIONS = 60
MAX_TURN_DIGESTS = 20
MAX_QUESTIONS = 20
MAX_ORDERS = 30


class NotesError(Exception):
    pass


def game_key(info):
    """Stable file-name key for one game from the game_info query."""
    parts = [
        info.get("civilizationType") or "civ",
        info.get("leaderType") or "leader",
        info.get("mapScript") or "map",
        info.get("worldSize") or "size",
        f"{info.get('startX', 'x')}-{info.get('startY', 'y')}",
    ]
    raw = "_".join(str(p) for p in parts)
    raw = raw.replace("CIVILIZATION_", "").replace("LEADER_", "").replace("WORLDSIZE_", "")
    return re.sub(r"[^A-Za-z0-9_-]+", "", raw).lower()


def _empty(info):
    return {
        "game": {
            "civilization": info.get("civilization"),
            "leader": info.get("leader"),
            "mapScript": info.get("mapScript"),
            "worldSize": info.get("worldSize"),
            "gameSpeed": info.get("gameSpeed"),
            "handicap": info.get("handicap"),
            "firstSeenTurn": info.get("turn"),
        },
        "lastSeenTurn": info.get("turn"),
        "strategy": {"victoryGoal": "", "summary": "", "directives": {}},
        "standingOrders": [],
        "openQuestions": [],
        "decisions": [],
        "turnDigests": [],
        "nextId": 1,
    }


class GameNotes:
    def __init__(self, base_dir, info):
        self.dir = os.path.join(base_dir, "notes")
        self.key = game_key(info)
        self.info = info
        self.json_path = os.path.join(self.dir, self.key + ".json")
        self.md_path = os.path.join(self.dir, self.key + ".md")
        self.journal_path = os.path.join(self.dir, self.key + ".actions.jsonl")

    # --- storage ---

    def load(self):
        try:
            with open(self.json_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except FileNotFoundError:
            return _empty(self.info)

    def save(self, notes):
        os.makedirs(self.dir, exist_ok=True)
        tmp = self.json_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(notes, f, ensure_ascii=False, indent=2)
        os.replace(tmp, self.json_path)
        tmp = self.md_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(render_text(notes))
        os.replace(tmp, self.md_path)

    # --- reading ---

    def read(self):
        """Notes plus a reload warning when the game is behind the notes."""
        notes = self.load()
        turn = self.info.get("turn")
        out = {"gameKey": self.key, "currentTurn": turn, "notes": notes}
        last = notes.get("lastSeenTurn")
        if turn is not None and last is not None and turn < last:
            out["reloadWarning"] = (
                f"The game is at turn {turn} but the notes were last updated at "
                f"turn {last}: an earlier save was loaded. Decisions and digests "
                f"dated after turn {turn} describe events that have not happened "
                f"in this timeline."
            )
        return out

    def recent_actions(self, limit=10):
        try:
            with open(self.journal_path, "r", encoding="utf-8") as f:
                lines = f.readlines()
        except FileNotFoundError:
            return []
        out = []
        for line in lines[-limit:]:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        return out

    # --- writing ---

    def update(self, action, text=None, item_id=None, domain=None, victory_goal=None):
        notes = self.load()
        turn = self.info.get("turn")

        def new_id():
            n = notes.get("nextId", 1)
            notes["nextId"] = n + 1
            return n

        if action == "set_strategy":
            strat = notes["strategy"]
            if victory_goal is not None:
                strat["victoryGoal"] = victory_goal
            if text is not None:
                strat["summary"] = text
            if victory_goal is None and text is None:
                raise NotesError("set_strategy needs text and/or victory_goal")
        elif action == "set_directive":
            if domain not in DOMAINS:
                raise NotesError(f"domain must be one of: {', '.join(DOMAINS)}")
            if text:
                notes["strategy"]["directives"][domain] = text
            else:
                notes["strategy"]["directives"].pop(domain, None)
        elif action == "add_standing_order":
            _need(text, action)
            notes["standingOrders"].append({"id": new_id(), "text": text, "since": turn})
            del notes["standingOrders"][:-MAX_ORDERS]
        elif action == "remove_standing_order":
            _remove_by_id(notes["standingOrders"], item_id, "standing order")
        elif action == "add_question":
            _need(text, action)
            notes["openQuestions"].append({"id": new_id(), "text": text, "since": turn})
            del notes["openQuestions"][:-MAX_QUESTIONS]
        elif action == "resolve_question":
            _remove_by_id(notes["openQuestions"], item_id, "question")
        elif action == "add_decision":
            _need(text, action)
            notes["decisions"].append({"turn": turn, "text": text})
            del notes["decisions"][:-MAX_DECISIONS]
        elif action == "add_turn_digest":
            _need(text, action)
            digests = [d for d in notes["turnDigests"] if d.get("turn") != turn]
            digests.append({"turn": turn, "text": text})
            notes["turnDigests"] = digests[-MAX_TURN_DIGESTS:]
        else:
            raise NotesError(f"unknown notes action: {action}")

        notes["lastSeenTurn"] = turn
        self.save(notes)
        return notes

    def journal(self, tool, arguments, ok, summary):
        os.makedirs(self.dir, exist_ok=True)
        entry = {
            "time": datetime.datetime.now().isoformat(timespec="seconds"),
            "turn": self.info.get("turn"),
            "tool": tool,
            "arguments": arguments,
            "ok": ok,
            "result": summary,
        }
        with open(self.journal_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def _need(text, action):
    if not text:
        raise NotesError(f"{action} needs text")


def _remove_by_id(items, item_id, what):
    try:
        wanted = int(item_id)
    except (TypeError, ValueError):
        raise NotesError(f"removing a {what} needs its numeric id")
    for i, item in enumerate(items):
        if item.get("id") == wanted:
            del items[i]
            return
    raise NotesError(f"no {what} with id {wanted}")


def render_text(notes):
    """Plain-text rendering for the player to read in an editor; headings
    and short lines so it reads well with a screen reader."""
    g = notes.get("game", {})
    lines = [f"# {g.get('civilization') or 'Game'} notes", ""]
    lines.append(f"Last updated at turn {notes.get('lastSeenTurn')}.")
    strat = notes.get("strategy", {})
    lines += ["", "## Strategy", ""]
    if strat.get("victoryGoal"):
        lines.append(f"Victory goal: {strat['victoryGoal']}")
    if strat.get("summary"):
        lines.append(strat["summary"])
    for domain, text in strat.get("directives", {}).items():
        lines.append(f"- {domain}: {text}")
    for title, key in (("Standing orders", "standingOrders"), ("Open questions", "openQuestions")):
        lines += ["", f"## {title}", ""]
        for item in notes.get(key, []):
            lines.append(f"- {item['text']} (number {item['id']}, since turn {item.get('since')})")
    for title, key in (("Decisions", "decisions"), ("Turn digests", "turnDigests")):
        lines += ["", f"## {title}", ""]
        for item in notes.get(key, []):
            lines.append(f"- Turn {item.get('turn')}: {item['text']}")
    return "\n".join(lines) + "\n"
