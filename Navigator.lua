-- Navigator.lua
-- Flat ownership-based navigation for a layer-based Q-SYS UCI.

local Navigator = {} -- public module table returned to the project script

local ACCESS_LOCKED     = "locked" -- locked/splash/keypad access
local GROUP_INTERLOCKED = "interlocked" -- one direct member active at a time
local GROUP_INDEPENDENT = "independent" -- multiple direct members may be active
local OWNER_VISIBLE     = "visible" -- keep owner page layer visible
local OWNER_HIDDEN      = "hidden" -- suppress owner page layer while group is active
local ROOT_OWNER        = "root" -- implicit top-level interlocked owner

-- Authoring helpers ----------------------------------------------------------

-- Authoring constructor for a navigation group.
function Navigator.group(spec)
  spec = spec or {}
  spec.__kind = "group"
  return spec
end

-- Authoring constructor for a navigable page.
function Navigator.page(spec)
  spec = spec or {}
  spec.__kind = "page"
  return spec
end

-- Exposes bare authoring helpers into the global scope for compact scripts.
if _G then
  rawset(_G, "group", rawget(_G, "group") or Navigator.group)
  rawset(_G, "page",  rawget(_G, "page")  or Navigator.page)
end

-- Runtime state --------------------------------------------------------------

local config -- validated project configuration

-- Mutable runtime navigation state: current access plus active pages and groups.
local state = {
  access       = ACCESS_LOCKED,
  activePageIds  = {},
  activeGroupIds = {},
}

local indexes              = {} -- derived lookup tables built from config
local visibleLayers        = {} -- last applied physical layer set
local visibilityInitialized = false -- whether first visibility pass has run
local historyBack          = {} -- back navigation snapshot stack
local historyForward       = {} -- forward navigation snapshot stack
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
  for k, v in pairs(source or {}) do result[k] = v end
  return result
end

-- Captures the active page/group state used for history and change detection.
local function copyStateSnapshot()
  return {
    activePageIds  = copyTable(state.activePageIds),
    activeGroupIds = copyTable(state.activeGroupIds),
  }
end

-- Compares two set-like tables without caring about table identity.
local function sameSet(a, b)
  for k in pairs(a or {}) do if not b[k] then return false end end
  for k in pairs(b or {}) do if not a[k] then return false end end
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
    for _, control in ipairs(controlOrList) do callback(control) end
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

-- Index helpers --------------------------------------------------------------

-- Tests whether a group lives under another group in the ownership tree.
local function groupIsUnder(groupId, ancestorGroupId, groups)
  groups = groups or config.groups
  local current = groupId
  while current do
    if current == ancestorGroupId then return true end
    if indexes.ownerKindByGroupId[current] ~= "group" then return false end
    current = groups[current].owner
  end
  return false
end

-- Identifies pages that should resolve locked views regardless of active access.
local function pageIsInLockedGroup(pageId)
  return groupIsUnder(config.pages[pageId].owner, config.access.lockedGroupId)
end

-- Chooses the access level a page should use for its view lookup.
local function effectiveAccessForPage(pageId)
  if pageIsInLockedGroup(pageId) then return ACCESS_LOCKED end
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
  if not layerNames then return end
  for _, name in ipairs(layerNames) do dest[name] = true end
end

-- Sends one physical layer visibility change to Q-SYS.
local function setLayerVisibility(layerName, isVisible)
  local pageName = config.uci.pageName or "Main"
  local diagnose = shouldLog("qsys") or shouldLog("manifest")
  if not diagnose then
    Uci.SetLayerVisibility(
      pageName,
      layerName,
      isVisible,
      config.uci.transition or "none"
    )
    return
  end
  local ok, err = pcall(Uci.SetLayerVisibility,
    pageName,
    layerName,
    isVisible,
    config.uci.transition or "none"
  )
  if ok then return end
  local message = "UCI layer visibility failed: page="
    .. tostring(pageName)
    .. ", layer=" .. tostring(layerName)
    .. ", visible=" .. tostring(isVisible)
    .. ", error=" .. tostring(err)
  log(shouldLog("qsys") and "qsys" or "manifest", message)
  error(message, 0)
end

