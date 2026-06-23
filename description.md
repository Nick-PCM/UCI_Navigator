# Q-SYS UCI Navigation and Access-Control System

Navigator is a reusable Lua module for controlling named Q-SYS UCI layers. Project authoring describes logical pages, their controls, and their physical layers. Navigator validates that authoring table, wires the standard button handlers, and determines which layers Q-SYS should show or hide.

The module is a singleton because one script controls one UCI. Configuration remains fixed after startup. Runtime state records the current access and active logical pages.

Project authors call `Navigator.configure(...)` with one project authoring table. Navigator uses that table directly after validation.

## Responsibility boundary

Project authoring provides:

- The UCI name, optional UCI page name, and optional transition.
- The access levels used by this project.
- The locked and default home page IDs.
- Whether the project uses keypad access.
- Q-SYS controls for access, optional history actions, page open/close actions, continue actions, and keypad actions when enabled.
- An optional page-history cap.
- Logical page IDs, hierarchy, views, frame overrides, and Q-SYS layer names.

Navigator governs:

- Reserved access semantics for `locked` and `default`.
- Custom access fallback to `default` views.
- Locked behavior, optional keypad behavior, timers, and session timeout.
- Page hierarchy validation and active-page state.
- Page navigation history for active page-set changes.
- Frame inheritance and override resolution.
- Standard button event handlers for declared controls.
- Q-SYS layer visibility reconciliation.

## Pages and hierarchy

All destinations—including Splash and Keypad—are entries in one keyed `pages` authoring table. Stable page IDs are separate from Q-SYS layer names.

- A root page has no `parentId`.
- An unlocked root page is called a section and has a default view.
- A child may reference a section or another child through `parentId`.
- Hierarchy is limited to section, subpage, and sub-subpage.
- Parent cycles and deeper hierarchies are rejected during configuration.
- Only one root page is active at a time.
- Closing a child also closes its active descendants; its parent remains active.
- Page navigation history is maintained for page open/close changes.

A parent uses `childDisplayMode` to allow one or multiple direct children. `SINGLE` is the default and closes active sibling branches when another child opens. `MULTIPLE` preserves active siblings.

A child uses `parentVisibility` to keep or hide its parent's physical view. The parent remains logically active in either case so closing the child returns to it.

A section may specify a direct default-capable `defaultChildId`. Opening that section, including as the default home page, activates the child automatically.

## Authoring Shape

```lua
Navigator.configure({
  uci = {
    name = "My UCI",
    pageName = "Main",
    transition = "none",
  },

  access = {
    levels = {
      locked = { homePageId = "splash" },
      default = { homePageId = "home" },
      advanced = {},
    },
    keypadRequired = true,
    keypadPageId = "keypad",
    pinEntryTimeoutSeconds = 30,
    sessionTimeoutSeconds = 600,
  },

  accessControls = {
    state = Controls["Access_State"],
    request = Controls["Access_Request"],
    lock = Controls["Lock_Request"],
    activityPulse = Controls["Activity_Pulse"],
  },

  historyControls = {
    back = Controls["Back"],
    forward = Controls["Forward"],
  },

  -- Optional. Omit for uncapped history.
  historyMaxEntries = 25,

  frame = {
    background = { views = { default = { "Background" } } },
    header = { views = { default = { "Header" } } },
    footer = { views = { default = { "Footer" } } },
    navigation = { views = { default = { "Navigation" } } },
  },

  pages = {
    home = {
      controls = { open = Controls["Home Nav"] },
      views = { default = { "Home Page" } },
    },
  },
})
```

## Access and views

Navigator has two reserved access values: `locked` and `default`. They must be present in `access.levels` and must define `homePageId`. Projects may add arbitrary lowercase user-defined access levels such as `advanced`, `staff`, or `service`.

- Locked starts at the configured locked default, normally Splash.
- Locked pages such as Splash and Keypad are ordinary configured pages.
- Locked can transition to default or a configured custom access level, opening the configured default section and rendering it for the requested access.
- Default can transition to a custom access level while preserving active pages.
- A custom access level can transition to default while preserving pages with default views and closing unavailable branches.
- Default or any custom access level can transition to locked, which restores the locked default page.

If `access.keypadRequired` is `true`, the keypad page is used from locked access and as a temporary default overlay when the user requests higher access from default. While this overlay is visible, the underlying default page state is preserved. Closing or timing out the keypad returns to the same default page state.

If `access.keypadRequired` is `false`, the project must omit `keypadPageId`, `pinEntryTimeoutSeconds`, `controls.openKeypad`, and `controls.closeKeypad`. A page-local `controls.continue` button or locked `accessControls.request` continues directly to default access.

Each page declares complete physical layer lists in a `views` table. View keys must be declared in `access.levels`. A missing custom access view falls back to `default`. Locked does not fall back.

```lua
access = {
  levels = {
    locked = { homePageId = "splash" },
    default = { homePageId = "home" },
    advanced = {},
  },
  keypadRequired = true,
}
```

