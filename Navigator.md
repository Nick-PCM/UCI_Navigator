# Navigator

Navigator is a small UCI navigation runtime and authoring compiler for Q-SYS Lua projects. Its job is to make layer visibility deterministic as the interface moves through pages, access levels, shared regions, history, timers, and Q-SYS control events.

The core design is ownership. Pages are not just buttons that show layers; they belong to groups, groups belong to other lifecycle owners, and regions live only while their owners are active. From that ownership graph, Navigator can decide which layers should be visible at any moment and which controls should change the current state.

## Mental Model

Navigator reduces a UCI to four authored concepts:

- `groups`: lifecycle containers. A group decides whether its pages are mutually exclusive or independent.
- `pages`: navigable states. A page contributes visible layer content and can own child groups.
- `regions`: optional owner-scoped presentation areas. A region has default content and may be filled by active pages.
- `access`: the current access level. Access chooses entry pages, content variants, keypad behavior, and timeout behavior.

The runtime continuously reconciles the desired visible layers from those concepts. It does not rely on old layer state; each navigation change computes the current desired set and writes Q-SYS layer visibility from that set.

## Runtime Shape

Authored projects are compiled before they are applied:

```lua
local Navigator = require("Navigator")

local config = Navigator.compile({
  -- authored project
})

Navigator.apply(config)
```

`Navigator.compile(project)` expands authoring constructors, typed references, access entries, layer names, and control-name strings into runtime tables. `Navigator.apply(config)` validates the compiled model, binds Q-SYS controls, initializes timers, resets the configured access-level control to `locked`, and opens the configured entry page.

The compiled config exposes handles under:

```lua
config.groups
config.pages
config.regions
```

Those handles are valid for custom code:

```lua
Navigator.open(config.pages.audio)
Navigator.close(config.pages.audio)
```

String ids are also available for diagnostic code:

```lua
Navigator.openPage("audio")
Navigator.closePage("audio")
```

## Authoring Surface

Navigator exposes a compact authoring API when `Navigator.lua` is loaded:

```lua
group(spec)
group(spec, pages)
page(spec)
region(spec)

groups.*
pages.*
regions.*

interlocked
independent
```

Table keys become object ids:

```lua
session = group({ owner = groups.root, mode = independent })

system = group(
  { owner = groups.session, mode = interlocked, startAt = pages.home },
  {
    home = page({ content = "Home" }),
    audio = page({ content = "Audio" }),
  }
)
```

`groups.session`, `pages.audio`, and `regions.footer` are typed references. They let the compiler validate relationships before the runtime starts.

## Groups

A group is a lifecycle container with an owner and a mode:

```lua
group({
  owner = groups.session, -- groups.root, another group, or a page
  mode = interlocked,     -- or independent
  startAt = pages.home,   -- optional
  parentVisible = true,   -- only meaningful for page-owned groups
})
```

`groups.root` is the built-in root owner. It behaves as the top of the lifecycle tree, so direct root-owned groups interlock with one another.

`interlocked` means only one page in the group is active at a time. Opening a page in that group closes the previous active sibling.

`independent` means pages in the group may coexist. Opening one page does not automatically close its siblings.

`startAt` marks the page a group should open when that group becomes active through access entry or parent lifecycle.

Page-owned groups are useful for subpages. `parentVisible = true` keeps the owning page visible while the child group is active. `parentVisible = false` lets the child group replace the owner page visually.

## Pages

A page contributes visible content and optional controls:

```lua
audio = page({ content = "Audio", controls = { open = "Open Audio Page" } })
```

`content` may be:

- one layer name
- a list of layer names
- an access-keyed table

```lua
audioSettings = page({
  content = {
    user = { "Audio Settings", regions.footer("Audio Settings Footer") },
    admin = { "Audio Settings", "Audio Admin Tools" },
  },
  controls = { open = "Open Audio Settings" },
})
```

For custom unlocked access levels, content falls back to the level marked `default = true` when that page or region does not define content for the current access level. Locked access does not use that fallback.

## Regions

Regions are optional lifecycle objects like groups. A region exists only while its owner is active, and the `content` assigned in the region constructor is its default:

```lua
regions = {
  header = region({ owner = groups.session, content = "Header" }),
  footer = region({ owner = groups.session, content = "Footer" }),
}
```

Pages fill regions by calling the region reference inside page content:

```lua
audioSettings = page({
  content = {
    "Audio Settings",
    regions.footer("Audio Settings Footer"),
  },
})
```

