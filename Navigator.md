# Navigator

Navigator controls which Q-SYS UCI layers are visible as a user moves through a touchscreen interface. It gives the project one place to define pages, groups, access levels, keypad behavior, history controls, and button bindings.

The core model is ownership. Pages and groups are top-level entries, and each one names its owner explicitly. Groups decide how their directly owned pages and groups behave. Pages contribute visible UCI layers through `content`. Access levels decide which page content is eligible to show, which content variant to use, which group becomes active first, and when the interface should return to locked access.

Navigator calls these navigation states `pages`, but it does not manage Q-SYS UCI pages directly. The visible assets it writes are Q-SYS UCI layers on the configured UCI page.

## Table Of Contents

- [Project Shape](#project-shape)
- [Startup And Runtime](#startup-and-runtime)
- [IDs And Q-SYS Names](#ids-and-q-sys-names)
- [Value Shapes](#value-shapes)
- [Authoring Surface](#authoring-surface)
- [Project Table](#project-table)
- [Groups](#groups)
- [Pages](#pages)
- [Access](#access)
- [Access Controls](#access-controls)
- [Page And History Controls](#page-and-history-controls)
- [Visibility Resolution](#visibility-resolution)
- [Logging](#logging)
- [Validation](#validation)

## Project Shape

A passcode protected project commonly uses a locked gate side and an unlocked session side:

```lua
accessGate = group({ owner = "root", mode = "interlocked", startAt = "splash" })

session = group({
  owner = "root",
  mode = "independent",
  startAt = { "frame", "system" },
})

system = group({ owner = "session", mode = "interlocked", startAt = "home" })

splash = page({ owner = "accessGate", content = { locked = "Splash" } })
keypad = page({ owner = "accessGate", content = { locked = "Keypad" } })
frame = page({ owner = "session", content = { "Header", "Footer", "Background", "Ribbon" } })
home = page({ owner = "system", content = "Home" })
settings = page({ owner = "system", content = "Settings" })
```

`access.locked.startAt = "accessGate"` enters the locked gate. `access.user.startAt = "session"` enters the unlocked session. `session.startAt = { "frame", "system" }` opens persistent frame layers and the primary interlocked system group together.

Use independent groups for frames, tools, overlays, modals, dialogs, and coexistence. Use interlocked groups for tabs, main destinations, or any directly owned pages or groups that should replace one another.

## Startup And Runtime

Navigator's runtime starts with `Navigator.apply(projectTable)`. `apply` is the boundary between authoring and runtime behavior: before it returns, Navigator has validated the project, built lookup indexes, initialized state, and written the initial Q-SYS layer visibility.

```lua
Navigator.apply({
  -- project table
})
```

At apply time Navigator:

1. Partitions top-level `group(...)` and `page(...)` entries from configuration tables.
2. Normalizes group, page, access, content, and control definitions.
3. Validates ownership, access start groups, page content, controls, `startAt`, and page-owned group rules.
4. Builds runtime indexes for owned groups, pages by group, and owner kinds.
5. Sets the external access-level control to `locked` when one is configured.
6. Sets internal access state to `locked`.
7. Activates the locked access start group.
8. Computes the desired Q-SYS layer set and applies visibility.
9. Binds configured Q-SYS controls to Navigator actions.

After apply, navigation is state-based. Opening pages, closing pages, changing access, history traversal, and timers mutate Navigator's active page/group state. Navigator then recomputes the desired Q-SYS layer set and writes only the visibility changes needed to reach that state.

There is no separate preprocessing step. The authoring helpers `group(...)` and `page(...)` mark top-level tables so `Navigator.apply(...)` can identify navigation objects.

## IDs And Q-SYS Names

Navigator uses strings for two different things, so keep the categories separate:

```lua
MyGroupId = group({
  owner = "root",          -- owner ID: built-in root owner
  mode = "interlocked",
  startAt = "MyPageId",    -- Navigator page ID
})

MyPageId = page({
  owner = "MyGroupId",     -- Navigator group ID
  content = "My Q-SYS Layer Name", -- Q-SYS UCI layer name
  controls = {
    open = "My Q-SYS Control Name", -- Q-SYS control name
  },
})
```

The left side table key is the Navigator ID:

- `MyGroupId` is a group ID.
- `MyPageId` is a page ID.

Strings inside relationship fields are Navigator IDs:

- `owner = "MyGroupId"`
- `startAt = "MyPageId"`
- `access.user.startAt = "MyGroupId"`
- `keypad = "MyPageId"`

Strings inside Q-SYS fields are Q-SYS names:

- `content = "My Q-SYS Layer Name"` is a UCI layer name.
- `controls.open = "My Q-SYS Control Name"` is a Q-SYS control name.
- `uci.pageName = "Main"` is a Q-SYS UCI page name.

## Value Shapes

Navigator intentionally accepts a few compact value shapes. This section lists the overloaded fields in one place.

`group.startAt`:

```lua
startAt = "MyPageId"
startAt = { "MyFramePageId", "MySystemGroupId" }
```

For an `interlocked` group, `startAt` must be one directly owned page or group ID. For an `independent` group, `startAt` may be one directly owned page/group ID or a list of directly owned page/group IDs.

`page.content`:

```lua
content = "My Q-SYS Layer Name"
content = { "Header Q-SYS Layer", "Footer Q-SYS Layer" }
content = { user = "User Audio Q-SYS Layer", admin = "Admin Audio Q-SYS Layer" }
content = { user = { "Header Q-SYS Layer", "Footer Q-SYS Layer" }, admin = { "Header Q-SYS Layer", "Admin Ribbon Q-SYS Layer" } }
```

A content string is one Q-SYS layer. A content list is multiple Q-SYS layers for the default unlocked access level. An access-keyed table selects different layer content per access level.

Control fields:

```lua
controls = { open = "My Q-SYS Control Name" }
controls = { open = { "My Q-SYS Control Name", "My Other Q-SYS Control Name" } }
controls = { open = Controls["My Q-SYS Control Name"] }
```

Control values may be Q-SYS control names, Q-SYS control objects, or lists of equivalent names/objects. A list such as `open = { "Control A", "Control B" }` wires every listed control to the same Navigator event handler.

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
MyGroupId = group({ owner = "root", mode = "interlocked", startAt = "MyPageId" })
MyPageId = page({ owner = "MyGroupId", content = "My Q-SYS Layer Name" })
```

IDs are the string keys in the project table. Custom handlers use those same string IDs:

```lua
Navigator.open("MyPageId")
Navigator.close("MyPageId")
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

  MyGroupId = group({ ... }),
  MyPageId = page({ ... }),
}
```

Only top-level entries returned by `group(...)` or `page(...)` become navigation objects. Other keys are configuration tables.

## Groups

A group is a container with an owner, a mode, optional defaults, and optional page-owner visibility behavior:

```lua
MyGroupId = group({
  owner = "root",
  mode = "interlocked",
  startAt = "MyPageId",
})
```

Owners are strings:

- `"root"` for a top-level group.
- another group ID for deeper hierarchy.
- a page ID for page-owned subpage groups.

`mode` is required:

- `interlocked`: one directly owned page or group can be active at a time.
- `independent`: multiple directly owned pages and groups can be active at once.

The implicit `"root"` owner behaves as interlocked, so direct root-owned groups replace one another.

Use `interlocked` for tab sets, main destinations, route pages, and any set where opening one directly owned page or group should close the others. Use `independent` for persistent frames, tool panels, overlays, modals, dialogs, and any directly owned pages or groups that should coexist.

### startAt

`group.startAt` names the directly owned page or group that opens when the group activates. In an independent group, it may name a list of directly owned pages and groups.

For an interlocked group:

```lua
MyGroupId = group({ owner = "root", mode = "interlocked", startAt = "MyPageId" })
```

An interlocked group may name only one directly owned page or group.

For an independent group:

```lua
MySessionGroupId = group({
  owner = "root",
  mode = "independent",
  startAt = { "MyFramePageId", "MySystemGroupId" },
})
```

An independent group may name one ID or a list of directly owned page/group IDs. Mixed page and group defaults are allowed as long as every ID is directly owned by that group.

If `startAt` is omitted, activating the group activates only the group container. No page or owned group opens automatically. This can be useful for optional tool groups and modals that should stay dormant until a control opens them.

### Page-Owned Groups

Page-owned groups model subpages:

```lua
MySubpageGroupId = group({
  owner = "MyParentPageId",
  mode = "interlocked",
  parentVisible = true,
  startAt = "MySubpageId",
})
```

`parentVisible` is required for page-owned groups:

- `true`: keep the owner page visible while the owned group is active.
- `false`: suppress the owner page while the owned group is active.

`parentVisible` is invalid on root-owned or group-owned groups.

## Pages

A page has an owner, content, and optional controls:

```lua
MyPageId = page({
  owner = "MyGroupId",
  content = { user = "User Q-SYS Layer", admin = "Admin Q-SYS Layer" },
  controls = { open = "My Q-SYS Control Name" },
})
```

`owner` must be a group ID.

`content` may be:

- one layer name
- a list of layer names
- an access-keyed table

Examples:

```lua
MyPageId = page({ owner = "MyGroupId", content = "My Q-SYS Layer Name" })

MyFramePageId = page({
  owner = "MySessionGroupId",
  content = { "Header Layer", "Footer Layer", "Background Layer" },
})

MyAudioPageId = page({
  owner = "MySystemGroupId",
  content = {
    user = "User Audio Layer",
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

`locked`, `user`, and `admin` are all authored access levels in the same table. The difference is that `locked` is the reserved key Navigator uses for the locked side of the interface. You author its `startAt`, content, keypad, and timeout behavior like the other levels, but the key itself must be `locked`.

Rules:

- `locked` is required and reserved; it cannot be renamed.
- One non-locked level must set `default = true`.
- `access.<level>.startAt` names one group ID.
- `locked.keypad`, when present, names a page under the locked root group.
- `pinEntryTimeoutSeconds` returns from keypad to locked access.
- `sessionTimeoutSeconds` returns from unlocked access to locked access.
- Access changes clear history.

Access primarily controls content selection. A page can show different Q-SYS layers at `user` and `admin`, and it can be unavailable at an access level by omitting both that level and the default fallback. Access also controls startup location by activating the configured `startAt` group.

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

For a no-keypad project, omit `locked.keypad` and point the access change control at a splash-screen button:

```lua
access = {
  locked = { startAt = "accessGate" },
  user = { startAt = "session", default = true },
}

accessControls = {
  change = "Continue",
  lock = "Lock Request",
}

accessGate = group({ owner = "root", mode = "interlocked", startAt = "splash" })
session = group({ owner = "root", mode = "interlocked", startAt = "home" })

splash = page({ owner = "accessGate", content = { locked = "Splash" } })
home = page({ owner = "session", content = "Home" })
```

Pressing `Continue` changes access from `locked` to the default unlocked level, then activates `session`.

`lock` returns to locked access.

`activityPulse` restarts active keypad and session timers.

Each control may be a control name string, a Q-SYS control object, or a list of equivalent control names/objects. A list hooks multiple Q-SYS controls to the same access action.

`accessControls` is optional. Without it, access can still be changed from custom script code with `Navigator.setAccess("user")`.

## Page And History Controls

Page controls live on pages:

```lua
controls = {
  open = "Open Audio Page",
  close = "Close Audio Page",
}
```

Supported page controls are `open` and `close`. A list hooks multiple Q-SYS controls to the same page action, so `open = { "Open Audio", "Open Admin Audio" }` makes either control open the same Navigator page.

Authoring a control inside a Navigator page only declares what that control does. It does not require the actual Q-SYS control to live on that page's layer, inside that page's visual area, or in any particular UCI context. For example, a global header button can be authored as `controls.open` on the `audio` page because pressing that header button opens `audio`.

Page controls are optional. Pages can also be opened or closed by custom handlers that call `Navigator.open(pageId)` and `Navigator.close(pageId)`.

History controls are global and optional:

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
- interlocked groups have at most one `startAt` page or group
- every `group.startAt` page or group is directly owned by that group
- page content references declared access levels
- controls use supported keys
- named controls exist in `Controls`

Runtime assertions catch invalid navigation, such as opening an unknown page or opening a page unavailable at the current access level.