A custom-access overlay is expressed by listing both layers:

```lua
views = {
  default = { "Audio Page" },
  advanced = { "Audio Page", "Advanced Audio Controls" },
}
```

A custom-access replacement lists only its replacement:

```lua
views = {
  default = { "Audio Page" },
  advanced = { "Advanced Audio Page" },
}
```

This explicit representation requires no separate overlay or replacement type.

## Frame

Unlocked pages normally include four frame roles:

- Background
- Header
- Footer
- Navigation

Project configuration provides a default view for every role. Frame views use the same access-based layer-list format as page views.

Pages may override individual roles using the same `{ views = ... }` pattern. The deepest active override replaces the less-specific selection for that role. Pages below an ancestor whose `childDisplayMode` is `MULTIPLE` cannot override frame roles, preventing ambiguous simultaneous selections.

Frame defaults have no locked view by default, so the locked experience contains only layers declared by its active page.

## Controls and timers

Navigator wires standard event handlers from the authoring table. Access controls are the external access bridge:

```lua
accessControls = {
  state = Controls["Access_State"],
  request = Controls["Access_Request"],
  lock = Controls["Lock_Request"],
  activityPulse = Controls["Activity_Pulse"],
}
```

`accessControls.state` receives validated strings from the external PIN module, such as `"locked"`, `"default"`, or `"advanced"`. Scripted lock and downgrade actions also write this control directly before applying access, keeping future value changes detectable.

`accessControls.request` opens the keypad while default when keypad access is enabled, continues directly to default while locked when keypad access is disabled, and downgrades to default while on any custom access level. `accessControls.lock` always sets locked.

History controls are optional global controls:

```lua
historyControls = {
  back = Controls["Back"],
  forward = Controls["Forward"],
}
```

`historyControls.back` calls `Navigator.back()`. `historyControls.forward` calls `Navigator.forward()`. Both controls are optional, and Navigator updates `IsDisabled` only for configured controls. They are disabled when their corresponding stack is empty. If `historyControls` is omitted, history still works through the public `Navigator.back()` and `Navigator.forward()` functions without touching any Q-SYS history controls.

Page controls live with the page they operate on:

```lua
pages = {
  volume = {
    parentId = "audio",
    controls = {
      open = Controls["Open Volume"],
      close = Controls["Volume Back"],
    },
    views = {
      default = { "Volume Page" },
    },
  },
}
```

`controls.open` calls `Navigator.openPage(pageId)`. `controls.close` calls `Navigator.closePage(pageId)`, except the keypad page closes through keypad behavior. `controls.continue` changes directly to default access for no-keypad projects. `controls.openKeypad` and `controls.closeKeypad` are available only when `access.keypadRequired` is `true`.

Page open and close operations record page-set history when they change the active page set. Access changes, locked-state resets, keypad open/close actions, keypad timeout, session timeout, and direct no-keypad continue clear both history stacks. Repeated writes of the current unlocked access value do not clear history. Keypad screens are not back/forward navigable, and back/forward are no-ops while the keypad is showing.

`historyMaxEntries` may be set to a positive integer to cap back and forward history. If it is omitted, history is uncapped.

`pinEntryTimeoutSeconds` controls keypad timeout and is required only when keypad access is enabled. `sessionTimeoutSeconds` controls unlocked access timeout. A value of `0` disables that timer. Activity pulses restart session timeout while default or a custom access level, and restart keypad timeout while the keypad is visible.

## State and visibility

Runtime state contains:

- Current access
- A set of active logical page IDs
- Whether the default keypad overlay is visible
- Whether back and forward history are available through `canGoBack` and `canGoForward`

From configuration and state, Navigator calculates the desired physical layer-name set. This includes active page views, parent-hiding rules, frame defaults, and frame overrides.

On initial configuration, Navigator explicitly assigns visibility to every configured layer. On later changes, it hides obsolete tracked layers before showing newly desired layers. Navigator must be the exclusive controller of those configured layers; outside changes can make its visibility tracking inaccurate.

Q-SYS calls use:

```lua
Uci.SetLayerVisibility(UCI_Name, Page_Name, Layer_Name, Visibility, Transition_Type)
```

Configuration requires `uci.name`. `uci.pageName` defaults to `"Main"`, and `uci.transition` defaults to `"none"`.

## Public runtime operations

After configuration, custom event handlers may still use five state-changing operations:

```lua
Navigator.setAccess(Navigator.Access.DEFAULT)
Navigator.openPage("audio")
Navigator.closePage("routing")
Navigator.back()
Navigator.forward()
```

Standard controls are normally declared in `Navigator.configure(...)` instead of manually assigning each event handler.

- `setAccess` changes authorization and applies its transition rules.
- `openPage` derives root or child behavior from page configuration.
- `closePage` closes an active nested page branch.
- `back` restores the previous active page set when available.
- `forward` restores the next active page set after a back operation.

Each successful operation updates logical state, resolves desired layers, and applies the necessary Q-SYS visibility calls automatically.
