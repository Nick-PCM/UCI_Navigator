# Authoring Spec

This file describes the current target authoring API. It is an implementation spec for the next Navigator iteration, not historical design notes.

## Goal

Authoring format should let authors describe the same navigation model with less ceremony while preserving Navigator's existing behavior model:

- pages are navigable visible states.
- groups define page coexistence behavior and ownership.
- regions are named presentation areas with owner-scoped lifetime.
- controls are authored by Q-SYS control name instead of `Controls["..."]`.

The authoring path is:

```lua
local config = Navigator.compile({
  -- authored project
})

Navigator.apply(config)
```

`Navigator.compile(...)` expands the authored project into native Navigator configuration.

`Navigator.apply(...)` installs native Navigator configuration into the active runtime.

The native path is:

```lua
Navigator.apply({
  -- native Navigator config
})
```

`Navigator.compile(...)` should return a native config table that also exposes resolved typed handles for custom script code:

```lua
local config = Navigator.compile({
  -- authored project
})

Navigator.apply(config)

Controls["Custom Audio Button"].EventHandler = function()
  Navigator.open(config.pages.audio)
end
```

This keeps Navigator module-level, avoids a `Navigator.new()` instance model, and avoids string IDs in custom calls.

## Constructors

Authoring format uses these constructors:

```lua
group(spec)
group(spec, pages)
page(spec)
region(spec)
```

`group(spec)` is shorthand for an owner-only group with no authored pages:

```lua
gate = group({ owner = groups.root, mode = independent })
```

Equivalent compiled meaning:

```lua
gate = group({ owner = groups.root, mode = independent }, {})
```

## IDs And References

Object IDs come from table keys:

```lua
system = group(...)
audio = page(...)
footer = region(...)
```

References use typed registries:

```lua
groups.session
pages.audio
regions.footer
```

These registries are symbolic handles. They do not need to resolve while Lua is building the table; `Navigator.compile(...)` resolves them after scanning the project.

Required registries:

```lua
groups.*
pages.*
regions.*
```

`groups.root` is a built-in group reference.

After compile, the returned config exposes resolved handles:

```lua
config.pages.audio
config.groups.session
config.regions.footer
```

These are intended for custom script calls after `Navigator.apply(config)`.

String IDs should not be required for:

```lua
owner
startAt
access.<level>.startAt
access.<level>.keypad
```

Expected style:

```lua
audio = group({
  owner = pages.audio,
  mode = interlocked,
  startAt = pages.audioRouting,
})
```

## Group Specs

Groups use `mode` instead of runtime `behavior`.

```lua
mode = interlocked
mode = independent
```

`interlocked` and `independent` are bare sentinel values provided by the authoring environment. `Navigator.compile(...)` compiles them to the existing runtime behavior strings.

Group spec fields:

```lua
owner = groups.session -- or pages.audio
mode = interlocked     -- or independent
startAt = pages.home   -- optional
parentVisible = true   -- optional
```

Owner-only groups are valid and useful:

```lua
gate = group({ owner = groups.root, mode = independent })
session = group({ owner = groups.root, mode = independent })
```

## Page Specs

Pages use two primary buckets:

```lua
content = ...
controls = ...
```

`content` describes what becomes visible when the page is active.

`controls` describes Q-SYS controls that operate the page.

Simple page:

```lua
home = page({
  content = "Home",
  controls = { open = "Open Home Page" },
})
```

Page with open and close controls:

```lua
videoRouting = page({
  content = "Video Routing",
  controls = {
    open = "Open Video Routing",
    close = "Close Video Routing",
  },
})
```

Control names are strings. `Navigator.compile(...)` resolves them through:

```lua
Controls[controlName]
```

## Content

`content` can be:

- a single Q-SYS layer name string.
- a list of content items.
- an access-keyed table.

Simple:

```lua
content = "Audio"
```

Access-keyed:

```lua
content = {
  locked = "Splash",
}
```

Access-keyed with multiple items:

```lua
content = {
  user = {
    "Audio Settings",
    regions.footer("Audio Settings Footer"),
  },

  admin = {
    "Audio Settings",
    "Audio Admin Tools",
    regions.footer("Audio Admin Footer"),
  },
}
```

