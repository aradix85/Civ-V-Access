"""Warnings checklist for the MCP bridge: what needs the player's
attention right now, from one set of fresh query results.

The assistant only sees what it asks for, so the things a sighted player
notices at a glance -- a starving city, a treasury running dry, an enemy
next to a city, a rival close to winning -- go unmentioned unless someone
checks for them every turn. This runs that check over live data in one
call and does the arithmetic (tiles from an enemy to a city, turns until
the treasury is empty) the same way every time. What already happened is
not repeated here: the game's own notifications and turn log carry that,
and civ5_turn_summary reads them.

Idea adapted from civ6-mcp's end-turn empire warnings (MIT,
github.com/lmwilki/civ6-mcp): a fixed checklist ranked by urgency.
"""

import civ5_geometry as geometry

HOSTILE_NEAR_CITY = 3  # tiles
BANKRUPTCY_WARN_TURNS = 15
SLOW_GROWTH_TURNS = 15

# Urgency, highest first; the assistant leads with the first.
URGENT, IMPORTANT, INFO = "urgent", "important", "info"
_ORDER = {URGENT: 0, IMPORTANT: 1, INFO: 2}


def _plural(n, word):
    return f"{n} {word}{'s' if n != 1 else ''}"


def _city_warnings(cities, add):
    for c in cities:
        food = c.get("food") or {}
        if food.get("starving"):
            add(URGENT, f"{c['name']} is starving.")
        elif food.get("perTurn") == 0:
            add(IMPORTANT, f"{c['name']} is not growing (no food surplus).")
        elif (food.get("turnsToGrow") or 0) > SLOW_GROWTH_TURNS:
            add(INFO, f"{c['name']} grows slowly ({food['turnsToGrow']} turns).")
        if c.get("maxHealth") and c.get("health") is not None and c["health"] < c["maxHealth"]:
            add(IMPORTANT, f"{c['name']} is damaged ({c['health']} of {c['maxHealth']}).")
        if c.get("resistanceTurns"):
            add(INFO, f"{c['name']} is in resistance for {c['resistanceTurns']} more turns.")


def _economy_warnings(empire, add):
    gold = empire.get("gold") or {}
    per_turn, total = gold.get("perTurn"), gold.get("total")
    if per_turn is not None and total is not None and per_turn < 0:
        turns = int(total // -per_turn)
        if turns <= BANKRUPTCY_WARN_TURNS:
            add(
                URGENT if turns <= 5 else IMPORTANT,
                f"Losing {-per_turn} gold per turn; the treasury runs out in about {turns} turns.",
            )
    state = (empire.get("happiness") or {}).get("state")
    if state in ("unhappy", "veryUnhappy", "superUnhappy"):
        add(IMPORTANT if state == "unhappy" else URGENT, f"The empire is {state}.")


def _threat_warnings(hostiles, hex_map, add):
    if hex_map is None:
        return
    for city in hostiles.get("yourCities", []):
        near = [
            u
            for u in hostiles.get("hostileUnits", [])
            if hex_map.distance(city["x"], city["y"], u["x"], u["y"]) <= HOSTILE_NEAR_CITY
        ]
        if near:
            kinds = ", ".join(sorted({u.get("name") for u in near}))
            add(
                URGENT,
                f"{_plural(len(near), 'enemy unit')} within {HOSTILE_NEAR_CITY} tiles of {city['name']} ({kinds}).",
            )


def _unit_warnings(units, add):
    idle = sum(1 for u in units if u.get("needsOrders"))
    if idle:
        add(INFO, f"{_plural(idle, 'unit')} waiting for orders.")
    promotable = sum(1 for u in units if u.get("promotionReady"))
    if promotable:
        add(INFO, f"{_plural(promotable, 'unit')} can be promoted.")


def _victory_warnings(victory, add):
    for team in (victory.get("science") or {}).get("teams", []):
        if team.get("civ") != "you" and team.get("apollo"):
            add(
                URGENT if team.get("partsBuilt") else IMPORTANT,
                f"{team['civ']} has the Apollo Program "
                f"({team.get('partsBuilt', 0)} of {team.get('partsNeeded')} spaceship parts).",
            )
    if (victory.get("diplomatic") or {}).get("unitedNations"):
        add(IMPORTANT, "The United Nations is active: a diplomatic victory vote is possible.")
    domination = victory.get("domination") or {}
    needed = domination.get("capitalsNeeded") or 0
    held = {}
    for cap in domination.get("capitals", []):
        holder = cap.get("heldBy") or cap.get("civ")
        if holder != "destroyed":
            held[holder] = held.get(holder, 0) + 1
    for holder, n in sorted(held.items()):
        if holder != "you" and needed and n >= max(2, (needed + 1) // 2):
            add(URGENT, f"{holder} holds {n} of {needed} original capitals.")


def hex_map_from(origin):
    if origin is None:
        return None
    return geometry.HexMap(origin["mapWidth"], origin["mapHeight"], origin.get("wrapX", False))


def warnings(empire, cities, hostiles, units, victory, origin):
    """What needs attention now, most urgent first. Coordinates in the
    inputs are raw engine coordinates (distances are measured before the
    payload is converted for the player)."""
    out = []

    def add(level, text):
        out.append({"level": level, "text": text})

    _city_warnings(cities, add)
    _economy_warnings(empire, add)
    _threat_warnings(hostiles, hex_map_from(origin), add)
    _unit_warnings(units, add)
    _victory_warnings(victory or {}, add)
    return sorted(out, key=lambda w: _ORDER[w["level"]])
