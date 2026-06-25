# Navigator

This document is a deeper companion to `README.md`. The README explains how to use Navigator; this file explains the model behind it and the rules the module follows at runtime.

## Goal

Navigator should model every navigable surface with the same primitive:

- locked splash and keypad pages
- normal unlocked pages
- page-owned detail/modal/tab pages
- independent pages such as power confirmation, help, diagnostics, or status
- custom access levels beyond `default`, such as `advanced`, `staff`, or `service`

The core primitive is ownership:

- A page group owns navigation policy.
- A page owns views, controls, and physical layer intent.
- A page belongs to exactly one page group.
- A page group is owned by `root`, another page group, or a page.

Do not merge pages and groups. A page is visible content. A group is lifecycle policy.

Navigator compiles the ownership tree once during `Navigator.configure(...)`, then uses precomputed lookup tables at runtime. This keeps page navigation mostly to table lookups and active-state walks.

## Core Authoring Shape

```lua
Navigator.configure({
  uci = {
    pageName = "Main",
    transition = "none",
  },

  access = {
    levels = {
      locked = { homePageId = "splashPage" },
      default = { homePageId = "homepage" },
      -- custom access levels may be added here:
      -- advanced = {},
    },
    keypadRequired = true,
    keypadPageId = "keypadPage",
    pinEntryTimeoutSeconds = 30,
    sessionTimeoutSeconds = 600,
  },

  accessControls = {
    state = Controls["Access State"],
    request = Controls["Access Request"],
    lock = Controls["Lock Request"],
    activityPulse = Controls["Activity Pulse"],
  },

  historyControls = {
    back = Controls["Back"],
    forward = Controls["Forward"],
  },

  frameRoles = {
    footer = "footerPage",
  },

  pageGroups = {
    groupId = {
      owner = "root", -- or another group id, or a page id
      behavior = "interlocked", -- or "independent"
      defaultPageIds = { "pageId" },
      -- ownerVisibility is required only when owner names a page:
      -- ownerVisibility = "visible" or "hidden",
    },
  },

  pages = {
    pageId = {
      pageGroup = "groupId",
      views = {
        default = { "Layer Name" },
      },
      frameOverrides = {
        footer = {
          default = { "Replacement Footer Layer" },
        },
      },
      controls = {
        open = Controls["Open Page"],
        close = Controls["Close Page"],
      },
    },
  },
})
```

## Vocabulary

- `pageGroups`: Declares lifecycle containers.
- `pageGroup`: Assigns one page to one group.
- `owner`: Names the lifecycle owner of a group.
- `behavior`: Defines how a group's direct members coexist.
- `root`: Reserved owner name for top-level groups.
- `defaultPageIds`: Optional pages to activate when a group is activated without a more specific target.
- `ownerVisibility`: For page-owned groups only, controls whether the owner page's own view remains visible.
- `frameRoles`: Names standard frame pages that active pages may override.
- `frameOverrides`: Page-local replacement views for named frame roles.

Accepted group behavior values:

- `interlocked`: Only one direct member of the group may be active at a time.
- `independent`: Direct members of the group may coexist.

A direct member may be a page or another page group.

Page ids and group ids share one owner namespace. Reject duplicate ids across `pages` and `pageGroups` so `owner = "audioPage"` is never ambiguous.

`root` is reserved and is not a page or group id. Treat `root` as an implicit interlocked owner: only one direct root-owned group is active at a time. This makes `lockedGroup` and `unlockedGroup` mutually exclusive without requiring a synthetic root group in authoring.

## Common Groups

Most projects should define at least these groups:

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

Meaning:

- `lockedGroup`: The authored locked navigation area. Splash, keypad, and locked help pages live here.
- `unlockedGroup`: The authored unlocked navigation area. It is independent so direct child groups such as `frameGroup`, `mainGroup`, and `systemGroup` can coexist.
- `frameGroup`: The standard unlocked frame surfaces. Its defaults are active whenever the unlocked group is activated.
- `mainGroup`: The normal unlocked navigation group. Its direct pages are interlocked.

Additional groups should be named for their actual purpose:

```lua
systemGroup = {
  owner = "unlockedGroup",
  behavior = "independent",
}

audioGroup = {
  owner = "audioPage",
  behavior = "interlocked",
  ownerVisibility = "visible",
}
```

## Examples

Concrete authoring examples live in:

- [Basic Keypad Example.lua](Examples/Basic%20Keypad%20Example.lua)
- [Basic No Keypad Example.lua](Examples/Basic%20No%20Keypad%20Example.lua)
- [Advanced Access Example.lua](Examples/Advanced%20Access%20Example.lua)

## Standard Locked Page Authoring

Locked pages are first-class authored pages.

Minimum locked setup:

```lua
pageGroups = {
  lockedGroup = {
    owner = "root",
    behavior = "interlocked",
    defaultPageIds = { "splashPage" },
  },
}

pages = {
  splashPage = {
    pageGroup = "lockedGroup",
    views = {
      locked = { "Splash" },
    },
    controls = {
      openKeypad = Controls["Open Keypad"],
    },
  },

  keypadPage = {
    pageGroup = "lockedGroup",
    views = {
      locked = { "Keypad" },
    },
    controls = {
      close = Controls["Keypad Close"],
    },
  },
}
```

Rules:

- `access.levels.locked.homePageId` must name a page in `lockedGroup`.
- `access.keypadPageId`, when keypad access is enabled, must name a page in `lockedGroup`.
- `Navigator.setAccess("locked")` activates the locked home page and its group ancestry.
- Opening the keypad while locked opens the authored keypad page in `lockedGroup`.
- Locked pages use `views.locked`; locked access does not fall back to `views.default`.
- Locked groups can contain additional pages such as locked help, support instructions, privacy notices, or service notices.

Access state remains the public boundary:

- Access changes clear history.
- Unlocking activates the configured default home page in the unlocked tree.
- Session timeout activates locked access.
- Keypad timers remain access behavior.

## Custom Access Levels

Navigator supports access levels beyond `locked` and `default`.

```lua
access = {
  levels = {
    locked = { homePageId = "splashPage" },
    default = { homePageId = "homepage" },
    advanced = {},
    staff = {},
  },
}
```

Rules:

- `locked` and `default` are reserved and required.
- `locked` and `default` define `homePageId`.
- Custom access levels do not define `homePageId`; unlocking into a custom access level uses the default home page and renders pages with that access level.
- Page and frame views are keyed by access level.
- A missing custom access view falls back to `default`.
- `locked` views do not fall back to `default`.
- Access changes clear history.
- Changing between unlocked access levels preserves active page/group state when the active pages remain available.
- If an active page has no view for the target custom access and no `default` fallback, close that page and any groups it owns.

Example:

```lua
audioPage = {
  pageGroup = "mainGroup",
  views = {
    default = { "Audio" },
    advanced = { "Audio", "Audio Advanced" },
  },
}
```

## Ownership Rules

1. Every group has exactly one owner.
2. Every page belongs to exactly one group.
3. A group owner may be:
   - `root`
   - a page group id
   - a page id
4. A page does not own pages directly. A page may own page groups.
5. A group does not have views or controls.
6. A page has views and controls.
7. Closing a page also closes every group owned by that page.
8. Closing a group closes active pages and groups beneath it.
9. Opening a page activates its page-group ancestry as needed.
10. Ownership cycles are invalid.
11. Page and group ids must be unique across both namespaces.
12. `root` is reserved and cannot be used as a page id or group id.

Opening a page means:

1. Find the page and its page group.
2. Activate each group in the page's owner chain.
3. Apply each owner's behavior from top to bottom.
4. Activate the target page inside its page group.
5. Activate default pages for any newly active groups that require them.
6. Close anything made inactive by those ownership decisions.
7. Reconcile layer visibility once at the end.

## Behavior Rules

Behavior applies to a group's direct members.

For an `interlocked` group:

- Opening one direct member closes other active direct members of the same group.
- If the direct member is a group, closing that member closes its active descendants.
- This supports locked splash/keypad interlock, normal main navigation, and page-owned interlocked sets such as audio subpages.

For an `independent` group:

- Opening one direct member does not close other active direct members of the same group.
- This supports independent pages such as power confirmation, help, diagnostics, or multiple visible page-owned utilities.

For implicit `root` ownership:

- Root behaves like an `interlocked` owner.
- Activating `lockedGroup` closes `unlockedGroup`.
- Activating `unlockedGroup` closes `lockedGroup`.
- This preserves the access boundary.

Example tree:

