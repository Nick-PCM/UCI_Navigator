-- Navigator.lua
-- Ownership/group based navigation for a layer-based Q-SYS UCI.

local Navigator = {} -- public module table returned to the project script

Navigator.Access = { -- built-in access names
  LOCKED = "locked", -- locked/splash/keypad access
  DEFAULT = "default", -- normal unlocked fallback access
}

Navigator.GroupBehavior = { -- how direct group members coexist
  INTERLOCKED = "interlocked", -- one direct member active at a time
  INDEPENDENT = "independent", -- multiple direct members may be active
}

Navigator.OwnerVisibility = { -- page-owned group owner view policy
  VISIBLE = "visible", -- keep owner page layer visible
  HIDDEN = "hidden", -- suppress owner page layer while group is active
}

local ROOT_OWNER = "root" -- implicit top-level interlocked owner
local LOCKED_GROUP = "lockedGroup" -- required group for locked pages
local UNLOCKED_GROUP = "unlockedGroup" -- required group for unlocked pages

local config -- validated project configuration
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
local accessStateControl -- Q-SYS control mirroring active access
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
  return groupIsUnder(indexes.pageGroupByPageId[pageId], LOCKED_GROUP)
end

-- Chooses the access level a page should use for its view lookup.
local function effectiveAccessForPage(pageId)
  if pageIsInLockedGroup(pageId) then return Navigator.Access.LOCKED end
  return state.access
end

-- Resolves a page view with default fallback for unlocked access levels.
local function viewForAccess(page, access)
  return page.views[access]
    or (not isLockedAccess(access) and page.views[Navigator.Access.DEFAULT])
end

-- Resolves an access-keyed layer table, used by frame overrides.
local function viewTableForAccess(views, access)
  return views[access]
    or (not isLockedAccess(access) and views[Navigator.Access.DEFAULT])
end

-- Resolves the concrete layer list for a page in the current or supplied access.
local function viewForPageId(pageId, access)
  local page = config.pages[pageId]
  return viewForAccess(page, access or effectiveAccessForPage(pageId))
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
  for _, page in pairs(config.pages) do
    for _, layerNames in pairs(page.views) do
      addLayers(layers, layerNames)
    end
    for _, roleViews in pairs(page.frameOverrides or {}) do
      for _, layerNames in pairs(roleViews) do
        addLayers(layers, layerNames)
      end
    end
  end
  return layers
end

-- Calculates page nesting depth for frame override precedence.
local function pageDepth(pageId)
  local groupId = indexes.pageGroupByPageId[pageId]
  return #(indexes.groupAncestorsById[groupId] or {}) + 1
end

-- Finds active owner pages whose own view is suppressed by owned groups.
local function hiddenOwnerPageIds()
  local hidden = {}
  for groupId in pairs(state.activeGroupIds) do
    local group = config.pageGroups[groupId]
    if group and group.ownerVisibility == Navigator.OwnerVisibility.HIDDEN then
      local owner = indexes.groupOwnerById[groupId]
      if indexes.ownerKindByGroupId[groupId] == "page" then
        hidden[owner] = true
      end
    end
  end
  return hidden
end

-- Selects the active frame override for each role, preferring deeper pages.
local function selectedFrameOverrides()
  local selected = {}
  for pageId in pairs(state.activePageIds) do
    local page = config.pages[pageId]
    for role, roleViews in pairs(page.frameOverrides or {}) do
      local view = viewTableForAccess(roleViews, effectiveAccessForPage(pageId))
      if view then
        local depth = pageDepth(pageId)
        local current = selected[role]
        assert(not current or current.depth ~= depth,
          "multiple active frame overrides for " .. role)
        if not current or depth > current.depth then
          selected[role] = {
            pageId = pageId,
            depth = depth,
            view = view,
          }
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
  local frameOverrides = selectedFrameOverrides()
  local hiddenFramePageIds = {}

  for role in pairs(frameOverrides) do
    local framePageId = config.frameRoles and config.frameRoles[role]
    if framePageId then hiddenFramePageIds[framePageId] = true end
  end

  for pageId in pairs(state.activePageIds) do
    if not hidden[pageId] and not hiddenFramePageIds[pageId] then
      local view = viewForPageId(pageId)
      assert(view, pageId .. " is active but unavailable")
      addLayers(desired, view)
    end
  end
  for _, override in pairs(frameOverrides) do
    addLayers(desired, override.view)
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
        and indexes.pageGroupByPageId[pageId] == groupId then
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
  if ownerId == ROOT_OWNER then return Navigator.GroupBehavior.INTERLOCKED end
  local group = config.pageGroups[ownerId]
  if group then return group.behavior end
  return Navigator.GroupBehavior.INDEPENDENT
