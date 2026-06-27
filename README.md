# UCI Navigator

UCI Navigator is a Lua navigation runtime for Q-SYS UCIs. It gives a UCI script a small authored model for pages, groups, access levels, timers, history, and controls, then keeps Q-SYS layer visibility synchronized with that model.

Navigator uses the word `page` for a navigation state. The Q-SYS assets it actually manages are UCI layers named in each page's `content`.

## What It Solves

Q-SYS UCIs often start as direct button-to-layer scripts. That becomes hard to maintain when a design needs:

- interlocked sections, tabs, or destinations
- persistent frame layers such as headers, footers, ribbons, and backgrounds
- tool panels, overlays, dialogs, or modals that can coexist with other pages
- locked and unlocked views
- keypad-based access changes
- session and keypad timeouts
- back/forward history
- multiple controls triggering the same navigation action

Navigator centralizes those rules in one project table and derives layer visibility from the current navigation state.

## Project Shape

Navigator projects use explicit ownership:

- Groups and pages are top-level entries in the authored project table.
- Every group and page has an explicit `owner`.
- `owner`, `startAt`, and `keypad` use Navigator IDs.
- `content` strings are Q-SYS UCI layer names.
- Control strings are Q-SYS control names.

```lua
MyGroupId = group({ owner = "root", mode = "interlocked", startAt = "MyPageId" })
MyPageId = page({ owner = "MyGroupId", content = "My Q-SYS Layer Name" })
```

## Key Capabilities

- Interlocked and independent groups.
- Group-owned and page-owned subnavigation.
- Access-specific content, with fallback to the default unlocked access level.
- Locked access with optional keypad.
- Session and keypad timeout handling.
- Page open/close controls, access controls, and history controls.
- Multiple Q-SYS controls can be wired to the same Navigator action.
- Manifest logging for configured layer/control names.
- Q-SYS layer-call diagnostics when layer names do not match the UCI.

## Repository Files

- `Navigator.lua`: runtime implementation.
- `Navigator.md`: reference manual for the model, rules, and API.
- `example-uci.lua`: example authored UCI project.
- `UCI Navigation Testing.qsys`: Q-SYS test design.
- `qsys-require.lua`: small experiment for loading Lua modules from a Core filesystem path.
- `old/`: archived prior experiments and implementations.

## Start Here

Read [Navigator.md](Navigator.md) for the model and API details, then compare it with [example-uci.lua](example-uci.lua). The example shows the current authored style with locked access, a keypad, persistent frame layers, an interlocked system group, independent tools, and page-owned subpages.
