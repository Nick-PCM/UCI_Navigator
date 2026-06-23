-- Navigator.lua
-- Reusable navigation state and behavior for a layer-based Q-SYS UCI.
-- This module uses ordinary tables and functions; it does not use inheritance.

local Navigator = {}

-- Access values are the authorization states Navigator understands.
-- These strings must match the values produced by the external PIN module
-- and the keys used in page/frame view tables.
Navigator.Access = {
  LOCKED = "locked",
  DEFAULT = "default",
}

-- childDisplayMode belongs on a parent page. SINGLE is the default and means
-- opening one direct child closes sibling branches. MULTIPLE preserves active
-- sibling branches under the same parent.
Navigator.ChildDisplayMode = {
  SINGLE = "single",
  MULTIPLE = "multiple",
}

-- parentVisibility belongs on a child page. KEEP leaves the parent's physical
-- layer view visible. HIDE keeps the parent logically active but omits
-- its physical layer view while this child is active.
Navigator.ParentVisibility = {
  KEEP = "keep",
  HIDE = "hide",
}

local config
local state = {
  access = Navigator.Access.LOCKED,
  -- Runtime set of active page IDs. Keys are page IDs; true means active.
  -- This changes whenever Navigator opens/closes pages or changes access.
  activePageIds = {},
  keypadVisible = false,
}
local historyBack = {}
local historyForward = {}
-- Tracks layers Navigator last applied as visible.
local visibleLayers = {}
local visibilityInitialized = false
local accessStateControl

-- Static set of supported frame role names. Keys are role names; true means
-- the role is valid. This never changes at runtime.
local frameRoles = {
  background = true,
  header = true,
  footer = true,
  navigation = true,
}

-- This is the only function that knows the Q-SYS layer API signature.
-- uci.pageName is a Q-SYS UCI page, not a Navigator logical page ID.
local function setLayerVisibility(layerName, isVisible)
  Uci.SetLayerVisibility(
    config.uci.name,
    config.uci.pageName or "Main",
    layerName,
    isVisible,
    config.uci.transition or "none"
  )
end

local function homePageId(access)
  return config.access.levels[access].homePageId
end

local function keypadRequired()
  return config.access.keypadRequired == true
end

local function isDescendantOf(pageId, ancestorId)
  local page = config.pages[pageId]
  while page and page.parentId do
    if page.parentId == ancestorId then return true end
    page = config.pages[page.parentId]
  end
  return false
end

