-- Basic Keypad Example.lua
-- Navigator is assumed to have already been loaded.
--
-- This example demonstrates the ownership model without custom access.
--
--[[
Page tree:
root (interlocked set)
|-- lockedGroup (interlocked set)
|   |-- splashPage: "Splash"
|   |   controls: openKeypad = "Open Keypad"
|   `-- keypadPage: "Keypad"
|       controls: close = "Close Keypad"
`-- unlockedGroup (independent set)
    |-- frameGroup (independent set)
    |   |-- backgroundPage: "Background"
    |   |-- headerPage: "Header"
    |   |-- footerPage: "Footer"
    |   `-- navPage: "Navigation"
    |-- mainGroup (interlocked set)
    |   |-- homepage: "Home"
    |   |   controls: open = "Open Home Page"
    |   |-- audioPage: "Audio"
    |   |   controls: open = "Open Audio Page"
    |   |   `-- audioGroup (interlocked set, audioPage remains visible)
    |   |       |-- audioRoutingPage: "Audio Routing"
    |   |       |   controls: open = "Open Audio Routing"
    |   |       `-- audioSettingsPage: "Audio Settings"
    |   |           frame override: footer = "Audio Settings Footer"
    |   |           controls: open = "Open Audio Settings"
    |   `-- videoPage: "Video"
    |       controls: open = "Open Video Page"
    |       |-- videoGroup (interlocked set, videoPage remains visible)
    |       |   |-- videoRoutingPage: "Video Routing"
    |       |   |   controls: open = "Open Video Routing", close = "Close Video Routing"
    |       |   `-- videoSettingsPage: "Video Settings"
    |       |       controls: open = "Open Video Settings", close = "Close Video Settings"
    |       `-- videoReplacementGroup (independent set, hides videoPage)
    |           `-- videoTestPage: "Video Test"
    |               controls: open = "Open Video Test", close = "Close Video Test"
    `-- systemGroup (independent set)
        |-- powerPage: "Power"
        |   controls: open = "Open Power", close = "Close Power"
        `-- helpPage: "Help"
            controls: open = "Open Help", close = "Close Help"
]]

local Navigator = require("Navigator") -- ommit from qsys script. just here to allow comments in vscode

Navigator.configure({
  -- Q-SYS UCI target and transition style for layer visibility changes.
  uci = {
    pageName = "Main", -- Q-SYS UCI page that contains the controlled layers.
    transition = "none", -- Q-SYS layer transition used when showing or hiding layers.
  },

  -- Turn individual print() log categories on or off.
  logging = {
    access = true,
    navigation = true,
    history = true,
    keypad = true,
    timeout = true,
    controls = true,
  },

  -- Locked/default entry points and access timeout policy.
  access = {
    levels = { -- Declares every supported access level.
      locked = { homePageId = "splashPage" }, -- Locked entry page shown before access is granted.
      default = { homePageId = "homepage" }, -- Default unlocked entry page after access is granted.
    },
    keypadRequired = true, -- Requires the configured keypad page before unlocking.
    keypadPageId = "keypadPage", -- Locked page opened when access is requested.
    pinEntryTimeoutSeconds = 30, -- Seconds before an open keypad returns to the locked home page.
    sessionTimeoutSeconds = 600, -- Seconds of inactivity before Navigator returns to locked access.
  },

  -- Global controls that change or mirror access state.
  accessControls = {
    state = Controls["Access State"], -- String control that mirrors the current access level.
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

  -- Page groups define ownership and coexistence behavior.
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
      defaultPageIds = { "videoRoutingPage" }
    },

    -- Replacement pages hide videoPage while they are active.
    videoReplacementGroup = {
      owner = "videoPage",
      behavior = "independent",
      ownerVisibility = "hidden",
    },
  },

  -- Pages bind logical page ids to Q-SYS layers and optional controls.
  pages = {
    -- Locked splash is the locked home page.
    splashPage = {
      pageGroup = "lockedGroup",
      views = {
        locked = { "Splash" },
      },
      controls = {
        openKeypad = Controls["Open Keypad"],
      },
    },

    -- Keypad is a normal locked page plus the configured access keypad target.
    keypadPage = {
      pageGroup = "lockedGroup",
      views = {
        locked = { "Keypad" },
      },
      controls = {
        close = Controls["Close Keypad"],
      },
    },

    -- Frame pages live under frameGroup and come up with unlocked access.
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
      },
    },

    -- The default unlocked main page.
    homepage = {
      pageGroup = "mainGroup",
      views = {
        default = { "Home" },
      },
      controls = {
        open = Controls["Open Home Page"],
      },
    },

    -- Main audio page owns an interlocked audioGroup below it.
    audioPage = {
      pageGroup = "mainGroup",
      views = {
        default = { "Audio" },
      },
      controls = {
        open = Controls["Open Audio Page"],
      },
    },

    -- Default audio subpage.
    audioRoutingPage = {
      pageGroup = "audioGroup",
      views = {
        default = { "Audio Routing" },
      },
      controls = {
        open = Controls["Open Audio Routing"],
      },
    },

    -- Audio settings replaces the standard footer while active.
    audioSettingsPage = {
      pageGroup = "audioGroup",
      views = {
        default = { "Audio Settings" },
      },
      frameOverrides = {
        footer = {
          default = { "Audio Settings Footer" },
        },
      },
      controls = {
        open = Controls["Open Audio Settings"],
      },
    },

    -- Main video page owns visible subpages and hidden replacement pages.
    videoPage = {
      pageGroup = "mainGroup",
      views = {
        default = { "Video" },
      },
      controls = {
        open = Controls["Open Video Page"],
      },
    },

    -- Video subpages use close controls, but closing the default returns to it.
    videoRoutingPage = {
      pageGroup = "videoGroup",
      views = {
        default = { "Video Routing" },
      },
      controls = {
        open = Controls["Open Video Routing"],
        close = Controls["Close Video Routing"],
      },
    },

    -- Second video subpage interlocked with video routing.
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

    -- Replacement page: hides videoPage until closed.
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

    -- Independent system page shown over the current unlocked state.
    powerPage = {
      pageGroup = "systemGroup",
      views = {
        default = { "Power" },
      },
      controls = {
        open = Controls["Open Power"],
        close = Controls["Close Power"],
      },
    },

    -- Another independent system page.
    helpPage = {
      pageGroup = "systemGroup",
      views = {
        default = { "Help" },
      },
      controls = {
        open = Controls["Open Help"],
        close = Controls["Close Help"],
      },
    },
  },
})