end

-- Enforces interlock by closing active siblings under the same owner.
local function closeOtherDirectMembers(ownerId, keepKind, keepId)
  if ownerBehavior(ownerId) ~= Navigator.GroupBehavior.INTERLOCKED then return end

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

  local groupId = indexes.pageGroupByPageId[pageId]
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
  local groupId = indexes.pageGroupByPageId[pageId]
  local group = config.pageGroups[groupId]
  local defaults = indexes.groupDefaultPagesById[groupId] or {}
  local isDefault = false
  for _, defaultPageId in ipairs(defaults) do
    if defaultPageId == pageId then
      isDefault = true
      break
    end
  end

  if group.behavior == Navigator.GroupBehavior.INTERLOCKED
      and isDefault then
    updateHistoryControls()
    return
  end

  closePageOnly(pageId)
  if group.behavior == Navigator.GroupBehavior.INTERLOCKED
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

-- Mirrors navigator access into the configured Q-SYS access state control.
local function writeAccessState(targetAccess)
  if accessStateControl then accessStateControl.String = targetAccess end
end

-- Changes access through the same path used by user-facing controls.
local function requestAccess(targetAccess)
  writeAccessState(targetAccess)
  Navigator.setAccess(targetAccess)
end

-- Returns the configured home page for locked or unlocked entry.
local function accessHomePageId(access)
  if isLockedAccess(access) then
    return config.access.levels[Navigator.Access.LOCKED].homePageId
  end
  return config.access.levels[Navigator.Access.DEFAULT].homePageId
end

-- Moves the navigator across access boundaries and resets state as needed.
function Navigator.setAccess(targetAccess)
  assert(config, "configure Navigator before changing access")
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
    if not state.activeGroupIds[UNLOCKED_GROUP] then
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
  assert(config, "configure Navigator before navigating")
  openPageInternal(pageId, true)
end

-- Public API for closing a page and recording history.
function Navigator.closePage(pageId)
  assert(config, "configure Navigator before navigating")
  closePageInternal(pageId, true)
end

-- Restores the previous page/group snapshot from navigation history.
function Navigator.back()
  assert(config, "configure Navigator before navigating")
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
  assert(config, "configure Navigator before navigating")
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
  Navigator.closePage(config.access.keypadPageId)
end

-- Handles unlocked session expiry by returning to locked access.
onSessionTimeout = function()
  if shouldLog("timeout") then log("timeout", "session") end
  requestAccess(Navigator.Access.LOCKED)
end

-- Supported per-page control aliases.
local pageControlKeys = {
  open = true,
  close = true,
}

