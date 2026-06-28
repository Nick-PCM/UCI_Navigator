-- Navigator.lua
-- Flat ownership-based navigation for a layer-based Q-SYS UCI.

local Navigator = {} -- public module table returned to the project script

local ACCESS_LOCKED  = "locked" -- locked/splash/keypad access
local GROUP_SWITCH = "switch" -- one direct member active at a time
local GROUP_STACK  = "stack" -- multiple direct members may be active
local ROOT_OWNER     = "root" -- implicit top-level switch owner

-- Authoring helpers ----------------------------------------------------------

-- Authoring constructor for a navigation group.
function Navigator.group(spec)
  assert(type(spec) == "table", "group requires a table")
  spec.__kind = "group"
  return spec
end

-- Authoring constructor for a navigable page.
function Navigator.page(spec)
  assert(type(spec) == "table", "page requires a table")
  spec.__kind = "page"
  return spec
end

-- Runtime state --------------------------------------------------------------

local config -- validated project configuration

-- Mutable runtime navigation state: current access plus active pages and groups.
local state = {
  access = ACCESS_LOCKED,
  activePageIds = {},
  activeGroupIds = {},
}

local indexes              = {} -- derived lookup tables built from config
local visibleLayers        = {} -- last applied physical layer set
local visibilityInitialized = false -- whether first visibility pass has run
local uciPageName = "Main"
local uciTransition = "none"
local historyBack          = {} -- back navigation snapshot stack
local historyForward       = {} -- forward navigation snapshot stack
local historyMaxEntries = 25
local accessLevelControl -- Q-SYS control mirroring active access
local pinEntryTimerObject -- private Q-SYS timer used while keypad is open
local sessionTimerObject -- private Q-SYS timer used while unlocked
local logging              = {} -- enabled log categories
local anyLoggingEnabled    = false -- fast skip when all logging is off
local manifestControlNames = {} -- diagnostic control names collected during normalization

-- Utilities ------------------------------------------------------------------

-- Copies a set-like table so callers cannot mutate navigator state by reference.
local function copyTable(source)
  local result = {}
  for k, v in pairs(source) do result[k] = v end
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
  for k in pairs(a) do if not b[k] then return false end end
  for k in pairs(b) do if not a[k] then return false end end
  return true
end

-- Compares a saved snapshot to the current active page/group state.
local function snapshotMatchesCurrent(snapshot)
  return sameSet(snapshot.activePageIds, state.activePageIds)
     and sameSet(snapshot.activeGroupIds, state.activeGroupIds)
end

-- Distinguishes a multi-control alias list from a single Q-SYS control object.
local function isControlList(value)
  return type(value) == "table" and value[1] ~= nil
end

-- Applies wiring or state updates to an optional single control or control list.
local function forEachControl(controlOrList, callback)
  if controlOrList == nil then return end
  if isControlList(controlOrList) then
    for _, control in ipairs(controlOrList) do callback(control) end
  else
    callback(controlOrList)
  end
end

-- Writes Boolean to an optional control or control list without callback churn.
local function setControlBoolean(controlOrList, value)
  if controlOrList == nil then return end
  if isControlList(controlOrList) then
    for _, control in ipairs(controlOrList) do control.Boolean = value end
  else
    controlOrList.Boolean = value
  end
end

-- Writes IsDisabled to an optional control or control list.
local function setControlDisabled(controlOrList, value)
  if controlOrList == nil then return end
  if isControlList(controlOrList) then
    for _, control in ipairs(controlOrList) do control.IsDisabled = value end
  else
    controlOrList.IsDisabled = value
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

-- Index helpers --------------------------------------------------------------

-- Tests whether a group lives under another group in the ownership tree.
local function groupIsUnder(groupId, ancestorGroupId, groups)
  local current = groupId
  while current do
    if current == ancestorGroupId then return true end
    local group = groups[current]
    if not group or group.owner == ROOT_OWNER then return false end
    current = group.owner
  end
  return false
end

-- Chooses the access level a page should use for its view lookup.
local function effectiveAccessForPage(pageId)
  if config.pages[pageId].lockedView then return ACCESS_LOCKED end
  return state.access
end

-- Resolves an access-keyed layer table.
local function viewTableForAccess(views, access)
  return views[access]
    or (access ~= ACCESS_LOCKED and views[config.access.defaultLevelId])
end

-- Resolves the concrete layer list for a page in the current or supplied access.
local function viewForPageId(pageId, access)
  local page = config.pages[pageId]
  return viewTableForAccess(page.views, access or effectiveAccessForPage(pageId))
end

-- Visibility -----------------------------------------------------------------

-- Adds layer names into the desired visibility set.
local function addLayers(dest, layerNames)
  for _, name in ipairs(layerNames) do dest[name] = true end
end

