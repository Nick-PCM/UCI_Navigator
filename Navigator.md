# Navigator

Navigator controls which Q-SYS UCI layers are visible as a user moves through a touchscreen interface. It gives the project one place to define pages, sections, access levels, keypad behavior, history controls, and button bindings.

The core model is ownership. Pages and sections are top-level entries, and each one names its owner explicitly. Sections decide how their directly owned pages and sections behave. Pages contribute visible UCI layers through `content`. Access levels decide which page content is eligible to show, which content variant to use, which section becomes active first, and when the interface should return to locked access.

Navigator calls these navigation states `pages`, but it does not manage Q-SYS UCI pages directly. The visible assets it writes are Q-SYS UCI layers on the configured UCI page.

## Table Of Contents

- [Project Shape](#project-shape)
- [Startup And Runtime](#startup-and-runtime)
- [IDs And Q-SYS Names](#ids-and-q-sys-names)
- [Value Shapes](#value-shapes)
- [Authoring Surface](#authoring-surface)
- [Project Table](#project-table)
- [Sections](#sections)
- [Pages](#pages)
- [Access](#access)
- [Access Controls](#access-controls)
- [Navigation And History Controls](#navigation-and-history-controls)
- [Visibility Resolution](#visibility-resolution)
- [Logging](#logging)
- [Validation](#validation)

## Project Shape

A passcode protected project commonly uses a locked gate side and an unlocked session side:

```lua
accessGate = section({ owner = "root", mode = "switch", open = "splash" })

session = section({
  owner = "root",
  mode = "stack",
  open = { "frame", "system" },
})

system = section({ owner = "session", mode = "switch", open = "home" })

splash = page({ owner = "accessGate", content = { locked = "Splash" } })
keypad = page({ owner = "accessGate", content = { locked = "Keypad" } })
frame = page({ owner = "session", content = { "Header", "Footer", "Background", "Ribbon" } })
home = page({ owner = "system", content = "Home" })
settings = page({ owner = "system", content = "Settings" })
```

`access.locked.open = "accessGate"` enters the locked gate. `access.user.open = "session"` enters the unlocked session. `session.open = { "frame", "system" }` opens persistent frame layers and the primary switch system section together.

Use stack sections for frames, tools, overlays, modals, dialogs, and coexistence. Use switch sections for tabs, main destinations, or any directly owned pages or sections that should replace one another.

## Startup And Runtime

Navigator's runtime starts with `Navigator.apply(projectTable)`. `apply` is the boundary between authoring and runtime behavior: before it returns, Navigator has validated the project, built lookup indexes, initialized state, and written the initial Q-SYS layer visibility.

```lua
Navigator.apply({
  -- project table
})
```

At apply time Navigator:

1. Partitions top-level `section(...)` and `page(...)` entries from configuration tables.
2. Normalizes section, page, access, content, and control definitions.
3. Validates ownership, access entry sections, page content, controls, and `open`.
4. Builds runtime indexes for owned sections, pages by section, open controls, and configured layers.
5. Sets the external access-level control to the startup access level when one is configured.
6. Sets internal access state to the startup access level.
7. Activates that access level's entry section.
8. Computes the desired Q-SYS layer set and applies visibility.
9. Binds configured Q-SYS controls to Navigator actions.

After apply, navigation is state-based. Opening pages, closing pages, changing access, history traversal, and timers mutate Navigator's active page/section state. Navigator then recomputes the desired Q-SYS layer set and writes only the visibility changes needed to reach that state.

There is no separate preprocessing step. The authoring helpers `section(...)` and `page(...)` mark top-level tables so `Navigator.apply(...)` can identify navigation objects.

## IDs And Q-SYS Names

Navigator uses strings for two different things, so keep the categories separate:

```lua
system = section({
  owner = "root",       -- owner ID: built-in root owner
  mode  = "switch",
  open  = "home",   -- Navigator page ID
})

home = page({
  owner   = "system",         -- Navigator section ID
  content = "Home Layer", -- Q-SYS UCI layer name
  controls = {
    open = "Open Home", -- Q-SYS control name
  },
})
```

The left side table key is the Navigator ID:

- `system` is a section ID.
- `home` is a page ID.

Strings inside relationship fields are Navigator IDs:

- `owner = "system"`
- `open = "home"`
- `access.user.open = "system"`
- `keypad = "keypad"`

Strings inside Q-SYS fields are Q-SYS names:

- `content = "Home Layer"` is a UCI layer name.
- `controls.open = "Open Home"` is a Q-SYS control name.
- `uci.pageName = "Main"` is a Q-SYS UCI page name.

## Value Shapes

Navigator intentionally accepts a few compact value shapes. This section lists the overloaded fields in one place.

Section `open`:

```lua
open = "home"
open = { "frame", "system" }
```

For a `switch` section, `open` must be one directly owned page or section ID. For a `stack` section, `open` may be one directly owned page/section ID or a list of directly owned page/section IDs.

`page.content`:

```lua
content = "Home Layer"
content = { "Header Q-SYS Layer", "Footer Q-SYS Layer" }
content = { user = "User Audio Q-SYS Layer", admin = "Admin Audio Q-SYS Layer" }
content = { user = { "Header Q-SYS Layer", "Footer Q-SYS Layer" }, admin = { "Header Q-SYS Layer", "Admin Ribbon Q-SYS Layer" } }
```

A content string is one Q-SYS layer. A content list is multiple Q-SYS layers for the default unlocked access level. An access-keyed table selects different layer content per access level.

Control fields:

```lua
controls = { open = "Open Home" }
controls = { open = { "Open Home", "Open Home Alternate" } }
controls = { open = Controls["Open Home"] }
```

Control values may be Q-SYS control names, Q-SYS control objects, or lists of equivalent names/objects. A list such as `open = { "Control A", "Control B" }` wires every listed control to the same Navigator event handler.

## Authoring Surface

Navigator exposes:

```lua
section(spec)
page(spec)

Navigator.apply(project)
Navigator.setAccess(accessLevel)
Navigator.open(id)
Navigator.close(id)
Navigator.back()
Navigator.forward()
Navigator.getState()
Navigator.getVisibleLayers()
```

`section` and `page` are also exposed globally for compact project scripts:

```lua
system = section({ owner = "root", mode = "switch", open = "home" })
home = page({ owner = "system", content = "Home Layer" })
```

IDs are the string keys in the project table. Custom handlers use those same string IDs:

```lua
Navigator.open("home")
Navigator.open("system")
Navigator.close("home")
Navigator.close("system")
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

  system = section({ ... }),
  home = page({ ... }),
}
```

Only top-level entries returned by `section(...)` or `page(...)` become navigation objects. Other keys are configuration tables.

## Sections

A section is a navigation container with an owner, mode, optional open members, and optional controls:

```lua
session = section({
  owner = "root",
  mode  = "stack",
  open  = { "frame", "system" },
})

system = section({ owner = "session", mode = "switch", open = "home" })
```

Owners are strings:

- `"root"` for a top-level section.
- another section ID for deeper hierarchy.

`mode` is required:

- `switch`: one directly owned page or section can be active at a time.
- `stack`: multiple directly owned pages and sections can be active at once.

The implicit `"root"` owner behaves like `switch`, so direct root-owned sections replace one another.

Use `switch` for tab sets, main destinations, route pages, and any set where opening one directly owned page or section should close the others. Use `stack` for persistent frames, tool panels, overlays, modals, dialogs, and any directly owned pages or sections that should coexist.

### open

`open` names the directly owned page or section that opens when the section activates. In a `stack` section, it may name a list of directly owned pages and sections.

For a `switch` section:

```lua
system = section({ owner = "root", mode = "switch", open = "home" })
```

A `switch` section may name only one directly owned page or section.

For a `stack` section:

```lua
session = section({
  owner = "root",
  mode  = "stack",
  open  = { "frame", "help" },
})
```

A `stack` section may name one ID or a list of directly owned page/section IDs. Mixed page and section open members are allowed as long as every ID is directly owned by that section.

If `open` is omitted, activating the section activates only the section container. No page or owned section opens automatically. This can be useful for optional tool sections and modals that should stay dormant until a control opens them.

### Sections As Destinations

Sections can be destinations. Use this when a main destination needs its own base content plus subnavigation:

```lua
audio = section({
  owner    = "system",
  mode     = "stack",
  open     = { "audioBase", "audioPages" },
  controls = { open = "Open Audio Page" },
})

audioBase = page({ owner = "audio", content = "Audio" })

audioPages = section({ owner = "audio", mode = "switch", open = "audioRouting" })
audioRouting = page({ owner = "audioPages", content = "Audio Routing" })
```

In this shape, `audio` is the destination in the system section. `audioBase` supplies the base Q-SYS layers, and `audioPages` supplies the nested switching behavior. Pages are leaves; sections own the graph.

## Pages

A page has an owner, content, and optional controls:

```lua
home = page({
  owner   = "system",
  content = { user = "User Q-SYS Layer", admin = "Admin Q-SYS Layer" },
  controls = { open = "Open Home" },
})
```

`owner` must be a section ID.

`content` may be:

- one layer name
- a list of layer names
- an access-keyed table

Examples:

```lua
home = page({ owner = "system", content = "Home Layer" })

frame = page({
  owner   = "session",
  content = { "Header Layer", "Footer Layer", "Background Layer" },
})

audioStatus = page({
  owner   = "system",
  content = {
    user  = "User Audio Layer",
    admin = "Admin Audio Layer",
  },
})
```

For unlocked access levels, missing content falls back to the access level marked `default = true`. Locked access does not fall back to unlocked content.

Content is the mechanism that actually shows Q-SYS assets. When a Navigator page is active, Navigator resolves that page's `content` for the effective access level and writes the named Q-SYS layers visible. If a page is not active, its layers are hidden unless another active page also names them.

## Access

The `access` table is keyed by access level:

```lua
access = {
  locked = {
    open = "accessGate",
    keypad = "keypad",
    pinEntryTimeoutSeconds = 30,
  },
  user = {
    open = "session",
    sessionTimeoutSeconds = 600,
    default = true,
  },
  admin = {
    open = "session",
    sessionTimeoutSeconds = 600,
  },
}
```

`locked`, `user`, and `admin` are all authored access levels in the same table. The difference is that `locked` is the reserved key Navigator uses for the locked side of the interface. You author its `open`, content, keypad, and timeout behavior like the other levels, but the key itself must be `locked`.

`locked` is optional. If it exists, Navigator starts at locked access. If it does not exist, Navigator starts at the default access level.

Rules:

- `locked` is optional and reserved; it cannot be renamed.
- One non-locked level must set `default = true`.
- `access.<level>.open` names one section ID.
- `locked.keypad`, when present, names a page under the locked root section.
- `pinEntryTimeoutSeconds` returns from keypad to locked access and requires `locked.keypad`.
- `sessionTimeoutSeconds` returns from unlocked access to locked access and requires `locked`.
- `accessControls.lock` requires `locked`.
- Access changes clear history.

Access primarily controls content selection. A page can show different Q-SYS layers at `user` and `admin`, and it can be unavailable at an access level by omitting both that level and the default fallback. Access also controls opening location by activating the configured `open` section.

At startup, Navigator sets the configured access-level control before opening the entry section. This prevents a restarted script from inheriting the previous Q-SYS control value.

For a project with no lockscreen and no keypad, omit `locked` entirely:

```lua
access = {
  user = { open = "session", default = true },
}

session = section({
  owner = "root",
  mode  = "stack",
  open  = { "frame", "system" },
})

system = section({ owner = "session", mode = "switch", open = "home" })

frame = page({ owner = "session", content = "Frame" })
home = page({ owner = "system", content = "Home" })
```

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

`level` is the external access-level bridge. Navigator writes it to the startup access level at startup and reads it when the control changes.

`change` requests an access change. With a keypad configured, it always opens the keypad. If the current access is not locked, Navigator locks first and then opens the keypad. Without a keypad, it changes directly to the default unlocked access level.

For a no-keypad project, omit `locked.keypad` and point the access change control at a splash-screen button:

```lua
access = {
  locked = { open = "accessGate" },
  user = { open = "session", default = true },
}

accessControls = {
  change = "Continue",
  lock = "Lock Request",
}

accessGate = section({ owner = "root", mode = "switch", open = "splash" })
session = section({ owner = "root", mode = "switch", open = "home" })

splash = page({ owner = "accessGate", content = { locked = "Splash" } })
home = page({ owner = "session", content = "Home" })
```

Pressing `Continue` changes access from `locked` to the default unlocked level, then activates `session`.

`lock` returns to locked access and requires `access.locked`.

`activityPulse` restarts active keypad and session timers.

Each control may be a control name string, a Q-SYS control object, or a list of equivalent control names/objects. A list hooks multiple Q-SYS controls to the same access action.

`accessControls` is optional. Without it, access can still be changed from custom script code with `Navigator.setAccess("user")`.

## Navigation And History Controls

Navigation controls can live on pages or sections:

```lua
controls = {
  open = "Open Audio Page",
  close = "Close Audio Page",
}
```

Supported navigation controls are `open` and `close`. A list hooks multiple Q-SYS controls to the same action, so `open = { "Open Audio", "Open Admin Audio" }` makes either control open the same Navigator page or section.

Authoring a control inside a Navigator page or section only declares what that control does. It does not require the actual Q-SYS control to live on that page's layer, inside that visual area, or in any particular UCI context. For example, a global header button can be authored as `controls.open` on the `audio` section because pressing that header button opens `audio`.

Navigation controls are optional. Pages and sections can also be opened or closed by custom handlers that call `Navigator.open(id)` and `Navigator.close(id)`.

History controls are global and optional:

```lua
historyControls = {
  back = "Back",
  forward = "Forward",
}
```

Navigation open/close changes push history when the visible page/section state changes. Access changes clear history because active pages may not be valid under the new access level. Mechanical access flow, such as opening the keypad from the access change control, does not add a history entry.

`historyMaxEntries` defaults to `25`. Set it to `false` to disable trimming.

## Visibility Resolution

On each navigation change, Navigator computes the desired layer set from state:

1. Start with the active page and section sets.
2. Resolve each active page's content for the effective access level.
3. Apply visibility changes to Q-SYS layers.

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

- section and page IDs are non-empty strings
- section and page IDs do not collide
- section modes are `switch` or `stack`
- every section and page has a valid owner
- section ownership has no cycles
- access entry sections exist
- locked access, when authored, opens at least one locked page through its entry section
- keypad page, when authored, exists, is under the locked root section, and has locked content
- lock controls and session timeouts require locked access
- pages are leaves; sections may only be owned by `root` or another section
- switch sections have at most one `open` page or section
- every section `open` page or section is directly owned by that section
- page content references declared access levels
- controls use supported keys
- named controls exist in `Controls`

Runtime assertions catch invalid navigation, such as opening an unknown page or opening a page unavailable at the current access level.
