"""Call any Civ V Access bridge tool from the command line.

For agents that can run commands but are not connected to the MCP server
itself. Same tools, same arguments, same replies as the server.

    py tools/mcp/civ5_cli.py list                      list the tools
    py tools/mcp/civ5_cli.py guide                     print the agent guide
    py tools/mcp/civ5_cli.py diagnose                  health check, game running or not
    py tools/mcp/civ5_cli.py <tool> ['<json args>']    call a tool

Example:
    py tools/mcp/civ5_cli.py civ5_city_details '{"city": "Rome"}'

A map render is written as a PNG into the system temp directory and its
path printed, since a terminal cannot show it.
"""

import base64
import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import civ5_access_mcp as server  # noqa: E402


def _print_content(content):
    if not isinstance(content, list):
        print(content)
        return
    for block in content:
        if block["type"] == "text":
            print(block["text"])
        elif block["type"] == "image":
            path = os.path.join(tempfile.gettempdir(), f"civ5_map_{int(time.time())}.png")
            with open(path, "wb") as f:
                f.write(base64.b64decode(block["data"]))
            print(f"[map image written to {path}]")


def main(argv):
    sys.stdout.reconfigure(encoding="utf-8")
    if len(argv) < 2 or argv[1] in ("list", "-h", "--help"):
        for tool in server.TOOLS:
            props = ", ".join(tool["inputSchema"]["properties"]) or "no arguments"
            print(f"{tool['name']} ({props})")
        return 0
    if argv[1] == "guide":
        print(server.INSTRUCTIONS)
        return 0
    if argv[1] == "diagnose":
        import civ5_diagnose

        print(civ5_diagnose.diagnose())
        return 0
    arguments = json.loads(argv[2]) if len(argv) > 2 else {}
    content, is_error = server.call_tool(argv[1], arguments)
    _print_content(content)
    return 1 if is_error else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
