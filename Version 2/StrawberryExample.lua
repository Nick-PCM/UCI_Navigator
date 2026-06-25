-- StrawberryExample.lua
-- Navigator is assumed to have already been loaded.
--
-- This example uses the same ownership tree as VanillaExample.lua and adds
-- an advanced access level with overlay, replacement, fallback, and
-- advanced-only page examples.

Navigator.configure({
  uci = {
    pageName = "Main",
    transition = "none",
  },

  access = {
    levels = {
      locked = { homePageId = "splashPage" },
      default = { homePageId = "homepage" },
      advanced = {},
    },
    keypadRequired = true,
    keypadPageId = "keypadPage",
    pinEntryTimeoutSeconds = 30,
    sessionTimeoutSeconds = 600,
  },

  accessControls = {
    state = Controls["Access State"],
    request = Controls["Access Request"],
    lock = Controls["Lock Request"],
    activityPulse = Controls["Activity Pulse"],
  },

  historyControls = {
    back = Controls["Back"],
    forward = Controls["Forward"],
  },

  frameRoles = {
    footer = "footerPage",
  },

  pageGroups = {
    lockedGroup = {
      owner = "root",
      behavior = "interlocked",
      defaultPageIds = { "splashPage" },
    },

    unlockedGroup = {
      owner = "root",
      behavior = "independent",
    },

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

    mainGroup = {
      owner = "unlockedGroup",
      behavior = "interlocked",
      defaultPageIds = { "homepage" },
    },

    systemGroup = {
      owner = "unlockedGroup",
      behavior = "independent",
    },

    audioGroup = {
      owner = "audioPage",
      behavior = "interlocked",
      ownerView = "keep",
      defaultPageIds = { "audioRoutingPage" },
    },

    videoGroup = {
      owner = "videoPage",
      behavior = "interlocked",
      ownerView = "keep",
    },

    videoReplacementGroup = {
      owner = "videoPage",
      behavior = "independent",
      ownerView = "hide",
    },
  },

  pages = {
    splashPage = {
      pageGroup = "lockedGroup",
      views = {
        locked = { "Splash" },
      },
      controls = {
        openKeypad = Controls["Open Keypad"],
      },
    },

    keypadPage = {
      pageGroup = "lockedGroup",
      views = {
        locked = { "Keypad" },
      },
      controls = {
        close = Controls["Close Keypad"],
      },
    },

    backgroundPage = {
      pageGroup = "frameGroup",
      views = {
        default = { "Background" },
      },
    },

    headerPage = {
      pageGroup = "frameGroup",
      views = {
        default = { "Header" },
      },
    },

    footerPage = {
      pageGroup = "frameGroup",
      views = {
        default = { "Footer" },
      },
    },

    navPage = {
      pageGroup = "frameGroup",
      views = {
        default = { "Navigation" },
        advanced = { "Navigation", "Navigation Advanced" },
      },
    },

    homepage = {
      pageGroup = "mainGroup",
      views = {
        default = { "Home" },
        advanced = { "Home", "Home Advanced" },
      },
      controls = {
        open = Controls["Open Home Page"],
      },
    },

    audioPage = {
      pageGroup = "mainGroup",
      views = {
        default = { "Audio" },
        advanced = { "Audio Advanced" },
      },
      controls = {
        open = Controls["Open Audio Page"],
      },
    },

    audioRoutingPage = {
      pageGroup = "audioGroup",
      views = {
        default = { "Audio Routing" },
        advanced = { "Audio Routing", "Audio Routing Advanced" },
      },
      controls = {
        open = Controls["Open Audio Routing"],
      },
    },

    audioSettingsPage = {
      pageGroup = "audioGroup",
      views = {
        advanced = { "Audio Settings Advanced" },
      },
      frameOverrides = {
        footer = {
          advanced = { "Audio Settings Footer" },
        },
      },
      controls = {
        open = Controls["Open Audio Settings"],
      },
    },

    videoPage = {
      pageGroup = "mainGroup",
      views = {
        default = { "Video" },
      },
      controls = {
        open = Controls["Open Video Page"],
      },
    },

    videoRoutingPage = {
      pageGroup = "videoGroup",
      views = {
        default = { "Video Routing" },
        advanced = { "Video Routing", "Video Routing Advanced" },
      },
      controls = {
        open = Controls["Open Video Routing"],
        close = Controls["Close Video Routing"],
      },
    },

    videoSettingsPage = {
      pageGroup = "videoGroup",
      views = {
        default = { "Video Settings" },
      },
      controls = {
        open = Controls["Open Video Settings"],
        close = Controls["Close Video Settings"],
      },
    },

    videoTestPage = {
      pageGroup = "videoReplacementGroup",
      views = {
        default = { "Video Test" },
      },
      controls = {
        open = Controls["Open Video Test"],
        close = Controls["Close Video Test"],
      },
    },

    powerPage = {
      pageGroup = "systemGroup",
      views = {
        default = { "Power Page" },
      },
      controls = {
        open = Controls["Open Power"],
        close = Controls["Close Power"],
      },
    },

    helpPage = {
      pageGroup = "systemGroup",
      views = {
        default = { "Help Page" },
      },
      controls = {
        open = Controls["Open Help"],
        close = Controls["Close Help"],
      },
    },
  },
})
