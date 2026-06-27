-- Navigator.lua
-- Flat ownership-based navigation for a layer-based Q-SYS UCI.

local Navigator = {} -- public module table returned to the project script

local ACCESS_LOCKED  = "locked" -- locked/splash/keypad access
local SECTION_SWITCH = "switch" -- one direct member active at a time
local SECTION_STACK  = "stack" -- multiple direct members may be active
local ROOT_OWNER     = "root" -- implicit top-level switch owner

-- Authoring helpers ----------------------------------------------------------

-- Authoring constructor for a navigation section.
function Navigator.section(spec)
  assert(type(spec) == "table", "section requires a table")
  spec.__kind = "section"
  return spec
end

-- Authoring constructor for a navigable page.
function Navigator.page(spec)
  assert(type(spec) == "table", "page requires a table")
  spec.__kind = "page"
  return spec
end

-- Exposes bare authoring helpers into the global scope for compact scripts.
if _G then
  rawset(_G, "section", rawget(_G, "section") or Navigator.section)
  rawset(_G, "page",    rawget(_G, "page")    or Navigator.page)
end

-- Runtime state --------------------------------------------------------------

local config -- validated project configuration

-- Mutable runtime navigation state: current access plus active pages and sections.
local state = {
  access = ACCESS_LOCKED,
  activePageIds = {},
  activeSectionIds = {},
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
  for k, v in pairs(source) do result[k] = v end
  return result
end

-- Captures the active page/section state used for history and change detection.
local function copyStateSnapshot()
  return {
    activePageIds = copyTable(state.activePageIds),
    activeSectionIds = copyTable(state.activeSectionIds),
  }
end

-- Compares two set-like tables without caring about table identity.
local function sameSet(a, b)
  for k in pairs(a) do if not b[k] then return false end end
  for k in pairs(b) do if not a[k] then return false end end
  return true
end

-- Compares a saved snapshot to the current active page/section state.
local function snapshotMatchesCurrent(snapshot)
  return sameSet(snapshot.activePageIds, state.activePageIds)
     and sameSet(snapshot.activeSectionIds, state.activeSectionIds)
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

-- Tests whether a section lives under another section in the ownership tree.
local function sectionIsUnder(sectionId, ancestorSectionId, sections)
  local current = sectionId
  while current do
    if current == ancestorSectionId then return true end
    local section = sections[current]
    if not section or section.owner == ROOT_OWNER then return false end
    current = section.owner
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
  local pageName = config.uci.pageName or "Main"
  local diagnose = shouldLog("qsys")
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
  local max = config.historyMaxEntries
  if max == nil then max = 25 end
  if max == false then return end
  if #stack > max then table.remove(stack, 1) end
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
local activateSection
local activateOpenMembersForSection

-- Determines how an owner's direct sections/pages switch or stack.
local function ownerBehavior(ownerId)
  if ownerId == ROOT_OWNER then return SECTION_SWITCH end
  return config.sections[ownerId].behavior
end

-- Closes a section, its active pages, and any active sections it owns.
local function closeSection(sectionId)
  for pageId in pairs(indexes.pagesBySectionId[sectionId]) do
    if state.activePageIds[pageId] then
      state.activePageIds[pageId] = nil
    end
  end
  for ownedSectionId in pairs(indexes.sectionsOwnedByOwnerId[sectionId]) do
    if state.activeSectionIds[ownedSectionId] then closeSection(ownedSectionId) end
  end
  state.activeSectionIds[sectionId] = nil
end

-- Removes one page and its owned sections without applying open policy.
local function closePageOnly(pageId)
  if not state.activePageIds[pageId] then return end
  state.activePageIds[pageId] = nil
end

-- Checks whether a section still has directly active pages or owned sections.
local function sectionHasActiveDirectMembers(sectionId)
  for pageId in pairs(indexes.pagesBySectionId[sectionId]) do
    if state.activePageIds[pageId] then return true end
  end
  for ownedSectionId in pairs(indexes.sectionsOwnedByOwnerId[sectionId]) do
    if state.activeSectionIds[ownedSectionId] then return true end
  end
  return false
end

-- Enforces switch behavior by closing active siblings under the same owner.
local function closeOtherDirectMembers(ownerId, keepKind, keepId)
  if ownerBehavior(ownerId) ~= SECTION_SWITCH then return end
  for sectionId in pairs(indexes.sectionsOwnedByOwnerId[ownerId]) do
    if not (keepKind == "section" and keepId == sectionId)
        and state.activeSectionIds[sectionId] then
      closeSection(sectionId)
    end
  end
  if config.sections[ownerId] then
    for pageId in pairs(indexes.pagesBySectionId[ownerId]) do
      if not (keepKind == "page" and keepId == pageId)
          and state.activePageIds[pageId] then
        closePageOnly(pageId)
      end
    end
  end
end

-- Activates a section, its owning chain, and its configured open members.
activateSection = function(sectionId)
  if state.activeSectionIds[sectionId] then return end
  local section = config.sections[sectionId]
  local owner = section.owner
  if owner ~= ROOT_OWNER then
    activateSection(owner)
  end
  closeOtherDirectMembers(owner, "section", sectionId)
  state.activeSectionIds[sectionId] = true
  activateOpenMembersForSection(sectionId)
end

-- Opens a page after activating its owner section chain.
activatePage = function(pageId)
  local page = config.pages[pageId]
  assert(page, "unknown pageId: " .. tostring(pageId))
  assert(viewForPageId(pageId), pageId .. " unavailable at " .. state.access)
  local sectionId = page.owner
  activateSection(sectionId)
  closeOtherDirectMembers(sectionId, "page", pageId)
  state.activePageIds[pageId] = true
end

-- Opens the configured open member or members for a section.
activateOpenMembersForSection = function(sectionId)
  local openIds = config.sections[sectionId].openIds
  if #openIds == 0 then return end
  for _, memberId in ipairs(openIds) do
    if config.pages[memberId] then
      activatePage(memberId)
    else
      activateSection(memberId)
    end
  end
end

-- Restores a previously captured page/section state for history navigation.
local function restoreSnapshot(snapshot)
  state.activePageIds = copyTable(snapshot.activePageIds)
  state.activeSectionIds = copyTable(snapshot.activeSectionIds)
end

-- Updates open controls to reflect currently active pages and sections.
local function updatePageOpenControls()
  for id, controls in pairs(indexes.openControlsById) do
    setControlBoolean(controls,
      state.activePageIds[id] == true or state.activeSectionIds[id] == true)
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
  updatePageOpenControls()
  reconcileVisibility()
  restartPinEntryTimer()
  restartSessionTimer()
  if record and not snapshotMatchesCurrent(before) then
    recordHistory(before)
  else
    updateHistoryControls()
  end
end

-- Shared open path for page and section navigation IDs.
local function openIdInternal(id, record)
  local before = record and copyStateSnapshot()
  if shouldLog("navigation") then log("navigation", "open " .. id) end
  if config.pages[id] then
    activatePage(id)
  elseif config.sections[id] then
    activateSection(id)
  else
    error("unknown page or section ID: " .. tostring(id), 3)
  end
  applyNavigationChange(before, record)
end

-- Shared page-close path that applies open-member and empty-section behavior.
local function closePageInternal(pageId, record)
  if not state.activePageIds[pageId] then
    updateHistoryControls(); return
  end
  local before = record and copyStateSnapshot()
  if shouldLog("navigation") then log("navigation", "close " .. pageId) end
  local sectionId  = config.pages[pageId].owner
  local section    = config.sections[sectionId]
  local openIds = section.openIds
  local isOpenMember = false
  for _, id in ipairs(openIds) do
    if id == pageId then isOpenMember = true; break end
  end
  if section.behavior == SECTION_SWITCH and isOpenMember then
    updateHistoryControls(); return
  end
  closePageOnly(pageId)
  if section.behavior == SECTION_SWITCH and #openIds > 0 then
    activateOpenMembersForSection(sectionId)
  elseif not sectionHasActiveDirectMembers(sectionId) then
    state.activeSectionIds[sectionId] = nil
  end
  applyNavigationChange(before, record)
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
        local sectionId = config.pages[pageId].owner
        local section = config.sections[sectionId]
        closePageOnly(pageId)
        if section.behavior == SECTION_SWITCH and #section.openIds > 0 then
          activateOpenMembersForSection(sectionId)
        elseif not sectionHasActiveDirectMembers(sectionId) then
          state.activeSectionIds[sectionId] = nil
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

-- Normalizes section open into an ordered direct-member ID list.
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

-- Activates the entry section configured by an access level's open field.
local function activateAccessEntrySection(access)
  activateSection(config.access.levels[access].entrySectionId)
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
  local resetToStart = targetAccess == ACCESS_LOCKED or state.access == ACCESS_LOCKED
  if targetAccess == ACCESS_LOCKED then stopSessionTimer() end
  if resetToStart then
    state.access = targetAccess
    state.activePageIds = {}
    state.activeSectionIds = {}
    activateAccessEntrySection(targetAccess)
  else
    state.access = targetAccess
    closeUnavailablePages(targetAccess)
    if not state.activeSectionIds[config.access.levels[targetAccess].rootSectionId] then
      activateAccessEntrySection(targetAccess)
    end
  end
  updatePageOpenControls()
  reconcileVisibility()
  restartSessionTimer()
  updateHistoryControls()
end

-- Public API for opening a page or section by ID and recording history.
function Navigator.open(id)
  assert(config, "apply Navigator before navigating")
  openIdInternal(id, true)
end

-- Public API for closing a page or section by ID and recording history.
function Navigator.close(id)
  assert(config, "apply Navigator before navigating")
  if config.pages[id] then
    closePageInternal(id, true)
  elseif config.sections[id] then
    if not state.activeSectionIds[id] then updateHistoryControls(); return end
    local section = config.sections[id]
    local owner = section.owner
    local ownerSection = config.sections[owner]
    local isOpenMember = false
    if ownerSection then
      for _, openId in ipairs(ownerSection.openIds) do
        if openId == id then isOpenMember = true; break end
      end
    end
    if ownerSection and ownerSection.behavior == SECTION_SWITCH and isOpenMember then
      updateHistoryControls(); return
    end
    local before = copyStateSnapshot()
    if shouldLog("navigation") then log("navigation", "close " .. id) end
    closeSection(id)
    if ownerSection and ownerSection.behavior == SECTION_SWITCH
        and #ownerSection.openIds > 0 then
      activateOpenMembersForSection(owner)
    elseif ownerSection and not sectionHasActiveDirectMembers(owner) then
      state.activeSectionIds[owner] = nil
    end
    applyNavigationChange(before, true)
  else
    error("unknown page or section ID: " .. tostring(id), 2)
  end
end

-- Restores the previous page/section snapshot from navigation history.
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

-- Restores the next page/section snapshot after a back operation.
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
    activeSectionIds = copyTable(state.activeSectionIds),
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
        "access." .. accessId .. ".open must be a section ID")
      level.entrySectionId = definition.open
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

