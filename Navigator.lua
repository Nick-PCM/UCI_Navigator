-- Navigator.lua
-- Ownership/group based navigation for a layer-based Q-SYS UCI.

local Navigator = {} -- public module table returned to the project script

local ACCESS_LOCKED = "locked" -- locked/splash/keypad access
local GROUP_INTERLOCKED = "interlocked" -- one direct member active at a time
local GROUP_INDEPENDENT = "independent" -- multiple direct members may be active
local OWNER_VISIBLE = "visible" -- keep owner page layer visible
local OWNER_HIDDEN = "hidden" -- suppress owner page layer while group is active
local ROOT_OWNER = "root" -- implicit top-level interlocked owner

Navigator.Access = { -- built-in access names
  LOCKED = ACCESS_LOCKED,
}

-- Authoring/compiler support -------------------------------------------------

-- Marker strings tag authoring helper outputs so compile can recognize
-- Navigator constructs without mistaking ordinary project tables for them.
local MARKER_GROUP = "navigator.group" -- authored group(...) marker
local MARKER_PAGE = "navigator.page" -- authored page(...) marker
local MARKER_REGION = "navigator.region" -- authored region(...) marker
local MARKER_REF = "navigator.ref" -- symbolic pages/groups/regions reference
local MARKER_REGION_FILL = "navigator.regionFill" -- callable region fill marker
local MARKER_MODE = "navigator.mode" -- interlocked/independent mode marker

-- Creates tagged compile-time values that validation can distinguish from user tables.
local function marker(kind, fields)
  fields = fields or {}
  fields.__navigatorMarker = kind
  return fields
end

-- Tests whether a table is one of Navigator's compile-time marker objects.
local function isMarker(value, kind)
  return type(value) == "table" and value.__navigatorMarker == kind
end

-- Creates a symbolic typed reference; region references are callable fill makers.
local function makeRef(kind, id)
  local ref = marker(MARKER_REF, { kind = kind, id = id })
  if kind == "region" then
    return setmetatable(ref, {
      __call = function(regionRef, content)
        return marker(MARKER_REGION_FILL, {
          region = regionRef,
          content = content,
        })
      end,
    })
  end
  return ref
end

-- Builds lazy registries such as pages.audio and regions.footer.
local function makeRegistry(kind, builtIns)
  return setmetatable({}, {
    __index = function(_, id)
      if builtIns and builtIns[id] then return builtIns[id] end
      return makeRef(kind, id)
    end,
    __newindex = function()
      error(kind .. " references are read-only")
    end,
  })
end

local groupsRegistry = makeRegistry("group", {
  root = makeRef("group", ROOT_OWNER),
})
local pagesRegistry = makeRegistry("page")
local regionsRegistry = makeRegistry("region")

local interlockedMode = marker(MARKER_MODE, {
  value = GROUP_INTERLOCKED,
})
local independentMode = marker(MARKER_MODE, {
  value = GROUP_INDEPENDENT,
})

-- Authoring constructor for lifecycle groups and their direct pages.
function Navigator.group(spec, pages)
  return marker(MARKER_GROUP, { spec = spec or {}, pages = pages or {} })
end

-- Authoring constructor for navigable visible pages.
function Navigator.page(spec)
  return marker(MARKER_PAGE, { spec = spec or {} })
end

-- Authoring constructor for owner-scoped shared presentation regions.
function Navigator.region(spec)
  return marker(MARKER_REGION, { spec = spec or {} })
end

Navigator.groups = groupsRegistry
Navigator.pages = pagesRegistry
Navigator.regions = regionsRegistry
Navigator.interlocked = interlockedMode
Navigator.independent = independentMode

-- Exposes bare authoring helpers for Q-SYS scripts and compact examples.
if _G then
  rawset(_G, "group", rawget(_G, "group") or Navigator.group)
  rawset(_G, "page", rawget(_G, "page") or Navigator.page)
  rawset(_G, "region", rawget(_G, "region") or Navigator.region)
  rawset(_G, "groups", rawget(_G, "groups") or groupsRegistry)
  rawset(_G, "pages", rawget(_G, "pages") or pagesRegistry)
  rawset(_G, "regions", rawget(_G, "regions") or regionsRegistry)
  rawset(_G, "interlocked", rawget(_G, "interlocked") or interlockedMode)
  rawset(_G, "independent", rawget(_G, "independent") or independentMode)
end

-- Core runtime helpers -------------------------------------------------------

local config -- validated project configuration

-- Mutable runtime navigation state: current access plus active pages and groups.
local state = {
  access = Navigator.Access.LOCKED, -- current access level
  activePageIds = {}, -- active page set
  activeGroupIds = {}, -- active group set
}

local indexes = {} -- derived lookup tables built from config
local visibleLayers = {} -- last applied physical layer set
local visibilityInitialized = false -- whether first visibility pass has run
local historyBack = {} -- back navigation snapshot stack
local historyForward = {} -- forward navigation snapshot stack
local accessLevelControl -- Q-SYS control mirroring active access
local logging = {} -- enabled log categories
local anyLoggingEnabled = false -- fast skip when all logging is off

-- Copies a set-like table so callers cannot mutate navigator state by reference.
local function copyTable(source)
  local result = {}
  for key, value in pairs(source or {}) do
    result[key] = value
  end
  return result
end

-- Captures the active page/group state used for history and change detection.
local function copyStateSnapshot()
  return {
    activePageIds = copyTable(state.activePageIds),
    activeGroupIds = copyTable(state.activeGroupIds),
  }
end

-- Compares two set-like tables without caring about table identity.
local function sameSet(a, b)
  for key in pairs(a or {}) do
    if not b[key] then return false end
  end
  for key in pairs(b or {}) do
    if not a[key] then return false end
  end
  return true
end

-- Determines whether a navigation operation actually changed visible state.
local function sameSnapshot(a, b)
  return sameSet(a.activePageIds, b.activePageIds)
    and sameSet(a.activeGroupIds, b.activeGroupIds)
end

-- Distinguishes a multi-control alias list from a single Q-SYS control object.
local function isControlList(value)
  return type(value) == "table" and value[1] ~= nil
end

-- Applies wiring or state updates to an optional single control or control list.
local function forEachControl(controlOrList, callback)
  if controlOrList == nil then return end
  if isControlList(controlOrList) then
    for _, control in ipairs(controlOrList) do
      callback(control)
    end
  else
    callback(controlOrList)
  end
end

-- Checks category logging with a fast global off path.
local function shouldLog(category)
  return anyLoggingEnabled and logging[category] == true
end

-- Emits a standardized navigator log line.
local function log(category, message)
  print("Navigator " .. category .. ": " .. message)
end

-- Centralizes the locked access test used by access and view resolution.
local function isLockedAccess(access)
  return access == Navigator.Access.LOCKED
end

-- Tests whether a group lives under another group in the ownership tree.
local function groupIsUnder(groupId, ancestorGroupId)
  local current = groupId
  while current do
    if current == ancestorGroupId then return true end
    local owner = indexes.groupOwnerById[current]
    if indexes.ownerKindByGroupId[current] ~= "group" then return false end
    current = owner
  end
  return false
end

-- Identifies pages that should resolve locked views regardless of active access.
local function pageIsInLockedGroup(pageId)
  return groupIsUnder(indexes.groupByPageId[pageId],
    config.access.lockedGroupId)
end

