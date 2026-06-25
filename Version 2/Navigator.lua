-- Navigator.lua
-- V2 ownership/group based navigation for a layer-based Q-SYS UCI.

local Navigator = {}

Navigator.Access = {
  LOCKED = "locked",
  DEFAULT = "default",
}

Navigator.GroupBehavior = {
  INTERLOCKED = "interlocked",
  INDEPENDENT = "independent",
}

Navigator.OwnerView = {
  KEEP = "keep",
  HIDE = "hide",
}

local ROOT_OWNER = "root"
local LOCKED_GROUP = "lockedGroup"
local UNLOCKED_GROUP = "unlockedGroup"

local config
local state = {
  access = Navigator.Access.LOCKED,
  activePageIds = {},
  activeGroupIds = {},
}

local indexes = {}
local visibleLayers = {}
local visibilityInitialized = false
local historyBack = {}
local historyForward = {}
local accessStateControl
local logging = {}
local anyLoggingEnabled = false

local function copyTable(source)
  local result = {}
  for key, value in pairs(source or {}) do
    result[key] = value
  end
  return result
end

local function copyStateSnapshot()
  return {
    activePageIds = copyTable(state.activePageIds),
    activeGroupIds = copyTable(state.activeGroupIds),
  }
end

local function sameSet(a, b)
  for key in pairs(a or {}) do
    if not b[key] then return false end
  end
  for key in pairs(b or {}) do
    if not a[key] then return false end
  end
  return true
end

local function sameSnapshot(a, b)
  return sameSet(a.activePageIds, b.activePageIds)
    and sameSet(a.activeGroupIds, b.activeGroupIds)
end

local function isControlList(value)
  return type(value) == "table" and value[1] ~= nil
end

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

local function shouldLog(category)
  return anyLoggingEnabled and logging[category] == true
end

local function log(category, message)
  print("Navigator " .. category .. ": " .. message)
end

local function isLockedAccess(access)
  return access == Navigator.Access.LOCKED
end

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

local function pageIsInLockedGroup(pageId)
  return groupIsUnder(indexes.pageGroupByPageId[pageId], LOCKED_GROUP)
end

local function effectiveAccessForPage(pageId)
  if pageIsInLockedGroup(pageId) then return Navigator.Access.LOCKED end
  return state.access
end

local function viewForAccess(page, access)
  return page.views[access]
    or (not isLockedAccess(access) and page.views[Navigator.Access.DEFAULT])
end

local function viewTableForAccess(views, access)
  return views[access]
    or (not isLockedAccess(access) and views[Navigator.Access.DEFAULT])
end

local function viewForPageId(pageId, access)
  local page = config.pages[pageId]
  return viewForAccess(page, access or effectiveAccessForPage(pageId))
end

local function addLayers(destination, layerNames)
  if not layerNames then return end
  for _, layerName in ipairs(layerNames) do
    destination[layerName] = true
  end
end

local function setLayerVisibility(layerName, isVisible)
  Uci.SetLayerVisibility(
    config.uci.pageName or "Main",
    layerName,
    isVisible,
    config.uci.transition or "none"
  )
end

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

local function pageDepth(pageId)
  local groupId = indexes.pageGroupByPageId[pageId]
  return #(indexes.groupAncestorsById[groupId] or {}) + 1
end

local function hiddenOwnerPageIds()
  local hidden = {}
  for groupId in pairs(state.activeGroupIds) do
    local group = config.pageGroups[groupId]
    if group and group.ownerView == Navigator.OwnerView.HIDE then
      local owner = indexes.groupOwnerById[groupId]
      if indexes.ownerKindByGroupId[groupId] == "page" then
        hidden[owner] = true
      end
    end
  end
  return hidden
end

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

