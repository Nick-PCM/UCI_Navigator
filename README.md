# UCI Navigator

UCI Navigator is a Lua navigation runtime for Q-SYS UCIs. It gives a UCI script a small authored model for pages, sections, access levels, timers, history, and controls, then keeps Q-SYS layer visibility synchronized with that model.

Navigator uses the word `page` for a navigation state. The Q-SYS assets it actually manages are UCI layers named in each page's `content`.

## What It Solves

Q-SYS UCIs often start as direct button-to-layer scripts. That becomes hard to maintain when a design needs:

- switching sections, tabs, or destinations
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

- Sections and pages are top-level entries in the authored project table.
- Every section and page has an explicit `owner`.
- Every section has a `mode`: `switch` keeps one direct member active, while `stack` allows direct members to coexist.
- `owner`, `open`, and `keypad` use Navigator IDs.
- `content` strings are Q-SYS UCI layer names.
- Control strings are Q-SYS control names.

```lua
system = section({ owner = "root", mode = "switch", open = "home" })
home = page({ owner = "system", content = "Home Layer" })
```

## Key Capabilities

- Switch and stack sections.
- Section-owned subnavigation with pages that show Q-SYS layers.
- Access-specific content, with fallback to the default unlocked access level.
- Locked access with optional keypad.
- Session and keypad timeout handling.
- Page/section open/close controls, access controls, and history controls.
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

Read [Navigator.md](Navigator.md) for the model and API details, then compare it with [example-uci.lua](example-uci.lua). The example shows the current authored style with locked access, a keypad, persistent frame layers, a switch system section, stack tools, and nested section subpages.

Locked access is optional. A project with no lockscreen can omit `access.locked`; Navigator starts at the default access level instead.

## Q-SYS Without Require

Q-SYS scripts cannot load `Navigator.lua` with `require`. Keep the project at the top of the script, add tiny local `section` and `page` helpers, then paste the Navigator implementation below it.

```lua
local function section(spec)
  spec.__kind = "section"
  return spec
end

local function page(spec)
  spec.__kind = "page"
  return spec
end

local project = {
  uci = { pageName = "Main" },

  accessGate = section({ owner = "root", mode = "switch", open = "splash" }),
  session = section({ owner = "root", mode = "stack", open = { "frame", "system" } }),
  system = section({ owner = "session", mode = "switch", open = "home" }),

  splash = page({ owner = "accessGate", content = { locked = "Splash" } }),
  frame = page({ owner = "session", content = "Frame" }),
  home = page({ owner = "system", content = "Home" }),
}

-- Paste Navigator.lua below this point.
-- In a single-file script, replace Navigator.lua's final `return Navigator`
-- with:
Navigator.apply(project)
```

The helpers are only authoring markers. They let the project use the normal Navigator shape before the full Navigator implementation appears later in the same Q-SYS script.
