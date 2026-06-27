
local Navigator = require("Navigator") -- remove in Q-Sys

Navigator.apply({
  uci = { pageName = "Main" },

  logging = {
    access = true, -- access level changes
    navigation = true, -- page open/close operations
    history = true, -- back/forward stack changes
    keypad = true, -- keypad access flow
    timeout = true, -- pin/session timeout activity
    controls = true, -- control event handling
    qsys = true, -- include UCI page/layer names when Q-SYS visibility calls fail
    manifest = false, -- print configured Q-SYS layers and controls at startup
  },

  access = {
    locked = {
      startAt = "accessGate",
      keypad = "keypad",
      pinEntryTimeoutSeconds = 30
    },
    user = {
      startAt = "session",
      sessionTimeoutSeconds = 600,
      default = true
    },
    admin = {
      startAt = "session",
      sessionTimeoutSeconds = 600,
    }
  },

  accessControls = {
    level = "Access Level", -- external access level bridge
    change = "Change Access Level", -- open the keypad to change access level
    lock = "Lock Request", -- return to locked access
    activityPulse = "Activity Pulse", -- restart active timers
  },

  historyControls = {
    back = "Back", -- navigate to previous state
    forward = "Forward", -- navigate to next state
  },

  -- accessGate is interlocked so splash and keypad replace each other inside gate.
  accessGate = group({
    owner = "root",
    mode = "interlocked",
    startAt = "splash"
  }),

  -- Session is the root-owned container for unlocked pages.
  session = group({ 
    owner = "root", 
    mode = "independent",
    startAt = { "frame", "system" }
  }),

  -- Tools are independent utility pages within the session.
  tools = group({ 
    owner = "session", 
    mode = "independent" 
  }),

  -- System is the primary interlocked page group.
  system = group({
    owner = "session",
    mode = "interlocked",
    startAt = "home"
  }),

  audioSubpages = group({
    owner = "audio",
    mode = "interlocked",
    parentVisible = true,
    startAt = "audioRouting"
  }),
  
  videoSubpages = group({
    owner = "video",
    mode = "independent",
    parentVisible = false,
    startAt = "videoRouting"
  }),

  splash = page({
    owner = "accessGate",
    content = { locked = "Splash" }
  }),

  keypad = page({
    owner = "accessGate",
    content = { locked = "Keypad" }, 
    controls = { open = "Open Keypad", close = "Close Keypad" } 
  }),

  power = page({
    owner = "tools",
    content = "Power",
    controls = { open = "Open Power", close = "Close Power" }
  }),

  help = page({
    owner = "tools",
    content = "Help",
    controls = { open = "Open Help", close = "Close Help" }
  }),

  secret = page({
    owner = "tools",
    content = "Secret",
    controls = { open = "Open Secret", close = "Close Secret" }
  }),

  frame = page({
    owner = "session",
    content = {
      user = { "Header", "Footer", "Ribbon", "Background"},
      admin = { "Header", "Footer", "Ribbon", "Admin Ribbon", "Background"},
    }
  }),

  home = page({
    owner = "system",
    content = "Home",
    controls = { open = "Open Home Page" }
  }),

  audio = page({ 
    owner = "system",
    content = { user = "Audio", admin = "Admin Audio"},
    controls = { open = "Open Audio Page" }
  }),

  video = page({
    owner = "system",
    content = "Video",
    controls = { open = "Open Video Page" }
  }),

  audioRouting = page({
    owner = "audioSubpages",
    content = "Audio Routing",
    controls = { open = { "Open Audio Routing", "Open Admin Audio Routing" }}
  }),

  audioSettings = page({
    owner = "audioSubpages",
    content = { user = "Audio Settings", admin = "Admin Audio Settings Footer"},
    controls = { open = { "Open Audio Settings", "Open Admin Audio Settings" }},
  }),

  videoRouting = page({
    owner = "videoSubpages",
    content = "Video Routing",
    controls = { open = "Open Video Routing", close = "Close Video Settings" }
  }),

  videoSettings = page({ 
    owner = "videoSubpages", 
    content = "Video Settings", 
    controls = { open = "Open Video Settings", close = "Close Video Settings" } 
  }),


})