-- Separates a flat project table into authored sections and pages.
local function partitionProject(project)
  local sections = {}
  local pages  = {}
  for key, value in pairs(project) do
    if type(value) == "table" then
      if value.__kind == "section" then
        assert(type(key) == "string" and key ~= "",
          "section IDs must be non-empty strings")
        sections[key] = value
      elseif value.__kind == "page" then
        assert(type(key) == "string" and key ~= "",
          "page IDs must be non-empty strings")
        pages[key] = value
      end
    end
  end
  return sections, pages
end

-- Normalizes authored sections while preserving owner and open IDs.
local function normalizeSections(rawSections)
  local normalized = {}
  for sectionId, spec in pairs(rawSections) do
    assert(type(spec) == "table", sectionId .. " section spec must be a table")
    local mode = spec.mode
    assert(mode == SECTION_SWITCH or mode == SECTION_STACK,
      sectionId .. ' mode must be "switch" or "stack"')
    local owner = spec.owner
    assert(type(owner) == "string" and owner ~= "",
      sectionId .. " requires owner")
    local section = {
      owner = owner,
      behavior = mode,
      openIds = {},
      controls = normalizeControls(sectionId .. ".controls",
        spec.controls, navigationControlKeys),
    }
    if spec.open then
      section.openIds = normalizeOpenList(sectionId .. ".open", spec.open)
    end
    normalized[sectionId] = section
  end
  return normalized
