# UCI Navigator V2

Navigator V2 is a Lua module for controlling Q-SYS UCI layer visibility from a project-authored navigation model. It wires standard controls, tracks access state, opens and closes pages, manages history, and reconciles the visible Q-SYS layers after each navigation change.

The goal is to let a project describe its UCI in terms of logical pages and ownership instead of writing one-off layer show/hide scripts for every button.

## Files

- `Navigator.lua`: the V2 module.
- `VanillaExample.lua`: complete default-access example.
- `StrawberryExample.lua`: complete advanced-access example.
- `ArchitectureUpdate.md`: implementation notes and deeper design rules.

## Mental Model

Navigator has two separate primitives:

- A **page** is visible content. It owns views, Q-SYS layer names, and controls.
- A **page group** is lifecycle policy. It controls how its direct members coexist.

Pages do not directly contain pages. A page belongs to one group, and a page may own groups.

```text
pageGroup -> page
page      -> pageGroup
```

That one ownership rule covers ordinary navigation, page-owned subpages, modals, replacement pages, locked splash/keypad pages, and independent system pages.

## Page Groups

Every page group declares:

```lua
someGroup = {
  owner = "root",
  behavior = "interlocked",
  defaultPageIds = { "somePage" },
}
```

`owner` names what owns the group:

- `"root"` for top-level groups.
- another group id.
- a page id.

`behavior` defines how direct members of the group coexist:

- `"interlocked"`: only one direct member is active at a time.
- `"independent"`: direct members may be active together.

`defaultPageIds` is optional. When a group becomes active, defaults are opened if the group has no active page.

For page-owned groups, `ownerView` is required:

```lua
audioGroup = {
  owner = "audioPage",
  behavior = "interlocked",
  ownerView = "keep",
  defaultPageIds = { "audioRoutingPage" },
}
```

- `ownerView = "keep"` keeps the owner page visible behind owned pages.
- `ownerView = "hide"` hides the owner page view while owned pages are active.

## Standard Groups

Most projects should start with these groups:

```lua
pageGroups = {
  lockedGroup = {
    owner = "root",
    behavior = "interlocked",
    defaultPageIds = { "splashPage" },
  },

  unlockedGroup = {
    owner = "root",
    behavior = "independent",
  },

  frameGroup = {
    owner = "unlockedGroup",
    behavior = "independent",
    defaultPageIds = {
      "backgroundPage",
      "headerPage",
      "footerPage",
      "navPage",
    },
  },

  mainGroup = {
    owner = "unlockedGroup",
    behavior = "interlocked",
    defaultPageIds = { "homepage" },
  },
}
```

`root` is implicitly interlocked, so `lockedGroup` and `unlockedGroup` are mutually exclusive. `unlockedGroup` is independent so frame, main navigation, and system pages can coexist.

## Pages

A page declares its group, access-keyed views, and optional controls:

```lua
audioPage = {
  pageGroup = "mainGroup",
  views = {
    default = { "Audio" },
  },
  controls = {
    open = Controls["Open Audio Page"],
  },
}
```

Layer names in `views` are Q-SYS UCI layer names. Page ids and group ids are Navigator authoring ids.

Controls belong to the page/action they operate on, not necessarily the layer where the physical control appears. A nav button on `navPage` that opens `audioPage` is authored on `audioPage`.

## Locked And Keypad Pages

Locked pages are authored like any other page. A minimal locked setup has a splash page and a keypad page in `lockedGroup`.

```lua
access = {
  levels = {
    locked = { homePageId = "splashPage" },
    default = { homePageId = "homepage" },
  },
  keypadRequired = true,
  keypadPageId = "keypadPage",
}
```

`locked` access uses locked views only; it does not fall back to default views.

## Access Levels

`locked` and `default` are required. Projects may add custom access levels:

```lua
access = {
  levels = {
    locked = { homePageId = "splashPage" },
    default = { homePageId = "homepage" },
    advanced = {},
  },
}
```

Custom access levels render views with the matching key and fall back to `default` when a custom view is missing. If an active page has no target-access view and no default fallback, Navigator closes that page and anything it owns.

## Common Patterns

Main navigation:

```lua
mainGroup = {
  owner = "unlockedGroup",
  behavior = "interlocked",
  defaultPageIds = { "homepage" },
}
```

Opening `audioPage` closes `homepage` and `videoPage`.

Page-owned interlocked subpages:

```lua
audioGroup = {
  owner = "audioPage",
  behavior = "interlocked",
  ownerView = "keep",
  defaultPageIds = { "audioRoutingPage" },
}
```

Opening `audioSettingsPage` closes `audioRoutingPage`, while `audioPage` remains visible.

Page-owned modal pages:

```lua
videoModalGroup = {
  owner = "videoPage",
  behavior = "independent",
  ownerView = "keep",
}
```

Opening a modal keeps `videoPage` visible. Closing the modal hides only that modal.

Page-owned replacement pages:

```lua
videoReplacementGroup = {
  owner = "videoPage",
  behavior = "independent",
  ownerView = "hide",
}
```

Opening `videoTestPage` hides `videoPage` visually while keeping it logically active. Closing `videoTestPage` reveals `videoPage`.

Independent system pages:

```lua
systemGroup = {
  owner = "unlockedGroup",
  behavior = "independent",
}
```

Pages such as power confirmation or help can open without replacing the main navigation page.

## Controls

Supported page controls:

- `open`: opens the page.
- `close`: closes the page.
- `openKeypad`: opens the configured keypad page.

Control fields can be a single Q-SYS control or a list of equivalent controls.

Open controls are treated as toggle-style navigation controls: when pressed, Navigator forces the control Boolean true and later updates related open controls from active page state. Trigger-style controls simply run their action when their event handler fires.

Access controls:

- `accessControls.state`: string bridge for external access modules.
- `accessControls.request`: access request/downgrade/open-keypad action.
- `accessControls.lock`: return to locked access.
- `accessControls.activityPulse`: restarts active timers.

History controls:

- `historyControls.back`
- `historyControls.forward`

## History

Navigator history stores active pages and active groups. Page open/close changes record history. Access changes and keypad/session boundaries clear history.

## Starting Point

Use `VanillaExample.lua` for a default-access project shape. Use `StrawberryExample.lua` to see how the same ownership tree supports an `advanced` access level.
