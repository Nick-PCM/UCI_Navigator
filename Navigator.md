# Navigator

Navigator is a Q-SYS UCI navigation runtime. It turns one flat authored project table into deterministic UCI layer visibility, access state, keypad/session timing, history state, and Q-SYS control bindings.

The core model is ownership. Pages and groups are top-level entries, and each one names its owner explicitly. Groups decide how their direct members behave. Pages contribute visible UCI layers. Access levels choose which group becomes active first.

## Runtime Shape

Navigator is applied directly to the authored project:

```lua
local Navigator = require("Navigator")

Navigator.apply({
  -- project table
})
```

In local tooling, `require("Navigator")` is convenient. In Q-SYS, built-in `require` is documented for Q-SYS-supplied modules such as `rapidjson`; project-local Lua files are not documented as a built-in module mechanism. If `Navigator.lua` is not available to Q-SYS through `require`, load it before the project table by whatever deployment approach your project uses.

There is no separate preprocessing step. The authoring helpers `group(...)` and `page(...)` mark top-level tables so `Navigator.apply(...)` can partition, normalize, validate, bind controls, and start from locked access.

## Core Filesystem Loader

`qsys-require.lua` is a minimal Lua 5.3 utility for testing whether a Q-SYS script can load project libraries from the Core filesystem. It expects the target file to end with `return aModule`.

```lua
local function loadModule(path)
  local file = assert(io.open(path, "r"))
  local source = file:read("*a")
  file:close()

  return assert(load(source, "@" .. path))()
end

local Navigator = loadModule("/design/lua/Navigator.lua")
```

This is not a replacement for Q-SYS built-in `require`; it is a small file-loader pattern for project-owned Lua files when the Core exposes the path to script code.

## Authoring Surface

Navigator exposes:

```lua
group(spec)
page(spec)

Navigator.apply(project)
Navigator.setAccess(accessLevel)
Navigator.open(pageId)
Navigator.close(pageId)
Navigator.back()
Navigator.forward()
Navigator.getState()
Navigator.getVisibleLayers()
```

`group` and `page` are also exposed globally for compact project scripts:

```lua
system = group({ owner = "session", mode = "interlocked", startAt = "home" })
home = page({ owner = "system", content = "Home" })
```

IDs are the string keys in the project table. Custom handlers use those same string IDs:

```lua
Navigator.open("audio")
Navigator.close("help")
Navigator.setAccess("admin")
```

## Project Table

A project table may contain:

```lua
{
  uci = { pageName = "Main", transition = "none" },
  logging = {},
  access = {},
  accessControls = {},
  historyControls = {},
  historyMaxEntries = 25,

  someGroup = group({ ... }),
  somePage = page({ ... }),
}
```

Only top-level entries returned by `group(...)` or `page(...)` become navigation objects. Other keys are configuration tables.

## Groups

A group is a container with an owner, a mode, optional defaults, and optional page-owner visibility behavior:

```lua
system = group({
  owner = "session",
  mode = "interlocked",
  startAt = "home",
})
```

Owners are strings:

- `"root"` for a top-level group.
- another group ID for deeper hierarchy.
- a page ID for page-owned subpage groups.

`mode` is required:

- `interlocked`: one direct member can be active at a time.
- `independent`: multiple direct members can be active at once.

The implicit `"root"` owner behaves as interlocked, so direct root-owned groups replace one another.

### startAt

`group.startAt` names the direct member or members that open when the group activates.

For an interlocked group:

```lua
system = group({ owner = "session", mode = "interlocked", startAt = "home" })
```

An interlocked group may name only one direct member.

For an independent group:

```lua
session = group({
  owner = "root",
  mode = "independent",
  startAt = { "frame", "system" },
})
```

An independent group may name one ID or a list of direct page/group IDs. Mixed page and group defaults are allowed as long as every ID is a direct member of that group.

### Page-Owned Groups

Page-owned groups model subpages:

```lua
audioSubpages = group({
  owner = "audio",
  mode = "interlocked",
  parentVisible = true,
  startAt = "audioRouting",
})
```

`parentVisible` is required for page-owned groups:

- `true`: keep the owner page visible while the owned group is active.
- `false`: suppress the owner page while the owned group is active.

`parentVisible` is invalid on root-owned or group-owned groups.

## Pages

A page has an owner, content, and optional controls:

```lua
audio = page({
  owner = "system",
  content = { user = "Audio", admin = "Admin Audio" },
  controls = { open = "Open Audio Page" },
})
```

`owner` must be a group ID.

`content` may be:

- one layer name
- a list of layer names
- an access-keyed table

Examples:

```lua
home = page({ owner = "system", content = "Home" })

frame = page({
  owner = "session",
  content = { "Header", "Footer", "Background" },
})

audio = page({
  owner = "system",
  content = {
    user = "Audio",
    admin = "Admin Audio",
  },
})
```

