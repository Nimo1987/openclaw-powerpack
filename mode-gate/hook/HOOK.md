---
name: mode-gate
description: "Inject MODE-GATE.md into agent bootstrap context to enforce Mode A/B/C routing"
metadata:
  {
    "openclaw":
      {
        "emoji": "🔀",
        "events": ["agent:bootstrap"],
        "always": true,
      },
  }
---
# Mode Gate — Bootstrap Hook

Injects `MODE-GATE.md` into the agent's bootstrap context on every session start.

Scans workspace for `workflows/*.py` files, extracts docstrings, and builds a complete
Mode A/B/C routing decision table. The agent sees this table before anything else,
ensuring workflow-first routing is enforced at the highest priority.