local function closeBranch(rootPageId)
  local pageIdsToClose = { rootPageId }
  for activeId in pairs(state.activePageIds) do
    if isDescendantOf(activeId, rootPageId) then
      pageIdsToClose[#pageIdsToClose + 1] = activeId
    end
  end
  for _, pageId in ipairs(pageIdsToClose) do
    state.activePageIds[pageId] = nil
  end
end

local function activateRootPage(pageId)
  local page = config.pages[pageId]
  state.activePageIds = { [pageId] = true }
  if page.defaultChildId then
    state.activePageIds[page.defaultChildId] = true
  end
end

local function isLockedAccess(access)
  return access == Navigator.Access.LOCKED
end

local function viewFor(page, access)
  return page.views[access]
    or (not isLockedAccess(access) and page.views[Navigator.Access.DEFAULT])
end

-- Calculate page layers from logical state without changing the UCI.
-- Active parents remain logical navigation targets even when a child hides
-- their physical view. If any active child hides a parent, hide wins.
local function resolvePageLayers()
  local hiddenPageIds = {}
  for pageId in pairs(state.activePageIds) do
    local page = config.pages[pageId]
    if page.parentId
        and page.parentVisibility == Navigator.ParentVisibility.HIDE then
      hiddenPageIds[page.parentId] = true
    end
  end

  local desiredLayers = {}
  for pageId in pairs(state.activePageIds) do
    if not hiddenPageIds[pageId] then
      local page = config.pages[pageId]
      local view = viewFor(page, state.access)
      assert(view, pageId .. " is active but unavailable")
      for _, layerName in ipairs(view) do
        desiredLayers[layerName] = true
      end
    end
  end
  return desiredLayers
end

local function addLayers(destination, layerNames)
  if not layerNames then return end
  for _, layerName in ipairs(layerNames) do
    destination[layerName] = true
  end
end

local function copyTable(source)
  local result = {}
  for key, value in pairs(source) do
    result[key] = value
  end
  return result
end

local function copyActivePageIds()
  return copyTable(state.activePageIds)
end

local function samePageIds(a, b)
  for pageId in pairs(a) do
    if not b[pageId] then return false end
  end
  for pageId in pairs(b) do
    if not a[pageId] then return false end
  end
  return true
end

local function pageDepth(pageId)
  local depth = 1
  local page = config.pages[pageId]
  while page.parentId do
    depth = depth + 1
    page = config.pages[page.parentId]
  end
  return depth
end

-- Resolve each frame role from its default through increasingly specific
-- active-page overrides. The deepest active override replaces its inherited
-- value for that role.
local function resolveFrameLayers()
  local desiredLayers = {}
  for role in pairs(frameRoles) do
    local roleLayers = {}
    local selected = config.frame[role]
    local selectedDepth = 0
    local usedDepths = {}

    for pageId in pairs(state.activePageIds) do
      local page = config.pages[pageId]
      local candidate = page.frame and page.frame[role]
      if candidate and viewFor(candidate, state.access) then
        local depth = pageDepth(pageId)
        assert(not usedDepths[depth], "multiple active " .. role .. " overrides")
        usedDepths[depth] = true
        if depth > selectedDepth then
          selected = candidate
          selectedDepth = depth
        end
      end
    end

    addLayers(roleLayers, viewFor(selected, state.access))
    for layerName in pairs(roleLayers) do
      desiredLayers[layerName] = true
    end
  end
  return desiredLayers
end

local function resolveDesiredLayers()
  local desiredLayers = resolvePageLayers()
  local frameLayers = resolveFrameLayers()
  for layerName in pairs(frameLayers) do
    desiredLayers[layerName] = true
  end
  if state.keypadVisible and keypadRequired() then
    addLayers(desiredLayers,
      config.pages[config.access.keypadPageId].views[Navigator.Access.LOCKED])
  end
  return desiredLayers
end

local function collectViewLayers(destination, views)
  for _, layerNames in pairs(views) do
    addLayers(destination, layerNames)
  end
end

local function collectConfiguredLayers()
  local allLayers = {}
  for _, definition in pairs(config.frame) do
    collectViewLayers(allLayers, definition.views)
  end
  for _, page in pairs(config.pages) do
    collectViewLayers(allLayers, page.views)
    for _, definition in pairs(page.frame or {}) do
      collectViewLayers(allLayers, definition.views)
    end
  end
  return allLayers
end

local function reconcileVisibility()
  local desiredLayers = resolveDesiredLayers()
  local layersToCheck = visibilityInitialized
    and visibleLayers or collectConfiguredLayers()

  for layerName in pairs(layersToCheck) do
    if not desiredLayers[layerName] then setLayerVisibility(layerName, false) end
  end
  for layerName in pairs(desiredLayers) do
    if not visibleLayers[layerName] then setLayerVisibility(layerName, true) end
  end

  visibleLayers = desiredLayers
  visibilityInitialized = true
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

local function updateHistoryControls()
  local controls = config and config.historyControls
  if not controls then return end
  if controls.back then controls.back.IsDisabled = #historyBack == 0 end
  if controls.forward then controls.forward.IsDisabled = #historyForward == 0 end
end

local function cappedPush(stack, pageIds)
  stack[#stack + 1] = pageIds
  local maxEntries = config.historyMaxEntries
  if maxEntries == nil then maxEntries = 25 end
  if maxEntries == false then return end
  if maxEntries and #stack > maxEntries then
    table.remove(stack, 1)
  end
end

local function clearHistory()
  historyBack = {}
  historyForward = {}
  updateHistoryControls()
end

local function recordHistory(beforePageIds)
  cappedPush(historyBack, beforePageIds)
  historyForward = {}
  updateHistoryControls()
end

local function updatePageOpenControls()
  if not config then return end
  for pageId, page in pairs(config.pages) do
    local controls = page.controls
    if controls and controls.open then
      controls.open.Boolean = state.activePageIds[pageId] == true
    end
  end
end

local function restartPinEntryTimer()
  if not keypadRequired() then
    stopPinEntryTimer()
    return
  end
  if config.access.pinEntryTimeoutSeconds == 0 then
    stopPinEntryTimer()
    return
  end
  pinEntryTimer():Start(config.access.pinEntryTimeoutSeconds)
end

local function restartSessionTimer()
  if state.access == Navigator.Access.LOCKED
      or config.access.sessionTimeoutSeconds == 0 then
    stopSessionTimer()
    return
  end
  sessionTimer():Start(config.access.sessionTimeoutSeconds)
end

local function closeUnavailablePages(targetAccess)
  local unavailableIds = {}
  for pageId in pairs(state.activePageIds) do
    if not viewFor(config.pages[pageId], targetAccess) then
      unavailableIds[#unavailableIds + 1] = pageId
    end
  end

  for _, pageId in ipairs(unavailableIds) do
    if state.activePageIds[pageId] then
      closeBranch(pageId)
    end
  end
end

local function resetState()
  state.access = Navigator.Access.LOCKED
  activateRootPage(homePageId(Navigator.Access.LOCKED))
  state.keypadVisible = false
end

local function showKeypad()
  assert(keypadRequired(), "keypad is not enabled")
  clearHistory()
  if state.access == Navigator.Access.LOCKED then
    state.activePageIds = { [config.access.keypadPageId] = true }
    state.keypadVisible = false
  else
    state.keypadVisible = true
  end
  updatePageOpenControls()
  reconcileVisibility()
  restartPinEntryTimer()
end

local function closeKeypad()
  clearHistory()
  stopPinEntryTimer()
  if state.access == Navigator.Access.LOCKED then
    activateRootPage(homePageId(Navigator.Access.LOCKED))
  else
    state.keypadVisible = false
  end
  updatePageOpenControls()
  reconcileVisibility()
end

local function validateHierarchy(pages)
  for pageId in pairs(pages) do
    local currentId = pageId
    local visited = {}
    local depth = 1

    while currentId do
      visited[currentId] = true
      local parentId = pages[currentId].parentId

      if parentId then
        assert(not visited[parentId],
          pageId .. " has a cycle in its parent chain")
        depth = depth + 1
        assert(depth <= 3,
          pageId .. " is deeper than sub-subpage level")
      end

      currentId = parentId
    end
  end
end

local function hasMultipleAncestor(pages, page)
  local parentId = page.parentId
  while parentId do
    local parent = pages[parentId]
    if not parent then return false end -- Unknown parents are reported later.
    if parent.childDisplayMode == Navigator.ChildDisplayMode.MULTIPLE then
      return true
    end
    parentId = parent.parentId
  end
  return false
end

local function validateAccessName(ownerId, access)
  assert(type(access) == "string" and access ~= "",
    ownerId .. " has an invalid access level")
  assert(access == string.lower(access),
    ownerId .. " access levels must be lowercase")
end

local function validateViews(pageId, views, levels)
  assert(type(views) == "table",
    pageId .. " requires a views table")
  for access, layers in pairs(views) do
    validateAccessName(pageId, access)
    assert(levels[access],
      pageId .. " uses undeclared access level " .. access)
    assert(type(layers) == "table" and #layers > 0,
      pageId .. " views must be non-empty layer lists")
    for _, layerName in ipairs(layers) do
      assert(type(layerName) == "string" and layerName ~= "",
        pageId .. " has an invalid layer name")
    end
  end
end

local function validateFrame(ownerId, definitions, isOverride, levels)
  assert(type(definitions) == "table", ownerId .. " requires frame")
  for role, definition in pairs(definitions) do
    assert(frameRoles[role], ownerId .. " has unknown frame role " .. role)
    assert(type(definition) == "table",
      ownerId .. " " .. role .. " definition must be a table")
    validateViews(ownerId .. " " .. role, definition.views, levels)
  end

  if not isOverride then
    for role in pairs(frameRoles) do
      local definition = definitions[role]
      assert(definition and definition.views[Navigator.Access.DEFAULT],
        ownerId .. " requires a default " .. role)
    end
  end
end

local function validateBuiltinLevel(levels, access)
  local definition = levels[access]
  assert(type(definition) == "table",
    "access.levels." .. access .. " is required")
  assert(type(definition.homePageId) == "string"
      and definition.homePageId ~= "",
    "access.levels." .. access .. ".homePageId must be a page ID")
  for key in pairs(definition) do
    assert(key == "homePageId",
      "access.levels." .. access .. " may only define homePageId")
  end
end

local function validateAccess(access)
  assert(type(access) == "table", "access must be a table")
  assert(type(access.levels) == "table", "access.levels must be a table")
  validateBuiltinLevel(access.levels, Navigator.Access.LOCKED)
  validateBuiltinLevel(access.levels, Navigator.Access.DEFAULT)

  for level, definition in pairs(access.levels) do
    validateAccessName("access.levels", level)
    assert(type(definition) == "table",
      "access.levels." .. level .. " must be a table")
    if level ~= Navigator.Access.LOCKED
        and level ~= Navigator.Access.DEFAULT then
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

-- Static set of supported page-local control names. Keys are field names;
-- true means the control name is valid. This never changes at runtime.
local pageControlKeys = {
  open = true,
  close = true,
  continue = true,
  openKeypad = true,
  closeKeypad = true,
}

-- Static set of supported access control names. Keys are field names;
-- true means the control name is valid. This never changes at runtime.
local accessControlKeys = {
  state = true,
  request = true,
  lock = true,
  activityPulse = true,
}

-- Static set of supported history control names. Keys are field names;
-- true means the control name is valid. This never changes at runtime.
local historyControlKeys = {
  back = true,
  forward = true,
}

local function validateControls(ownerId, controls, allowedKeys)
  assert(type(controls) == "table", ownerId .. " must be a table")
  for key, control in pairs(controls) do
    assert(allowedKeys[key], ownerId .. "." .. tostring(key)
      .. " is not a supported control")
    assert(control ~= nil, ownerId .. "." .. key .. " must be a control")
  end
end

local function validateConfig(candidate)
  assert(type(candidate.uci) == "table", "uci must be a table")
  assert(type(candidate.uci.name) == "string" and candidate.uci.name ~= "",
    "uci.name must be a non-empty string")
  assert(candidate.uci.pageName == nil
      or type(candidate.uci.pageName) == "string" and candidate.uci.pageName ~= "",
    "uci.pageName must be a non-empty string")
  assert(candidate.uci.transition == nil
      or type(candidate.uci.transition) == "string" and candidate.uci.transition ~= "",
    "uci.transition must be a non-empty string")

  validateAccess(candidate.access)
  if candidate.accessControls then
    validateControls("accessControls", candidate.accessControls, accessControlKeys)
    assert(candidate.accessControls.state,
      "accessControls.state is required")
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

  assert(type(candidate.pages) == "table", "pages must be a table")
  validateFrame("config", candidate.frame, false, candidate.access.levels)

  for _, access in ipairs({ Navigator.Access.LOCKED, Navigator.Access.DEFAULT }) do
    local pageId = candidate.access.levels[access].homePageId
    local page = candidate.pages[pageId]
    assert(page, "missing home page for " .. access .. ": " .. pageId)
    assert(not page.parentId, access .. " home page must be a root page")
    assert(page.views[access], access .. " home page has no matching view")
  end

  if candidate.access.keypadRequired then
    local keypadPage = candidate.pages[candidate.access.keypadPageId]
    assert(type(keypadPage) == "table",
      "access.keypadPageId does not identify a page")
    assert(type(keypadPage.views) == "table", "keypad page requires views")
    assert(keypadPage.views[Navigator.Access.LOCKED],
      "keypad page requires a locked view")
  end

  for pageId, page in pairs(candidate.pages) do
    assert(type(pageId) == "string" and pageId ~= "", "page IDs must be strings")
    assert(type(page) == "table", pageId .. " page definition must be a table")
    validateViews(pageId, page.views, candidate.access.levels)

    if page.controls then
      validateControls(pageId .. ".controls", page.controls, pageControlKeys)
      if not candidate.access.keypadRequired then
        assert(page.controls.openKeypad == nil,
          pageId .. ".controls.openKeypad requires access.keypadRequired = true")
        assert(page.controls.closeKeypad == nil,
          pageId .. ".controls.closeKeypad requires access.keypadRequired = true")
      else
        assert(page.controls.continue == nil,
          pageId .. ".controls.continue requires access.keypadRequired = false")
      end
    end

    if page.parentId then
      assert(candidate.pages[page.parentId],
        pageId .. " has an unknown parentId")
    else
      assert(page.views[Navigator.Access.LOCKED]
          or page.views[Navigator.Access.DEFAULT],
        pageId .. " root requires a locked or default view")
    end

    if page.frame then
      assert(not hasMultipleAncestor(candidate.pages, page),
        pageId .. " cannot override frame below a MULTIPLE parent")
      validateFrame(pageId, page.frame, true, candidate.access.levels)
    end

    local mode = page.childDisplayMode
    assert(mode == nil or mode == Navigator.ChildDisplayMode.SINGLE
        or mode == Navigator.ChildDisplayMode.MULTIPLE,
      pageId .. " has an invalid childDisplayMode")

    local parentVisibility = page.parentVisibility
    assert(parentVisibility == nil
        or parentVisibility == Navigator.ParentVisibility.KEEP
        or parentVisibility == Navigator.ParentVisibility.HIDE,
      pageId .. " has an invalid parentVisibility")
    assert(parentVisibility == nil or page.parentId,
      pageId .. " is a section and cannot set parentVisibility")

    if page.defaultChildId then
      assert(not page.parentId,
        pageId .. " is not a section and cannot set defaultChildId")
      local child = candidate.pages[page.defaultChildId]
      assert(child and child.parentId == pageId,
        pageId .. " defaultChildId must identify a direct child")
      assert(viewFor(child, Navigator.Access.DEFAULT),
        pageId .. " default child requires a default view")
    end
  end

  validateHierarchy(candidate.pages)
end

-- Change access, prune unavailable pages, and apply layer visibility.
function Navigator.setAccess(targetAccess)
  assert(config, "configure Navigator before changing access level")
  assert(type(targetAccess) == "string" and config.access.levels[targetAccess],
    "invalid access level")

  if targetAccess == state.access then
    if targetAccess == Navigator.Access.LOCKED then
      clearHistory()
      stopPinEntryTimer()
      stopSessionTimer()
      resetState()
      updatePageOpenControls()
      reconcileVisibility()
    end
    return
  end

  clearHistory()

  if targetAccess == Navigator.Access.LOCKED then
    stopPinEntryTimer()
    stopSessionTimer()
    resetState()
    updatePageOpenControls()
    reconcileVisibility()
    return
  end

  stopPinEntryTimer()
  state.keypadVisible = false
  if state.access == Navigator.Access.LOCKED then
    activateRootPage(homePageId(Navigator.Access.DEFAULT))
  else
    closeUnavailablePages(targetAccess)
  end
  state.access = targetAccess
  updatePageOpenControls()
  reconcileVisibility()
  restartSessionTimer()
end

-- Open a configured page ID and apply section/child behavior from config.
function Navigator.openPage(pageId)
  assert(config, "configure Navigator before navigating")

  local page = config.pages[pageId]
  assert(page, "unknown pageId: " .. tostring(pageId))
  assert(viewFor(page, state.access),
    pageId .. " is unavailable for " .. state.access .. " access")

  local beforePageIds = copyActivePageIds()
  if not page.parentId then
    activateRootPage(pageId)
    if samePageIds(beforePageIds, state.activePageIds) then
      updatePageOpenControls()
      return
    end
    updatePageOpenControls()
    reconcileVisibility()
    recordHistory(beforePageIds)
    return
  end

  assert(state.activePageIds[page.parentId], pageId .. " has an inactive parent")

  local parent = config.pages[page.parentId]
  local mode = parent.childDisplayMode or Navigator.ChildDisplayMode.SINGLE
  if mode == Navigator.ChildDisplayMode.SINGLE then
    for activeId in pairs(state.activePageIds) do
      local activePage = config.pages[activeId]
      if activeId ~= pageId and activePage.parentId == page.parentId then
        closeBranch(activeId)
      end
    end
  end

  state.activePageIds[pageId] = true
  if samePageIds(beforePageIds, state.activePageIds) then
    updatePageOpenControls()
    return
  end
  updatePageOpenControls()
  reconcileVisibility()
  recordHistory(beforePageIds)
end

-- Close an active nested page branch; root pages cannot close.
function Navigator.closePage(pageId)
  assert(config, "configure Navigator before navigating")

  local page = config.pages[pageId]
  assert(page, "unknown pageId: " .. tostring(pageId))
  assert(page.parentId, pageId .. " is a root page and cannot be closed")
  assert(state.activePageIds[pageId], pageId .. " is not active")

  local beforePageIds = copyActivePageIds()
  closeBranch(pageId)
  if samePageIds(beforePageIds, state.activePageIds) then
    updatePageOpenControls()
    return
  end
  updatePageOpenControls()
  reconcileVisibility()
  recordHistory(beforePageIds)
end

local function isRisingEdge(control)
  return control.Boolean ~= false
end

local function writeAccessState(targetAccess)
  if accessStateControl then accessStateControl.String = targetAccess end
end

local function applyAccessString(accessString)
  local targetAccess = string.lower(tostring(accessString or ""))
  if targetAccess == "" then return end
  if not config.access.levels[targetAccess] then
    print("Navigator ignored unknown access: " .. targetAccess)
    return
  end
  Navigator.setAccess(targetAccess)
end

local function requestAccess(targetAccess)
  writeAccessState(targetAccess)
  Navigator.setAccess(targetAccess)
end

local function keypadIsShowing()
  return keypadRequired() and (state.keypadVisible
    or state.activePageIds[config.access.keypadPageId] == true
  )
end

local function restoreActivePageIds(pageIds)
  state.activePageIds = copyTable(pageIds)
  updatePageOpenControls()
  reconcileVisibility()
end

function Navigator.back()
  assert(config, "configure Navigator before navigating")
  if keypadIsShowing() or #historyBack == 0 then
    updateHistoryControls()
    return
  end

  local currentPageIds = copyActivePageIds()
  local previousPageIds = historyBack[#historyBack]
  historyBack[#historyBack] = nil
  cappedPush(historyForward, currentPageIds)
  restoreActivePageIds(previousPageIds)
  updateHistoryControls()
end

function Navigator.forward()
  assert(config, "configure Navigator before navigating")
  if keypadIsShowing() or #historyForward == 0 then
    updateHistoryControls()
    return
  end

  local currentPageIds = copyActivePageIds()
  local nextPageIds = historyForward[#historyForward]
  historyForward[#historyForward] = nil
  cappedPush(historyBack, currentPageIds)
  restoreActivePageIds(nextPageIds)
  updateHistoryControls()
end

onPinEntryTimeout = function()
  closeKeypad()
end

onSessionTimeout = function()
  requestAccess(Navigator.Access.LOCKED)
end

local function bindControls()
  local accessControls = config.accessControls
  if accessControls then
    accessStateControl = accessControls.state
    accessStateControl.EventHandler = function(control)
      applyAccessString(control.String)
    end

    if accessControls.request then
      accessControls.request.EventHandler = function(control)
        if not isRisingEdge(control) then return end
        if state.access == Navigator.Access.LOCKED
            and not keypadRequired() then
          requestAccess(Navigator.Access.DEFAULT)
        elseif state.access == Navigator.Access.DEFAULT
            and keypadRequired() then
          showKeypad()
        elseif not isLockedAccess(state.access) then
          requestAccess(Navigator.Access.DEFAULT)
        end
      end
    end

    if accessControls.lock then
      accessControls.lock.EventHandler = function(control)
        if isRisingEdge(control) then requestAccess(Navigator.Access.LOCKED) end
      end
    end

    if accessControls.activityPulse then
      accessControls.activityPulse.EventHandler = function()
        if keypadIsShowing() then restartPinEntryTimer() end
        restartSessionTimer()
      end
    end

    applyAccessString(accessStateControl.String)
  end

  for pageId, page in pairs(config.pages) do
    local controls = page.controls
    if controls then
      if controls.open then
        controls.open.EventHandler = function(control)
          if isRisingEdge(control) then Navigator.openPage(pageId) end
        end
      end

      if controls.close then
        controls.close.EventHandler = function(control)
          if not isRisingEdge(control) then return end
          if keypadRequired() and pageId == config.access.keypadPageId then
            closeKeypad()
          else
            Navigator.closePage(pageId)
          end
        end
      end

      if controls.continue then
        controls.continue.EventHandler = function(control)
          if isRisingEdge(control) then requestAccess(Navigator.Access.DEFAULT) end
        end
      end

      if controls.openKeypad then
        controls.openKeypad.EventHandler = function(control)
          if isRisingEdge(control) then showKeypad() end
        end
      end

      if controls.closeKeypad then
        controls.closeKeypad.EventHandler = function(control)
          if isRisingEdge(control) then closeKeypad() end
        end
      end
    end
  end

  local historyControls = config.historyControls
  if historyControls then
    if historyControls.back then
      historyControls.back.EventHandler = function(control)
        if isRisingEdge(control) then Navigator.back() end
      end
    end

    if historyControls.forward then
      historyControls.forward.EventHandler = function(control)
        if isRisingEdge(control) then Navigator.forward() end
      end
    end

    updateHistoryControls()
  end
end

function Navigator.configure(projectConfig)
  assert(not config, "Navigator may be configured only once")
  assert(type(projectConfig) == "table", "configure requires a config table")
  validateConfig(projectConfig)
  config = projectConfig
  resetState()
  updatePageOpenControls()
  reconcileVisibility()
  bindControls()
end

function Navigator.getState()
  return {
    access = state.access,
    activePageIds = copyTable(state.activePageIds),
    keypadVisible = state.keypadVisible,
    canGoBack = #historyBack > 0,
    canGoForward = #historyForward > 0,
  }
end

function Navigator.getVisibleLayers()
  return copyTable(visibleLayers)
end

return Navigator