-- Collects every declared layer so first reconciliation can hide stale layers.
local function collectConfiguredLayers()
  local layers = {}
  for _, page in pairs(config.pages) do
    for _, layerNames in pairs(page.views) do
      addLayers(layers, layerNames)
    end
  end
  return layers
end

-- Finds active owner pages whose own view is suppressed by owned groups.
local function hiddenOwnerPageIds()
  local hidden = {}
  for groupId in pairs(state.activeGroupIds) do
    local group = config.groups[groupId]
    if group and group.ownerVisibility == OWNER_HIDDEN then
      if indexes.ownerKindByGroupId[groupId] == "page" then
        hidden[group.owner] = true
      end
    end
  end
  return hidden
end

-- Converts active navigator state into the full desired layer set.
local function resolveDesiredLayers()
  local desired = {}
  local hidden  = hiddenOwnerPageIds()
  for pageId in pairs(state.activePageIds) do
    if not hidden[pageId] then
      local view = viewForPageId(pageId)
      assert(view, pageId .. " is active but unavailable")
      addLayers(desired, view)
    end
  end
  return desired
end

-- Diffs desired layers against current layers and applies Q-SYS changes.
local function reconcileVisibility()
  local desired      = resolveDesiredLayers()
  local layersToCheck = visibilityInitialized
    and visibleLayers or collectConfiguredLayers()
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
  local max = config.historyMaxEntries
  if max == nil then max = 25 end
  if max == false then return end
  if #stack > max then table.remove(stack, 1) end
end

-- Keeps optional history controls disabled when their stack is empty.
local function updateHistoryControls()
  local controls = config and config.historyControls
  if not controls then return end
  forEachControl(controls.back, function(c)
    c.IsDisabled = #historyBack == 0
  end)
  forEachControl(controls.forward, function(c)
    c.IsDisabled = #historyForward == 0
  end)
end

-- Clears both history stacks when navigation crosses an access/keypad boundary.
local function clearHistory()
  local had = #historyBack > 0 or #historyForward > 0
  historyBack    = {}
  historyForward = {}
  updateHistoryControls()
  if had and shouldLog("history") then log("history", "cleared") end
end

-- Records the previous state after a page navigation changes state.
local function recordHistory(before)
  cappedPush(historyBack, before)
  historyForward = {}
  updateHistoryControls()
  if shouldLog("history") then log("history", "recorded state") end
end

-- Navigation engine ----------------------------------------------------------

local activatePage
local activateGroup
local activateDefaultMembersForGroup

-- Determines how an owner's direct groups/pages should interlock.
local function ownerBehavior(ownerId)
  if ownerId == ROOT_OWNER then return GROUP_INTERLOCKED end
  local group = config.groups[ownerId]
  if group then return group.behavior end
  return GROUP_INDEPENDENT
end

-- Closes a group, its active pages, and any active groups it owns.
local function closeGroup(groupId)
  for pageId, page in pairs(config.pages) do
    if state.activePageIds[pageId] and page.owner == groupId then
      state.activePageIds[pageId] = nil
    end
  end
  for ownedGroupId in pairs(indexes.groupsOwnedByOwnerId[groupId] or {}) do
    if state.activeGroupIds[ownedGroupId] then closeGroup(ownedGroupId) end
  end
  state.activeGroupIds[groupId] = nil
end

-- Closes groups that explicitly name this page as owner.
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

-- Checks whether a group still has directly active pages or owned groups.
local function groupHasActiveDirectMembers(groupId)
  for pageId in pairs(indexes.pagesByGroupId[groupId] or {}) do
    if state.activePageIds[pageId] then return true end
  end
  for ownedGroupId in pairs(indexes.groupsOwnedByOwnerId[groupId] or {}) do
    if state.activeGroupIds[ownedGroupId] then return true end
  end
  return false
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
  if config.groups[ownerId] then
    for pageId in pairs(indexes.pagesByGroupId[ownerId] or {}) do
      if not (keepKind == "page" and keepId == pageId)
          and state.activePageIds[pageId] then
        closePageOnly(pageId)
      end
    end
  end
end

