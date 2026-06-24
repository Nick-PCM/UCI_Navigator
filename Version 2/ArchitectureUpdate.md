# Navigator Architecture Update

This document defines the proposed ownership and page-group architecture for the next Navigator implementation. It is an implementation spec, not documentation for the current `Navigator.lua`.

The current Navigator API has not been deployed. Do not spend implementation effort on backward compatibility with `parentId`, `childDisplayMode`, `parentVisibility`, or `defaultChildId`. The goal is a coherent fresh design.

## Goal

Navigator should model every navigable surface with the same primitive:

- locked splash and keypad pages
- normal unlocked pages
- page-owned detail/modal/tab pages
- independent pages such as power confirmation, help, diagnostics, or status
- custom access levels beyond `default`, such as `advanced`, `staff`, or `service`

The proposed primitive is ownership:

- A page group owns navigation policy.
- A page owns views, controls, and physical layer intent.
- A page belongs to exactly one page group.
- A page group is owned by `root`, another page group, or a page.

Do not merge pages and groups. A page is visible content. A group is lifecycle policy.

Compile the ownership tree once during `Navigator.configure(...)`, then use precomputed lookup tables at runtime. This should not become a general graph engine.

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
    state = Controls["Access_State"],
    request = Controls["Access_Request"],
    lock = Controls["Lock_Request"],
    activityPulse = Controls["Activity_Pulse"],
  },

  historyControls = {
    back = Controls["Back"],
    forward = Controls["Forward"],
  },

  pageGroups = {
    groupId = {
      owner = "root", -- or another group id, or a page id
      behavior = "interlocked", -- or "independent"
      defaultPageIds = { "pageId" },
      -- ownerView is required only when owner names a page:
      -- ownerView = "keep" or "hide",
    },
  },

  pages = {
    pageId = {
      pageGroup = "groupId",
      views = {
        default = { "Layer Name" },
      },
      controls = {
        open = Controls["Open_Page"],
        close = Controls["Close_Page"],
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
- `ownerView`: For page-owned groups only, controls whether the owner page's own view remains visible.

Accepted group behavior values:

- `interlocked`: Only one direct member of the group may be active at a time.
- `independent`: Direct members of the group may coexist.

A direct member may be a page or another page group.

Page ids and group ids share one owner namespace. Reject duplicate ids across `pages` and `pageGroups` so `owner = "audioPage"` is never ambiguous.

`root` is reserved and is not a page or group id. Treat `root` as an implicit interlocked owner: only one direct root-owned group is active at a time. This makes `lockedGroup` and `unlockedGroup` mutually exclusive without requiring a synthetic root group in authoring.

## Standard Groups

Every project should define at least these groups:

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
  ownerView = "keep",
}
```

## Examples

Concrete authoring examples live in:

- [VanillaExample.lua](VanillaExample.lua)
- [StrawberryExample.lua](StrawberryExample.lua)

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
      openKeypad = Controls["Open_Keypad"],
    },
  },

  keypadPage = {
    pageGroup = "lockedGroup",
    views = {
      locked = { "Keypad" },
    },
    controls = {
      close = Controls["Keypad_Close"],
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

V2 must preserve support for access levels beyond `locked` and `default`.

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

Ownership does not by itself decide whether an owner page's physical layers stay visible behind pages in owned groups. Page-owned groups use `ownerView`.

```lua
videoModalGroup = {
  owner = "videoPage",
  behavior = "independent",
  ownerView = "keep",
}

audioGroup = {
  owner = "audioPage",
  behavior = "interlocked",
  ownerView = "keep",
}
```

Accepted `ownerView` values:

- `hide`: When this group has active pages, hide the owner page's own view while keeping the owner page logically active.
- `keep`: Keep the owner page's resolved view visible while pages in this group are active.

Rules:

- `ownerView` is required for page-owned groups.
- `ownerView` is invalid for root-owned and group-owned groups.
- A hidden owner page remains active and still owns its groups.
- If multiple active owned groups disagree about the same owner page, `hide` wins.

Frame behavior should continue to resolve from active pages. If multiple active pages at the same ownership depth define the same frame override, keep the current runtime error behavior until a clearer group-level frame policy is designed.

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

Do not add a `closable` flag for the first implementation. A page is user-closable only if the author wires a close control to it. Public `Navigator.closePage(pageId)` should be forgiving enough for Q-SYS button wiring and should not throw when closing the default page is a no-op.

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
groupOwnerViewById[groupId]
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
  - suppress owner page views for active page-owned groups whose `ownerView` is `hide`
  - resolve page views for the current access
  - resolve frame layers
  - apply UCI layer changes once

Avoid scanning the full config on each navigation event.

## Controls

Keep the existing page-local control idea:

```lua
controls = {
  open = Controls["Audio_Nav"],
  close = Controls["Audio_Close"],
  openKeypad = Controls["Open_Keypad"],
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
- `ownerView` is present and valid for page-owned groups.
- `ownerView` is absent for root-owned and group-owned groups.
- `defaultPageIds`, when present, contains pages in the same group.
- `access.levels.locked.homePageId` identifies a page in `lockedGroup`.
- `access.levels.default.homePageId` identifies a page under `unlockedGroup`.
- `access.keypadPageId`, when keypad access is enabled, identifies a page in `lockedGroup`.
- Locked pages have `views.locked`.
- Unlocked pages have `views.default` or another valid unlocked access view.
- Every view key is declared in `access.levels`.

Do not validate or support these replaced fields:

- `parentId`
- `childDisplayMode`
- `parentVisibility`
- `defaultChildId`

If any replaced field appears in config, fail validation with a clear error.

## History Direction

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
- If a project later needs history exclusion, make that a group-level policy rather than a hardcoded page-id exception.

## Implementation Plan

Suggested order:

1. Add validation and indexing for `pageGroups`, `pageGroup`, ownership, behavior, `ownerView`, and `defaultPageIds`.
2. Change runtime state to track `activeGroupIds` plus `activePageIds`.
3. Replace root/child open logic with group ancestry activation and group behavior enforcement.
4. Replace `closeBranch` with close-page and close-group operations based on ownership.
5. Implement group `ownerView`.
6. Implement group `defaultPageIds`.
7. Update access, locked, and keypad behavior to open authored locked/unlocked pages.
8. Update history snapshots to include active groups.
9. Remove validation and runtime support for `parentId`, `childDisplayMode`, `parentVisibility`, and `defaultChildId`.
10. Update examples and user docs after behavior is verified.

## Remaining Decisions

- None at this point. Vanilla and Strawberry are the concrete example targets, and custom access levels are a core engine requirement.
