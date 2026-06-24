-- VanillaExample.lua
-- Navigator is assumed to have already been loaded.
--
-- This example demonstrates the V2 ownership model without custom access.

Navigator.configure({
  uci = {
    pageName = "Main",
    transition = "none",
  },

  access = {
    levels = {
      locked = { homePageId = "splashPage" },
      default = { homePageId = "homepage" },
    },
    keypadRequired = true,
    keypadPageId = "keypadPage",
    pinEntryTimeoutSeconds = 30,
    sessionTimeoutSeconds = 600,
  },

  accessControls = {
    state = Controls["Access_State"],
    request = Controls["Access_Request"],
    lock = Controls["Lock_Request"],
    activityPulse = Controls["Activity_Pulse"],
  },

  historyControls = {
    back = Controls["Back"],
    forward = Controls["Forward"],
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

    videoModalGroup = {
      owner = "videoPage",
      behavior = "independent",
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
        openKeypad = Controls["Open_Keypad"],
      },
    },

    keypadPage = {
      pageGroup = "lockedGroup",
      views = {
        locked = { "Keypad" },
      },
      controls = {
        close = Controls["Close_Keypad"],
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
        default = { "Nav Page" },
      },
    },

    homepage = {
      pageGroup = "mainGroup",
      views = {
        default = { "Home" },
      },
      controls = {
        open = Controls["Open_Home_Page"],
      },
    },

    audioPage = {
      pageGroup = "mainGroup",
      views = {
        default = { "Audio" },
      },
      controls = {
        open = Controls["Open_Audio_Page"],
      },
    },

    audioRoutingPage = {
      pageGroup = "audioGroup",
      views = {
        default = { "Audio Routing" },
      },
      controls = {
        open = Controls["Open_Audio_Routing"],
      },
    },

    audioSettingsPage = {
      pageGroup = "audioGroup",
      views = {
        default = { "Audio Settings" },
      },
      controls = {
        open = Controls["Open_Audio_Settings"],
      },
    },

    videoPage = {
      pageGroup = "mainGroup",
      views = {
        default = { "Video" },
      },
      controls = {
        open = Controls["Open_Video_Page"],
      },
    },

    videoRoutingPage = {
      pageGroup = "videoModalGroup",
      views = {
        default = { "Video Routing" },
      },
      controls = {
        open = Controls["Open_Video_Routing"],
        close = Controls["Close_Video_Routing"],
      },
    },

    videoSettingsPage = {
      pageGroup = "videoModalGroup",
      views = {
        default = { "Video Settings" },
      },
      controls = {
        open = Controls["Open_Video_Settings"],
        close = Controls["Close_Video_Settings"],
      },
    },

    videoTestPage = {
      pageGroup = "videoReplacementGroup",
      views = {
        default = { "Video Test" },
      },
      controls = {
        open = Controls["Open_Video_Test"],
        close = Controls["Close_Video_Test"],
      },
    },

    powerPage = {
      pageGroup = "systemGroup",
      views = {
        default = { "Power Page" },
      },
      controls = {
        open = Controls["Open_Power"],
        close = Controls["Close_Power"],
      },
    },

    helpPage = {
      pageGroup = "systemGroup",
      views = {
        default = { "Help Page" },
      },
      controls = {
        open = Controls["Open_Help"],
        close = Controls["Close_Help"],
      },
    },
  },
})
