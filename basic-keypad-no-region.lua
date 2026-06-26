
local Navigator = require("Navigator-NoRegion")

Navigator.apply({
  uci = { pageName = "Main" },

  logging = {
    access = true, -- access level changes
    navigation = true, -- page open/close operations
    history = true, -- back/forward stack changes
    keypad = true, -- keypad access flow
    timeout = true, -- pin/session timeout activity
    controls = true, -- control event handling
    manifest = true, -- print configured Q-SYS layers and controls at startup
  },

  access = {
    locked = {
      startAt = "splash",
      keypad = "keypad",
      pinEntryTimeoutSeconds = 30
    },
    user = {
      startAt = "home",
      sessionTimeoutSeconds = 600,
      default = true
    },
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

  -- Root-owned groups separate locked access from the unlocked session.
  gate = group({
    owner = "root",
    mode = "independent"
  }),

  -- accessGate is interlocked so splash and keypad replace each other inside gate.
  accessGate = group({
    owner = "gate",
    mode = "interlocked",
    startAt = "splash"
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

  -- Session is the root-owned container for unlocked pages.
  session = group({ 
    owner = "root", 
    mode = "independent" 
  }),

  -- Tools are independent utility pages within the session.
  tools = group({ 
    owner = "session", 
    mode = "independent" 
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

  -- System is the primary interlocked page group.
  system = group({
    owner = "session",
    mode = "interlocked",
    startAt = "home"
  }),

  home = page({
    owner = "system",
    content = "Home",
    controls = { open = "Open Home Page" }
  }),

  audio = page({ 
    owner = "system",
    content = "Audio",
    controls = { open = "Open Audio Page" }
  }),

  video = page({
    owner = "system",
    content = "Video",
    controls = { open = "Open Video Page" }
  }),

  audioSubpages = group({
    owner = "audio",
    mode = "interlocked",
    parentVisible = true,
    startAt = "audioRouting"
  }),

  audioRouting = page({
    owner = "audioSubpages",
    content = "Audio Routing",
    controls = { open = "Open Audio Routing" }
  }),

  audioSettings = page({
    owner = "audioSubpages",
    content = { "Audio Settings", "Audio Settings Footer"},
    controls = { open = "Open Audio Settings" },
  }),


  videoSubpages = group({
    owner = "video",
    mode = "interlocked",
    parentVisible = true,
    startAt = "videoRouting"
  }),

  videoRouting = page({
    owner = "videoSubpages",
    content = "Video Routing",
    controls = { open = "Open Video Routing" }
  }),

  videoSettings = page({ 
    owner = "videoSubpages", 
    content = "Video Settings", 
    controls = { open = "Open Video Settings", close = "Close Video Settings" } 
  }),


  videoReplacement = group({
    owner = "video",
    mode = "independent",
    parentVisible = false
  }),

  videoTest = page({
    owner = "video",
    content = "Video Test",
    controls = { open = "Open Video Test", close = "Close Video Test" }
  }),

})