Page fills override region defaults. Deeper active pages win over shallower active pages. Same-depth fills for the same region are treated as a configuration/runtime conflict and error rather than guessing.

This rule lets broad defaults live on the session, while specific pages temporarily replace the shared header, footer, ribbon, background, or other chrome.

## Access

The authored `access` table is keyed by access level:

```lua
access = {
  locked = { startAt = pages.splash, keypad = pages.keypad, pinEntryTimeoutSeconds = 30 },
  user = { startAt = pages.home, sessionTimeoutSeconds = 600, default = true },
  admin = {},
}
```

Rules:

- `locked` is required and reserved for locked access.
- One unlocked level should set `default = true`.
- `locked.startAt` defines the locked entry page.
- `locked.keypad`, when present, must reference a locked page.
- Unlocked access levels can define `startAt` and `sessionTimeoutSeconds`.
- Custom unlocked levels can omit content and fall back to the default unlocked level.
- Access changes clear history.

`admin` is only an example access level. Projects may define whatever unlocked levels they need as long as one unlocked level is the default.

On startup, Navigator sets the configured access-level control to `locked` as one of its first actions. This prevents a restarted script from inheriting a stale logged-in Q-SYS control value.

If the keypad times out, Navigator locks. If the unlocked session times out, Navigator locks.

## Access Controls

`accessControls` binds global Q-SYS controls:

```lua
accessControls = {
  level = "Access Level",
  change = "Change Access Level",
  lock = "Lock Request",
  activityPulse = "Activity Pulse",
}
```

`level` is the external access-level bridge. Navigator writes it to `locked` at startup and reads it when the keypad flow completes.

`change` is a change-access-level request. With a keypad configured, it always takes the user to the keypad. If the current access level is not locked, Navigator locks first so the keypad starts from the locked side of the boundary. Without a keypad, it changes directly to the default unlocked access level.

`lock` immediately returns to locked access.

`activityPulse` restarts active keypad or session timers.

Each entry may be a single control name or a list of equivalent control names.

## Page And History Controls

Page controls are authored on the page:

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

Navigation changes push history unless the change is itself a history traversal or access transition. Access changes clear history because the visible state may no longer be valid under the new access level.

## Visibility Resolution

On each navigation change, Navigator computes desired layers in this order:

1. Determine the active owner tree from root, groups, pages, and page-owned groups.
2. Select page content for the current access level.
3. Suppress an owner page when an active child group has `parentVisible = false`.
4. Determine which regions are active from their owners.
5. Apply region defaults or the most specific active page fill.
6. Write Q-SYS layer visibility from the final desired set.

This makes visibility an output of the model, not an accumulation of previous button presses.

## Logging

Logging is configured by category:

```lua
logging = {
  access = true,
  navigation = true,
  history = true,
  keypad = true,
  timeout = true,
  controls = true,
  manifest = true,
}
```

`manifest = true` prints the configured Q-SYS layer names and authored control names when `Navigator.apply(config)` runs. It is the fastest way to verify that the authored project names match the UCI.

## Validation

Navigator validates before applying config and continues to assert runtime conflicts that depend on active state.

Compile/apply validation includes:

- unknown page, group, or region references
- duplicate page, group, or region ids
- invalid group modes
- invalid owners
- invalid `startAt` pages
- page-owned group rules
- region fills for unknown regions
- unsupported page or global control names
- missing Q-SYS controls when `Controls` is available
- missing or invalid access definitions
- invalid keypad page placement

Runtime validation includes same-depth active region fill conflicts. Navigator errors in that case because neither fill is more specific than the other.

## Usage Patterns

A typical keyed project uses two root-level containers:

```lua
gate = group({ owner = groups.root, mode = independent })
session = group({ owner = groups.root, mode = independent })
```

`gate` owns locked pages through an interlocked `accessGate` group:

```lua
accessGate = group(
  { owner = groups.gate, mode = interlocked, startAt = pages.splash },
  {
    splash = page({ content = { locked = "Splash" } }),
    keypad = page({ content = { locked = "Keypad" } }),
  }
)
```

`session` owns unlocked pages and optional regions:

```lua
system = group(
  { owner = groups.session, mode = interlocked, startAt = pages.home },
  {
    home = page({ content = "Home" }),
    audio = page({ content = "Audio" }),
  }
)
```

Use independent groups for overlays, tools, dialogs, and other pages that can coexist. Use interlocked groups for tab sets, route destinations, and any surface where one active page should replace another.
196