-- Activates a group and its owning chain before opening pages within it.
activateGroup = function(groupId, options)
  options = options or {}
  if state.activeGroupIds[groupId] then return end
  local group     = config.groups[groupId]
  local owner     = group.owner
  local ownerKind = indexes.ownerKindByGroupId[groupId]
  if ownerKind == "group" then
    activateGroup(owner, options)
  elseif ownerKind == "page" then
    activatePage(owner, { activateOwnedDefaults = false })
  end
  closeOtherDirectMembers(owner, "group", groupId)
  state.activeGroupIds[groupId] = true
  if options.activateDefaults ~= false then
    activateDefaultMembersForGroup(groupId)
  end
end

-- Opens a page, activating required groups and owned default groups.
activatePage = function(pageId, options)
  options = options or {}
  local page = config.pages[pageId]
  assert(page, "unknown pageId: " .. tostring(pageId))
  assert(viewForPageId(pageId), pageId .. " unavailable at " .. state.access)
  local groupId = page.owner
  activateGroup(groupId, options)
  closeOtherDirectMembers(groupId, "page", pageId)
  state.activePageIds[pageId] = true
  if options.activateOwnedDefaults ~= false then
    for ownedGroupId in pairs(indexes.groupsOwnedByOwnerId[pageId] or {}) do
      local defaults = config.groups[ownedGroupId].defaultMemberIds
      if defaults and #defaults > 0 then activateGroup(ownedGroupId) end
    end
  end
end

-- Opens the configured default direct member or members for a group.
activateDefaultMembersForGroup = function(groupId)
  local defaults = config.groups[groupId].defaultMemberIds
  if not defaults or #defaults == 0 then return end
  for _, memberId in ipairs(defaults) do
    if config.pages[memberId] then
      activatePage(memberId)
    else
      activateGroup(memberId)
    end
  end
end

-- Restores a previously captured page/group state for history navigation.
local function restoreSnapshot(snapshot)
  state.activePageIds  = copyTable(snapshot.activePageIds)
  state.activeGroupIds = copyTable(snapshot.activeGroupIds)
end

-- Interlocks page open controls to reflect the currently active pages.
local function updatePageOpenControls()
  if not config then return end
  for pageId, page in pairs(config.pages) do
    if page.controls and page.controls.open then
      forEachControl(page.controls.open, function(c)
        c.Boolean = state.activePageIds[pageId] == true
      end)
    end
  end
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
  if state.access == ACCESS_LOCKED
      or config.access.sessionTimeoutSeconds == 0 then
    stopSessionTimer(); return
  end
  sessionTimer():Start(config.access.sessionTimeoutSeconds)
end

-- Navigation commit ----------------------------------------------------------

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
    updateHistoryControls(); return
  end
  if shouldLog("navigation") then log("navigation", "close " .. pageId) end
  local groupId  = config.pages[pageId].owner
  local group    = config.groups[groupId]
  local defaults = group.defaultMemberIds or {}
  local isDefault = false
  for _, id in ipairs(defaults) do
    if id == pageId then isDefault = true; break end
  end
  if group.behavior == GROUP_INTERLOCKED and isDefault then
    updateHistoryControls(); return
  end
  closePageOnly(pageId)
  if group.behavior == GROUP_INTERLOCKED and #defaults > 0 then
    activateDefaultMembersForGroup(groupId)
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
      local access = pageIsInLockedGroup(pageId) and ACCESS_LOCKED or targetAccess
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

-- Normalizes group startAt into an ordered direct-member ID list.
local function normalizeStartAtList(ownerId, value)
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

-- Resolves the group that an access level should activate first.
local function accessStartGroupId(access)
  if access == ACCESS_LOCKED then
    return config.access.levels[ACCESS_LOCKED].groupId
  end
  return config.access.levels[access].groupId
    or config.access.levels[config.access.defaultLevelId].groupId
end

-- Activates the configured entry group for an access level.
local function activateAccessStartGroup(access)
  activateGroup(accessStartGroupId(access))
end

-- Public API -----------------------------------------------------------------

