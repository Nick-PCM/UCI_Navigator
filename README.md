# UCI Navigator

Navigator is a Lua module for controlling Q-SYS UCI layer visibility from a project table that describes pages, groups, access, regions, and controls.

The normal authoring path is:

```lua
local config = Navigator.compile({
  -- authored project
})

Navigator.apply(config)
```

`Navigator.compile(...)` expands the authoring format into Navigator's runtime configuration. `Navigator.apply(...)` installs that configuration into the active Q-SYS runtime.

## Files

- `Navigator.lua`: the navigation module.
- `Navigator.md`: deeper model and runtime rules.
- `Examples/Basic Keypad Example.lua`: authored config with keypad access.
- `Examples/Basic No Keypad Example.lua`: authored config without keypad access.
- `Examples/Advanced Access Example.lua`: authored config with a custom access level.

## Authoring Model

Navigator has three authored primitives:

- A `page(...)` is navigable visible content.
- A `group(...)` defines ownership and coexistence policy for pages.
- A `region(...)` is an owner-scoped presentation area with default content that active pages can fill.

Object ids come from table keys:

```lua
session = group({ owner = groups.root, mode = independent })

system = group({ owner = groups.session, mode = interlocked, startAt = pages.home }, {
  home = page({ content = "Home" }),
  audio = page({ content = "Audio" }),
})
```

References use typed registries:

```lua
groups.session
pages.audio
regions.footer
```

`groups.root` is the built-in root owner. Group modes use bare sentinels:

```lua
mode = interlocked
mode = independent
```

## Access

Top-level `access` declares access levels. The basic examples use `locked` and `user`; the advanced example adds `admin` as a custom access level. `locked` is reserved for locked access, and `user` sets `default = true` so it becomes the fallback target for bare content and normal access requests.

```lua
access = {
  locked = {
    startAt = pages.splash,
    keypad = pages.keypad,
    pinEntryTimeoutSeconds = 30,
  },

  user = {
    startAt = pages.home,
    sessionTimeoutSeconds = 600,
    default = true,
  },

  admin = {},
}
```

## Pages And Controls

Page `content` can be a layer name, a list of layer names, or an access-keyed table. Page controls are authored by Q-SYS control name and compiled through `Controls[controlName]`.

```lua
audioSettings = page({
  content = {
    user = { "Audio Settings", regions.footer("Audio Settings Footer") },
    admin = { "Audio Settings", "Audio Admin Tools" },
  },
  controls = {
    open = "Open Audio Settings",
  },
})
```

Supported page controls are `open` and `close`. Global `accessControls` and `historyControls` also accept control-name strings.

## Regions

Regions exist while their owner is active. They show default content unless the most specific active page fills them.

```lua
regions = {
  footer = region({ owner = groups.session, content = "Footer" }),
}
```

Page fills use a callable region reference:

```lua
regions.footer("Audio Settings Footer")
```

If two equally specific active pages fill the same region, Navigator errors instead of guessing.

## Custom Calls

Compiled pages are handles for custom script code:

```lua
local config = Navigator.compile({
  -- project
})

Navigator.apply(config)

Controls["Custom Audio Button"].EventHandler = function()
  Navigator.open(config.pages.audio)
end
```

`Navigator.close(config.pages.audio)` closes the same page.

## Runtime Config

The compiled config exposes resolved handles under `config.pages`, `config.groups`, and `config.regions`. Treat that compiled table as Navigator's runtime config and pass it directly to `Navigator.apply(...)`.
