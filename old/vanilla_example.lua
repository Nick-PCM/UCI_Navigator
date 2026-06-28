-- vanilla_example.lua
-- Navigator is assumed to have already been loaded.
--
-- This example is the minimum project shape: locked splash, keypad, and
-- default-access navigation. The table below is project-specific authoring
-- data. Navigator owns validation, button EventHandler assignment, access
-- transitions, timers, and Q-SYS layer visibility.

Navigator.configure({
  -- uci identifies the Q-SYS page whose layers Navigator controls.
  -- Layer names below are Q-SYS layer names on this page.
  uci = {
    -- pageName defaults to "Main".
    -- transition defaults to "none".
  },

  -- Access levels define the authorization states this project supports.
  -- locked and default are reserved Navigator levels and must be present.
  -- homePageId is the page ID Navigator opens when entering that level.
  access = {
    levels = {
      locked = { homePageId = "splash" },
      default = { homePageId = "home" },
    },

    -- The keypad is an ordinary page, but Navigator gives it special behavior:
    -- from locked it replaces splash; from default it appears as an overlay.
    keypadRequired = true,
    keypadPageId = "keypad",

    -- 0 disables the corresponding timer.
    pinEntryTimeoutSeconds = 30,
    sessionTimeoutSeconds = 600,
  },

  -- Access controls are the bridge to the external PIN/access system.
  -- Navigator writes state when it performs scripted lock/downgrade actions,
  -- and reads state when the external module grants an access level.
  accessControls = {
    -- Required string control. External auth writes "locked" or "default";
    -- Navigator also writes this when it locks or downgrades.
    state = Controls["Access_State"],

    -- Optional button. From default it opens the keypad; from a custom level
    -- it downgrades to default. This example has no custom levels.
    request = Controls["Access_Request"],

    -- Optional button. Always returns to locked access.
    lock = Controls["Lock_Request"],

    -- Optional pulse/button. Restarts the active session or keypad timer.
    activityPulse = Controls["Activity_Pulse"],
  },

  -- Optional global history controls. They move through page navigation only;
  -- access and keypad transitions clear history.
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

  -- Frame entries are shared page-like layer groups. They use the same
  -- views pattern as pages. Every frame role must provide a default view.
  -- Locked normally omits frame layers unless a locked view is added here.
  frame = {
    background = { views = { default = { "Background" } } },
    header = { views = { default = { "Header" } } },
    footer = { views = { default = { "Footer" } } },
    navigation = { views = { default = { "Navigation" } } },
  },

  -- Pages are keyed by stable page ID. The key is what other pages reference
  -- through parentId/defaultChildId and what Navigator uses for navigation.
  -- controls live with the page they operate on, so Navigator can wire the
  -- standard button handlers automatically.
  pages = {
    -- The locked home page. It can open the keypad using page-local controls.
    splash = {
      controls = {
        openKeypad = Controls["Open_Keypad"],
      },
      views = { locked = { "Splash", "Splash Controls" } },
    },

    -- The keypad is authored as a normal page with a locked view. Its close
    -- control uses keypad close behavior instead of ordinary closePage.
    keypad = {
      controls = {
        close = Controls["Close_Keypad"],
      },
      views = { locked = { "Keypad" } },
    },

    -- Root pages without parentId are groups. controls.open navigates to
    -- the page and replaces the currently active root page.
    home = {
      controls = {
        open = Controls["Home_Nav"],
      },
      views = { default = { "Home Page" } },
    },

    -- Opening this group also opens its default child. The child must be a
    -- direct child and must have a default-capable view.
    audio = {
      controls = {
        open = Controls["Audio_Nav"],
      },
      views = { default = { "Audio Page" } },
      defaultChildId = "volume",
    },

    -- A child page references its parent by page ID. controls.open opens the
    -- child under the active parent; controls.close closes this branch.
    volume = {
      parentId = "audio",
      controls = {
        open = Controls["Open_Volume"],
        close = Controls["Volume_Back"],
      },
      views = { default = { "Volume Page" } },
    },

    -- Pages can be simple: a nav control plus one default view is enough.
    -- A group close control returns to the default home page.
    settings = {
      controls = {
        open = Controls["Control_Nav"],
        close = Controls["Close_Control"],
      },
      views = { default = { "Control Page" } },
    },
  },
})