Strings in `content` are normal Q-SYS layers for the current page.

Callable region handles in `content` are region fills:

```lua
regions.footer("Audio Settings Footer")
```

This means: while this page is active, show `"Audio Settings Footer"` in the footer region.

## Regions

Regions are first-class named presentation areas.

```lua
regions = {
  background = region({ owner = groups.session, content = "Background" }),
  header = region({ owner = groups.session, content = "Header" }),
  nav = region({ owner = groups.session, content = "Navigation" }),
  footer = region({ owner = groups.session, content = "Footer" }),
}
```

A region has:

```lua
owner = groups.session
content = "Footer"
```

Meaning:

- The region exists while its owner is active.
- The region shows its default content when no more specific active page fills it.
- `regions.footer` is the region handle.
- `regions.footer("Layer Name")` creates a fill for that region.

Region content should support the same layer normalization rules as page content.

## Region Resolution

Runtime behavior should be:

1. Find active regions whose owners are active.
2. For each active region, start with the region's default content.
3. Find active pages that fill that region.
4. Prefer the fill from the most specific active page.
5. If two equally specific active pages fill the same region, error instead of guessing.

This generalizes the current frame override behavior.

Prefer implementing regions as a real runtime concept. An initial implementation may compile regions into current `frameRoles` / `frameOverrides` internals only as a temporary stepping stone if that is clearly lower risk. The public authoring model should be regions, not frame roles.

## Access

The top-level table remains `access`, not `accessLevels`.

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

Entries under `access` are access levels.

`default = true` marks the default access level for bare page/region content.

## Global Controls

Global controls can continue using existing top-level buckets, but control values may be strings:

```lua
accessControls = {
  state = "Access State",
  request = "Access Request",
  lock = "Lock Request",
  activityPulse = "Activity Pulse",
}

historyControls = {
  back = "Back",
  forward = "Forward",
}
```

`Navigator.compile(...)` resolves these through `Controls[controlName]`.

## Custom Calls

Custom script should use resolved handles from the compiled config:

```lua
local config = Navigator.compile({
  -- authored project
})

Navigator.apply(config)

Controls["Custom Audio Button"].EventHandler = function()
  Navigator.open(config.pages.audio)
end

Controls["Custom Audio Settings Button"].EventHandler = function()
  Navigator.open(config.pages.audioSettings)
end
```

Preferred custom calls:

```lua
Navigator.open(config.pages.audio)
Navigator.close(config.pages.audio)
```

String IDs should remain supported only if needed for native compatibility, not as the preferred authoring style:

```lua
Navigator.open("audio")
```

## Current Example Shape

The current preferred ordering in `authoringExample.lua` is:

```text
gate
access
session
regions
tools
system
audio
video
videoReplacement
```

Conceptual tree:

```text
root
  gate
    access
      splash
      keypad

  session
    regions
      background
      header
      nav
      footer

    tools
      power
      help

    system
      home
      audio
      video

      audio
        audioRouting
        audioSettings

      video
        videoRouting
        videoSettings

      videoReplacement
        videoTest
```

`system` and `tools` are the preferred example pair:

- `system`: pages that control the external AV/system behavior.
- `tools`: support or utility pages for the UCI/session.

## Validation Requirements

`Navigator.compile(...)` should fail clearly for:

- unknown `pages.*`, `groups.*`, or `regions.*` references.
- duplicate page IDs.
- duplicate group IDs.
- duplicate region IDs.
- invalid group mode.
- `startAt` that does not reference a page in the group.
- region fills that reference unknown regions.
- region owners that are not valid page/group refs.
- unsupported page control names.
- control-name strings that do not exist in `Controls`, if detectable.
- multiple same-depth active fills for the same region.

## Migration Stance

Current Navigator is not in production. Existing public API shapes are not compatibility requirements.

Prefer moving the runtime/internal representation toward the authoring model where reasonable, especially for:

- `content`
- `controls`
- typed page/group/region refs
- `mode = interlocked` / `mode = independent`
- first-class regions

Existing examples and docs may be updated to the new API during implementation. Avoid preserving old shapes solely for backwards compatibility.