-- Supported global access control aliases.
local accessControlKeys = {
  state = true,
  request = true,
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
  defaultAccess = defaultAccess or Navigator.Access.DEFAULT
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
  candidate.uci.transition = candidate.uci.transition or "none"
  for pageId, page in pairs(candidate.pages) do
    page.views = normalizeViews(pageId, page.views)
    if page.overrides ~= nil then
      assert(page.frameOverrides == nil,
        pageId .. " cannot define both overrides and frameOverrides")
      page.frameOverrides = page.overrides
      page.overrides = nil
    end
    if page.frameOverrides then
      assert(type(page.frameOverrides) == "table",
        pageId .. ".overrides must be a table")
      for role, roleViews in pairs(page.frameOverrides) do
        page.frameOverrides[role] =
          normalizeViews(pageId .. ".frameOverrides." .. role, roleViews)
      end
    end
  end
end

-- Validates that a page or override has usable access-keyed layer lists.
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

-- Validates named frame roles before pages can override them.
local function validateFrameRoles(candidate)
  if candidate.frameRoles == nil then return end
  assert(type(candidate.frameRoles) == "table", "frameRoles must be a table")
  for role, pageId in pairs(candidate.frameRoles) do
    assert(type(role) == "string" and role ~= "",
      "frameRoles contains an invalid role")
    assert(type(pageId) == "string" and pageId ~= "",
      "frameRoles." .. role .. " must be a page ID")
    assert(candidate.pages[pageId],
      "frameRoles." .. role .. " identifies unknown page " .. tostring(pageId))
  end
end

-- Validates per-page frame replacement layers.
local function validateFrameOverrides(pageId, frameOverrides, levels, frameRoles)
  if frameOverrides == nil then return end
  assert(type(frameOverrides) == "table",
    pageId .. ".frameOverrides must be a table")
  assert(type(frameRoles) == "table",
    pageId .. ".frameOverrides requires frameRoles")
  for role, roleViews in pairs(frameOverrides) do
    assert(frameRoles[role],
      pageId .. ".frameOverrides has unknown role " .. tostring(role))
    validateViews(pageId .. ".frameOverrides." .. role, roleViews, levels)
  end
end

-- Validates access levels, keypad requirements, and timeout settings.
local function validateAccess(access)
  assert(type(access) == "table", "access must be a table")
  assert(type(access.levels) == "table", "access.levels must be a table")
  for _, level in ipairs({ Navigator.Access.LOCKED, Navigator.Access.DEFAULT }) do
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
        and level ~= Navigator.Access.DEFAULT then
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
    pageGroupByPageId = {}, -- owning group for each page
    groupOwnerById = {}, -- owner id for each group
    groupsOwnedByOwnerId = {}, -- child groups owned by each owner
    pagesByGroupId = {}, -- direct pages in each group
    groupBehaviorById = {}, -- interlocked/independent behavior by group
    groupOwnerVisibilityById = {}, -- owner visibility policy by group
    groupDefaultPagesById = {}, -- default page list by group
    groupAncestorsById = {}, -- group-owner ancestor chain by group
    ownerKindByGroupId = {}, -- root/group/page owner type by group
  }

  for groupId, group in pairs(candidate.pageGroups) do
    assert(groupId ~= ROOT_OWNER, "root is reserved")
    assert(not candidate.pages[groupId],
      groupId .. " is both a page id and a group id")
    indexes.groupsById[groupId] = group
  end
  for pageId, page in pairs(candidate.pages) do
    assert(pageId ~= ROOT_OWNER, "root is reserved")
    indexes.pagesById[pageId] = page
    indexes.pageGroupByPageId[pageId] = page.pageGroup
    indexes.pagesByGroupId[page.pageGroup] =
      indexes.pagesByGroupId[page.pageGroup] or {}
    indexes.pagesByGroupId[page.pageGroup][pageId] = true
  end

  for groupId, group in pairs(candidate.pageGroups) do
    local owner = group.owner
    indexes.groupOwnerById[groupId] = owner
    indexes.groupBehaviorById[groupId] = group.behavior
    indexes.groupOwnerVisibilityById[groupId] = group.ownerVisibility
    indexes.groupDefaultPagesById[groupId] = group.defaultPageIds or {}
    indexes.groupsOwnedByOwnerId[owner] = indexes.groupsOwnedByOwnerId[owner] or {}
    indexes.groupsOwnedByOwnerId[owner][groupId] = true
    if owner == ROOT_OWNER then
      indexes.ownerKindByGroupId[groupId] = "root"
    elseif candidate.pageGroups[owner] then
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
  for groupId in pairs(candidate.pageGroups) do ancestorsFor(groupId) end
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
  assert(type(candidate.pageGroups) == "table", "pageGroups must be a table")
  assert(type(candidate.pages) == "table", "pages must be a table")
  normalizeConfig(candidate)

  validateAccess(candidate.access)
  validateFrameRoles(candidate)
  assert(candidate.pageGroups[LOCKED_GROUP], "lockedGroup is required")
  assert(candidate.pageGroups[UNLOCKED_GROUP], "unlockedGroup is required")

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
    assert(type(page.pageGroup) == "string" and page.pageGroup ~= "",
      pageId .. " requires pageGroup")
    assert(candidate.pageGroups[page.pageGroup],
      pageId .. " has unknown pageGroup " .. tostring(page.pageGroup))
    validateViews(pageId, page.views, candidate.access.levels)
    validateFrameOverrides(pageId, page.frameOverrides,
      candidate.access.levels, candidate.frameRoles)
    if page.controls then
      validateControls(pageId .. ".controls", page.controls, pageControlKeys)
    end
  end

  buildIndexes(candidate)

  for groupId, group in pairs(candidate.pageGroups) do
    assert(type(groupId) == "string" and groupId ~= "",
      "group IDs must be strings")
    assert(type(group) == "table", groupId .. " group definition must be a table")
    assert(group.behavior == Navigator.GroupBehavior.INTERLOCKED
        or group.behavior == Navigator.GroupBehavior.INDEPENDENT,
      groupId .. " has invalid behavior")
    assert(type(group.owner) == "string" and group.owner ~= "",
      groupId .. " requires owner")
    local ownerKind = indexes.ownerKindByGroupId[groupId]
    if ownerKind == "page" then
      assert(group.ownerVisibility == Navigator.OwnerVisibility.VISIBLE
          or group.ownerVisibility == Navigator.OwnerVisibility.HIDDEN,
        groupId .. " page-owned groups require ownerVisibility")
    else
      assert(group.ownerVisibility == nil,
        groupId .. " ownerVisibility is only valid for page-owned groups")
    end
    if group.defaultPageIds then
      assert(type(group.defaultPageIds) == "table",
        groupId .. ".defaultPageIds must be a table")
      if group.behavior == Navigator.GroupBehavior.INTERLOCKED then
        assert(#group.defaultPageIds <= 1,
          groupId .. " interlocked groups may have at most one default")
      end
      for _, pageId in ipairs(group.defaultPageIds) do
        assert(candidate.pages[pageId],
          groupId .. " defaultPageIds contains unknown page " .. tostring(pageId))
        assert(candidate.pages[pageId].pageGroup == groupId,
          groupId .. " defaultPageIds must contain pages in the same group")
      end
    end
  end

  local lockedHome = candidate.access.levels[Navigator.Access.LOCKED].homePageId
  local defaultHome = candidate.access.levels[Navigator.Access.DEFAULT].homePageId
  assert(candidate.pages[lockedHome], "locked home page is missing")
  assert(candidate.pages[defaultHome], "default home page is missing")
  assert(groupIsUnder(candidate.pages[lockedHome].pageGroup, LOCKED_GROUP),
    "locked home page must be in lockedGroup")
  assert(groupIsUnder(candidate.pages[defaultHome].pageGroup, UNLOCKED_GROUP),
    "default home page must be under unlockedGroup")
  assert(candidate.pages[lockedHome].views[Navigator.Access.LOCKED],
    "locked home page requires locked view")

  if candidate.access.keypadRequired then
    local keypadPage = candidate.pages[candidate.access.keypadPageId]
    assert(keypadPage, "access.keypadPageId does not identify a page")
    assert(groupIsUnder(keypadPage.pageGroup, LOCKED_GROUP),
      "keypad page must be in lockedGroup")
    assert(keypadPage.views[Navigator.Access.LOCKED],
      "keypad page requires locked view")
  end

  if candidate.accessControls then
    validateControls("accessControls", candidate.accessControls, accessControlKeys)
    assert(candidate.accessControls.state, "accessControls.state is required")
    assert(not isControlList(candidate.accessControls.state),
      "accessControls.state must be a single control")
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

