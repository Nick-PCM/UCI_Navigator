-- Basic No Keypad Example.lua
-- Navigator is assumed to have already been loaded.
--
-- Mirrors Basic Keypad Example.lua, but access requests unlock directly.

-- Compile the user-friendly authored project into Navigator runtime config.
local config = Navigator.compile({
  uci = { pageName = "Main" },

  -- Enable Navigator print() logging by category.
  logging = {
    access = true, -- access level changes
    navigation = true, -- page open/close operations
    history = true, -- back/forward stack changes
    timeout = true, -- session timeout activity
    controls = true, -- control event handling
  },

  -- Define access levels and entry pages.
  access = {
    locked = { startAt = pages.splash }, -- locked entry without keypad
    user = { startAt = pages.home, sessionTimeoutSeconds = 600, default = true }, -- default unlocked access
  },

  -- Bind global Q-SYS controls for access behavior.
  accessControls = {
    state = "Access State", -- external access state bridge
    request = "Access Request", -- request unlock
    lock = "Lock Request", -- return to locked access
    activityPulse = "Activity Pulse", -- restart active timers
  },

  -- Bind optional Q-SYS controls for navigation history.
  historyControls = {
    back = "Back", -- navigate to previous state
    forward = "Forward", -- navigate to next state
  },

  -- groups.root is the built-in interlocked top-level owner.

  -- Gate is the root-owned container for locked access.
  gate = group({ owner = groups.root, mode = independent }),

  -- accessGate is interlocked so splash and keypad replace each other inside gate.
  accessGate = group(
    { owner = groups.gate, mode = interlocked, startAt = pages.splash },
    {
      splash = page({ content = { locked = "Splash" } }),
    }
  ),

  -- Session is the root-owned container for unlocked pages.
  session = group({ owner = groups.root, mode = independent }),

  -- Regions are optional shared presentation areas with an owner-controlled lifetime; each region content value is its default.
  -- Page fills override defaults, deeper pages win, and same-depth fills conflict.
  regions = {
    header = region({ owner = groups.session, content = "Header" }),
    footer = region({ owner = groups.session, content = "Footer" }),
    ribbon = region({ owner = groups.session, content = "Ribbon" }),
    background = region({ owner = groups.session, content = "Background" }),
  },

  -- Tools are independent utility pages within the session.
  tools = group(
    { owner = groups.session, mode = independent },
    {
      power = page({ content = "Power", controls = { open = "Open Power", close = "Close Power" } }),
      help = page({ content = "Help", controls = { open = "Open Help", close = "Close Help" } }),
    }
  ),

  -- System is the primary interlocked page group.
  system = group(
    { owner = groups.session, mode = interlocked, startAt = pages.home },
    {
      home = page({ content = "Home", controls = { open = "Open Home Page" } }),
      audio = page({ content = "Audio", controls = { open = "Open Audio Page" } }),
      video = page({ content = "Video", controls = { open = "Open Video Page" } }),
    }
  ),

  audioSubpages = group(
    { owner = pages.audio, mode = interlocked, parentVisible = true, startAt = pages.audioRouting },
    {
      audioRouting = page({ content = "Audio Routing", controls = { open = "Open Audio Routing" } }),
      audioSettings = page({
        content = {
          "Audio Settings",
          regions.footer("Audio Settings Footer"), -- fill the footer region while this page is active
        },
        controls = { open = "Open Audio Settings" },
      }),
    }
  ),

  videoSubpages = group(
    { owner = pages.video, mode = interlocked, parentVisible = true, startAt = pages.videoRouting },
    {
      videoRouting = page({ content = "Video Routing", controls = { open = "Open Video Routing", close = "Close Video Routing" } }),
      videoSettings = page({ content = "Video Settings", controls = { open = "Open Video Settings", close = "Close Video Settings" } }),
    }
  ),

  videoReplacement = group(
    { owner = pages.video, mode = independent, parentVisible = false },
    {
      videoTest = page({ content = "Video Test", controls = { open = "Open Video Test", close = "Close Video Test" } }),
    }
  ),
})

-- Install the compiled config and initialize navigation.
Navigator.apply(config)