-- Sends one physical layer visibility change to Q-SYS.
local function setLayerVisibility(layerName, isVisible)
  local diagnose = shouldLog("qsys")
  if not diagnose then
    Uci.SetLayerVisibility(
      uciPageName,
      layerName,
      isVisible,
      uciTransition
    )
    return
  end
  local ok, err = pcall(Uci.SetLayerVisibility,
    uciPageName,
    layerName,
    isVisible,
    uciTransition
  )
  if ok then return end
  local message = "UCI layer visibility failed: page="
    .. tostring(uciPageName)
    .. ", layer=" .. tostring(layerName)
    .. ", visible=" .. tostring(isVisible)
    .. ", error=" .. tostring(err)
  log("qsys", message)
  error(message, 0)
end

-- Converts active navigator state into the full desired layer set.
local function resolveDesiredLayers()
  local desired = {}
  for pageId in pairs(state.activePageIds) do
    local view = viewForPageId(pageId)
    assert(view, pageId .. " is active but unavailable")
    addLayers(desired, view)
  end
  return desired
end

-- Diffs desired layers against current layers and applies Q-SYS changes.
local function reconcileVisibility()
  local desired      = resolveDesiredLayers()
  local layersToCheck = visibilityInitialized
    and visibleLayers or indexes.configuredLayers
  for name in pairs(layersToCheck) do
    if not desired[name] then setLayerVisibility(name, false) end
  end
  for name in pairs(desired) do
    if not visibleLayers[name] then setLayerVisibility(name, true) end
  end
  visibleLayers        = desired
  visibilityInitialized = true
end

-- History --------------------------------------------------------------------

