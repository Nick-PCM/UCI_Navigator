-- Keypad.lua
-- Q-SYS text-controller code keypad and active-access bridge.
--
-- Required controls:
--
-- Controls.Digit[1]..Controls.Digit[10]
--   Trigger Button controls. Digit[1] enters 1, Digit[2] enters 2, ...
--   Digit[9] enters 9, and Digit[10] enters 0.
--
-- Controls.Display
--   Text display. Shows one "*" per entered digit, shows access-denied
--   feedback, and is cleared after successful entry, Clear, or timeout.
--
-- Controls.Clear
--   Trigger Button control. Clears the current entered code and prompt.
--
-- Controls.Enter
--   Trigger Button control. Evaluates the currently entered code.
--
-- Controls.AccessName[1]..Controls.AccessName[n]
--   Text Edit controls. Access names matched with AccessCode by index.
--   AccessName[1] is the locked access name. AccessName[2] is the default
--   access name. Additional entries are project-defined access names.
--
-- Controls.AccessCode[1]..Controls.AccessCode[n]
--   Text Edit controls. Access codes matched with AccessName by index.
--   AccessCode[1] is forced blank because locked has no code. AccessCode[2]
--   unlocks AccessName[2]. Additional entries unlock matching access names.
--   Codes must be blank or 3-8 digits. Duplicate nonblank codes are cleared.
--
-- Controls.ActiveAccessName
--   Text control. Output is set to the currently valid access name. Input may
--   also be wired from another controller; matching values sync this module.
--
-- Controls.Override[1]..Controls.Override[n]
--   Trigger Button controls. Override[i] directly sets ActiveAccessName to
--   AccessName[i].

local INVALID_CODE_MESSAGE = "Try Again"
local INVALID_CODE_TIMEOUT = 10
local MIN_CODE_LENGTH = 3
local MAX_CODE_LENGTH = 8

local enteredCode = ""
local invalidDisplayVisible = false
local lastActiveAccessName = Controls.ActiveAccessName
  and tostring(Controls.ActiveAccessName.String or "")
  or ""

local function logActiveAccessName(access)
  if access == lastActiveAccessName then return end
  print("Keypad active access: " .. lastActiveAccessName .. " -> " .. access)
  lastActiveAccessName = accessw
end

local function invalidCodeTimer()
  if not _invalidCodeTimer then
    _invalidCodeTimer = Timer.New()
    _invalidCodeTimer.EventHandler = function(timer)
      timer:Stop()
      invalidDisplayVisible = false
      Controls.Display.String = ""
    end
  end
  return _invalidCodeTimer
end

local function stopInvalidCodeTimer()
  if _invalidCodeTimer then _invalidCodeTimer:Stop() end
end

local function accessNameAt(index)
  local control = Controls.AccessName and Controls.AccessName[index]
  return control and tostring(control.String or "") or ""
end

local function codeAt(index)
  local control = Controls.AccessCode and Controls.AccessCode[index]
  return control and tostring(control.String or "") or ""
end

local function accessCount()
  local count = 0
  while Controls.AccessName and Controls.AccessName[count + 1] do
    count = count + 1
  end
  return count
end

local function isValidCode(code)
  return code == ""
    or code:match("^%d+$") ~= nil
      and #code >= MIN_CODE_LENGTH
      and #code <= MAX_CODE_LENGTH
end

local function clearEntry()
  enteredCode = ""
  invalidDisplayVisible = false
  stopInvalidCodeTimer()
  Controls.Display.String = ""
end

local function setAccess(access)
  if access == "" then return end
  Controls.ActiveAccessName.String = access
  logActiveAccessName(access)
end

local function setAccessByIndex(index)
  setAccess(accessNameAt(index))
  clearEntry()
end

local function updatePrompt()
  Controls.Display.String = string.rep("*", #enteredCode)
end

local function beginFreshEntryIfNeeded()
  if invalidDisplayVisible then
    enteredCode = ""
    invalidDisplayVisible = false
    stopInvalidCodeTimer()
    Controls.Display.String = ""
  end
end

local function appendDigit(digit)
  beginFreshEntryIfNeeded()
  if #enteredCode >= MAX_CODE_LENGTH then return end
  enteredCode = enteredCode .. tostring(digit)
  updatePrompt()
end

local function showInvalidCode()
  enteredCode = ""
  Controls.Display.String = INVALID_CODE_MESSAGE
  invalidDisplayVisible = true
  invalidCodeTimer():Start(INVALID_CODE_TIMEOUT)
end

local function evaluateCode()
  beginFreshEntryIfNeeded()
  if enteredCode == "" then return end

  for index = 2, accessCount() do
    if enteredCode == codeAt(index) then
      setAccessByIndex(index)
      return
    end
  end

  showInvalidCode()
end

local function syncExternalAccess()
  local access = tostring(Controls.ActiveAccessName.String or "")
  if access == "" then return end
  for index = 1, accessCount() do
    if access == accessNameAt(index) then
      logActiveAccessName(access)
      return
    end
  end
end

local function codeIsDuplicate(index, code)
  if code == "" then return false end
  for otherIndex = 2, accessCount() do
    if otherIndex ~= index and codeAt(otherIndex) == code then
      return true
    end
  end
  return false
end

local function validateAccessCode(index)
  local control = Controls.AccessCode[index]
  local code = tostring(control.String or "")

  if index == 1 then
    if code ~= "" then control.String = "" end
    return
  end

  if not isValidCode(code) or codeIsDuplicate(index, code) then
    control.String = ""
  end
end

local function bindDigitControls()
  for index = 1, 10 do
    local control = Controls.Digit and Controls.Digit[index]
    if control then
      local digit = index == 10 and 0 or index
      control.EventHandler = function()
        appendDigit(digit)
      end
    end
  end
end

local function bindActionControls()
  Controls.Clear.EventHandler = function()
    clearEntry()
  end

  Controls.Enter.EventHandler = function()
    evaluateCode()
  end

  Controls.ActiveAccessName.EventHandler = function()
    syncExternalAccess()
  end
end

local function bindOverrideControls()
  for index = 1, accessCount() do
    local control = Controls.Override and Controls.Override[index]
    if control then
      control.EventHandler = function()
        setAccessByIndex(index)
      end
    end
  end
end

local function bindAccessCodeControls()
  for index = 1, accessCount() do
    local control = Controls.AccessCode[index]
    if control then
      control.EventHandler = function()
        validateAccessCode(index)
      end
      validateAccessCode(index)
    end
  end
end

local function initialize()
  assert(Controls.Digit, "Controls.Digit is required")
  assert(Controls.Display, "Controls.Display is required")
  assert(Controls.Clear, "Controls.Clear is required")
  assert(Controls.Enter, "Controls.Enter is required")
  assert(Controls.AccessName, "Controls.AccessName is required")
  assert(Controls.AccessCode, "Controls.AccessCode is required")
  assert(Controls.ActiveAccessName, "Controls.ActiveAccessName is required")

  assert(accessCount() >= 2,
    "Controls.AccessName must define locked and default access names")

  bindDigitControls()
  bindActionControls()
  bindOverrideControls()
  bindAccessCodeControls()

  clearEntry()
  setAccess(accessNameAt(1))
end

initialize()