end

-- Normalizes authored pages into owner, content view, and control tables.
local function normalizePages(rawPages, normalizedSections, defaultAccess)
  local normalized = {}
  for pageId, spec in pairs(rawPages) do
    assert(type(spec) == "table", pageId .. " page spec must be a table")
    local owner = spec.owner
    assert(type(owner) == "string" and owner ~= "",
      pageId .. " requires owner")
    assert(normalizedSections[owner],
      pageId .. " owner " .. owner .. " is not a known section")
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
    sectionsOwnedByOwnerId = {},
    pagesBySectionId       = {},
    openControlsById       = {},
    configuredLayers       = {},
  }

  for pageId, page in pairs(candidate.pages) do
    local owner = page.owner
    indexes.pagesBySectionId[owner] = indexes.pagesBySectionId[owner] or {}
    indexes.pagesBySectionId[owner][pageId] = true
    if page.controls and page.controls.open then
      indexes.openControlsById[pageId] = page.controls.open
    end
    for _, layerNames in pairs(page.views) do
      addLayers(indexes.configuredLayers, layerNames)
    end
  end

  for sectionId, section in pairs(candidate.sections) do
    assert(not candidate.pages[sectionId],
      sectionId .. " is used as both a section ID and a page ID")
    local owner = section.owner
    indexes.pagesBySectionId[sectionId] = indexes.pagesBySectionId[sectionId] or {}
    indexes.sectionsOwnedByOwnerId[sectionId] =
      indexes.sectionsOwnedByOwnerId[sectionId] or {}
    indexes.sectionsOwnedByOwnerId[owner] =
      indexes.sectionsOwnedByOwnerId[owner] or {}
    indexes.sectionsOwnedByOwnerId[owner][sectionId] = true
    if section.controls and section.controls.open then
      indexes.openControlsById[sectionId] = section.controls.open
    end
    assert(owner == ROOT_OWNER or candidate.sections[owner],
      sectionId .. " owner " .. owner .. " is not a known section")
  end

  -- Confirms section ownership does not loop back into itself.
  local visiting, visited = {}, {}
  local function validateSectionAcyclic(sectionId)
    if visited[sectionId] then return end
    assert(not visiting[sectionId], sectionId .. " has an ownership cycle")
    visiting[sectionId] = true
    local owner = candidate.sections[sectionId].owner
    if owner ~= ROOT_OWNER then
      validateSectionAcyclic(owner)
    end
    visiting[sectionId] = nil
    visited[sectionId]  = true
  end
  for sectionId in pairs(candidate.sections) do validateSectionAcyclic(sectionId) end