For unlocked access levels, missing content falls back to the access level marked `default = true`. Locked access does not fall back to unlocked content.

## Access

The `access` table is keyed by access level:

```lua
access = {
  locked = {
    startAt = "accessGate",
    keypad = "keypad",
    pinEntryTimeoutSeconds = 30,
  },
  user = {
    startAt = "session",
    sessionTimeoutSeconds = 600,
    default = true,
  },
  admin = {
    startAt = "session",
    sessionTimeoutSeconds = 600,
  },
}
```

Rules:

- `locked` is the reserved locked access level.
- One non-locked level must set `default = true`.
- `access.<level>.startAt` names one group ID.
- `locked.keypad`, when present, names a page under the locked root group.
- `pinEntryTimeoutSeconds` returns from keypad to locked access.
- `sessionTimeoutSeconds` returns from unlocked access to locked access.
- Access changes clear history.

At startup, Navigator sets the configured access-level control to `locked` before startup navigation. This prevents a restarted script from inheriting a stale logged-in value from Q-SYS control state.

## Access Controls

Global access controls are configured under `accessControls`:

```lua
accessControls = {
  level = "Access Level",
  change = "Change Access Level",
  lock = "Lock Request",
  activityPulse = "Activity Pulse",
}
```

`level` is the external access-level bridge. Navigator writes it to `locked` at startup and reads it when the control changes.

`change` requests an access change. With a keypad configured, it always opens the keypad. If the current access is not locked, Navigator locks first and then opens the keypad. Without a keypad, it changes directly to the default unlocked access level.

`lock` returns to locked access.

`activityPulse` restarts active keypad and session timers.

Each control may be a control name string, a Q-SYS control object, or a list of equivalent control names/objects.

## Page And History Controls

Page controls live on pages:

```lua
controls = {
  open = "Open Audio Page",
  close = "Close Audio Page",
}
```

Supported page controls are `open` and `close`.

History controls are global:

```lua
historyControls = {
  back = "Back",
  forward = "Forward",
}
```

Navigation changes push history when the visible page/group state changes. Access changes clear history because active pages may not be valid under the new access level.

`historyMaxEntries` defaults to `25`. Set it to `false` to disable trimming.

## Visibility Resolution

On each navigation change, Navigator computes the desired layer set from state:

1. Start with the active page and group sets.
2. Hide an owner page if an active page-owned group has `parentVisible = false`.
3. Resolve each active page's content for the effective access level.
4. Apply visibility changes to Q-SYS layers.

Visibility is derived from current state. It is not an accumulation of previous button presses.

Locked pages always resolve locked content, even if the current access is temporarily unlocked during an access transition. Unlocked pages resolve the current access level and fall back to the default unlocked level when needed.

## Logging

Logging is configured by category:

```lua
logging = {
  access = true,
  navigation = true,
  history = true,
  timeout = true,
  controls = true,
  qsys = true,
  manifest = true,
}
```

`manifest = true` prints configured Q-SYS layer names and control names when `Navigator.apply(...)` runs.

`qsys = true` wraps UCI layer visibility calls so Q-SYS layer errors include the UCI page name, layer name, requested visibility, and original error.

## Validation

Navigator validates before startup:

- group and page IDs are non-empty strings
- group and page IDs do not collide
- group modes are `interlocked` or `independent`
- every group and page has a valid owner
- group ownership has no cycles
- access start groups exist
- locked access has at least one default locked page through its start group
- keypad page exists, is under the locked root group, and has locked content
- page-owned groups set `parentVisible`
- non-page-owned groups do not set `parentVisible`
- interlocked groups have at most one `startAt` member
- every `group.startAt` member is a direct page or group member
- page content references declared access levels
- controls use supported keys
- named controls exist in `Controls`

Runtime assertions catch invalid navigation, such as opening an unknown page or opening a page unavailable at the current access level.

## Basic Shape

A keyed project commonly uses a locked entry side and an unlocked session side:

```lua
entry = group({ owner = "root", mode = "independent" })
accessGate = group({ owner = "entry", mode = "interlocked", startAt = "splash" })

session = group({
  owner = "root",
  mode = "independent",
  startAt = { "frame", "system" },
})

system = group({ owner = "session", mode = "interlocked", startAt = "home" })

splash = page({ owner = "accessGate", content = { locked = "Splash" } })
keypad = page({ owner = "accessGate", content = { locked = "Keypad" } })
frame = page({ owner = "session", content = { "Header", "Footer", "Background" } })
home = page({ owner = "system", content = "Home" })
```

`access.locked.startAt = "accessGate"` enters the locked gate. `access.user.startAt = "session"` enters the unlocked session. `session.startAt = { "frame", "system" }` opens persistent frame layers and the primary interlocked system group together.

Use independent groups for frames, tools, overlays, dialogs, and coexistence. Use interlocked groups for tabs, main destinations, or any direct members that should replace one another.
