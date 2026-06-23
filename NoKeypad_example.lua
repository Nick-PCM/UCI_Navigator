-- NoKeypad_example.lua
-- Navigator is assumed to have already been loaded.
--
-- This project has no keypad and no custom access levels. Pressing the splash
-- continue button moves directly from locked to default access.

Navigator.configure({
  uci = {
    name = "My UCI",
    -- pageName defaults to "Main".
    -- transition defaults to "none".
  },

  access = {
    levels = {
      locked = { homePageId = "splash" },
      default = { homePageId = "home" },
    },

    -- keypadRequired = false means no keypad page, keypad timer, openKeypad,
    -- or closeKeypad controls are allowed in this project.
    keypadRequired = false,

    -- 0 disables the default-access session timer.
    sessionTimeoutSeconds = 600,
  },

  accessControls = {
    -- Required string control. External systems may still write "locked" or
    -- "default"; Navigator writes lock/downgrade changes here too.
    state = Controls["Access_State"],

    -- Optional button. With no keypad, a locked request continues directly to
    -- default access.
    request = Controls["Access_Request"],

    -- Optional button. Always returns to locked access.
    lock = Controls["Lock_Request"],

    -- Optional pulse/button. Restarts the default-access session timer.
    activityPulse = Controls["Activity_Pulse"],
  },

  -- Optional global history controls. They move through page navigation only;
  -- access changes clear history.
  historyControls = {
    back = Controls["Back"],
    forward = Controls["Forward"],
  },
  -- historyMaxEntries = 25, -- Optional. Defaults to 25.
  -- historyMaxEntries = false, -- Optional. Use uncapped history.

  -- Optional runtime logging. Omitted categories are silent.
  -- logging = {
  --   access = true,
  --   navigation = true,
  --   history = true,
  --   keypad = true,
  --   timeout = true,
  --   controls = true,
  -- },

  frame = {
    background = { views = { default = { "Background" } } },
    header = { views = { default = { "Header" } } },
    footer = { views = { default = { "Footer" } } },
    navigation = { views = { default = { "Navigation" } } },
  },

  pages = {
    splash = {
      controls = {
        -- Page-local continue is the direct no-keypad equivalent of opening
        -- the keypad in a PIN-protected project.
        continue = Controls["Continue"],
      },
      views = { locked = { "Splash", "Splash Controls" } },
    },

    home = {
      controls = {
        open = Controls["Home Nav"],
      },
      views = { default = { "Home Page" } },
    },

    audio = {
      controls = {
        open = Controls["Audio Nav"],
        close = Controls["Audio Back"],
      },
      views = { default = { "Audio Page" } },
      defaultChildId = "volume",
    },

    volume = {
      parentId = "audio",
      controls = {
        open = Controls["Open Volume"],
        close = Controls["Volume Back"],
      },
      views = { default = { "Volume Page" } },
    },
  },
})