-- Applies an access state control string as a navigator access request.
local function applyAccessString(accessString)
  local targetAccess = string.lower(tostring(accessString or ""))
  if targetAccess == "" then return end
  if not config.access.levels[targetAccess] then
    if shouldLog("access") then log("access", "ignored unknown " .. targetAccess) end
    return
  end
  Navigator.setAccess(targetAccess)
end

-- Wires configured Q-SYS controls to navigator actions.
local function bindControls()
  local accessControls = config.accessControls
  if accessControls then
    accessStateControl = accessControls.state
    accessStateControl.EventHandler = function(control)
      applyAccessString(control.String)
    end

    forEachControl(accessControls.request, function(control)
      control.EventHandler = function()
        if shouldLog("controls") then log("controls", "access request pressed") end
        if isLockedAccess(state.access) and config.access.keypadRequired then
          Navigator.openPage(config.access.keypadPageId)
        elseif isLockedAccess(state.access) then
          requestAccess(Navigator.Access.DEFAULT)
        elseif not isLockedAccess(state.access) then
          requestAccess(Navigator.Access.DEFAULT)
        end
      end
    end)

    forEachControl(accessControls.lock, function(control)
      control.EventHandler = function()
        if shouldLog("controls") then log("controls", "lock pressed") end
        requestAccess(Navigator.Access.LOCKED)
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
function Navigator.configure(projectConfig)
  assert(not config, "Navigator may be configured only once")
  assert(type(projectConfig) == "table", "configure requires a config table")
  validateConfig(projectConfig)
  config = projectConfig
  configureLogging()
  state.access = Navigator.Access.LOCKED
  state.activePageIds = {}
  state.activeGroupIds = {}
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
