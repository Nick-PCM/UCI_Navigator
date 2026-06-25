-- advanced_example.lua
-- Navigator is assumed to have already been loaded.
--
-- This extends the vanilla example with one project-defined access level and
-- one page-specific frame override. The structure is intentionally the same:
-- pages and frame entries both declare views, and controls stay with the page
-- or access function they operate on.

Navigator.configure({
  -- UCI identifies the Q-SYS UCI and page whose layers Navigator controls.
  uci = {
    -- pageName defaults to "Main".
    -- transition defaults to "none".
  },

  -- locked and default are Navigator-reserved levels. advanced is a
  -- project-defined level; it has no built-in behavior except falling back to
  -- default views when an advanced view is not declared.
  access = {
    levels = {
      locked = { homePageId = "splash" },
      default = { homePageId = "home" },
      advanced = {},
    },

    -- The keypad page is referenced here so Navigator can apply keypad
    -- overlay/replacement behavior and timeout handling.
    keypadRequired = true,
    keypadPageId = "keypad",
    pinEntryTimeoutSeconds = 30,
    sessionTimeoutSeconds = 600,
  },

  -- Access controls connect Navigator to the external PIN/access module.
  -- The external module writes strings like "locked", "default", or
  -- "advanced" to state. Navigator validates those strings against
  -- access.levels.
  accessControls = {
    -- Required string control. The external auth module writes "locked",
    -- "default", or "advanced"; Navigator writes lock/downgrade changes.
    state = Controls["Access_State"],

    -- Optional button. From default it opens the keypad; from advanced it
    -- downgrades to default.
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
  logging = {
    access = true,
    navigation = true,
    -- history = true,
    keypad = true,
    timeout = true,
    controls = true,
  },

  -- Default frame layers used by unlocked pages. These are inherited unless
  -- an active page supplies a frame override for the same role.
  frame = {
    background = { views = { default = { "Background" } } },
    header = { views = { default = { "Header" } } },
    footer = { views = { default = { "Footer" } } },
    navigation = { views = { default = { "Navigation" } } },
  },

  -- Pages are keyed by stable page ID. The key is the public page reference
  -- used by parentId, defaultChildId, and Navigator.openPage.
  pages = {
    -- Locked home page.
    splash = {
      controls = {
        openKeypad = Controls["Open_Keypad"],
      },
      -- views = { locked = { "Splash", "Splash Controls" } }, -- if you want some unlocked controls above splash
      views = { locked = { "Splash",} },
    },

    -- Keypad close returns to splash while locked, or hides the keypad overlay
    -- while default/custom access is active.
    keypad = {
      controls = {
        close = Controls["Close_Keypad"],
      },
      views = { locked = { "Keypad" } },
    },

    -- This page has no advanced view, so advanced access falls back to the
    -- default view automatically.
    home = {
      controls = {
        open = Controls["Home_Nav"],
      },
      views = { default = { "Home Page" }, advanced = {"Home Page", "Advanced Home Overlay"}  },
    },

    AdvancedHomeModal = {
      parentId = "home",
      controls = {
        open = Controls["Open_Home_Modal"],
        close = Controls["Close_Home_Modal"]
      },
      views = {advanced = {"Home Page", "Advanced Home Overlay", "Advanced Home Modal" } }
    },

    -- Section with a default child. Opening audio activates both audio and
    -- volume unless another child behavior closes volume later.
    audio = {
      controls = {
        open = Controls["Audio_Nav"],
      },
      views = { default = { "Audio Page" } },
      -- defaultChildId = "volume",
    },

    -- This child overrides the footer frame role while it is active. The
    -- override uses the same views pattern as global frame entries.
    volume = {
      parentId = "audio",
      controls = {
        open = Controls["Open_Volume"],
        close = Controls["Close_Volume"],
      },
      views = { default = { "Volume Page" } },
      frame = {
        footer = { views = { default = { "Volume Footer" } } },
      },
    },

    -- This page replaces its default layer list when advanced access is active.
    -- If advanced were omitted here, Navigator would use the default view.
    settings = {
      controls = {
        open = {
          Controls["Settings_Nav"],
        },
        close = {
          Controls["Settings_Close_Default"],
          Controls["Settings_Close_Advanced"],
        },
      },
      views = {
        default = { "Settings Page" },
        advanced = { "Advanced Settings Page" },
      },
    },
    settingModal = {
      parentId = "settings",
      controls = {
        open = { Controls["Open_Settings_Modal_Default"], Controls["Open_Settings_Modal_Advanced"]},
        close = Controls["Close_Settings_Modal"],
      },
      views = { default = {"Settings Page", "Settings Modal Page" } },
    },
  },
})