end

-- Validates cross-references that require the full normalized project.
local function validateFinal(candidate)
  local access = candidate.access
  -- Walk up to find the true root section for each.
  local function rootSectionOf(sectionId)
    local current = sectionId
    while candidate.sections[current].owner ~= ROOT_OWNER do
      current = candidate.sections[current].owner
    end
    return current
  end

  for accessId, definition in pairs(access.levels) do
    local entrySectionId = definition.entrySectionId
    assert(type(entrySectionId) == "string" and entrySectionId ~= "",
      accessId .. " access requires open")
    assert(candidate.sections[entrySectionId],
      accessId .. " entry section not found: " .. tostring(entrySectionId))
    definition.rootSectionId = rootSectionOf(entrySectionId)
  end

  for pageId, page in pairs(candidate.pages) do
    page.lockedView = access.hasLocked
      and sectionIsUnder(page.owner, access.levels[ACCESS_LOCKED].rootSectionId,
        candidate.sections)
  end

  if candidate.accessControls and candidate.accessControls.lock then
    assert(access.hasLocked, "accessControls.lock requires locked access")
  end

  assert(access.hasLocked or access.sessionTimeoutSeconds == 0,
    "sessionTimeoutSeconds requires locked access")

  if access.keypadRequired then
    local kp = candidate.pages[access.keypadPageId]
    assert(kp, "keypad page not found: " .. tostring(access.keypadPageId))
    assert(sectionIsUnder(kp.owner, access.levels[ACCESS_LOCKED].rootSectionId, candidate.sections),
      "keypad page must be under the locked root section")
    assert(kp.views[ACCESS_LOCKED],
      "keypad page must have a locked view")
  end

  for sectionId, section in pairs(candidate.sections) do
    local openIds = section.openIds
    if section.behavior == SECTION_SWITCH then
      assert(#openIds <= 1,
        sectionId .. " is switch mode and open must name one direct member")
    end
    for _, memberId in ipairs(openIds) do
      if candidate.pages[memberId] then
        assert(candidate.pages[memberId].owner == sectionId,
          sectionId .. " open page " .. memberId .. " is not in this section")
      elseif candidate.sections[memberId] then
        assert(candidate.sections[memberId].owner == sectionId,
          sectionId .. " open section " .. memberId .. " is not owned by this section")
      else
        error(sectionId .. " open references unknown page or section " .. memberId)
      end
    end
  end

  local function collectOpenPages(sectionId, result, visiting)
    assert(not visiting[sectionId], sectionId .. " has a recursive open")
    visiting[sectionId] = true
    for _, memberId in ipairs(candidate.sections[sectionId].openIds) do
      if candidate.pages[memberId] then
        result[#result + 1] = memberId
      else
        collectOpenPages(memberId, result, visiting)
      end
    end
    visiting[sectionId] = nil
    return result
  end

  if access.hasLocked then
    local lockedEntrySection = access.levels[ACCESS_LOCKED].entrySectionId
    local lockedOpenPages = collectOpenPages(lockedEntrySection, {}, {})
    assert(#lockedOpenPages > 0, lockedEntrySection .. " requires open")
    for _, pageId in ipairs(lockedOpenPages) do
      assert(candidate.pages[pageId].views[ACCESS_LOCKED],
        lockedEntrySection .. " open page " .. tostring(pageId) .. " must have a locked view")
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
  local rawSections, rawPages = partitionProject(project)

  local normalizedSections = normalizeSections(rawSections)
  local normalizedPages = normalizePages(rawPages, normalizedSections,
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
    sections          = normalizedSections,
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

  for sectionId, section in pairs(config.sections) do
    bindNavigationControls(sectionId, section.controls)
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
  initializeAccessLevelControl()
  configureLogging()
  logManifest()
  state.access = config.access.startupLevelId
  state.activePageIds = {}
  state.activeSectionIds = {}
  visibleLayers        = {}
  visibilityInitialized = false
  historyBack          = {}
  historyForward       = {}
  activateAccessEntrySection(state.access)
  updatePageOpenControls()
  reconcileVisibility()
  bindControls()
  updateHistoryControls()
end

return Navigator