-- Chooses the access level a page should use for its view lookup.
local function effectiveAccessForPage(pageId)
  if pageIsInLockedGroup(pageId) then return Navigator.Access.LOCKED end
  return state.access
end

-- Resolves an access-keyed layer table, used by regions and fills.
local function viewTableForAccess(views, access)
  return views[access]
    or (not isLockedAccess(access) and views[config.access.defaultLevelId])
end

-- Resolves the concrete layer list for a page in the current or supplied access.
local function viewForPageId(pageId, access)
  local page = config.pages[pageId]
  return viewTableForAccess(page.views, access or effectiveAccessForPage(pageId))
end

-- Adds layer names into the desired visibility set.
local function addLayers(destination, layerNames)
  if not layerNames then return end
  for _, layerName in ipairs(layerNames) do
    destination[layerName] = true
  end
end

-- Sends one physical layer visibility change to Q-SYS.
local function setLayerVisibility(layerName, isVisible)
  Uci.SetLayerVisibility(
    config.uci.pageName or "Main",
    layerName,
    isVisible,
    config.uci.transition or "none"
  )
end

-- Collects every declared layer so first reconciliation can hide stale layers.
local function collectConfiguredLayers()
  local layers = {}
  for _, region in pairs(config.regions or {}) do
    for _, layerNames in pairs(region.views) do
      addLayers(layers, layerNames)
    end
  end
  for _, page in pairs(config.pages) do
    for _, layerNames in pairs(page.views) do
      addLayers(layers, layerNames)
    end
    for _, regionViews in pairs(page.regionFills or {}) do
      for _, layerNames in pairs(regionViews) do
        addLayers(layers, layerNames)
      end
    end
  end
  return layers
end

-- Calculates page nesting depth for region fill precedence.
local function pageDepth(pageId)
  local groupId = indexes.groupByPageId[pageId]
  return #(indexes.groupAncestorsById[groupId] or {}) + 1
end

-- Finds active owner pages whose own view is suppressed by owned groups.
local function hiddenOwnerPageIds()
  local hidden = {}
  for groupId in pairs(state.activeGroupIds) do
    local group = config.groups[groupId]
    if group and group.ownerVisibility == OWNER_HIDDEN then
      local owner = indexes.groupOwnerById[groupId]
      if indexes.ownerKindByGroupId[groupId] == "page" then
        hidden[owner] = true
      end
    end
  end
  return hidden
end

-- Tests whether a group, page, or root owner is currently active.
local function ownerIsActive(ownerId)
  if ownerId == ROOT_OWNER then return true end
  return state.activeGroupIds[ownerId] == true
    or state.activePageIds[ownerId] == true
end

-- Chooses region default access from the owning page or current access state.
local function accessForOwner(ownerId)
  if indexes.pagesById[ownerId] then
    return effectiveAccessForPage(ownerId)
  end
  return state.access
end

-- Selects the active fill for each region, preferring deeper pages.
local function selectedRegionFills()
  local selected = {}
  for pageId in pairs(state.activePageIds) do
    local page = config.pages[pageId]
    for regionId, regionViews in pairs(page.regionFills or {}) do
      local region = config.regions and config.regions[regionId]
      if region and ownerIsActive(region.owner) then
        local view = viewTableForAccess(regionViews, effectiveAccessForPage(pageId))
        if view then
          local depth = pageDepth(pageId)
          local current = selected[regionId]
          assert(not current or current.depth ~= depth,
            "multiple active region fills for " .. regionId)
          if not current or depth > current.depth then
            selected[regionId] = {
              pageId = pageId,
              depth = depth,
              view = view,
            }
          end
        end
      end
    end
  end
  return selected
end

-- Converts active navigator state into the full desired layer set.
local function resolveDesiredLayers()
  local desired = {}
  local hidden = hiddenOwnerPageIds()
  local regionFills = selectedRegionFills()

  for pageId in pairs(state.activePageIds) do
    if not hidden[pageId] then
      local view = viewForPageId(pageId)
      assert(view, pageId .. " is active but unavailable")
      addLayers(desired, view)
    end
  end
  for regionId, region in pairs(config.regions or {}) do
    if ownerIsActive(region.owner) then
      local fill = regionFills[regionId]
      if fill then
        addLayers(desired, fill.view)
      else
        addLayers(desired,
          viewTableForAccess(region.views, accessForOwner(region.owner)))
      end
    end
  end
  return desired
end

-- Diffs desired layers against current layers and applies Q-SYS changes.
local function reconcileVisibility()
  local desired = resolveDesiredLayers()
  local layersToCheck = visibilityInitialized
    and visibleLayers or collectConfiguredLayers()

  for layerName in pairs(layersToCheck) do
    if not desired[layerName] then setLayerVisibility(layerName, false) end
  end
  for layerName in pairs(desired) do
    if not visibleLayers[layerName] then setLayerVisibility(layerName, true) end
  end

  visibleLayers = desired
  visibilityInitialized = true
end