local function cappedPush(stack, snapshot)
  stack[#stack + 1] = snapshot
  local maxEntries = config.historyMaxEntries
  if maxEntries == nil then maxEntries = 25 end
  if maxEntries == false then return end
  if #stack > maxEntries then table.remove(stack, 1) end
end

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

local function clearHistory()
  local hadHistory = #historyBack > 0 or #historyForward > 0
  historyBack = {}
  historyForward = {}
  updateHistoryControls()
  if hadHistory and shouldLog("history") then log("history", "cleared") end
end

local function recordHistory(before)
  cappedPush(historyBack, before)
  historyForward = {}
  updateHistoryControls()
  if shouldLog("history") then log("history", "recorded state") end
end

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

local function closeGroupsOwnedByPage(pageId)
  for groupId in pairs(indexes.groupsOwnedByOwnerId[pageId] or {}) do
    if state.activeGroupIds[groupId] then closeGroup(groupId) end
  end
end

local function closePageOnly(pageId)
  if not state.activePageIds[pageId] then return end
  closeGroupsOwnedByPage(pageId)
  state.activePageIds[pageId] = nil
end

local function groupHasActiveDirectMembers(groupId)
  for pageId in pairs(indexes.pagesByGroupId[groupId] or {}) do
    if state.activePageIds[pageId] then return true end
  end
  for childGroupId in pairs(indexes.groupsOwnedByOwnerId[groupId] or {}) do
    if state.activeGroupIds[childGroupId] then return true end
  end
  return false
end

local function ownerBehavior(ownerId)
  if ownerId == ROOT_OWNER then return Navigator.GroupBehavior.INTERLOCKED end
  local group = config.pageGroups[ownerId]
  if group then return group.behavior end
  return Navigator.GroupBehavior.INDEPENDENT
end

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

local function activateDefaultPageForGroup(groupId)
  local defaults = indexes.groupDefaultPagesById[groupId]
  if not defaults or #defaults == 0 then return false end
  for _, pageId in ipairs(defaults) do
    activatePage(pageId)
  end
  return true
end

local function restoreSnapshot(snapshot)
  state.activePageIds = copyTable(snapshot.activePageIds)
  state.activeGroupIds = copyTable(snapshot.activeGroupIds)
end

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

local function stopPinEntryTimer()
  if Navigator._pinEntryTimer then Navigator._pinEntryTimer:Stop() end
end

local function stopSessionTimer()
  if Navigator._sessionTimer then Navigator._sessionTimer:Stop() end
end

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

local function restartSessionTimer()
  if isLockedAccess(state.access)
      or config.access.sessionTimeoutSeconds == 0 then
    stopSessionTimer()
    return
  end
  sessionTimer():Start(config.access.sessionTimeoutSeconds)
end

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

local function openPageInternal(pageId, record)
  local before = copyStateSnapshot()
  if shouldLog("navigation") then log("navigation", "open " .. pageId) end
  activatePage(pageId)
  applyNavigationChange(before, record)
end

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

local function writeAccessState(targetAccess)
  if accessStateControl then accessStateControl.String = targetAccess end
end

local function requestAccess(targetAccess)
  writeAccessState(targetAccess)
  Navigator.setAccess(targetAccess)
end

local function accessHomePageId(access)
  if isLockedAccess(access) then
    return config.access.levels[Navigator.Access.LOCKED].homePageId
  end
  return config.access.levels[Navigator.Access.DEFAULT].homePageId
end

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

function Navigator.openPage(pageId)
  assert(config, "configure Navigator before navigating")
  openPageInternal(pageId, true)
end

function Navigator.closePage(pageId)
  assert(config, "configure Navigator before navigating")
  closePageInternal(pageId, true)
end

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

onPinEntryTimeout = function()
  if shouldLog("timeout") then log("timeout", "pin entry") end
  Navigator.closePage(config.access.keypadPageId)
end

onSessionTimeout = function()
  if shouldLog("timeout") then log("timeout", "session") end
  requestAccess(Navigator.Access.LOCKED)
end

local pageControlKeys = {
  open = true,
  close = true,
  openKeypad = true,
}

local accessControlKeys = {
  state = true,
  request = true,
  lock = true,
  activityPulse = true,
}

local historyControlKeys = {
  back = true,
  forward = true,
}

local loggingKeys = {
  access = true,
  navigation = true,
  history = true,
  keypad = true,
  timeout = true,
  controls = true,
}

local function validateAccessName(ownerId, access)
  assert(type(access) == "string" and access ~= "",
    ownerId .. " has an invalid access level")
  assert(access == string.lower(access),
    ownerId .. " access levels must be lowercase")
end

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

local function buildIndexes(candidate)
  indexes = {
    groupsById = {},
    pagesById = {},
    pageGroupByPageId = {},
    groupOwnerById = {},
    groupsOwnedByOwnerId = {},
    pagesByGroupId = {},
    groupBehaviorById = {},
    groupOwnerViewById = {},
    groupDefaultPagesById = {},
    groupAncestorsById = {},
    ownerKindByGroupId = {},
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
    indexes.groupOwnerViewById[groupId] = group.ownerView
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

  local visiting = {}
  local visited = {}
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

  validateAccess(candidate.access)
  validateFrameRoles(candidate)
  assert(candidate.pageGroups[LOCKED_GROUP], "lockedGroup is required")
  assert(candidate.pageGroups[UNLOCKED_GROUP], "unlockedGroup is required")

  for pageId, page in pairs(candidate.pages) do
    assert(type(pageId) == "string" and pageId ~= "", "page IDs must be strings")
    assert(type(page) == "table", pageId .. " page definition must be a table")
    assert(page.parentId == nil, pageId .. ".parentId is not supported in V2")
    assert(page.childDisplayMode == nil,
      pageId .. ".childDisplayMode is not supported in V2")
    assert(page.parentVisibility == nil,
      pageId .. ".parentVisibility is not supported in V2")
    assert(page.defaultChildId == nil,
      pageId .. ".defaultChildId is not supported in V2")
    assert(type(page.pageGroup) == "string" and page.pageGroup ~= "",
      pageId .. " requires pageGroup")
    assert(candidate.pageGroups[page.pageGroup],
      pageId .. " has unknown pageGroup " .. tostring(page.pageGroup))
    validateViews(pageId, page.views, candidate.access.levels)
    validateFrameOverrides(pageId, page.frameOverrides,
      candidate.access.levels, candidate.frameRoles)
    if page.controls then
      validateControls(pageId .. ".controls", page.controls, pageControlKeys)
      if not candidate.access.keypadRequired then
        assert(page.controls.openKeypad == nil,
          pageId .. ".controls.openKeypad requires access.keypadRequired = true")
      end
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
      assert(group.ownerView == Navigator.OwnerView.KEEP
          or group.ownerView == Navigator.OwnerView.HIDE,
        groupId .. " page-owned groups require ownerView")
    else
      assert(group.ownerView == nil,
        groupId .. " ownerView is only valid for page-owned groups")
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

local function applyAccessString(accessString)
  local targetAccess = string.lower(tostring(accessString or ""))
  if targetAccess == "" then return end
  if not config.access.levels[targetAccess] then
    if shouldLog("access") then log("access", "ignored unknown " .. targetAccess) end
    return
  end
  Navigator.setAccess(targetAccess)
end

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
      forEachControl(controls.openKeypad, function(control)
        control.EventHandler = function()
          if shouldLog("controls") then log("controls", "open keypad pressed") end
          Navigator.openPage(config.access.keypadPageId)
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

function Navigator.getState()
  return {
    access = state.access,
    activePageIds = copyTable(state.activePageIds),
    activeGroupIds = copyTable(state.activeGroupIds),
    canGoBack = #historyBack > 0,
    canGoForward = #historyForward > 0,
  }
end

function Navigator.getVisibleLayers()
  return copyTable(visibleLayers)
end

return Navigator
