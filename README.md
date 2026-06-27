# UCI Navigator

Navigator is a Lua runtime for Q-SYS UCI navigation. It keeps layer visibility, access level, keypad/session timing, history, and Q-SYS control bindings in one flat project table.

Use it when a UCI has more than a few pages, when locked and unlocked views need to coexist, or when repeated frame layers such as headers, footers, ribbons, and backgrounds should stay predictable as pages change.

## Core Terms

- `page`: a navigable state that shows one or more Q-SYS UCI layers.
- `group`: a container that owns direct pages and/or groups.
- `mode`: `interlocked` means one direct member at a time; `independent` means direct members can coexist.
- `access`: the current access level, usually `locked`, `user`, and optionally project-specific levels such as `admin`.
- `startAt`: the direct member or members a group opens by default.
- `controls`: Q-SYS controls that open pages, change access, lock, pulse activity, or move through history.

The implicit top-level owner is the string `"root"`.

## Quick Start

```lua
-- Useful for local tooling and documentation. In Q-SYS, require only works if
-- Navigator.lua is available to the Lua environment; otherwise load/paste it first.
local Navigator = require("Navigator")

Navigator.apply({
  uci = { pageName = "Main" },

  logging = {
    manifest = true,
    qsys = true,
  },

  access = {
    locked = { startAt = "accessGate", keypad = "keypad", pinEntryTimeoutSeconds = 30 },
    user = { startAt = "session", sessionTimeoutSeconds = 600, default = true },
    admin = { startAt = "session", sessionTimeoutSeconds = 600 },
  },

  accessControls = {
    level = "Access Level",
    change = "Change Access Level",
    lock = "Lock Request",
    activityPulse = "Activity Pulse",
  },

  entry = group({ owner = "root", mode = "independent" }),
  accessGate = group({ owner = "entry", mode = "interlocked", startAt = "splash" }),

  session = group({
    owner = "root",
    mode = "independent",
    startAt = { "frame", "system" },
  }),

  system = group({ owner = "session", mode = "interlocked", startAt = "home" }),

  splash = page({ owner = "accessGate", content = { locked = "Splash" } }),
  keypad = page({ owner = "accessGate", content = { locked = "Keypad" } }),

  frame = page({
    owner = "session",
    content = {
      user = { "Header", "Footer", "Ribbon", "Background" },
      admin = { "Header", "Footer", "Ribbon", "Admin Ribbon", "Background" },
    },
  }),

  home = page({
    owner = "system",
    content = "Home",
    controls = { open = "Open Home Page" },
  }),
})
```

`Navigator.apply(project)` validates the authored table, binds configured Q-SYS controls, sets the external access-level control to `locked`, opens locked access, and reconciles UCI layer visibility.

## Loading From A Core File

If Q-SYS can read project files from the Core filesystem, `qsys-require.lua` shows a minimal Lua 5.3 loader for files that end with `return aModule`:

```lua
local function loadModule(path)
  local file = assert(io.open(path, "r"))
  local source = file:read("*a")
  file:close()

  return assert(load(source, "@" .. path))()
end

local Navigator = loadModule("/design/lua/Navigator.lua")
```

## Authoring Rules

- Groups and pages are top-level entries in the project table.
- Every group and page has an explicit `owner`.
- `access.<level>.startAt` names one group.
- `group.startAt` names direct members of that group.
- An `independent` group can use a single `startAt` ID or a list of direct page/group IDs.
- An `interlocked` group can use only one `startAt` ID.
- Page-owned groups require `parentVisible = true` or `parentVisible = false`.
- Page content can be one layer name, a list of layer names, or an access-keyed table.

## Files

- `Navigator.lua`: the implementation.
- `Navigator.md`: the full technical model, validation rules, and usage patterns.
- `example-uci.lua`: a flat keypad example using the current engine surface.
- `qsys-require.lua`: a minimal loader experiment for Core filesystem Lua files.
