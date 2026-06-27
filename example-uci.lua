
local Navigator = require("Navigator") -- remove in Q-Sys

Navigator.apply({
  uci = { pageName = "Main" },

  logging = {
    access     = true, -- access level changes
    navigation = true, -- page open/close operations
    history    = true, -- back/forward stack changes
    keypad     = true, -- keypad access flow
    timeout    = true, -- pin/session timeout activity
    controls   = true, -- control event handling
    qsys       = true, -- include UCI page/layer names when Q-SYS visibility calls fail
    manifest   = false, -- print configured Q-SYS layers and controls at startup
  },

  access = {
    locked = {
      open                   = "accessGate",
      keypad                 = "keypad",
      pinEntryTimeoutSeconds = 30
    },
    user = {
      open                  = "session",
      sessionTimeoutSeconds = 600,
      default               = true
    },
    admin = {
      open                  = "session",
      sessionTimeoutSeconds = 600,
    }
  },

  accessControls = {
    level         = "Access Level", -- external access level bridge
    change        = "Change Access Level", -- open the keypad to change access level
    lock          = "Lock Request", -- return to locked access
    activityPulse = "Activity Pulse", -- restart active timers
  },

  historyControls = {
    back    = "Back", -- navigate to previous state
    forward = "Forward", -- navigate to next state
  },

  -- accessGate switches between splash and keypad.
  accessGate = section({ owner = "root", mode = "switch", open = "splash" }),

  splash = page({
    owner = "accessGate",
    content = { locked = "Splash" },
  }),

  keypad = page({
    owner = "accessGate",
    content = { locked = "Keypad" },
    controls = { open = "Open Keypad", close = "Close Keypad" },
  }),

  -- Session is the root-owned container for unlocked pages.
  session = section({
    owner = "root",
    mode = "stack",
    open = { "frame", "system" },
  }),

  frame = page({
    owner = "session",
    content = {
      user  = { "Header", "Footer", "Ribbon", "Background" },
      admin = { "Header", "Footer", "Ribbon", "Admin Ribbon", "Background" },
    },
  }),

  -- Tools stack utility pages within the session.
  tools = section({ owner = "session", mode = "stack" }),

  power = page({
    owner = "tools",
    content = "Power",
    controls = { open = "Open Power", close = "Close Power" },
  }),

  help = page({
    owner = "tools",
    content = "Help",
    controls = { open = "Open Help", close = "Close Help" },
  }),

  secret = page({
    owner = "tools",
    content = "Secret",
    controls = { open = "Open Secret", close = "Close Secret" },
  }),

  -- System switches between primary pages.
  system = section({ owner = "session", mode = "switch", open = "home" }),

  home = page({
    owner = "system",
    content = "Home",
    controls = { open = "Open Home Page" },
  }),

  audio = section({
    owner = "system",
    mode = "stack",
    open = { "audioBase", "audioPages" },
    controls = { open = "Open Audio Page" },
  }),

  audioBase = page({
    owner = "audio",
    content = { user = "Audio", admin = "Admin Audio" },
  }),

  audioPages = section({ owner = "audio", mode = "switch", open = "audioRouting" }),

  audioRouting = page({
    owner = "audioPages",
    content = "Audio Routing",
    controls = { open = { "Open Audio Routing", "Open Admin Audio Routing" } },
  }),

  audioSettings = page({
    owner = "audioPages",
    content = { user = "Audio Settings", admin = "Admin Audio Settings Footer" },
    controls = { open = { "Open Audio Settings", "Open Admin Audio Settings" } },
  }),

  video = section({
    owner = "system",
    mode = "switch",
    open = "videoBase",
    controls = { open = "Open Video Page" },
  }),

  videoBase = page({
    owner = "video",
    content = "Video",
  }),

  videoPages = section({ owner = "video", mode = "stack" }),

  videoRouting = page({
    owner = "videoPages",
    content = "Video Routing",
    controls = { open = "Open Video Routing", close = "Close Video Routing" },
  }),

  videoSettings = page({
    owner = "videoPages",
    content = "Video Settings",
    controls = { open = "Open Video Settings", close = "Close Video Settings" },
  }),
})