-- Pushes a history snapshot while respecting the configured history cap.
local function cappedPush(stack, snapshot)
  stack[#stack + 1] = snapshot
  if historyMaxEntries ~= false and #stack > historyMaxEntries then
    table.remove(stack, 1)
  end
end

-- Keeps optional history controls disabled when their stack is empty.
local function updateHistoryControls()
  local controls = config and config.historyControls
  if not controls then return end
  setControlDisabled(controls.back, #historyBack == 0)
  setControlDisabled(controls.forward, #historyForward == 0)
end

-- Clears both history stacks when navigation crosses an access boundary.
local function clearHistory()
  local had = #historyBack > 0 or #historyForward > 0
  historyBack    = {}
  historyForward = {}
  updateHistoryControls()
  if had and shouldLog("history") then log("history", "cleared") end
end

-- Records the previous state after navigation changes state.
local function recordHistory(before)
  cappedPush(historyBack, before)
  historyForward = {}
  updateHistoryControls()
  if shouldLog("history") then log("history", "recorded state") end
end

-- Navigation engine ----------------------------------------------------------

local activatePage
local activateGroup
local activateOpenMembersForGroup

-- Determines how an owner's direct groups/pages switch or stack.
local function ownerBehavior(ownerId)
  if ownerId == ROOT_OWNER then return GROUP_SWITCH end
  return config.groups[ownerId].behavior
end

-- Closes a group, its active pages, and any active groups it owns.
local function closeGroup(groupId)
  for pageId in pairs(indexes.pagesByGroupId[groupId]) do
    if state.activePageIds[pageId] then
      state.activePageIds[pageId] = nil
    end
  end
  for ownedGroupId in pairs(indexes.groupsOwnedByOwnerId[groupId]) do
    if state.activeGroupIds[ownedGroupId] then closeGroup(ownedGroupId) end
  end
  state.activeGroupIds[groupId] = nil
end

-- Removes one active page without applying owner open policy.
local function closeActivePage(pageId)
  if not state.activePageIds[pageId] then return end
  state.activePageIds[pageId] = nil
end

-- Checks whether a group still has directly active pages or owned groups.
local function groupHasActiveDirectMembers(groupId)
  for pageId in pairs(indexes.pagesByGroupId[groupId]) do
    if state.activePageIds[pageId] then return true end
  end
  for ownedGroupId in pairs(indexes.groupsOwnedByOwnerId[groupId]) do
    if state.activeGroupIds[ownedGroupId] then return true end
  end
  return false
end

-- Enforces switch behavior by closing active siblings under the same owner.
local function closeOtherDirectMembers(ownerId, keepKind, keepId)
  if ownerBehavior(ownerId) ~= GROUP_SWITCH then return end
  for groupId in pairs(indexes.groupsOwnedByOwnerId[ownerId]) do
    if not (keepKind == "group" and keepId == groupId)
        and state.activeGroupIds[groupId] then
      closeGroup(groupId)
    end
  end
  if config.groups[ownerId] then
    for pageId in pairs(indexes.pagesByGroupId[ownerId]) do
      if not (keepKind == "page" and keepId == pageId)
          and state.activePageIds[pageId] then
        closeActivePage(pageId)
      end
    end
  end
end

-- Activates a group, its owning chain, and its configured open members.
activateGroup = function(groupId)
  if state.activeGroupIds[groupId] then return end
  local group = config.groups[groupId]
  local owner = group.owner
  if owner ~= ROOT_OWNER then
    activateGroup(owner)
  end
  closeOtherDirectMembers(owner, "group", groupId)
  state.activeGroupIds[groupId] = true
  activateOpenMembersForGroup(groupId)
end

-- Opens a page after activating its owner group chain.
activatePage = function(pageId)
  local page = config.pages[pageId]
  assert(page, "unknown pageId: " .. tostring(pageId))
  assert(viewForPageId(pageId), pageId .. " unavailable at " .. state.access)
  local groupId = page.owner
  activateGroup(groupId)
  closeOtherDirectMembers(groupId, "page", pageId)
  state.activePageIds[pageId] = true
end

-- Opens the configured open member or members for a group.
activateOpenMembersForGroup = function(groupId)
  local openIds = config.groups[groupId].openIds
  if #openIds == 0 then return end
  for _, memberId in ipairs(openIds) do
    if config.pages[memberId] then
      activatePage(memberId)
    else
      activateGroup(memberId)
    end
  end
end

-- Restores a previously captured page/group state for history navigation.
local function restoreSnapshot(snapshot)
  state.activePageIds = copyTable(snapshot.activePageIds)
  state.activeGroupIds = copyTable(snapshot.activeGroupIds)
end

local function isActiveIn(pageIds, groupIds, id)
  return pageIds[id] == true or groupIds[id] == true
end

local function updateOpenControls(before)
  if not before then
    for id, controls in pairs(indexes.openControlsById) do
      setControlBoolean(controls,
        isActiveIn(state.activePageIds, state.activeGroupIds, id))
    end
    return
  end

  local seen = {}
  local function updateChanged(ids)
    for id in pairs(ids) do
      if not seen[id] then
        seen[id] = true
        local active = isActiveIn(state.activePageIds, state.activeGroupIds, id)
        if active ~= isActiveIn(before.activePageIds, before.activeGroupIds, id) then
          setControlBoolean(indexes.openControlsById[id], active)
        end
      end
    end
  end

  updateChanged(before.activePageIds)
  updateChanged(before.activeGroupIds)
  updateChanged(state.activePageIds)
  updateChanged(state.activeGroupIds)
end

-- Timers ---------------------------------------------------------------------

local onPinEntryTimeout
local onSessionTimeout

-- Lazily creates the Q-SYS timer used while the keypad is open.
local function pinEntryTimer()
  if not pinEntryTimerObject then
    pinEntryTimerObject = Timer.New()
    pinEntryTimerObject.EventHandler = function(t)
      t:Stop(); onPinEntryTimeout()
    end
  end
  return pinEntryTimerObject
end

-- Lazily creates the Q-SYS timer used for unlocked-session expiry.
local function sessionTimer()
  if not sessionTimerObject then
    sessionTimerObject = Timer.New()
    sessionTimerObject.EventHandler = function(t)
      t:Stop(); onSessionTimeout()
    end
  end
  return sessionTimerObject
end

-- Stops keypad entry timing when keypad is closed or disabled.
local function stopPinEntryTimer()
  if pinEntryTimerObject then pinEntryTimerObject:Stop() end
end

-- Stops session timing when locked or before resetting access.
local function stopSessionTimer()
  if sessionTimerObject then sessionTimerObject:Stop() end
end

-- Starts or stops keypad timing based on whether the keypad page is active.
local function restartPinEntryTimer()
  if not config.access.keypadRequired
      or config.access.pinEntryTimeoutSeconds == 0 then
    stopPinEntryTimer(); return
  end
  if state.activePageIds[config.access.keypadPageId] then
    pinEntryTimer():Start(config.access.pinEntryTimeoutSeconds)
  else
    stopPinEntryTimer()
  end
end

-- Restarts the session timer while the navigator is unlocked.
local function restartSessionTimer()
  if not config.access.hasLocked
      or state.access == ACCESS_LOCKED
      or config.access.sessionTimeoutSeconds == 0 then
    stopSessionTimer(); return
  end
  sessionTimer():Start(config.access.sessionTimeoutSeconds)
end

-- Navigation commit ----------------------------------------------------------

-- Finishes navigation by reconciling controls, layers, timers, and history.
local function applyNavigationChange(before, record)
  updateOpenControls(before)
  reconcileVisibility()
  restartPinEntryTimer()
  restartSessionTimer()
  if record and not snapshotMatchesCurrent(before) then
    recordHistory(before)
  else
    updateHistoryControls()
  end
end

-- Finishes a history restore after the snapshot has replaced active state.
local function applyRestoredSnapshot(snapshot, before)
  restoreSnapshot(snapshot)
  updateOpenControls(before)
  reconcileVisibility()
  restartPinEntryTimer()
  restartSessionTimer()
  updateHistoryControls()
end

-- Shared open path for page and group navigation IDs.
local function openIdInternal(id, record)
  local before = copyStateSnapshot()
  if shouldLog("navigation") then log("navigation", "open " .. id) end
  if config.pages[id] then
    activatePage(id)
  elseif config.groups[id] then
    activateGroup(id)
  else
    error("unknown page or group ID: " .. tostring(id), 3)
  end
  applyNavigationChange(before, record)
end

-- Shared page-close path that applies open-member and empty-group behavior.
local function closePageInternal(pageId)
  if not state.activePageIds[pageId] then
    updateHistoryControls(); return
  end
  local before = copyStateSnapshot()
  if shouldLog("navigation") then log("navigation", "close " .. pageId) end
  local groupId  = config.pages[pageId].owner
  local group    = config.groups[groupId]
  local openIds = group.openIds
  local isOpenMember = indexes.openMembersByGroupId[groupId][pageId] == true
  if group.behavior == GROUP_SWITCH and isOpenMember then
    updateHistoryControls(); return
  end
  closeActivePage(pageId)
  if group.behavior == GROUP_SWITCH and #openIds > 0 then
    activateOpenMembersForGroup(groupId)
  elseif not groupHasActiveDirectMembers(groupId) then
    state.activeGroupIds[groupId] = nil
  end
  applyNavigationChange(before, true)
end

-- Prunes active pages unavailable at a new access level without reconciling yet.
local function closeUnavailablePages(targetAccess)
  local activeIds = {}
  for pageId in pairs(state.activePageIds) do
    activeIds[#activeIds + 1] = pageId
  end
  for _, pageId in ipairs(activeIds) do
    if state.activePageIds[pageId] then
      local access = config.pages[pageId].lockedView and ACCESS_LOCKED or targetAccess
      if not viewForPageId(pageId, access) then
        local groupId = config.pages[pageId].owner
        local group = config.groups[groupId]
        closeActivePage(pageId)
        if group.behavior == GROUP_SWITCH and #group.openIds > 0 then
          activateOpenMembersForGroup(groupId)
        elseif not groupHasActiveDirectMembers(groupId) then
          state.activeGroupIds[groupId] = nil
        end
      end
    end
  end
end

-- Changes access through the same path used by user-facing controls.
local function changeAccess(targetAccess)
  if accessLevelControl then accessLevelControl.String = targetAccess end
  Navigator.setAccess(targetAccess)
end

-- Normalizes group open into an ordered direct-member ID list.
local function normalizeOpenList(ownerId, value)
  if type(value) == "string" then return { value } end
  assert(type(value) == "table" and value[1] ~= nil,
    ownerId .. " must be an ID or ID list")
  local result = {}
  for index, memberId in ipairs(value) do
    assert(type(memberId) == "string" and memberId ~= "",
      ownerId .. "[" .. index .. "] must be a non-empty ID")
    result[index] = memberId
  end
  return result
end

-- Activates the entry group configured by an access level's open field.
local function activateAccessEntryGroup(access)
  activateGroup(config.access.levels[access].entryGroupId)
end

-- Public API -----------------------------------------------------------------

-- Moves the navigator across access boundaries and resets state as needed.
function Navigator.setAccess(targetAccess)
  assert(config, "apply Navigator before changing access")
  assert(type(targetAccess) == "string" and config.access.levels[targetAccess],
    "invalid access level: " .. tostring(targetAccess))
  local before = copyStateSnapshot()
  clearHistory()
  if shouldLog("access") then
    log("access", state.access .. " -> " .. targetAccess)
  end
  stopPinEntryTimer()
  local resetToStart = targetAccess == ACCESS_LOCKED or state.access == ACCESS_LOCKED
  if targetAccess == ACCESS_LOCKED then stopSessionTimer() end
  if resetToStart then
    state.access = targetAccess
    state.activePageIds = {}
    state.activeGroupIds = {}
    activateAccessEntryGroup(targetAccess)
  else
    state.access = targetAccess
    closeUnavailablePages(targetAccess)
    if not state.activeGroupIds[config.access.levels[targetAccess].rootGroupId] then
      activateAccessEntryGroup(targetAccess)
    end
  end
  updateOpenControls(before)
  reconcileVisibility()
  restartSessionTimer()
  updateHistoryControls()
end

-- Public API for opening a page or group by ID and recording history.
function Navigator.open(id)
  assert(config, "apply Navigator before navigating")
  openIdInternal(id, true)
end

-- Public API for closing a page or group by ID and recording history.
function Navigator.close(id)
  assert(config, "apply Navigator before navigating")
  if config.pages[id] then
    closePageInternal(id)
  elseif config.groups[id] then
    if not state.activeGroupIds[id] then updateHistoryControls(); return end
    local group = config.groups[id]
    local owner = group.owner
    local ownerGroup = config.groups[owner]
    local isOpenMember = ownerGroup
      and indexes.openMembersByGroupId[owner][id] == true
    if ownerGroup and ownerGroup.behavior == GROUP_SWITCH and isOpenMember then
      updateHistoryControls(); return
    end
    local before = copyStateSnapshot()
    if shouldLog("navigation") then log("navigation", "close " .. id) end
    closeGroup(id)
    if ownerGroup and ownerGroup.behavior == GROUP_SWITCH
        and #ownerGroup.openIds > 0 then
      activateOpenMembersForGroup(owner)
    elseif ownerGroup and not groupHasActiveDirectMembers(owner) then
      state.activeGroupIds[owner] = nil
    end
    applyNavigationChange(before, true)
  else
    error("unknown page or group ID: " .. tostring(id), 2)
  end
end

-- Restores the previous page/group snapshot from navigation history.
function Navigator.back()
  assert(config, "apply Navigator before navigating")
  if #historyBack == 0 then updateHistoryControls(); return end
  local current  = copyStateSnapshot()
  local previous = historyBack[#historyBack]
  historyBack[#historyBack] = nil
  cappedPush(historyForward, current)
  applyRestoredSnapshot(previous, current)
end

-- Restores the next page/group snapshot after a back operation.
function Navigator.forward()
  assert(config, "apply Navigator before navigating")
  if #historyForward == 0 then updateHistoryControls(); return end
  local current      = copyStateSnapshot()
  local nextSnapshot = historyForward[#historyForward]
  historyForward[#historyForward] = nil
  cappedPush(historyBack, current)
  applyRestoredSnapshot(nextSnapshot, current)
end

-- Handles keypad inactivity by returning from keypad to locked access.
onPinEntryTimeout = function()
  if shouldLog("timeout") then log("timeout", "pin entry") end
  changeAccess(ACCESS_LOCKED)
end

-- Handles unlocked session expiry by returning to locked access.
onSessionTimeout = function()
  if shouldLog("timeout") then log("timeout", "session") end
  changeAccess(ACCESS_LOCKED)
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

-- Returns a copy of the currently visible physical layer set.
function Navigator.getVisibleLayers()
  return copyTable(visibleLayers)
end

-- Normalization --------------------------------------------------------------

-- Validates access level names before they are used as view keys.
local function validateAccessName(ownerId, access)
  assert(type(access) == "string" and access ~= "",
    ownerId .. " has an invalid access level")
  assert(access == string.lower(access),
    ownerId .. " access levels must be lowercase")
end

-- Resolves authored control names through Q-SYS Controls while preserving objects.
local function normalizeControl(ownerId, value)
  if type(value) == "string" then
    manifestControlNames[value] = true
    assert(type(Controls) == "table",
      ownerId .. " control " .. value .. " requires Controls")
    local control = Controls[value]
    assert(control ~= nil, ownerId .. " references missing control " .. value)
    return control
  end
  if isControlList(value) then
    local result = {}
    for i, item in ipairs(value) do
      result[i] = normalizeControl(ownerId .. "[" .. i .. "]", item)
    end
    return result
  end
  return value
end

local navigationControlKeys = { open = true, close = true }
local accessControlKeys = { level = true, change = true, lock = true, activityPulse = true }
local historyControlKeys = { back = true, forward = true }

-- Normalizes a controls table and rejects unsupported control aliases.
local function normalizeControls(ownerId, controls, allowedKeys)
  if controls == nil then return nil end
  assert(type(controls) == "table", ownerId .. " controls must be a table")
  local normalized = {}
  for key, value in pairs(controls) do
    assert(allowedKeys[key], ownerId .. "." .. tostring(key)
      .. " is not a supported control")
    normalized[key] = normalizeControl(ownerId .. "." .. key, value)
  end
  return normalized
end

-- Adds a layer item into normalized access-keyed content tables.
local function addContentItem(ownerId, access, item, views)
  assert(type(item) == "string", ownerId .. " content must contain layer names")
  views[access] = views[access] or {}
  views[access][#views[access] + 1] = item
end

-- Normalizes authored content into page views.
local function normalizeContent(ownerId, content, defaultAccess)
  local views = {}
  if type(content) == "string" then
    addContentItem(ownerId, defaultAccess, content, views)
  else
    assert(type(content) == "table", ownerId .. " requires content")
    if content[1] ~= nil then
      -- list of layer names: all belong to default access
      for _, item in ipairs(content) do
        addContentItem(ownerId, defaultAccess, item, views)
      end
    else
      -- access-keyed table
      for access, accessContent in pairs(content) do
        validateAccessName(ownerId, access)
        if type(accessContent) == "string" then
          addContentItem(ownerId, access, accessContent, views)
        else
          assert(type(accessContent) == "table",
            ownerId .. "." .. access .. " must be a layer or layer list")
          for _, item in ipairs(accessContent) do
            addContentItem(ownerId, access, item, views)
          end
        end
      end
    end
  end
  return views
end

-- Normalizes authored access levels into the runtime access configuration.
local function normalizeAccess(authored)
  assert(type(authored) == "table", "access must be a table")
  local normalized = {
    levels               = {},
    keypadRequired       = false,
    sessionTimeoutSeconds = 0,
  }
  for accessId, definition in pairs(authored) do
    validateAccessName("access", accessId)
    assert(type(definition) == "table",
      "access." .. accessId .. " must be a table")
    local level = {}
    if definition.open then
      assert(type(definition.open) == "string" and definition.open ~= "",
        "access." .. accessId .. ".open must be a group ID")
      level.entryGroupId = definition.open
    end
    normalized.levels[accessId] = level
    if definition.default == true then
      assert(normalized.defaultLevelId == nil,
        "only one access level can be default")
      normalized.defaultLevelId = accessId
    end
    if definition.keypad then
      assert(accessId == ACCESS_LOCKED,
        "only locked access can define keypad")
      normalized.keypadRequired = true
      normalized.keypadPageId   = definition.keypad
    end
    if definition.pinEntryTimeoutSeconds ~= nil then
      assert(accessId == ACCESS_LOCKED,
        "only locked access can define pinEntryTimeoutSeconds")
      normalized.pinEntryTimeoutSeconds = definition.pinEntryTimeoutSeconds
    end
    if definition.sessionTimeoutSeconds ~= nil then
      normalized.sessionTimeoutSeconds = definition.sessionTimeoutSeconds
    end
  end
  assert(normalized.defaultLevelId ~= nil,
    "one non-locked access level must set default = true")
  assert(normalized.defaultLevelId ~= ACCESS_LOCKED,
    "locked access cannot be the default access level")
  normalized.hasLocked = normalized.levels[ACCESS_LOCKED] ~= nil
  normalized.startupLevelId = normalized.hasLocked
    and ACCESS_LOCKED or normalized.defaultLevelId
  if normalized.keypadRequired and normalized.pinEntryTimeoutSeconds == nil then
    normalized.pinEntryTimeoutSeconds = 0
  end
  assert(normalized.keypadRequired or normalized.pinEntryTimeoutSeconds == nil,
    "pinEntryTimeoutSeconds requires locked.keypad")
  return normalized
end

-- Separates a flat project table into authored groups and pages.
local function partitionProject(project)
  local groups = {}
  local pages  = {}
  for key, value in pairs(project) do
    if type(value) == "table" then
      if value.__kind == "group" then
        assert(type(key) == "string" and key ~= "",
          "group IDs must be non-empty strings")
        groups[key] = value
      elseif value.__kind == "page" then
        assert(type(key) == "string" and key ~= "",
          "page IDs must be non-empty strings")
        pages[key] = value
      end
    end
  end
  return groups, pages
end

-- Normalizes authored groups while preserving owner and open IDs.
local function normalizeGroups(rawGroups)
  local normalized = {}
  for groupId, spec in pairs(rawGroups) do
    assert(type(spec) == "table", groupId .. " group spec must be a table")
    local mode = spec.mode
    assert(mode == GROUP_SWITCH or mode == GROUP_STACK,
      groupId .. ' mode must be "switch" or "stack"')
    local owner = spec.owner
    assert(type(owner) == "string" and owner ~= "",
      groupId .. " requires owner")
    local group = {
      owner = owner,
      behavior = mode,
      openIds = {},
      controls = normalizeControls(groupId .. ".controls",
        spec.controls, navigationControlKeys),
    }
    if spec.open then
      group.openIds = normalizeOpenList(groupId .. ".open", spec.open)
    end
    normalized[groupId] = group
  end
  return normalized
end

-- Normalizes authored pages into owner, content view, and control tables.
local function normalizePages(rawPages, normalizedGroups, defaultAccess)
  local normalized = {}
  for pageId, spec in pairs(rawPages) do
    assert(type(spec) == "table", pageId .. " page spec must be a table")
    local owner = spec.owner
    assert(type(owner) == "string" and owner ~= "",
      pageId .. " requires owner")
    assert(normalizedGroups[owner],
      pageId .. " owner " .. owner .. " is not a known group")
    local views = normalizeContent(pageId, spec.content, defaultAccess)
    normalized[pageId] = {
      owner    = owner,
      views    = views,
      controls = normalizeControls(pageId .. ".controls",
        spec.controls, navigationControlKeys),
    }
  end
  return normalized
end

-- Builds lookup tables used by navigation and validation.
local function buildIndexes(candidate)
  indexes = {
    groupsOwnedByOwnerId = {},
    pagesByGroupId       = {},
    openControlsById     = {},
    openMembersByGroupId = {},
    configuredLayers     = {},
  }

  for pageId, page in pairs(candidate.pages) do
    local owner = page.owner
    indexes.pagesByGroupId[owner] = indexes.pagesByGroupId[owner] or {}
    indexes.pagesByGroupId[owner][pageId] = true
    if page.controls and page.controls.open then
      indexes.openControlsById[pageId] = page.controls.open
    end
    for _, layerNames in pairs(page.views) do
      addLayers(indexes.configuredLayers, layerNames)
    end
  end

  for groupId, group in pairs(candidate.groups) do
    assert(not candidate.pages[groupId],
      groupId .. " is used as both a group ID and a page ID")
    local owner = group.owner
    indexes.pagesByGroupId[groupId] = indexes.pagesByGroupId[groupId] or {}
    indexes.groupsOwnedByOwnerId[groupId] =
      indexes.groupsOwnedByOwnerId[groupId] or {}
    indexes.openMembersByGroupId[groupId] = {}
    indexes.groupsOwnedByOwnerId[owner] =
      indexes.groupsOwnedByOwnerId[owner] or {}
    indexes.groupsOwnedByOwnerId[owner][groupId] = true
    if group.controls and group.controls.open then
      indexes.openControlsById[groupId] = group.controls.open
    end
    assert(owner == ROOT_OWNER or candidate.groups[owner],
      groupId .. " owner " .. owner .. " is not a known group")
    for _, memberId in ipairs(group.openIds) do
      indexes.openMembersByGroupId[groupId][memberId] = true
    end
  end

  -- Confirms group ownership does not loop back into itself.
  local visiting, visited = {}, {}
  local function validateGroupAcyclic(groupId)
    if visited[groupId] then return end
    assert(not visiting[groupId], groupId .. " has an ownership cycle")
    visiting[groupId] = true
    local owner = candidate.groups[groupId].owner
    if owner ~= ROOT_OWNER then
      validateGroupAcyclic(owner)
    end
    visiting[groupId] = nil
    visited[groupId]  = true
  end
  for groupId in pairs(candidate.groups) do validateGroupAcyclic(groupId) end
end

-- Validates cross-references that require the full normalized project.
local function validateFinal(candidate)
  local access = candidate.access
  -- Walk up to find the true root group for each.
  local function rootGroupOf(groupId)
    local current = groupId
    while candidate.groups[current].owner ~= ROOT_OWNER do
      current = candidate.groups[current].owner
    end
    return current
  end

  for accessId, definition in pairs(access.levels) do
    local entryGroupId = definition.entryGroupId
    assert(type(entryGroupId) == "string" and entryGroupId ~= "",
      accessId .. " access requires open")
    assert(candidate.groups[entryGroupId],
      accessId .. " entry group not found: " .. tostring(entryGroupId))
    definition.rootGroupId = rootGroupOf(entryGroupId)
  end

  for pageId, page in pairs(candidate.pages) do
    page.lockedView = access.hasLocked
      and groupIsUnder(page.owner, access.levels[ACCESS_LOCKED].rootGroupId,
        candidate.groups)
  end

  if candidate.accessControls and candidate.accessControls.lock then
    assert(access.hasLocked, "accessControls.lock requires locked access")
  end

  assert(access.hasLocked or access.sessionTimeoutSeconds == 0,
    "sessionTimeoutSeconds requires locked access")

  if access.keypadRequired then
    local kp = candidate.pages[access.keypadPageId]
    assert(kp, "keypad page not found: " .. tostring(access.keypadPageId))
    assert(groupIsUnder(kp.owner, access.levels[ACCESS_LOCKED].rootGroupId, candidate.groups),
      "keypad page must be under the locked root group")
    assert(kp.views[ACCESS_LOCKED],
      "keypad page must have a locked view")
  end

  for groupId, group in pairs(candidate.groups) do
    local openIds = group.openIds
    if group.behavior == GROUP_SWITCH then
      assert(#openIds <= 1,
        groupId .. " is switch mode and open must name one direct member")
    end
    for _, memberId in ipairs(openIds) do
      if candidate.pages[memberId] then
        assert(candidate.pages[memberId].owner == groupId,
          groupId .. " open page " .. memberId .. " is not in this group")
      elseif candidate.groups[memberId] then
        assert(candidate.groups[memberId].owner == groupId,
          groupId .. " open group " .. memberId .. " is not owned by this group")
      else
        error(groupId .. " open references unknown page or group " .. memberId)
      end
    end
  end

  local function collectOpenPages(groupId, result, visiting)
    assert(not visiting[groupId], groupId .. " has a recursive open")
    visiting[groupId] = true
    for _, memberId in ipairs(candidate.groups[groupId].openIds) do
      if candidate.pages[memberId] then
        result[#result + 1] = memberId
      else
        collectOpenPages(memberId, result, visiting)
      end
    end
    visiting[groupId] = nil
    return result
  end

  if access.hasLocked then
    local lockedEntryGroup = access.levels[ACCESS_LOCKED].entryGroupId
    local lockedOpenPages = collectOpenPages(lockedEntryGroup, {}, {})
    assert(#lockedOpenPages > 0, lockedEntryGroup .. " requires open")
    for _, pageId in ipairs(lockedOpenPages) do
      assert(candidate.pages[pageId].views[ACCESS_LOCKED],
        lockedEntryGroup .. " open page " .. tostring(pageId) .. " must have a locked view")
    end
  end

  -- Validate page views reference declared access levels.
  for pageId, page in pairs(candidate.pages) do
    for access in pairs(page.views) do
      assert(candidate.access.levels[access],
        pageId .. " uses undeclared access level " .. access)
    end
  end
end

-- Converts an authored project table into the runtime configuration model.
local function normalizeProject(project)
  assert(type(project) == "table", "apply requires a project table")
  assert(type(project.uci) == "table", "project requires uci table")

  local access        = normalizeAccess(project.access)
  local defaultAccess = access.defaultLevelId
  local rawGroups, rawPages = partitionProject(project)

  local normalizedGroups = normalizeGroups(rawGroups)
  local normalizedPages = normalizePages(rawPages, normalizedGroups,
    defaultAccess)

  local candidate = {
    uci              = project.uci,
    logging          = project.logging,
    access           = access,
    accessControls   = normalizeControls("accessControls",
      project.accessControls, accessControlKeys),
    historyControls  = normalizeControls("historyControls",
      project.historyControls, historyControlKeys),
    historyMaxEntries = project.historyMaxEntries,
    groups          = normalizedGroups,
    pages             = normalizedPages,
  }

  buildIndexes(candidate)
  validateFinal(candidate)
  return candidate
end

-- Control binding ------------------------------------------------------------

-- Caches logging settings so disabled logging is cheap at runtime.
local function configureLogging()
  logging           = config.logging or {}
  anyLoggingEnabled = false
  for _, enabled in pairs(logging) do
    if enabled then anyLoggingEnabled = true; return end
  end
end

-- Returns sorted keys from a set-like table for stable diagnostic output.
local function sortedSetKeys(set)
  local keys = {}
  for k in pairs(set) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- Logs configured Q-SYS layer and control names when manifest logging is enabled.
local function logManifest()
  if not shouldLog("manifest") then return end
  log("manifest", "Q-SYS layers")
  for _, name in ipairs(sortedSetKeys(indexes.configuredLayers)) do
    log("manifest", "  layer: " .. name)
  end
  log("manifest", "Q-SYS controls")
  for _, name in ipairs(sortedSetKeys(manifestControlNames)) do
    log("manifest", "  control: " .. name)
  end
end

-- Applies an external access level string to Navigator.
local function applyAccessLevelString(accessString)
  local target = string.lower(tostring(accessString or ""))
  if target == "" then return end
  if not config.access.levels[target] then
    if shouldLog("access") then log("access", "ignored unknown " .. target) end
    return
  end
  Navigator.setAccess(target)
end

-- Resets the external access level bridge before any startup navigation runs.
local function initializeAccessLevelControl()
  accessLevelControl = config.accessControls and config.accessControls.level
  if accessLevelControl then
    accessLevelControl.String = config.access.startupLevelId
  end
end

-- Wires configured Q-SYS controls to navigator actions.
local function bindControls()
  local ac = config.accessControls
  if ac then
    if accessLevelControl then
      accessLevelControl.EventHandler = function(control)
        applyAccessLevelString(control.String)
      end
    end

    forEachControl(ac.change, function(control)
      control.EventHandler = function()
        if shouldLog("controls") then log("controls", "change access pressed") end
        if config.access.keypadRequired then
          if state.access ~= ACCESS_LOCKED then
            changeAccess(ACCESS_LOCKED)
          end
          openIdInternal(config.access.keypadPageId, false)
        else
          changeAccess(config.access.defaultLevelId)
        end
      end
    end)

    forEachControl(ac.lock, function(control)
      control.EventHandler = function()
        if shouldLog("controls") then log("controls", "lock pressed") end
        changeAccess(ACCESS_LOCKED)
      end
    end)

    forEachControl(ac.activityPulse, function(control)
      control.EventHandler = function()
        if shouldLog("controls") then log("controls", "activity pulse") end
        restartPinEntryTimer()
        restartSessionTimer()
      end
    end)
  end

  local function bindNavigationControls(id, controls)
    if controls then
      forEachControl(controls.open, function(control)
        control.EventHandler = function()
          control.Boolean = true
          if shouldLog("controls") then log("controls", "open " .. id) end
          Navigator.open(id)
        end
      end)
      forEachControl(controls.close, function(control)
        control.EventHandler = function()
          if shouldLog("controls") then log("controls", "close " .. id) end
          Navigator.close(id)
        end
      end)
    end
  end

  for groupId, group in pairs(config.groups) do
    bindNavigationControls(groupId, group.controls)
  end

  for pageId, page in pairs(config.pages) do
    bindNavigationControls(pageId, page.controls)
  end

  local hc = config.historyControls
  if hc then
    forEachControl(hc.back, function(control)
      control.EventHandler = function()
        if shouldLog("controls") then log("controls", "back pressed") end
        Navigator.back()
      end
    end)
    forEachControl(hc.forward, function(control)
      control.EventHandler = function()
        if shouldLog("controls") then log("controls", "forward pressed") end
        Navigator.forward()
      end
    end)
  end
end

-- Entry point ----------------------------------------------------------------

-- Initializes Navigator with an authored project model and startup access state.
function Navigator.apply(project)
  assert(not config, "Navigator may be applied only once")
  manifestControlNames = {}
  config = normalizeProject(project)
  uciPageName = config.uci.pageName or "Main"
  uciTransition = config.uci.transition or "none"
  historyMaxEntries = config.historyMaxEntries
  if historyMaxEntries == nil then historyMaxEntries = 25 end
  initializeAccessLevelControl()
  configureLogging()
  logManifest()
  state.access = config.access.startupLevelId
  state.activePageIds = {}
  state.activeGroupIds = {}
  visibleLayers        = {}
  visibilityInitialized = false
  historyBack          = {}
  historyForward       = {}
  activateAccessEntryGroup(state.access)
  updateOpenControls()
  reconcileVisibility()
  bindControls()
  updateHistoryControls()
end

return Navigator