-- Pushes a history snapshot while respecting the configured history cap.
local function cappedPush(stack, snapshot)
  stack[#stack + 1] = snapshot
  local maxEntries = config.historyMaxEntries
  if maxEntries == nil then maxEntries = 25 end
  if maxEntries == false then return end
  if #stack > maxEntries then table.remove(stack, 1) end
end

-- Keeps optional history controls disabled when their stack is empty.
local function updateHistoryControls()
  local controls = config and config.historyControls
  if not controls then return end
  forEachControl(controls.back, function(control)
    control.IsDisabled = #historyBack == 0
  end)
  forEachControl(controls.forward, function(control)
    control.IsDisabled = #historyForward == 0
  end)
end

-- Clears both history stacks when navigation crosses an access/keypad boundary.
local function clearHistory()
  local hadHistory = #historyBack > 0 or #historyForward > 0
  historyBack = {}
  historyForward = {}
  updateHistoryControls()
  if hadHistory and shouldLog("history") then log("history", "cleared") end
end

-- Records the previous state after a page navigation changes state.
local function recordHistory(before)
  cappedPush(historyBack, before)
  historyForward = {}
  updateHistoryControls()
  if shouldLog("history") then log("history", "recorded state") end
end

-- Deactivates a group, its direct active pages, and any active owned groups.
local function closeGroup(groupId)
  for pageId, page in pairs(config.pages) do
    if state.activePageIds[pageId]
        and indexes.groupByPageId[pageId] == groupId then
      state.activePageIds[pageId] = nil
    end
  end

  for childGroupId in pairs(indexes.groupsOwnedByOwnerId[groupId] or {}) do
    if state.activeGroupIds[childGroupId] then closeGroup(childGroupId) end
  end

  state.activeGroupIds[groupId] = nil
end

-- Closes subordinate groups when their owner page is closed.
local function closeGroupsOwnedByPage(pageId)
  for groupId in pairs(indexes.groupsOwnedByOwnerId[pageId] or {}) do
    if state.activeGroupIds[groupId] then closeGroup(groupId) end
  end
end

-- Removes one page and its owned groups without applying default-page policy.
local function closePageOnly(pageId)
  if not state.activePageIds[pageId] then return end
  closeGroupsOwnedByPage(pageId)
  state.activePageIds[pageId] = nil
end

-- Checks whether a group still has directly active pages or child groups.
local function groupHasActiveDirectMembers(groupId)
  for pageId in pairs(indexes.pagesByGroupId[groupId] or {}) do
    if state.activePageIds[pageId] then return true end
  end
  for childGroupId in pairs(indexes.groupsOwnedByOwnerId[groupId] or {}) do
    if state.activeGroupIds[childGroupId] then return true end
  end
  return false
end

-- Determines how an owner's direct groups/pages should interlock.
local function ownerBehavior(ownerId)
  if ownerId == ROOT_OWNER then return GROUP_INTERLOCKED end
  local group = config.groups[ownerId]
  if group then return group.behavior end
  return GROUP_INDEPENDENT
end

-- Enforces interlock by closing active siblings under the same owner.
local function closeOtherDirectMembers(ownerId, keepKind, keepId)
  if ownerBehavior(ownerId) ~= GROUP_INTERLOCKED then return end

  for groupId in pairs(indexes.groupsOwnedByOwnerId[ownerId] or {}) do
    if not (keepKind == "group" and keepId == groupId)
        and state.activeGroupIds[groupId] then
      closeGroup(groupId)
    end
  end

  if indexes.groupsById[ownerId] then
    for pageId in pairs(indexes.pagesByGroupId[ownerId] or {}) do
      if not (keepKind == "page" and keepId == pageId)
          and state.activePageIds[pageId] then
        closePageOnly(pageId)
      end
    end
  end
end

local activatePage
local activateGroup
local activateDefaultOwnedGroups

-- Activates a group and its owning chain before opening pages within it.
activateGroup = function(groupId, options)
  options = options or {}
  if state.activeGroupIds[groupId] then return end

  local owner = indexes.groupOwnerById[groupId]
  local ownerKind = indexes.ownerKindByGroupId[groupId]
  if ownerKind == "group" then
    activateGroup(owner, options)
  elseif ownerKind == "page" then
    activatePage(owner, { activateOwnedDefaults = false })
  end

  closeOtherDirectMembers(owner, "group", groupId)
  state.activeGroupIds[groupId] = true
  if options.activateDefaults ~= false then
    activateDefaultOwnedGroups(groupId)
  end
end

-- Opens default pages for groups owned by an active group or page.
activateDefaultOwnedGroups = function(ownerId)
  for groupId in pairs(indexes.groupsOwnedByOwnerId[ownerId] or {}) do
    local defaults = indexes.groupDefaultPagesById[groupId]
    if defaults and #defaults > 0 then
      activateGroup(groupId)
      local hasActivePage = false
      for pageId in pairs(indexes.pagesByGroupId[groupId] or {}) do
        if state.activePageIds[pageId] then
          hasActivePage = true
          break
        end
      end
      if not hasActivePage then
        for _, pageId in ipairs(defaults) do
          activatePage(pageId)
        end
      end
    end
  end
end

-- Opens a page, activating required groups and owned default groups.
activatePage = function(pageId, options)
  options = options or {}
  local page = config.pages[pageId]
  assert(page, "unknown pageId: " .. tostring(pageId))
  assert(viewForPageId(pageId), pageId .. " is unavailable for " .. state.access)

  local groupId = indexes.groupByPageId[pageId]
  activateGroup(groupId, options)
  closeOtherDirectMembers(groupId, "page", pageId)
  state.activePageIds[pageId] = true

  if options.activateOwnedDefaults ~= false then
    activateDefaultOwnedGroups(pageId)
  end
end

-- Opens the configured default page or pages for a group.
local function activateDefaultPageForGroup(groupId)
  local defaults = indexes.groupDefaultPagesById[groupId]
  if not defaults or #defaults == 0 then return false end
  for _, pageId in ipairs(defaults) do
    activatePage(pageId)
  end
  return true
end

-- Restores a previously captured page/group state for history navigation.
local function restoreSnapshot(snapshot)
  state.activePageIds = copyTable(snapshot.activePageIds)
  state.activeGroupIds = copyTable(snapshot.activeGroupIds)
end

-- Interlocks page open controls to reflect the currently active pages.
local function updatePageOpenControls()
  if not config then return end
  for pageId, page in pairs(config.pages) do
    if page.controls and page.controls.open then
      forEachControl(page.controls.open, function(control)
        control.Boolean = state.activePageIds[pageId] == true
      end)
    end
  end
end

local onPinEntryTimeout
local onSessionTimeout

-- Lazily creates the keypad entry timeout timer.
local function pinEntryTimer()
  if not Navigator._pinEntryTimer then
    Navigator._pinEntryTimer = Timer.New()
    Navigator._pinEntryTimer.EventHandler = function(timer)
      timer:Stop()
      onPinEntryTimeout()
    end
  end
  return Navigator._pinEntryTimer
end

-- Lazily creates the unlocked-session timeout timer.
local function sessionTimer()
  if not Navigator._sessionTimer then
    Navigator._sessionTimer = Timer.New()
    Navigator._sessionTimer.EventHandler = function(timer)
      timer:Stop()
      onSessionTimeout()
    end
  end
  return Navigator._sessionTimer
end

-- Stops keypad entry timing when keypad is closed or disabled.
local function stopPinEntryTimer()
  if Navigator._pinEntryTimer then Navigator._pinEntryTimer:Stop() end
end

-- Stops session timing when locked or before resetting access.
local function stopSessionTimer()
  if Navigator._sessionTimer then Navigator._sessionTimer:Stop() end
end

-- Starts or stops keypad timing based on whether the keypad page is active.
local function restartPinEntryTimer()
  if not config.access.keypadRequired
      or config.access.pinEntryTimeoutSeconds == 0 then
    stopPinEntryTimer()
    return
  end
  if state.activePageIds[config.access.keypadPageId] then
    pinEntryTimer():Start(config.access.pinEntryTimeoutSeconds)
  else
    stopPinEntryTimer()
  end
end

-- Restarts the session timer while the navigator is unlocked.
local function restartSessionTimer()
  if isLockedAccess(state.access)
      or config.access.sessionTimeoutSeconds == 0 then
    stopSessionTimer()
    return
  end
  sessionTimer():Start(config.access.sessionTimeoutSeconds)
end

-- Finishes a page navigation by reconciling controls, layers, timers, and history.
local function applyNavigationChange(before, record)
  updatePageOpenControls()
  reconcileVisibility()
  restartPinEntryTimer()
  restartSessionTimer()
  if record and not sameSnapshot(before, copyStateSnapshot()) then
    recordHistory(before)
  else
    updateHistoryControls()
  end
end

-- Shared page-open path used by public navigation and internal transitions.
local function openPageInternal(pageId, record)
  local before = copyStateSnapshot()
  if shouldLog("navigation") then log("navigation", "open " .. pageId) end
  activatePage(pageId)
  applyNavigationChange(before, record)
end

-- Shared page-close path that applies default and empty-group behavior.
local function closePageInternal(pageId, record)
  local before = copyStateSnapshot()
  if not state.activePageIds[pageId] then
    updateHistoryControls()
    return
  end

  if shouldLog("navigation") then log("navigation", "close " .. pageId) end
  local groupId = indexes.groupByPageId[pageId]
  local group = config.groups[groupId]
  local defaults = indexes.groupDefaultPagesById[groupId] or {}
  local isDefault = false
  for _, defaultPageId in ipairs(defaults) do
    if defaultPageId == pageId then
      isDefault = true
      break
    end
  end

  if group.behavior == GROUP_INTERLOCKED
      and isDefault then
    updateHistoryControls()
    return
  end

  closePageOnly(pageId)
  if group.behavior == GROUP_INTERLOCKED
      and #defaults > 0 then
    activateDefaultPageForGroup(groupId)
  elseif not groupHasActiveDirectMembers(groupId) then
    state.activeGroupIds[groupId] = nil
  end

  applyNavigationChange(before, record)
end

-- Prunes active pages that do not define a view for a new access level.
local function closeUnavailablePages(targetAccess)
  local activeIds = {}
  for pageId in pairs(state.activePageIds) do
    activeIds[#activeIds + 1] = pageId
  end
  for _, pageId in ipairs(activeIds) do
    if state.activePageIds[pageId] then
      local access = pageIsInLockedGroup(pageId)
        and Navigator.Access.LOCKED or targetAccess
      if not viewForPageId(pageId, access) then
        closePageInternal(pageId, false)
      end
    end
  end
end

-- Changes access through the same path used by user-facing controls.
local function changeAccess(targetAccess)
  if accessLevelControl then accessLevelControl.String = targetAccess end
  Navigator.setAccess(targetAccess)
end

-- Returns the configured home page for locked or unlocked entry.
local function accessHomePageId(access)
  if isLockedAccess(access) then
    return config.access.levels[Navigator.Access.LOCKED].homePageId
  end
  return config.access.levels[config.access.defaultLevelId].homePageId
end

-- Moves the navigator across access boundaries and resets state as needed.
function Navigator.setAccess(targetAccess)
  assert(config, "apply Navigator before changing access")
  assert(type(targetAccess) == "string" and config.access.levels[targetAccess],
    "invalid access level")

  clearHistory()
  if shouldLog("access") then
    log("access", state.access .. " -> " .. targetAccess)
  end

  stopPinEntryTimer()
  if isLockedAccess(targetAccess) then
    stopSessionTimer()
    state.access = targetAccess
    state.activePageIds = {}
    state.activeGroupIds = {}
    activatePage(accessHomePageId(targetAccess))
  elseif isLockedAccess(state.access) then
    state.access = targetAccess
    state.activePageIds = {}
    state.activeGroupIds = {}
    activatePage(accessHomePageId(targetAccess))
  else
    state.access = targetAccess
    closeUnavailablePages(targetAccess)
    if not state.activeGroupIds[config.access.unlockedGroupId] then
      activatePage(accessHomePageId(targetAccess))
    end
  end

  updatePageOpenControls()
  reconcileVisibility()
  restartSessionTimer()
  updateHistoryControls()
end

-- Public API for opening a page and recording history.
function Navigator.openPage(pageId)
  assert(config, "apply Navigator before navigating")
  openPageInternal(pageId, true)
end

-- Public API for closing a page and recording history.
function Navigator.closePage(pageId)
  assert(config, "apply Navigator before navigating")
  closePageInternal(pageId, true)
end

local function pageIdFromHandle(pageOrId)
  if type(pageOrId) == "table" then
    assert(type(pageOrId.id) == "string" and pageOrId.id ~= "",
      "page handle must include an id")
    return pageOrId.id
  end
  return pageOrId
end

function Navigator.open(pageOrId)
  Navigator.openPage(pageIdFromHandle(pageOrId))
end

function Navigator.close(pageOrId)
  Navigator.closePage(pageIdFromHandle(pageOrId))
end

-- Restores the previous page/group snapshot from navigation history.
function Navigator.back()
  assert(config, "apply Navigator before navigating")
  if #historyBack == 0 then
    updateHistoryControls()
    return
  end
  local current = copyStateSnapshot()
  local previous = historyBack[#historyBack]
  historyBack[#historyBack] = nil
  cappedPush(historyForward, current)
  restoreSnapshot(previous)
  updatePageOpenControls()
  reconcileVisibility()
  updateHistoryControls()
end

-- Restores the next page/group snapshot after a back operation.
function Navigator.forward()
  assert(config, "apply Navigator before navigating")
  if #historyForward == 0 then
    updateHistoryControls()
    return
  end
  local current = copyStateSnapshot()
  local nextSnapshot = historyForward[#historyForward]
  historyForward[#historyForward] = nil
  cappedPush(historyBack, current)
  restoreSnapshot(nextSnapshot)
  updatePageOpenControls()
  reconcileVisibility()
  updateHistoryControls()
end

-- Handles keypad inactivity by returning from keypad to the locked default.
onPinEntryTimeout = function()
  if shouldLog("timeout") then log("timeout", "pin entry") end
  changeAccess(Navigator.Access.LOCKED)
end

-- Handles unlocked session expiry by returning to locked access.
onSessionTimeout = function()
  if shouldLog("timeout") then log("timeout", "session") end
  changeAccess(Navigator.Access.LOCKED)
end

-- Runtime config validation --------------------------------------------------

-- Supported per-page control aliases.
local pageControlKeys = {
  open = true,
  close = true,
}

-- Supported global access control aliases.
local accessControlKeys = {
  level = true,
  change = true,
  lock = true,
  activityPulse = true,
}

-- Supported global history control aliases.
local historyControlKeys = {
  back = true,
  forward = true,
}

-- Supported logging categories.
local loggingKeys = {
  access = true,
  navigation = true,
  history = true,
  keypad = true,
  timeout = true,
  controls = true,
  manifest = true,
}

-- Validates access level names before they are used as view keys.
local function validateAccessName(ownerId, access)
  assert(type(access) == "string" and access ~= "",
    ownerId .. " has an invalid access level")
  assert(access == string.lower(access),
    ownerId .. " access levels must be lowercase")
end

-- Normalizes shorthand layer declarations into access-keyed layer lists.
local function normalizeViews(ownerId, views, defaultAccess)
  assert(type(defaultAccess) == "string" and defaultAccess ~= "",
    ownerId .. " requires a default access level")
  if type(views) == "string" then
    return { [defaultAccess] = { views } }
  end
  assert(type(views) == "table", ownerId .. " requires views")
  if views[1] ~= nil then
    return { [defaultAccess] = views }
  end

  local normalized = {}
  for access, layerNames in pairs(views) do
    if type(layerNames) == "string" then
      normalized[access] = { layerNames }
    else
      normalized[access] = layerNames
    end
  end
  return normalized
end

-- Normalizes page authoring aliases before validation and indexing.
local function normalizeConfig(candidate)
  candidate.uci = candidate.uci or {}
  candidate.uci.transition = candidate.uci.transition or "none"
  candidate.regions = candidate.regions or {}
  for regionId, region in pairs(candidate.regions) do
    region.views = normalizeViews(regionId, region.views,
      candidate.access.defaultLevelId)
  end
  for pageId, page in pairs(candidate.pages) do
    page.views = normalizeViews(pageId, page.views,
      candidate.access.defaultLevelId)
    if page.regionFills then
      assert(type(page.regionFills) == "table",
        pageId .. ".regionFills must be a table")
      for regionId, regionViews in pairs(page.regionFills) do
        page.regionFills[regionId] =
          normalizeViews(pageId .. ".regionFills." .. regionId, regionViews,
            candidate.access.defaultLevelId)
      end
    end
  end
end

-- Validates that a page, region, or fill has usable access-keyed layer lists.
local function validateViews(pageId, views, levels)
  assert(type(views) == "table", pageId .. " requires views")
  for access, layerNames in pairs(views) do
    validateAccessName(pageId, access)
    assert(levels[access], pageId .. " uses undeclared access level " .. access)
    assert(type(layerNames) == "table" and #layerNames > 0,
      pageId .. " views must be non-empty layer lists")
    for _, layerName in ipairs(layerNames) do
      assert(type(layerName) == "string" and layerName ~= "",
        pageId .. " has an invalid layer name")
    end
  end
end

-- Validates optional Q-SYS control aliases without touching missing controls.
local function validateControls(ownerId, controls, allowedKeys)
  assert(type(controls) == "table", ownerId .. " controls must be a table")
  for key, controlOrList in pairs(controls) do
    assert(allowedKeys[key], ownerId .. "." .. tostring(key)
      .. " is not a supported control")
    assert(controlOrList ~= nil, ownerId .. "." .. key .. " must be a control")
    if isControlList(controlOrList) then
      assert(#controlOrList > 0, ownerId .. "." .. key
        .. " control list cannot be empty")
      for index, control in ipairs(controlOrList) do
        assert(control ~= nil, ownerId .. "." .. key .. "["
          .. index .. "] must be a control")
      end
    end
  end
end

-- Validates first-class region defaults and ownership.
local function validateRegions(candidate)
  assert(type(candidate.regions) == "table", "regions must be a table")
  for regionId, region in pairs(candidate.regions) do
    assert(type(regionId) == "string" and regionId ~= "",
      "region IDs must be strings")
    assert(not candidate.pages[regionId] and not candidate.groups[regionId],
      regionId .. " is used by more than one page, group, or region")
    assert(type(region) == "table",
      regionId .. " region definition must be a table")
    assert(type(region.owner) == "string" and region.owner ~= "",
      regionId .. " requires owner")
    assert(region.owner == ROOT_OWNER
        or candidate.groups[region.owner]
        or candidate.pages[region.owner],
      regionId .. " has an unknown owner")
    validateViews(regionId, region.views, candidate.access.levels)
  end
end

-- Validates per-page fills for first-class regions.
local function validateRegionFills(pageId, regionFills, levels, regions)
  if regionFills == nil then return end
  assert(type(regionFills) == "table", pageId .. ".regionFills must be a table")
  for regionId, regionViews in pairs(regionFills) do
    assert(regions[regionId],
      pageId .. ".regionFills has unknown region " .. tostring(regionId))
    validateViews(pageId .. ".regionFills." .. regionId, regionViews, levels)
  end
end

-- Validates access levels, keypad requirements, and timeout settings.
local function validateAccess(access)
  assert(type(access) == "table", "access must be a table")
  assert(type(access.levels) == "table", "access.levels must be a table")
  assert(type(access.defaultLevelId) == "string" and access.defaultLevelId ~= "",
    "one non-locked access level must be the default access level")
  assert(access.defaultLevelId ~= Navigator.Access.LOCKED,
    "locked access cannot be the default access level")
  for _, level in ipairs({ Navigator.Access.LOCKED, access.defaultLevelId }) do
    local definition = access.levels[level]
    assert(type(definition) == "table", "access.levels." .. level .. " is required")
    assert(type(definition.homePageId) == "string"
        and definition.homePageId ~= "",
      "access.levels." .. level .. ".homePageId must be a page ID")
  end
  for level, definition in pairs(access.levels) do
    validateAccessName("access.levels", level)
    assert(type(definition) == "table",
      "access.levels." .. level .. " must be a table")
    if level ~= Navigator.Access.LOCKED
        and level ~= access.defaultLevelId then
      assert(definition.homePageId == nil,
        "custom access levels do not define homePageId")
      for key in pairs(definition) do
        error("access.levels." .. level .. "." .. key
          .. " is not supported")
      end
    end
  end
  assert(type(access.keypadRequired) == "boolean",
    "access.keypadRequired must be true or false")
  if access.keypadRequired then
    assert(type(access.keypadPageId) == "string" and access.keypadPageId ~= "",
      "access.keypadPageId must be a page ID")
    assert(type(access.pinEntryTimeoutSeconds) == "number"
        and access.pinEntryTimeoutSeconds >= 0,
      "access.pinEntryTimeoutSeconds must be a number >= 0")
  else
    assert(access.keypadPageId == nil,
      "access.keypadPageId requires access.keypadRequired = true")
    assert(access.pinEntryTimeoutSeconds == nil,
      "access.pinEntryTimeoutSeconds requires access.keypadRequired = true")
  end
  assert(type(access.sessionTimeoutSeconds) == "number"
      and access.sessionTimeoutSeconds >= 0,
    "access.sessionTimeoutSeconds must be a number >= 0")
end

-- Builds lookup tables that make runtime navigation avoid config scans.
local function buildIndexes(candidate)
  indexes = {
    groupsById = {}, -- all group definitions by group id
    pagesById = {}, -- all page definitions by page id
    groupByPageId = {}, -- owning group for each page
    groupOwnerById = {}, -- owner id for each group
    groupsOwnedByOwnerId = {}, -- child groups owned by each owner
    pagesByGroupId = {}, -- direct pages in each group
    groupBehaviorById = {}, -- interlocked/independent behavior by group
    groupOwnerVisibilityById = {}, -- owner visibility policy by group
    groupDefaultPagesById = {}, -- default page list by group
    groupAncestorsById = {}, -- group-owner ancestor chain by group
    ownerKindByGroupId = {}, -- root/group/page owner type by group
  }

  for groupId, group in pairs(candidate.groups) do
    assert(groupId ~= ROOT_OWNER, "root is reserved")
    assert(not candidate.pages[groupId],
      groupId .. " is both a page id and a group id")
    assert(not candidate.regions or not candidate.regions[groupId],
      groupId .. " is used by more than one page, group, or region")
    indexes.groupsById[groupId] = group
  end
  for pageId, page in pairs(candidate.pages) do
    assert(pageId ~= ROOT_OWNER, "root is reserved")
    assert(not candidate.regions or not candidate.regions[pageId],
      pageId .. " is used by more than one page, group, or region")
    indexes.pagesById[pageId] = page
    indexes.groupByPageId[pageId] = page.group
    indexes.pagesByGroupId[page.group] =
      indexes.pagesByGroupId[page.group] or {}
    indexes.pagesByGroupId[page.group][pageId] = true
  end

  for groupId, group in pairs(candidate.groups) do
    local owner = group.owner
    indexes.groupOwnerById[groupId] = owner
    indexes.groupBehaviorById[groupId] = group.behavior
    indexes.groupOwnerVisibilityById[groupId] = group.ownerVisibility
    indexes.groupDefaultPagesById[groupId] = group.defaultPageIds or {}
    indexes.groupsOwnedByOwnerId[owner] = indexes.groupsOwnedByOwnerId[owner] or {}
    indexes.groupsOwnedByOwnerId[owner][groupId] = true
    if owner == ROOT_OWNER then
      indexes.ownerKindByGroupId[groupId] = "root"
    elseif candidate.groups[owner] then
      indexes.ownerKindByGroupId[groupId] = "group"
    elseif candidate.pages[owner] then
      indexes.ownerKindByGroupId[groupId] = "page"
    else
      error(groupId .. " has an unknown owner")
    end
  end

  local visiting = {} -- groups currently in the ancestor walk
  local visited = {} -- groups whose ancestors are already cached
  -- Computes ownership ancestors and detects cycles in group ownership.
  local function ancestorsFor(groupId)
    if visited[groupId] then return indexes.groupAncestorsById[groupId] end
    assert(not visiting[groupId], groupId .. " has an ownership cycle")
    visiting[groupId] = true
    local owner = indexes.groupOwnerById[groupId]
    local result = {}
    if indexes.ownerKindByGroupId[groupId] == "group" then
      local parentAncestors = ancestorsFor(owner)
      for _, ancestorId in ipairs(parentAncestors) do
        result[#result + 1] = ancestorId
      end
      result[#result + 1] = owner
    end
    indexes.groupAncestorsById[groupId] = result
    visiting[groupId] = nil
    visited[groupId] = true
    return result
  end
  for groupId in pairs(candidate.groups) do ancestorsFor(groupId) end
end

-- Validates the complete authoring model before Navigator accepts it.
local function validateConfig(candidate)
  assert(type(candidate.uci) == "table", "uci must be a table")
  assert(candidate.uci.pageName == nil
      or type(candidate.uci.pageName) == "string" and candidate.uci.pageName ~= "",
    "uci.pageName must be a non-empty string")
  assert(candidate.uci.transition == nil
      or type(candidate.uci.transition) == "string" and candidate.uci.transition ~= "",
    "uci.transition must be a non-empty string")
  assert(type(candidate.groups) == "table", "groups must be a table")
  assert(type(candidate.pages) == "table", "pages must be a table")

  validateAccess(candidate.access)
  normalizeConfig(candidate)

  for pageId, page in pairs(candidate.pages) do
    assert(type(pageId) == "string" and pageId ~= "", "page IDs must be strings")
    assert(type(page) == "table", pageId .. " page definition must be a table")
    assert(page.parentId == nil, pageId .. ".parentId is not supported")
    assert(page.childDisplayMode == nil,
      pageId .. ".childDisplayMode is not supported")
    assert(page.parentVisibility == nil,
      pageId .. ".parentVisibility is not supported")
    assert(page.defaultChildId == nil,
      pageId .. ".defaultChildId is not supported")
    assert(type(page.group) == "string" and page.group ~= "",
      pageId .. " requires group")
    assert(candidate.groups[page.group],
      pageId .. " has unknown group " .. tostring(page.group))
    validateViews(pageId, page.views, candidate.access.levels)
    validateRegionFills(pageId, page.regionFills,
      candidate.access.levels, candidate.regions)
    if page.controls then
      validateControls(pageId .. ".controls", page.controls, pageControlKeys)
    end
  end

  buildIndexes(candidate)
  validateRegions(candidate)

  for groupId, group in pairs(candidate.groups) do
    assert(type(groupId) == "string" and groupId ~= "",
      "group IDs must be strings")
    assert(type(group) == "table", groupId .. " group definition must be a table")
    assert(group.behavior == GROUP_INTERLOCKED
        or group.behavior == GROUP_INDEPENDENT,
      groupId .. " has invalid behavior")
    assert(type(group.owner) == "string" and group.owner ~= "",
      groupId .. " requires owner")
    local ownerKind = indexes.ownerKindByGroupId[groupId]
    if ownerKind == "page" then
      assert(group.ownerVisibility == OWNER_VISIBLE
          or group.ownerVisibility == OWNER_HIDDEN,
        groupId .. " page-owned groups require ownerVisibility")
    else
      assert(group.ownerVisibility == nil,
        groupId .. " ownerVisibility is only valid for page-owned groups")
    end
    if group.defaultPageIds then
      assert(type(group.defaultPageIds) == "table",
        groupId .. ".defaultPageIds must be a table")
      if group.behavior == GROUP_INTERLOCKED then
        assert(#group.defaultPageIds <= 1,
          groupId .. " interlocked groups may have at most one default")
      end
      for _, pageId in ipairs(group.defaultPageIds) do
        assert(candidate.pages[pageId],
          groupId .. " defaultPageIds contains unknown page " .. tostring(pageId))
        assert(candidate.pages[pageId].group == groupId,
          groupId .. " defaultPageIds must contain pages in the same group")
      end
    end
  end

  local lockedHome = candidate.access.levels[Navigator.Access.LOCKED].homePageId
  local defaultHome =
    candidate.access.levels[candidate.access.defaultLevelId].homePageId
  assert(candidate.pages[lockedHome], "locked home page is missing")
  assert(candidate.pages[defaultHome], "default home page is missing")
  candidate.access.lockedGroupId =
    candidate.access.lockedGroupId or candidate.pages[lockedHome].group
  candidate.access.unlockedGroupId =
    candidate.access.unlockedGroupId or candidate.pages[defaultHome].group
  assert(groupIsUnder(candidate.pages[lockedHome].group,
      candidate.access.lockedGroupId),
    "locked home page must be under access.lockedGroupId")
  assert(groupIsUnder(candidate.pages[defaultHome].group,
      candidate.access.unlockedGroupId),
    "default home page must be under access.unlockedGroupId")
  assert(candidate.pages[lockedHome].views[Navigator.Access.LOCKED],
    "locked home page requires locked view")

  if candidate.access.keypadRequired then
    local keypadPage = candidate.pages[candidate.access.keypadPageId]
    assert(keypadPage, "access.keypadPageId does not identify a page")
    assert(groupIsUnder(keypadPage.group, candidate.access.lockedGroupId),
      "keypad page must be under access.lockedGroupId")
    assert(keypadPage.views[Navigator.Access.LOCKED],
      "keypad page requires locked view")
  end

  if candidate.accessControls then
    validateControls("accessControls", candidate.accessControls, accessControlKeys)
    assert(candidate.accessControls.level, "accessControls.level is required")
    assert(not isControlList(candidate.accessControls.level),
      "accessControls.level must be a single control")
  end
  if candidate.historyControls then
    validateControls("historyControls", candidate.historyControls,
      historyControlKeys)
  end
  assert(candidate.historyMaxEntries == nil
      or candidate.historyMaxEntries == false
      or type(candidate.historyMaxEntries) == "number"
        and candidate.historyMaxEntries >= 1
        and candidate.historyMaxEntries % 1 == 0,
    "historyMaxEntries must be false or a positive integer")
  if candidate.logging then
    assert(type(candidate.logging) == "table", "logging must be a table")
    for key, enabled in pairs(candidate.logging) do
      assert(loggingKeys[key], "logging." .. tostring(key)
        .. " is not a supported category")
      assert(type(enabled) == "boolean", "logging." .. key .. " must be boolean")
    end
  end
end

-- Authoring compiler ---------------------------------------------------------

-- Copies public spec fields while dropping fields handled by the compiler.
local function clonePlainTable(source, skip)
  local result = {}
  for key, value in pairs(source or {}) do
    if not skip or not skip[key] then result[key] = value end
  end
  return result
end

-- Resolves a typed reference marker into its authored ID.
local function refId(value, expectedKind, context)
  assert(isMarker(value, MARKER_REF),
    context .. " must be a " .. expectedKind .. " reference")
  assert(value.kind == expectedKind,
    context .. " must be a " .. expectedKind .. " reference")
  return value.id
end

-- Resolves owner references, which may point to a group or a page.
local function resolveOwnerRef(value, context)
  assert(isMarker(value, MARKER_REF),
    context .. " must be a group or page reference")
  assert(value.kind == "group" or value.kind == "page",
    context .. " must be a group or page reference")
  return value.id
end

-- Resolves a page reference marker into its authored page ID.
local function resolvePageRef(value, context)
  return refId(value, "page", context)
end

-- Resolves authored control names through Q-SYS Controls while preserving objects.
local function compileControl(ownerId, value, manifestControls)
  if type(value) == "string" then
    if manifestControls then manifestControls[value] = true end
    assert(type(Controls) == "table",
      ownerId .. " control " .. value .. " requires Controls")
    local control = Controls[value]
    assert(control ~= nil, ownerId .. " references missing control " .. value)
    return control
  end
  if isControlList(value) then
    local result = {}
    for index, item in ipairs(value) do
      result[index] =
        compileControl(ownerId .. "[" .. index .. "]", item, manifestControls)
    end
    return result
  end
  return value
end

-- Compiles a page/global controls table and rejects unsupported control aliases.
local function compileControls(ownerId, controls, allowedKeys, manifestControls)
  if controls == nil then return nil end
  assert(type(controls) == "table", ownerId .. " controls must be a table")
  local compiled = {}
  for key, value in pairs(controls) do
    assert(allowedKeys[key], ownerId .. "." .. tostring(key)
      .. " is not a supported control")
    compiled[key] = compileControl(ownerId .. "." .. key, value, manifestControls)
  end
  return compiled
end

-- Adds a layer item or region fill into the compiled access-keyed content tables.
local function addContentItem(ownerId, access, item, views, fills)
  if type(item) == "string" then
    views[access] = views[access] or {}
    views[access][#views[access] + 1] = item
    return
  end
  if isMarker(item, MARKER_REGION_FILL) then
    local regionId = refId(item.region, "region", ownerId .. " region fill")
    fills[regionId] = fills[regionId] or {}
    assert(fills[regionId][access] == nil,
      ownerId .. " fills region " .. regionId .. " more than once for " .. access)
    local fillViews = {}
    local normalized = item.content
    if type(normalized) == "string" then normalized = { normalized } end
    assert(type(normalized) == "table" and normalized[1] ~= nil,
      ownerId .. " region fill content must be a layer name or layer list")
    for _, fillItem in ipairs(normalized) do
      assert(type(fillItem) == "string",
        ownerId .. " region fill content must contain only layer names")
      addContentItem(ownerId, access, fillItem, fillViews, {})
    end
    fills[regionId][access] = fillViews[access]
    return
  end
  error(ownerId .. " content contains an unsupported item")
end

-- Compiles authored content into page/region views plus per-page region fills.
local function compileContent(ownerId, content, defaultAccess)
  local views = {}
  local fills = {}
  if type(content) == "string" or isMarker(content, MARKER_REGION_FILL) then
    addContentItem(ownerId, defaultAccess, content, views, fills)
  else
    assert(type(content) == "table", ownerId .. " requires content")
    if content[1] ~= nil then
      for _, item in ipairs(content) do
        addContentItem(ownerId, defaultAccess, item, views, fills)
      end
    else
      for access, accessContent in pairs(content) do
        validateAccessName(ownerId, access)
        if type(accessContent) == "string"
            or isMarker(accessContent, MARKER_REGION_FILL) then
          addContentItem(ownerId, access, accessContent, views, fills)
        else
          assert(type(accessContent) == "table",
            ownerId .. "." .. access .. " content must be a layer or layer list")
          for _, item in ipairs(accessContent) do
            addContentItem(ownerId, access, item, views, fills)
          end
        end
      end
    end
  end
  return views, fills
end

-- Compiles authored access levels into the runtime access configuration.
local function compileAccess(authored)
  assert(type(authored) == "table", "access must be a table")
  local compiled = {
    levels = {},
    keypadRequired = false,
    sessionTimeoutSeconds = 0,
  }
  for accessId, definition in pairs(authored) do
    assert(type(accessId) == "string" and accessId ~= "",
      "access IDs must be strings")
    validateAccessName("access", accessId)
    assert(type(definition) == "table",
      "access." .. accessId .. " must be a table")
    local level = {}
    if definition.startAt then
      level.homePageId = resolvePageRef(definition.startAt,
        "access." .. accessId .. ".startAt")
    end
    compiled.levels[accessId] = level
    if definition.default == true then
      assert(compiled.defaultLevelId == nil,
        "only one access level can be default")
      compiled.defaultLevelId = accessId
    end
    if definition.keypad then
      assert(accessId == Navigator.Access.LOCKED,
        "only locked access can define keypad")
      compiled.keypadRequired = true
      compiled.keypadPageId = resolvePageRef(definition.keypad,
        "access." .. accessId .. ".keypad")
    end
    if definition.pinEntryTimeoutSeconds ~= nil then
      compiled.pinEntryTimeoutSeconds = definition.pinEntryTimeoutSeconds
    end
    if definition.sessionTimeoutSeconds ~= nil then
      compiled.sessionTimeoutSeconds = definition.sessionTimeoutSeconds
    end
  end
  assert(compiled.defaultLevelId ~= nil,
    "one non-locked access level must set default = true")
  if compiled.keypadRequired and compiled.pinEntryTimeoutSeconds == nil then
    compiled.pinEntryTimeoutSeconds = 0
  end
  return compiled
end

-- Compiles group ownership, mode, default page, and owner visibility.
local function compileGroupSpec(groupId, spec)
  assert(type(spec) == "table", groupId .. " group spec must be a table")
  local mode = spec.mode
  assert(isMarker(mode, MARKER_MODE), groupId .. " has invalid group mode")
  local compiled = {
    owner = resolveOwnerRef(spec.owner, groupId .. ".owner"),
    behavior = mode.value,
  }
  if spec.startAt then
    compiled.defaultPageIds = {
      resolvePageRef(spec.startAt, groupId .. ".startAt"),
    }
  end
  if spec.parentVisible ~= nil then
    assert(type(spec.parentVisible) == "boolean",
      groupId .. ".parentVisible must be boolean")
    compiled.ownerVisibility = spec.parentVisible
      and OWNER_VISIBLE
      or OWNER_HIDDEN
  end
  return compiled
end

-- Compiles one authored page into the runtime page representation.
local function compilePage(pageId, pageMarker, groupId, defaultAccess, manifestControls)
  local spec = pageMarker.spec
  assert(type(spec) == "table", pageId .. " page spec must be a table")
  local views, fills = compileContent(pageId, spec.content, defaultAccess)
  local compiled = clonePlainTable(spec, {
    content = true,
    controls = true,
  })
  compiled.id = pageId
  compiled.group = groupId
  compiled.views = views
  if next(fills) then compiled.regionFills = fills end
  compiled.controls = compileControls(pageId .. ".controls",
    spec.controls, pageControlKeys, manifestControls)
  return compiled
end

-- Compiles one authored region into the runtime region representation.
local function compileRegion(regionId, regionMarker, defaultAccess)
  local spec = regionMarker.spec
  assert(type(spec) == "table", regionId .. " region spec must be a table")
  local views, fills = compileContent(regionId, spec.content, defaultAccess)
  assert(next(fills) == nil, regionId .. " region content cannot fill regions")
  local compiled = clonePlainTable(spec, {
    content = true,
    owner = true,
  })
  compiled.id = regionId
  compiled.owner = resolveOwnerRef(spec.owner, regionId .. ".owner")
  compiled.views = views
  return compiled
end

-- Public compiler from authoring format into validated runtime configuration.
function Navigator.compile(project)
  assert(type(project) == "table", "compile requires a project table")
  local access = compileAccess(project.access or {})
  local defaultAccess = access.defaultLevelId
  local manifestControls = {}
  local compiled = {
    uci = clonePlainTable(project.uci or {}),
    logging = project.logging,
    access = access,
    accessControls = compileControls("accessControls",
      project.accessControls, accessControlKeys, manifestControls),
    historyControls = compileControls("historyControls",
      project.historyControls, historyControlKeys, manifestControls),
    historyMaxEntries = project.historyMaxEntries,
    groups = {},
    pages = {},
    regions = {},
  }

  -- First scan top-level authored group blocks so page ownership can target them.
  for key, value in pairs(project) do
    if isMarker(value, MARKER_GROUP) then
      assert(type(key) == "string" and key ~= "", "group IDs must be strings")
      assert(compiled.groups[key] == nil, "duplicate group ID " .. key)
      compiled.groups[key] = compileGroupSpec(key, value.spec)
      compiled.groups[key].id = key
    end
  end

  -- Then compile pages nested inside each authored group block.
  for groupId, groupMarker in pairs(project) do
    if isMarker(groupMarker, MARKER_GROUP) then
      for pageId, pageMarker in pairs(groupMarker.pages or {}) do
        assert(isMarker(pageMarker, MARKER_PAGE),
          groupId .. "." .. tostring(pageId) .. " must be page(...)")
        assert(compiled.pages[pageId] == nil,
          "duplicate page ID " .. tostring(pageId))
        compiled.pages[pageId] =
          compilePage(pageId, pageMarker, groupId, defaultAccess,
            manifestControls)
      end
    end
  end

  -- Regions are optional and live in their own top-level namespace.
  if project.regions ~= nil then
    assert(type(project.regions) == "table", "regions must be a table")
    for regionId, regionMarker in pairs(project.regions) do
      assert(isMarker(regionMarker, MARKER_REGION),
        "regions." .. tostring(regionId) .. " must be region(...)")
      assert(compiled.regions[regionId] == nil,
        "duplicate region ID " .. tostring(regionId))
      compiled.regions[regionId] =
        compileRegion(regionId, regionMarker, defaultAccess)
    end
  end

  compiled.manifest = {
    controls = manifestControls,
  }
  validateConfig(compiled)
  return compiled
end

-- Runtime installation and control binding ----------------------------------

-- Caches logging settings so disabled logging is cheap at runtime.
local function configureLogging()
  logging = config.logging or {}
  anyLoggingEnabled = false
  for _, enabled in pairs(logging) do
    if enabled then
      anyLoggingEnabled = true
      return
    end
  end
end

-- Returns sorted keys from a set-like table for stable diagnostic output.
local function sortedSetKeys(set)
  local keys = {}
  for key in pairs(set or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- Logs configured Q-SYS layer and control names when manifest logging is enabled.
local function logManifest()
  if not shouldLog("manifest") then return end

  log("manifest", "Q-SYS layers")
  for _, layerName in ipairs(sortedSetKeys(collectConfiguredLayers())) do
    log("manifest", "  layer: " .. layerName)
  end

  log("manifest", "Q-SYS controls")
  for _, controlName in ipairs(sortedSetKeys(config.manifest
      and config.manifest.controls)) do
    log("manifest", "  control: " .. controlName)
  end
end

-- Applies an external access level string to Navigator.
local function applyAccessLevelString(accessString)
  local targetAccess = string.lower(tostring(accessString or ""))
  if targetAccess == "" then return end
  if not config.access.levels[targetAccess] then
    if shouldLog("access") then log("access", "ignored unknown " .. targetAccess) end
    return
  end
  Navigator.setAccess(targetAccess)
end

-- Resets the external access level bridge before any startup navigation runs.
local function initializeAccessLevelControl()
  accessLevelControl = config.accessControls and config.accessControls.level
  if accessLevelControl then accessLevelControl.String = Navigator.Access.LOCKED end
end

-- Wires configured Q-SYS controls to navigator actions.
local function bindControls()
  local accessControls = config.accessControls
  if accessControls then
    accessLevelControl = accessControls.level
    accessLevelControl.EventHandler = function(control)
      applyAccessLevelString(control.String)
    end

    forEachControl(accessControls.change, function(control)
      control.EventHandler = function()
        if shouldLog("controls") then log("controls", "change access pressed") end
        if config.access.keypadRequired then
          if not isLockedAccess(state.access) then
            changeAccess(Navigator.Access.LOCKED)
          end
          Navigator.openPage(config.access.keypadPageId)
        else
          changeAccess(config.access.defaultLevelId)
        end
      end
    end)

    forEachControl(accessControls.lock, function(control)
      control.EventHandler = function()
        if shouldLog("controls") then log("controls", "lock pressed") end
        changeAccess(Navigator.Access.LOCKED)
      end
    end)

    forEachControl(accessControls.activityPulse, function(control)
      control.EventHandler = function()
        if shouldLog("controls") then log("controls", "activity pulse") end
        restartPinEntryTimer()
        restartSessionTimer()
      end
    end)
  end

  for pageId, page in pairs(config.pages) do
    local controls = page.controls
    if controls then
      forEachControl(controls.open, function(control)
        control.EventHandler = function()
          control.Boolean = true
          if shouldLog("controls") then log("controls", "open " .. pageId .. " pressed") end
          Navigator.openPage(pageId)
        end
      end)
      forEachControl(controls.close, function(control)
        control.EventHandler = function()
          if shouldLog("controls") then log("controls", "close " .. pageId .. " pressed") end
          Navigator.closePage(pageId)
        end
      end)
    end
  end

  local historyControls = config.historyControls
  if historyControls then
    forEachControl(historyControls.back, function(control)
      control.EventHandler = function()
        if shouldLog("controls") then log("controls", "history back pressed") end
        Navigator.back()
      end
    end)
    forEachControl(historyControls.forward, function(control)
      control.EventHandler = function()
        if shouldLog("controls") then log("controls", "history forward pressed") end
        Navigator.forward()
      end
    end)
  end
end

-- Initializes Navigator with a validated project model and locked home state.
function Navigator.apply(projectConfig)
  assert(not config, "Navigator may be applied only once")
  assert(type(projectConfig) == "table", "apply requires a config table")
  validateConfig(projectConfig)
  config = projectConfig
  initializeAccessLevelControl()
  configureLogging()
  logManifest()
  state.access = Navigator.Access.LOCKED
  state.activePageIds = {}
  state.activeGroupIds = {}
  visibleLayers = {}
  visibilityInitialized = false
  historyBack = {}
  historyForward = {}
  activatePage(accessHomePageId(Navigator.Access.LOCKED))
  updatePageOpenControls()
  reconcileVisibility()
  bindControls()
  updateHistoryControls()
end

-- Returns a copy of current navigation state for diagnostics and tests.
function Navigator.getState()
  return {
    access = state.access,
    activePageIds = copyTable(state.activePageIds),
    activeGroupIds = copyTable(state.activeGroupIds),
    canGoBack = #historyBack > 0,
    canGoForward = #historyForward > 0,
  }
end

-- Returns a copy of the last reconciled physical layer set.
function Navigator.getVisibleLayers()
  return copyTable(visibleLayers)
end

return Navigator