-- Moves the navigator across access boundaries and resets state as needed.
function Navigator.setAccess(targetAccess)
  assert(config, "apply Navigator before changing access")
  assert(type(targetAccess) == "string" and config.access.levels[targetAccess],
    "invalid access level: " .. tostring(targetAccess))
  clearHistory()
  if shouldLog("access") then
    log("access", state.access .. " -> " .. targetAccess)
  end
  stopPinEntryTimer()
  if targetAccess == ACCESS_LOCKED then
    stopSessionTimer()
    state.access       = targetAccess
    state.activePageIds  = {}
    state.activeGroupIds = {}
    activateAccessStartGroup(targetAccess)
  elseif state.access == ACCESS_LOCKED then
    state.access       = targetAccess
    state.activePageIds  = {}
    state.activeGroupIds = {}
    activateAccessStartGroup(targetAccess)
  else
    state.access = targetAccess
    closeUnavailablePages(targetAccess)
    if not state.activeGroupIds[config.access.unlockedGroupId] then
      activateAccessStartGroup(targetAccess)
    end
  end
  updatePageOpenControls()
  reconcileVisibility()
  restartSessionTimer()
  updateHistoryControls()
end

-- Public API for opening a page by ID and recording history.
function Navigator.open(pageId)
  assert(config, "apply Navigator before navigating")
  openPageInternal(pageId, true)
end

-- Public API for closing a page by ID and recording history.
function Navigator.close(pageId)
  assert(config, "apply Navigator before navigating")
  closePageInternal(pageId, true)
end

-- Restores the previous page/group snapshot from navigation history.
function Navigator.back()
  assert(config, "apply Navigator before navigating")
  if #historyBack == 0 then updateHistoryControls(); return end
  local current  = copyStateSnapshot()
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
  if #historyForward == 0 then updateHistoryControls(); return end
  local current      = copyStateSnapshot()
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
    access         = state.access,
    activePageIds  = copyTable(state.activePageIds),
    activeGroupIds = copyTable(state.activeGroupIds),
    canGoBack      = #historyBack > 0,
    canGoForward   = #historyForward > 0,
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

local pageControlKeys   = { open = true, close = true }
local accessControlKeys = { level = true, change = true, lock = true, activityPulse = true }
local historyControlKeys = { back = true, forward = true }

-- Normalizes a page/global controls table and rejects unsupported control aliases.
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
    if definition.startAt then
      assert(type(definition.startAt) == "string" and definition.startAt ~= "",
        "access." .. accessId .. ".startAt must be a group ID")
      level.groupId = definition.startAt
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
      normalized.pinEntryTimeoutSeconds = definition.pinEntryTimeoutSeconds
    end
    if definition.sessionTimeoutSeconds ~= nil then
      normalized.sessionTimeoutSeconds = definition.sessionTimeoutSeconds
    end
  end
  assert(normalized.defaultLevelId ~= nil,
    "one non-locked access level must set default = true")
  if normalized.keypadRequired and normalized.pinEntryTimeoutSeconds == nil then
    normalized.pinEntryTimeoutSeconds = 0
  end
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

-- Normalizes authored groups while preserving owner and startAt IDs.
local function normalizeGroups(rawGroups)
  local normalized = {}
  for groupId, spec in pairs(rawGroups) do
    assert(type(spec) == "table", groupId .. " group spec must be a table")
    local mode = spec.mode
    assert(mode == GROUP_INTERLOCKED or mode == GROUP_INDEPENDENT,
      groupId .. ' mode must be "interlocked" or "independent"')
    local owner = spec.owner
    assert(type(owner) == "string" and owner ~= "",
      groupId .. " requires owner")
    local g = { owner = owner, behavior = mode }
    if spec.startAt then
      g.defaultMemberIds = normalizeStartAtList(groupId .. ".startAt", spec.startAt)
    end
    if spec.parentVisible ~= nil then
      assert(type(spec.parentVisible) == "boolean",
        groupId .. ".parentVisible must be boolean")
      g.ownerVisibility = spec.parentVisible and OWNER_VISIBLE or OWNER_HIDDEN
    end
    normalized[groupId] = g
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
        spec.controls, pageControlKeys),
    }
  end
  return normalized
end