```text
root
├─ lockedGroup                   interlocked
│  ├─ splash page
│  ├─ keypad page
│  └─ lockedHelp page
└─ unlockedGroup                 independent
   ├─ frameGroup                 independent
   │  ├─ backgroundPage
   │  ├─ headerPage
   │  ├─ footerPage
   │  └─ navPage
   ├─ mainGroup                  interlocked
   │  ├─ homepage
   │  ├─ audioPage
   │  │  └─ audioGroup           interlocked
   │  │     ├─ audioRoutingPage
   │  │     └─ audioSettingsPage
   │  └─ videoPage
   │     ├─ videoModalGroup      independent
   │     │  ├─ videoRoutingPage
   │     │  └─ videoSettingsPage
   │     └─ videoReplacementGroup independent
   │        └─ videoTestPage
   └─ systemGroup                independent
      ├─ powerPage
      └─ helpPage
```

## Visibility Rules

Ownership does not by itself decide whether an owner page's physical layers stay visible behind pages in owned groups. Page-owned groups use `ownerVisibility`.

```lua
videoModalGroup = {
  owner = "videoPage",
  behavior = "independent",
  ownerVisibility = "visible",
}

audioGroup = {
  owner = "audioPage",
  behavior = "interlocked",
  ownerVisibility = "visible",
}
```

Accepted `ownerVisibility` values:

- `hidden`: When this group has active pages, hide the owner page's own view while keeping the owner page logically active.
- `visible`: Keep the owner page's resolved view visible while pages in this group are active.

Rules:

- `ownerVisibility` is required for page-owned groups.
- `ownerVisibility` is invalid for root-owned and group-owned groups.
- A hidden owner page remains active and still owns its groups.
- If multiple active owned groups disagree about the same owner page, `hidden` wins.

Frame behavior should continue to resolve from active pages. If multiple active pages at the same ownership depth define the same frame override, keep the current runtime error behavior until a clearer group-level frame policy is designed.

## Frame Overrides

Frame roles let active pages replace named frame pages without splitting every frame component into its own group.

```lua
frameRoles = {
  footer = "footerPage",
}
```

Any active page can override a role:

```lua
audioSettingsPage = {
  pageGroup = "audioGroup",
  views = {
    default = { "Audio Settings" },
  },
  frameOverrides = {
    footer = {
      default = { "Audio Settings Footer" },
    },
  },
}
```

Rules:

- `frameRoles` maps role names to the standard frame page ids.
- `frameOverrides` uses the same access-keyed layer-list shape as `views`.
- When an active page overrides a frame role, Navigator hides the role's standard frame page view and shows the override layers.
- The deepest active page override wins.
- If multiple active pages at the same depth override the same role, Navigator errors instead of guessing.
- Access-level fallback works the same as page `views`: custom access falls back to `default`; `locked` does not.

## Default Pages

Groups may define default pages:

```lua
mainGroup = {
  owner = "unlockedGroup",
  behavior = "interlocked",
  defaultPageIds = { "homepage" },
}

audioGroup = {
  owner = "audioPage",
  behavior = "interlocked",
  defaultPageIds = { "audioRoutingPage" },
}
```

Rules:

- `defaultPageIds`, when present, must contain page ids in that group.
- An `interlocked` group may have zero or one default page.
- An `independent` group may have zero or more default pages.
- Activating a group may activate its `defaultPageIds` when no page in that group is already active.
- When a page or group owner becomes active, owned groups with `defaultPageIds` activate automatically.
- This automatic owned-group activation is recursive.
- Root-owned groups are not activated automatically; access state chooses between `lockedGroup` and `unlockedGroup`.
- `access.levels.locked.homePageId` and `access.levels.default.homePageId` continue to name pages directly.
- Opening an access home page activates the required group ancestry.

Examples:

- Activating `unlockedGroup` automatically activates `frameGroup.defaultPageIds` and `mainGroup.defaultPageIds`.
- `systemGroup` does not activate automatically because it has no `defaultPageIds`.
- Opening `audioPage` automatically activates `audioGroup.defaultPageIds`.
- Opening `videoPage` does not activate `videoModalGroup` because it has no `defaultPageIds`.

## Close Rules

A page is user-closable only if the author wires a close control to it. Public `Navigator.closePage(pageId)` is forgiving enough for Q-SYS button wiring and does not throw when closing the default page is a no-op.

Rules:

- Closing an inactive page is a no-op.
- Closing a page in an `independent` group deactivates that page and any groups it owns.
- Closing a non-default page in an `interlocked` group activates the group's default page when one exists.
- Closing the default page of an `interlocked` group is a no-op.
- Closing a page in an `interlocked` group with no default page deactivates that page and any groups it owns.
- Closing `keypadPage` while still locked returns to `lockedGroup.defaultPageIds`, normally `splashPage`.
- Closing `keypadPage` after unlock activates `unlockedGroup`; default-owned-group activation brings up `frameGroup.defaultPageIds` and `mainGroup.defaultPageIds`, but not `systemGroup`.
- Closing the current default/home page is a no-op.

## Runtime Strategy

Compile authoring once during configuration.

Precompute indexes such as:

```lua
groupsById[groupId]
pagesById[pageId]
pageGroupByPageId[pageId]
groupOwnerById[groupId]
groupsOwnedByOwnerId[ownerId]
pagesByGroupId[groupId]
groupBehaviorById[groupId]
groupOwnerVisibilityById[groupId]
groupDefaultPagesById[groupId]
groupAncestorsById[groupId]
ownerKindByGroupId[groupId] -- "root", "group", or "page"
```

Runtime state should track active pages and active groups:

```lua
state.activePageIds = {
  [pageId] = true,
}

state.activeGroupIds = {
  [groupId] = true,
}
```

`activeGroupIds` exists so the navigator can activate an ancestor group such as `unlockedGroup` while its child groups carry visible pages.

Runtime navigation should use only simple table lookups and small active-state walks:

- Open page:
  - find page
  - find page group
  - activate group ancestry
  - apply interlock or independent behavior along the ownership path
  - activate page
  - activate applicable default pages and default owned groups
  - reconcile visibility

- Close page:
  - close page
  - close page-owned groups
  - reconcile visibility

- Close group:
  - close active pages in the group
  - close active child groups
  - reconcile visibility

- Reconcile visibility:
  - collect active pages
  - suppress owner page views for active page-owned groups whose `ownerVisibility` is `hidden`
  - resolve page views for the current access
  - resolve frame layers
  - apply UCI layer changes once

Avoid scanning the full config on each navigation event.

## Controls

Keep the existing page-local control idea:

```lua
controls = {
  open = Controls["Audio Nav"],
  close = Controls["Audio Close"],
  openKeypad = Controls["Open Keypad"],
}
```

Rules:

- `controls.open` calls `Navigator.openPage(pageId)`.
- `controls.close` calls `Navigator.closePage(pageId)`.
- `controls.openKeypad` opens the configured keypad page.
- Toggle nav controls should be forced `Boolean = true` when pressed and updated from active page state during reconciliation.
- Trigger controls should simply execute their action when their event handler fires.
- Control fields may still accept a single Q-SYS control or a list of equivalent controls.

## Validation Checklist

Validate during `Navigator.configure(...)`:

- `access.levels.locked` and `access.levels.default` exist.
- `access.levels.locked.homePageId` and `access.levels.default.homePageId` are valid page ids.
- Custom access levels are allowed and do not define `homePageId`.
- `pageGroups` is a table.
- `pages` is a table.
- Every group has a valid `owner`.
- Every group has `behavior = "interlocked"` or `behavior = "independent"`.
- Every page has a valid `pageGroup`.
- Every owner refers to `root`, a known group, or a known page.
- No ownership cycles exist.
- Page ids and group ids are unique across both namespaces.
- `root` is not used as a page id or group id.
- `ownerVisibility` is present and valid for page-owned groups.
- `ownerVisibility` is absent for root-owned and group-owned groups.
- `frameRoles`, when present, maps role names to valid page ids.
- `frameOverrides`, when present, references declared frame roles.
- `defaultPageIds`, when present, contains pages in the same group.
- `access.levels.locked.homePageId` identifies a page in `lockedGroup`.
- `access.levels.default.homePageId` identifies a page under `unlockedGroup`.
- `access.keypadPageId`, when keypad access is enabled, identifies a page in `lockedGroup`.
- Locked pages have `views.locked`.
- Unlocked pages have `views.default` or another valid unlocked access view.
- Every view key is declared in `access.levels`.

## History

History should snapshot both active pages and active groups:

```lua
{
  activePageIds = { ... },
  activeGroupIds = { ... },
}
```

Rules:

- Page open/close records history when active page/group state changes.
- Access changes clear history.
- Keypad/session/access boundaries clear history.
- Back/forward restores both active pages and active groups.
- If a project later needs history exclusion, that should be a group-level policy rather than a hardcoded page-id exception.
