# /// script
# dependencies = ["iterm2"]
# ///
"""Add (or remove) the iterm-peek Smart Selection rules on every iTerm2 profile.

Cmd-click only considers Smart Selection rules that have actions, so these rules
take over Cmd-click for GitHub PR/issue links, Linear issue links and bare Linear
IDs. Every other link still opens normally. Rules are tagged by their notes, so
running this again replaces them rather than adding duplicates.

    uv run install_rules.py <peek-binary> [TEAM,KEYS]
    uv run install_rules.py --uninstall
"""

import plistlib
import sys

import iterm2

MARK = "iterm-peek: "
DEFAULTS = "/Applications/iTerm.app/Contents/Resources/SmartSelectionRules.plist"
SKIP_PROFILES = {"Web Browser"}
URL_TAIL = r"[a-zA-Z0-9;/.\-_+%?&@=#~]*"

RUN_COMMAND = 2
OPEN_URL = 1


def peek_rules(binary, team_keys):
    peek = {"title": "Peek", "action": RUN_COMMAND, "parameter": f"'{binary}' \\0"}
    open_url = {"title": "Open in browser", "action": OPEN_URL, "parameter": "\\0"}
    rules = [
        {
            "notes": MARK + "GitHub PR or issue",
            "regex": r"https?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pull|issues)/[0-9]+" + URL_TAIL,
            "precision": "very_high",
            "actions": [peek, open_url],
        },
        {
            "notes": MARK + "Linear issue URL",
            "regex": r"https?://linear\.app/[A-Za-z0-9_-]+/issue/[A-Za-z0-9]+-[0-9]+" + URL_TAIL,
            "precision": "very_high",
            "actions": [peek, open_url],
        },
    ]
    if team_keys:
        rules.append({
            "notes": MARK + "Linear issue ID",
            "regex": r"\b(?:" + "|".join(team_keys) + r")-[0-9]+\b",
            "precision": "very_high",
            "actions": [peek],
        })
    return rules


async def main(connection):
    uninstall = sys.argv[1:2] == ["--uninstall"]
    ours = [] if uninstall else peek_rules(sys.argv[1], [k for k in "".join(sys.argv[2:3]).split(",") if k])
    with open(DEFAULTS, "rb") as f:
        defaults = plistlib.load(f)["Rules"]

    profiles = await iterm2.PartialProfile.async_query(
        connection, properties=["Guid", "Name", "Smart Selection Rules"]
    )
    for profile in profiles:
        if profile.name in SKIP_PROFILES:
            continue
        existing = profile.smart_selection_rules or defaults
        kept = [r for r in existing if not r.get("notes", "").startswith(MARK)]
        await profile.async_set_smart_selection_rules(kept + ours)
        print(f"{'removed from' if uninstall else 'installed on'} profile: {profile.name}")


iterm2.run_until_complete(main)