-- Builds lookup tables used by navigation and validation.
local function buildIndexes(candidate)
  indexes = {
    groupsOwnedByOwnerId = {},
    pagesByGroupId       = {},
    ownerKindByGroupId   = {},
  }

  for pageId, page in pairs(candidate.pages) do
    local g = page.owner
    indexes.pagesByGroupId[g] = indexes.pagesByGroupId[g] or {}
    indexes.pagesByGroupId[g][pageId] = true
  end

  for groupId, group in pairs(candidate.groups) do
    assert(not candidate.pages[groupId],
      groupId .. " is used as both a group ID and a page ID")
    local owner = group.owner
    indexes.groupsOwnedByOwnerId[owner] =
      indexes.groupsOwnedByOwnerId[owner] or {}
    indexes.groupsOwnedByOwnerId[owner][groupId] = true
    if owner == ROOT_OWNER then
      indexes.ownerKindByGroupId[groupId] = "root"
    elseif candidate.groups[owner] then
      indexes.ownerKindByGroupId[groupId] = "group"
    elseif candidate.pages[owner] then
      indexes.ownerKindByGroupId[groupId] = "page"
    else
      error(groupId .. " owner " .. owner .. " is not a known group or page")
    end
  end

  -- Confirms group ownership does not loop back into itself.
  local visiting, visited = {}, {}
  local function validateGroupAcyclic(groupId)
    if visited[groupId] then return end
    assert(not visiting[groupId], groupId .. " has an ownership cycle")
    visiting[groupId] = true
    if indexes.ownerKindByGroupId[groupId] == "group" then
      local owner = candidate.groups[groupId].owner
      validateGroupAcyclic(owner)
    end
    visiting[groupId] = nil
    visited[groupId]  = true
  end
  for groupId in pairs(candidate.groups) do validateGroupAcyclic(groupId) end
end

