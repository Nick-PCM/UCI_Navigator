# Basic Keypad Runtime Config

This is the basic keypad example written without the authoring helpers. It does not use `Navigator.compile(...)`, `group(...)`, `page(...)`, `region(...)`, `groups.*`, `pages.*`, `regions.*`, `interlocked`, or `independent`.

This is the shape Navigator runs after authoring has been compiled. It is useful for understanding the internal config model, but it is more verbose and easier to get wrong than the authored example.

Because this bypasses `Navigator.compile(...)`, Q-SYS control names must be resolved manually with `Controls["..."]`. `logging.manifest` still prints configured layer names, but authored control-name manifest logging is normally compiler-provided and is omitted here.

```lua
local Navigator = require("Navigator")

local config = {
  uci = { pageName = "Main" },

  logging = {
    access = true,
    navigation = true,
    history = true,
    keypad = true,
    timeout = true,
    controls = true,
  manifest = true,
  },

  access = {
    levels = {
      locked = { homePageId = "splash" },
      user = { homePageId = "home" },
    },
    defaultLevelId = "user",
    keypadRequired = true,
    keypadPageId = "keypad",
    pinEntryTimeoutSeconds = 30,
    sessionTimeoutSeconds = 600,
  },

  accessControls = {
    level = Controls["Access Level"],
    change = Controls["Change Access Level"],
    lock = Controls["Lock Request"],
    activityPulse = Controls["Activity Pulse"],
  },

  historyControls = {
    back = Controls["Back"],
    forward = Controls["Forward"],
  },

  groups = {
    gate = { id = "gate", owner = "root", behavior = "independent" },
    accessGate = { id = "accessGate", owner = "gate", behavior = "interlocked", defaultPageIds = { "splash" } },
    session = { id = "session", owner = "root", behavior = "independent" },
    tools = { id = "tools", owner = "session", behavior = "independent" },
    system = { id = "system", owner = "session", behavior = "interlocked", defaultPageIds = { "home" } },
    audioSubpages = { id = "audioSubpages", owner = "audio", behavior = "interlocked", ownerVisibility = "visible", defaultPageIds = { "audioRouting" } },
    videoSubpages = { id = "videoSubpages", owner = "video", behavior = "interlocked", ownerVisibility = "visible", defaultPageIds = { "videoRouting" } },
    videoReplacement = { id = "videoReplacement", owner = "video", behavior = "independent", ownerVisibility = "hidden" },
  },

  pages = {
    splash = {
      id = "splash",
      group = "accessGate",
      views = { locked = { "Splash" } },
    },

    keypad = {
      id = "keypad",
      group = "accessGate",
      views = { locked = { "Keypad" } },
      controls = {
        open = Controls["Open Keypad"],
        close = Controls["Close Keypad"],
      },
    },

    power = {
      id = "power",
      group = "tools",
      views = { user = { "Power" } },
      controls = {
        open = Controls["Open Power"],
        close = Controls["Close Power"],
      },
    },

    help = {
      id = "help",
      group = "tools",
      views = { user = { "Help" } },
      controls = {
        open = Controls["Open Help"],
        close = Controls["Close Help"],
      },
    },

    home = {
      id = "home",
      group = "system",
      views = { user = { "Home" } },
      controls = {
        open = Controls["Open Home Page"],
      },
    },

    audio = {
      id = "audio",
      group = "system",
      views = { user = { "Audio" } },
      controls = {
        open = Controls["Open Audio Page"],
      },
    },

    video = {
      id = "video",
      group = "system",
      views = { user = { "Video" } },
      controls = {
        open = Controls["Open Video Page"],
      },
    },

    audioRouting = {
      id = "audioRouting",
      group = "audioSubpages",
      views = { user = { "Audio Routing" } },
      controls = {
        open = Controls["Open Audio Routing"],
      },
    },

    audioSettings = {
      id = "audioSettings",
      group = "audioSubpages",
      views = { user = { "Audio Settings" } },
      regionFills = {
        footer = {
          user = { "Audio Settings Footer" },
        },
      },
      controls = {
        open = Controls["Open Audio Settings"],
      },
    },

    videoRouting = {
      id = "videoRouting",
      group = "videoSubpages",
      views = { user = { "Video Routing" } },
      controls = {
        open = Controls["Open Video Routing"],
      },
    },

    videoSettings = {
      id = "videoSettings",
      group = "videoSubpages",
      views = { user = { "Video Settings" } },
      controls = {
        open = Controls["Open Video Settings"],
        close = Controls["Close Video Settings"],
      },
    },

    videoTest = {
      id = "videoTest",
      group = "videoReplacement",
      views = { user = { "Video Test" } },
      controls = {
        open = Controls["Open Video Test"],
        close = Controls["Close Video Test"],
      },
    },
  },

  regions = {
    header = {
      id = "header",
      owner = "session",
      views = { user = { "Header" } },
    },

    footer = {
      id = "footer",
      owner = "session",
      views = { user = { "Footer" } },
    },

    ribbon = {
      id = "ribbon",
      owner = "session",
      views = { user = { "Ribbon" } },
    },

    background = {
      id = "background",
      owner = "session",
      views = { user = { "Background" } },
    },
  },

}

Navigator.apply(config)
```
