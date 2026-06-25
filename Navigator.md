# Navigator

This document is the model companion to `README.md`. The public authoring flow is:

```lua
local config = Navigator.compile({
  -- authored project
})

Navigator.apply(config)
```

`Navigator.compile(...)` converts authored groups, pages, regions, references, access entries, and control-name strings into the native runtime model. `Navigator.apply(...)` validates and installs that model.

## Runtime Primitives

Navigator runtime state is built from:

- `pageGroups`: lifecycle containers with an owner and behavior.
- `pages`: visible navigable states with layer views, controls, and optional region fills.
- `regions`: owner-scoped presentation areas with default layer views.
- `access`: locked/default/custom access behavior.

A page belongs to exactly one group. A group is owned by `root`, another group, or a page. A region is owned by `root`, a group, or a page.

## Authoring Constructors

The module exposes these authoring constructors and registries when loaded:

```lua
group(spec)
group(spec, pages)
page(spec)
region(spec)

groups.*
pages.*
regions.*
```

`groups.root` is built in. `interlocked` and `independent` are bare mode sentinels.

Groups use:

```lua
group({
  owner = groups.session, -- or pages.audio
  mode = interlocked,     -- or independent
  startAt = pages.home,   -- optional default page
  parentVisible = true,   -- only for page-owned groups
})
```

`parentVisible = true` keeps a page owner visible while its owned group is active. `false` hides the owner page while the owned group is active.

## Access Rules

The authored `access` table is keyed by access level:

```lua
access = {
  locked = { startAt = pages.splash, keypad = pages.keypad },
  user = { startAt = pages.home, default = true },
  admin = {},
}
```

Rules:

- `locked` is required.
- One unlocked level should set `default = true`.
- Locked access does not fall back to default content.
- Unlocked custom levels fall back to the configured default level when a page or region does not define custom content.
- `keypad`, when present, must reference a locked page.
- Access changes clear history.

The compiler preserves the authored default access id. In the example above, the runtime access state is `user`, not a renamed `default`.

## Content Rules

Page and region `content` support:

- a single layer string
- a list of layer strings
- an access-keyed table

Example:

```lua
content = {
  user = { "Audio Settings", regions.footer("Audio Settings Footer") },
  admin = { "Audio Settings", "Audio Admin Tools" },
}
```

Strings become normal page or region layer views. Callable region references create fills for that region while the page is active.

## Region Resolution

On each navigation change, Navigator resolves desired layers in this order:

1. Active pages contribute their current access view unless hidden by an active page-owned group.
2. Active native frame overrides are applied for native configs that still use `frameRoles`.
3. Active regions contribute either their selected fill or their default content.

For each active region:

- The owner must be active.
- Default content is used when no active page fills the region.
- Deeper active pages beat shallower active pages.
- Same-depth active fills for the same region error.

## Controls

Authored controls are strings resolved through `Controls[controlName]` during compile:

```lua
controls = {
  open = "Open Audio Page",
  close = "Close Audio Page",
}
```

Supported page controls are `open` and `close`.

Supported global access controls are:

- `state`
- `request`
- `lock`
- `activityPulse`

Supported history controls are:

- `back`
- `forward`

Control aliases may also be lists of equivalent controls.

## Custom Script Handles

Compiled page definitions are valid page handles:

```lua
Navigator.open(config.pages.audio)
Navigator.close(config.pages.audio)
```

String ids still work through `Navigator.openPage("audio")` and `Navigator.closePage("audio")` for native or diagnostic code.

## Validation

Navigator validates before applying a config:

- unknown page, group, or region references
- duplicate page, group, or region ids
- invalid group modes
- invalid owners
- invalid `startAt` pages
- region fills for unknown regions
- unsupported page/global control names
- missing Q-SYS controls when `Controls` is available
- invalid access definitions
- same-depth active region fill conflicts at runtime

`Navigator.apply(...)` can install either a compiled config or a native config with `pageGroups` and `pages`. New project authoring should use `Navigator.compile(...)`.
