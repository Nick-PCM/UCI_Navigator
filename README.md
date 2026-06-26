# UCI Navigator

Navigator is a Lua module for Q-SYS UCI navigation. It keeps UCI layer visibility, access level, page history, shared regions, and control bindings in one authored project table.

Use it when a UCI has more than a few pages, when locked and unlocked experiences need to coexist, or when shared chrome such as headers, footers, ribbons, or backgrounds should change with the active page.

## Core Terms

- `page`: a navigable unit that shows one or more Q-SYS UCI layers.
- `group`: a container that decides whether its pages interlock or can coexist.
- `region`: an optional shared presentation area with default content that active pages can fill.
- `access`: the current access level, such as `locked`, `user`, or an optional project-specific level.
- `controls`: Q-SYS controls that open pages, change access, lock, pulse activity, or move through history.

`groups.root` is the built-in top-level owner. Root-owned groups are normally used to separate the locked access gate from the unlocked session.

## Quick Start

```lua
-- Helpful for local tooling, editor diagnostics, and documentation examples.
local Navigator = require("Navigator")

local config = Navigator.compile({
  uci = { pageName = "Main" },

  logging = {
    manifest = true,
  },

  access = {
    locked = { startAt = pages.splash, keypad = pages.keypad, pinEntryTimeoutSeconds = 30 },
    user = { startAt = pages.home, sessionTimeoutSeconds = 600, default = true },
  },

  accessControls = {
    level = "Access Level",
    change = "Change Access Level",
    lock = "Lock Request",
    activityPulse = "Activity Pulse",
  },

  gate = group({ owner = groups.root, mode = independent }),

  accessGate = group(
    { owner = groups.gate, mode = interlocked, startAt = pages.splash },
    {
      splash = page({ content = { locked = "Splash" } }),
      keypad = page({ content = { locked = "Keypad" }, controls = { open = "Open Keypad", close = "Close Keypad" } }),
    }
  ),

  session = group({ owner = groups.root, mode = independent }),

  system = group(
    { owner = groups.session, mode = interlocked, startAt = pages.home },
    {
      home = page({ content = "Home", controls = { open = "Open Home Page" } }),
      audio = page({ content = "Audio", controls = { open = "Open Audio Page" } }),
    }
  ),
})

Navigator.apply(config)
```

`Navigator.compile(...)` turns the authored table into runtime config. `Navigator.apply(config)` validates it, binds Q-SYS controls, resets access to `locked`, and initializes navigation.


## Files

- `Navigator.lua`: the implementation.
- `Navigator.md`: the full technical model, validation rules, and usage patterns.
- `Basic Keypad Runtime Config.md`: the basic keypad example written without the authoring helpers or compiler.
- `Examples/Basic Keypad Example.lua`: a basic locked/unlocked UCI with keypad access.
- `Examples/Basic No Keypad Example.lua`: the same structure without keypad access.
- `Examples/Advanced Access Example.lua`: custom access content, fallback, and region fills.
