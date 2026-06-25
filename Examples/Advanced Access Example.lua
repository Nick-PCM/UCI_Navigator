-- Advanced Access Example.lua
-- Navigator is assumed to have already been loaded.
--
-- This example uses the same ownership tree as Basic Keypad Example.lua and adds
-- an advanced access level with overlay, replacement, fallback, and
-- advanced-only page examples.

Navigator.configure({
  -- Q-SYS UCI target for layer visibility changes.
  uci = {
    pageName = "Main", -- Q-SYS UCI page that contains the controlled layers.
  },

  -- Advanced is declared without a homePageId; default remains the unlocked home.
  access = {
    levels = { -- Declares every supported access level.
      locked = { homePageId = "splashPage" }, -- Locked entry page shown before access is granted.
      default = { homePageId = "homepage" }, -- Default unlocked entry page after access is granted.
      advanced = {}, -- Custom unlocked level that renders advanced views and uses the default home.
    },
    keypadRequired = true, -- Requires the configured keypad page before unlocking.
    keypadPageId = "keypadPage", -- Locked page opened when access is requested.
    pinEntryTimeoutSeconds = 30, -- Seconds before an open keypad returns to the locked home page.
    sessionTimeoutSeconds = 600, -- Seconds of inactivity before Navigator returns to locked access.
  },

  -- Global controls that change or mirror access state.
  accessControls = {
    state = Controls["Access State"], -- String control the external keypad module writes to set UCI accessibility.
    request = Controls["Access Request"], -- Button that opens the keypad or requests default access.
    lock = Controls["Lock Request"], -- Button that returns Navigator to locked access.
    activityPulse = Controls["Activity Pulse"], -- Pulse control that restarts active access timers.
  },

  -- Optional global back/forward controls for page navigation history.
  historyControls = {
    back = Controls["Back"],
    forward = Controls["Forward"],
  },

  -- Named frame pages that active pages may temporarily replace.
  frameRoles = {
    footer = "footerPage",
  },

  -- Navigation ownership tree: owner places each group; behavior decides whether its pages replace or coexist.
  pageGroups = {
    -- Locked pages interlock: splash and keypad replace each other.
    lockedGroup = {
      owner = "root",
      behavior = "interlocked",
      defaultPageIds = { "splashPage" },
    },

    -- Unlocked is independent so frame, main, and system groups can coexist.
    unlockedGroup = {
      owner = "root",
      behavior = "independent",
    },

    -- Frame pages are always-on unlocked layers.
    frameGroup = {
      owner = "unlockedGroup",
      behavior = "independent",
      defaultPageIds = {
        "backgroundPage",
        "headerPage",
        "footerPage",
        "navPage",
      },
    },

    -- Main pages interlock: home, audio, and video replace each other.
    mainGroup = {
      owner = "unlockedGroup",
      behavior = "interlocked",
      defaultPageIds = { "homepage" },
    },

    -- System pages are global modals: power/help can appear over anything.
    systemGroup = {
      owner = "unlockedGroup",
      behavior = "independent",
    },

    -- Audio subpages interlock while audioPage remains visible.
    audioGroup = {
      owner = "audioPage",
      behavior = "interlocked",
      ownerVisibility = "visible",
      defaultPageIds = { "audioRoutingPage" },
    },

    -- Video subpages interlock while videoPage remains visible.
    videoGroup = {
      owner = "videoPage",
      behavior = "interlocked",
      ownerVisibility = "visible",
    },

    -- Replacement pages hide videoPage while they are active.
    videoReplacementGroup = {
      owner = "videoPage",
      behavior = "independent",
      ownerVisibility = "hidden",
    },
  },

  -- Pages demonstrate default fallback, advanced overlays, and advanced-only views.
  pages = {
    -- Locked splash is unaffected by custom unlocked access levels.
    splashPage = {
      pageGroup = "lockedGroup",
      views = {
        locked = { "Splash" },
      },
    },

    -- Keypad is the configured locked keypad target.
    keypadPage = {
      pageGroup = "lockedGroup",
      views = {
        locked = { "Keypad" },
      },
      controls = {
        open = Controls["Open Keypad"],
        close = Controls["Close Keypad"],
      },
    },

    -- Frame pages without advanced views fall back to default when advanced.
    backgroundPage = {
      pageGroup = "frameGroup",
      views = "Background",
    },

    headerPage = {
      pageGroup = "frameGroup",
      views = "Header",
    },

    footerPage = {
      pageGroup = "frameGroup",
      views = "Footer",
    },

    -- Navigation overlays an advanced layer on top of the default layer.
    navPage = {
      pageGroup = "frameGroup",
      views = {
        default = "Navigation",
        advanced = { "Navigation", "Navigation Advanced" },
      },
    },

    -- Home overlays an advanced layer on top of the default home layer.
    homepage = {
      pageGroup = "mainGroup",
      views = {
        default = "Home",
        advanced = { "Home", "Home Advanced" },
      },
      controls = {
        open = Controls["Open Home Page"],
      },
    },

    -- Audio replaces its default view with an advanced-only view.
    audioPage = {
      pageGroup = "mainGroup",
      views = {
        default = "Audio",
        advanced = "Audio Advanced",
      },
      controls = {
        open = Controls["Open Audio Page"],
      },
    },

    -- Audio routing overlays an advanced layer while remaining available to default.
    audioRoutingPage = {
      pageGroup = "audioGroup",
      views = {
        default = "Audio Routing",
        advanced = { "Audio Routing", "Audio Routing Advanced" },
      },
      controls = {
        open = Controls["Open Audio Routing"],
      },
    },

    -- Audio settings is advanced-only and overrides the footer in advanced access.
    audioSettingsPage = {
      pageGroup = "audioGroup",
      views = {
        advanced = "Audio Settings Advanced",
      },
      overrides = {
        footer = {
          advanced = "Audio Settings Footer",
        },
      },
      controls = {
        open = Controls["Open Audio Settings"],
      },
    },

    -- Video has no advanced view, so it falls back to default.
    videoPage = {
      pageGroup = "mainGroup",
      views = "Video",
      controls = {
        open = Controls["Open Video Page"],
      },
    },

    -- Video routing is available to both default and advanced access.
    videoRoutingPage = {
      pageGroup = "videoGroup",
      views = {
        default = "Video Routing",
        advanced = { "Video Routing", "Video Routing Advanced" },
      },
      controls = {
        open = Controls["Open Video Routing"],
        close = Controls["Close Video Routing"],
      },
    },

    -- Video settings has only a default view, so advanced falls back to it.
    videoSettingsPage = {
      pageGroup = "videoGroup",
      views = "Video Settings",
      controls = {
        open = Controls["Open Video Settings"],
        close = Controls["Close Video Settings"],
      },
    },

    -- Replacement page inherits default behavior for advanced access.
    videoTestPage = {
      pageGroup = "videoReplacementGroup",
      views = "Video Test",
      controls = {
        open = Controls["Open Video Test"],
        close = Controls["Close Video Test"],
      },
    },

    -- Independent system page shown over the current unlocked state.
    powerPage = {
      pageGroup = "systemGroup",
      views = "Power Page",
      controls = {
        open = Controls["Open Power"],
        close = Controls["Close Power"],
      },
    },

    -- Another independent system page.
    helpPage = {
      pageGroup = "systemGroup",
      views = "Help Page",
      controls = {
        open = Controls["Open Help"],
        close = Controls["Close Help"],
      },
    },
  },
})