-- Validates cross-references that require the full normalized project.
local function validateFinal(candidate)
  local access      = candidate.access
  local lockedGroup  = access.levels[ACCESS_LOCKED].groupId
  local defaultGroup = access.levels[access.defaultLevelId].groupId
  assert(type(lockedGroup) == "string" and lockedGroup ~= "",
    "locked access requires startAt")
  assert(type(defaultGroup) == "string" and defaultGroup ~= "",
    access.defaultLevelId .. " access requires startAt")
  assert(candidate.groups[lockedGroup],
    "locked startAt group not found: " .. tostring(lockedGroup))
  assert(candidate.groups[defaultGroup],
    access.defaultLevelId .. " startAt group not found: " .. tostring(defaultGroup))
  for accessId, definition in pairs(access.levels) do
    if definition.groupId then
      assert(candidate.groups[definition.groupId],
        accessId .. " startAt group not found: " .. tostring(definition.groupId))
    end
  end

  -- Walk up to find the true root group for each.
  local function rootGroupOf(groupId)
    local current = groupId
    while indexes.ownerKindByGroupId[current] == "group" do
      current = candidate.groups[current].owner
    end
    return current
  end
  access.lockedGroupId   = rootGroupOf(lockedGroup)
  access.unlockedGroupId = rootGroupOf(defaultGroup)

  if access.keypadRequired then
    local kp = candidate.pages[access.keypadPageId]
    assert(kp, "keypad page not found: " .. tostring(access.keypadPageId))
    assert(groupIsUnder(kp.owner, access.lockedGroupId, candidate.groups),
      "keypad page must be under the locked root group")
    assert(kp.views[ACCESS_LOCKED],
      "keypad page must have a locked view")
  end

  -- Validate ownerVisibility is only set on page-owned groups.
  for groupId, group in pairs(candidate.groups) do
    if indexes.ownerKindByGroupId[groupId] == "page" then
      assert(group.ownerVisibility == OWNER_VISIBLE
          or group.ownerVisibility == OWNER_HIDDEN,
        groupId .. " is owned by a page and requires parentVisible")
    else
      assert(group.ownerVisibility == nil,
        groupId .. " parentVisible is only valid for page-owned groups")
    end
    local defaults = group.defaultMemberIds or {}
    if group.behavior == GROUP_INTERLOCKED then
      assert(#defaults <= 1,
        groupId .. " is interlocked and startAt must name one direct member")
    end
    for _, memberId in ipairs(defaults) do
      if candidate.pages[memberId] then
        assert(candidate.pages[memberId].owner == groupId,
          groupId .. " startAt page " .. memberId .. " is not in this group")
      elseif candidate.groups[memberId] then
        assert(candidate.groups[memberId].owner == groupId,
          groupId .. " startAt group " .. memberId .. " is not owned by this group")
      else
        error(groupId .. " startAt references unknown page or group " .. memberId)
      end
    end
  end

  local function collectDefaultPages(groupId, result, visiting)
    result   = result or {}
    visiting = visiting or {}
    assert(not visiting[groupId], groupId .. " has a recursive startAt")
    visiting[groupId] = true
    for _, memberId in ipairs(candidate.groups[groupId].defaultMemberIds or {}) do
      if candidate.pages[memberId] then
        result[#result + 1] = memberId
      else
        collectDefaultPages(memberId, result, visiting)
      end
    end
    visiting[groupId] = nil
    return result
  end

  local lockedDefaults = collectDefaultPages(lockedGroup)
  assert(#lockedDefaults > 0, lockedGroup .. " requires startAt")
  for _, pageId in ipairs(lockedDefaults) do
    assert(candidate.pages[pageId].views[ACCESS_LOCKED],
      lockedGroup .. " startAt page " .. tostring(pageId) .. " must have a locked view")
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

  local access        = normalizeAccess(project.access or {})
  local defaultAccess = access.defaultLevelId
  local rawGroups, rawPages = partitionProject(project)

  local normalizedGroups = normalizeGroups(rawGroups)
  local normalizedPages  = normalizePages(rawPages, normalizedGroups,
    defaultAccess)

  local candidate = {
    uci              = project.uci or {},
    logging          = project.logging,
    access           = access,
    accessControls   = normalizeControls("accessControls",
      project.accessControls, accessControlKeys),
    historyControls  = normalizeControls("historyControls",
      project.historyControls, historyControlKeys),
    historyMaxEntries = project.historyMaxEntries,
    groups           = normalizedGroups,
    pages            = normalizedPages,
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
  for k in pairs(set or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- Logs configured Q-SYS layer and control names when manifest logging is enabled.
local function logManifest()
  if not shouldLog("manifest") then return end
  log("manifest", "Q-SYS layers")
  for _, name in ipairs(sortedSetKeys(collectConfiguredLayers())) do
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
  if accessLevelControl then accessLevelControl.String = ACCESS_LOCKED end
end

-- Wires configured Q-SYS controls to navigator actions.
local function bindControls()
  local ac = config.accessControls
  if ac then
    accessLevelControl = ac.level
    accessLevelControl.EventHandler = function(control)
      applyAccessLevelString(control.String)
    end

    forEachControl(ac.change, function(control)
      control.EventHandler = function()
        if shouldLog("controls") then log("controls", "change access pressed") end
        if config.access.keypadRequired then
          if state.access ~= ACCESS_LOCKED then
            changeAccess(ACCESS_LOCKED)
          end
          Navigator.open(config.access.keypadPageId)
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

  for pageId, page in pairs(config.pages) do
    if page.controls then
      forEachControl(page.controls.open, function(control)
        control.EventHandler = function()
          control.Boolean = true
          if shouldLog("controls") then log("controls", "open " .. pageId) end
          Navigator.open(pageId)
        end
      end)
      forEachControl(page.controls.close, function(control)
        control.EventHandler = function()
          if shouldLog("controls") then log("controls", "close " .. pageId) end
          Navigator.close(pageId)
        end
      end)
    end
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

-- Initializes Navigator with an authored project model and locked access state.
function Navigator.apply(project)
  assert(not config, "Navigator may be applied only once")
  manifestControlNames = {}
  config = normalizeProject(project)
  initializeAccessLevelControl()
  configureLogging()
  logManifest()
  state.access       = ACCESS_LOCKED
  state.activePageIds  = {}
  state.activeGroupIds = {}
  visibleLayers        = {}
  visibilityInitialized = false
  historyBack          = {}
  historyForward       = {}
  activateAccessStartGroup(ACCESS_LOCKED)
  updatePageOpenControls()
  reconcileVisibility()
  bindControls()
  updateHistoryControls()
end

return Navigator
