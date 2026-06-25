-- Basic No Keypad Example.lua
-- Navigator is assumed to have already been loaded.
--
-- Mirrors Basic Keypad Example.lua, but access requests unlock directly.

local config = Navigator.compile({
  uci = {
    pageName = "Main",
  },

  logging = {
    access = true,
    navigation = true,
    history = true,
    timeout = true,
    controls = true,
  },

  access = {
    locked = { startAt = pages.splash },
    user = { startAt = pages.home, sessionTimeoutSeconds = 600, default = true },
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

  accessGate = group(
    { owner = groups.gate, mode = interlocked, startAt = pages.splash },
    {
      splash = page({ content = { locked = "Splash" } }),
    }
  ),

  session = group({ owner = groups.root, mode = independent }),

  regions = {
    background = region({ owner = groups.session, content = "Background" }),
    header = region({ owner = groups.session, content = "Header" }),
    nav = region({ owner = groups.session, content = "Navigation" }),
    footer = region({ owner = groups.session, content = "Footer" }),
  },

  tools = group(
    { owner = groups.session, mode = independent },
    {
      power = page({ content = "Power", controls = { open = "Open Power", close = "Close Power" } }),
      help = page({ content = "Help", controls = { open = "Open Help", close = "Close Help" } }),
    }
  ),

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
          regions.footer("Audio Settings Footer"),
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

Navigator.apply(config)
