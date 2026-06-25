-- authoringExample.lua
-- Proposed flat group authoring style based on Examples/Basic Keypad Example.lua.
--
-- Navigator.compile(...) expands each group(...) block into Navigator's runtime
-- pageGroups/pages/access shape, then Navigator.apply(...) installs it.
--
-- This version removes Page/Group suffixes from authored IDs.
--
-- Navigator.compile provides typed reference registries, mode sentinels,
-- control-name resolution, and first-class owner-scoped regions.

local Navigator = require("Navigator") -- omit from Q-SYS script; useful for editor comments.

local config = Navigator.compile({
  uci = {
    pageName = "Main",
  },

  logging = {
    access = true,
    navigation = true,
    history = true,
    keypad = true,
    timeout = true,
    controls = true,
  },

  access = {
    locked = { startAt = pages.splash, keypad = pages.keypad, pinEntryTimeoutSeconds = 30,},
    user = { startAt = pages.home, sessionTimeoutSeconds = 600, default = true,},
    admin = {},
  },

  accessControls = {
    state = "Access State",
    request = "Access Request",
    lock = "Lock Request",
    activityPulse = "Activity Pulse",
  },

  historyControls = {
    back = "Back",
    forward = "Forward",
  },

  gate = group({ owner = groups.root, mode = independent }),

  accessGate = group({ owner = groups.gate, mode = interlocked, startAt = pages.splash },
    {
      splash = page({ content = { locked = "Splash" } }),
      keypad = page({ content = { locked = "Keypad" }, controls = { open = "Open Keypad", close = "Close Keypad",},}),
    }),

    
  session = group({ owner = groups.root, mode = independent }),

  regions = {
    background = region({ owner = groups.session, content = "Background" }),
    header = region({ owner = groups.session, content = "Header" }),
    nav = region({ owner = groups.session, content = "Navigation" }),
    footer = region({ owner = groups.session, content = "Footer" }),
  },

  tools = group({ owner = groups.session, mode = independent },
    {
      power = page({ content = "Power", controls = { open = "Open Power", close = "Close Power" } }),
      help = page({ content = "Help", controls = { open = "Open Help", close = "Close Help" } }),
    }
  ),

  system = group({ owner = groups.session, mode = interlocked, startAt = pages.home },
    {
      home = page({ content = "Home", controls = { open = "Open Home Page" } }),
      audio = page({ content = "Audio", controls = { open = "Open Audio Page" } }),
      video = page({ content = "Video", controls = { open = "Open Video Page" } }),
    }
  ),

  audioSubpages = group({ owner = pages.audio, mode = interlocked, parentVisible = true, startAt = pages.audioRouting },
    {
      audioRouting = page({ content = "Audio Routing", controls = { open = "Open Audio Routing" } }),
      audioSettings = page({
        content = {
          user = {"Audio Settings", regions.footer("Audio Settings Footer"),},
          admin = {"Audio Settings", "Audio Admin Tools", regions.footer("Audio Admin Footer"),},
        },
        controls = {open = "Open Audio Settings"},
      }),
    }
  ),

  videoSubpages = group({ owner = pages.video, mode = interlocked, parentVisible = true, startAt = pages.videoRouting },
    {
      videoRouting = page({ content = "Video Routing", controls = { open = "Open Video Routing", close = "Close Video Routing" } }),
      videoSettings = page({ content = "Video Settings", controls = { open = "Open Video Settings", close = "Close Video Settings" } }),
    }
  ),

  videoReplacement = group({ owner = pages.video, mode = independent, parentVisible = false },
    {
      videoTest = page({ content = "Video Test", controls = { open = "Open Video Test", close = "Close Video Test" } }),
    }
  ),


})

Navigator.apply(config)
