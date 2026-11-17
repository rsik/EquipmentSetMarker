-- red/green harness for EquipmentSetMarker: drives the addon against a stubbed wow api.
-- scenarios pick the container shape, because the two bag systems on this client differ:
--   blizzard  ContainerFrameContainer.ContainerFrames + buttons that know their ItemLocation
--   gw2       GW2_UI hides blizzards frames and uses unnamed ItemFrame.Containers frames
--             whose gw_items buttons only answer GetID()
--   broken    C_EquipmentSet throws, nothing may die and /esm must still answer
-- run: node run.js <addon.lua> <harness.lua> [scenario]

local scenario = _G.__scenario or "blizzard"

local report = {}
local function ok(cond, label)
  report[#report + 1] = (cond and "PASS " or "RED  ") .. label
  return cond
end
local realprint = print

--------------------------------------------------------------------------------
-- frame / texture stubs
--------------------------------------------------------------------------------

local messages = {}

-- every name here was verified as a string in Wow.exe on this client (count >= 1). the real
-- client prints its own chat error for an unknown event and pcall cannot hush it, and
-- GetSendEventNames does not exist here, so the stub refuses unknown names too instead of
-- accepting anything, which is how two dead events reached a release
local knownEvents = {
  ADDON_LOADED = true, PLAYER_LOGIN = true, PLAYER_ENTERING_WORLD = true,
  PLAYER_EQUIPMENT_CHANGED = true, EQUIPMENT_SETS_CHANGED = true,
  BAG_UPDATE = true, BAG_UPDATE_DELAYED = true, GET_ITEM_INFO_RECEIVED = true,
  BANKFRAME_OPENED = true, BANKFRAME_CLOSED = true, PLAYERBANKSLOTS_CHANGED = true,
}

local allFrames = {}

local function mixin(t)
  function t:RegisterEvent(e)
    if not knownEvents[e] then
      error(('Attempt to register unknown event "%s"'):format(tostring(e)))
    end
    self.events[e] = true
  end
  function t:UnregisterEvent(e) self.events[e] = nil end
  function t:IsEventRegistered(e) return self.events[e] end
  function t:SetScript(name, fn) self.scripts[name] = fn end
  function t:GetScript(name) return self.scripts[name] end
  function t:HookScript(name, fn)
    self.hooks[name] = self.hooks[name] or {}
    if not self.scripts[name] then
      self.scripts[name] = function(...) for _, h in ipairs(self.hooks[name]) do h(...) end end
    else
      local orig = self.scripts[name]
      self.scripts[name] = function(...)
        orig(...)
        for _, h in ipairs(self.hooks[name]) do h(...) end
      end
    end
    self.hooks[name][#self.hooks[name] + 1] = fn
    return true
  end
  function t:Fire(name, ...) if self.scripts[name] then self.scripts[name](self, ...) end end
  function t:HasScript() return true end
  function t:SetFrameLevel(v) self.level = v end
  function t:GetFrameLevel() return self.level or 1 end
  function t:SetID(v) self.id = v end
  function t:GetID() return self.id end
  function t:GetName() return self.name end
  function t:GetParent() return self.parent end
  function t:GetChildren() return unpack(self.children) end
  function t:AddChild(c) self.children[#self.children + 1] = c end
  function t:IsShown() return self.shown ~= false end
  function t:IsVisible()
    -- __visible lets a test model a frame whose own shown flag is true while an ancestor
    -- is hidden, which is what IsVisible is for
    if self.__visible ~= nil then return self.__visible end
    return self:IsShown()
  end
  function t:Show() self.shown = true end
  function t:Hide() self.shown = false end
  function t:SetWidth(v) self.width = v end
  function t:GetWidth() return self.width or 36 end
  function t:SetHeight(v) self.height = v end
  function t:GetHeight() return self.height or 36 end
  function t:SetSize(w, h) self.width, self.height = w, h end
  function t:SetAllPoints() end
  function t:SetParent() end
  function t:SetPoint(a, rel, p, x, y)
    self.anchor = { point = a, relative = rel, relativePoint = p, x = x, y = y }
  end
  function t:ClearAllPoints() self.anchorCount = (self.anchorCount or 0) + 1 end
  function t:SetTexture(v) self.texture = v texWrites = (texWrites or 0) + 1 end
  function t:SetColorTexture() end
  function t:SetTexCoord() end
  function t:SetDrawLayer(layer, level) self.layer, self.drawLevel = layer, level end
  function t:SetVertexColor() end
  function t:SetBlendMode() end
  function t:AddMessage(m) messages[#messages + 1] = tostring(m) end
  function t:AddLine(m) messages[#messages + 1] = "LINE " .. tostring(m) end
  return t
end

local function newFrame(kind, name, parent)
  local f = mixin({
    kind = kind or "Frame", name = name, parent = parent,
    children = {}, events = {}, scripts = {}, hooks = {}, textures = {},
  })
  function f:CreateTexture()
    local t = mixin({ kind = "Texture", parent = f, children = {}, events = {}, scripts = {}, hooks = {} })
    f.textures[#f.textures + 1] = t
    return t
  end
  allFrames[#allFrames + 1] = f
  if name then _G[name] = f end
  if parent and parent.AddChild then parent:AddChild(f) end
  return f
end

function CreateFrame(kind, name, parent, template)
  local f = newFrame(kind, name, parent or UIParent)
  f.template = template
  return f
end

local function fireEvent(event, ...)
  for _, f in ipairs(allFrames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end

local function tick()
  clock = clock + 5
  for _, f in ipairs(allFrames) do
    if f.scripts.OnUpdate then f.scripts.OnUpdate(f, 1) end
  end
end

local function runTimers()
  local pending = C_Timer.__p or {}
  C_Timer.__p = {}
  for _, fn in ipairs(pending) do pcall(fn) end
end

--------------------------------------------------------------------------------
-- cost meter: the work a refresh actually pushes through the client api
--------------------------------------------------------------------------------
local calls = {}

local function count(key, t, method)
  if type(t) ~= "table" or type(t[method]) ~= "function" then return end
  local raw = t[method]
  t[method] = function(...) calls[key] = (calls[key] or 0) + 1 return raw(...) end
end

local function resetCalls()
  for k in pairs(calls) do calls[k] = nil end
  texWrites = 0
end

local function total()
  local n = 0
  for _, v in pairs(calls) do n = n + v end
  return n + (texWrites or 0)
end

local function callReport()
  local parts = {}
  for k, v in pairs(calls) do parts[#parts + 1] = k .. " " .. v end
  parts[#parts + 1] = "texWrites " .. (texWrites or 0)
  return table.concat(parts, ", ")
end

--------------------------------------------------------------------------------
-- wow globals
--------------------------------------------------------------------------------

messages = {}
clock = 100
DEFAULT_CHAT_FRAME = mixin({ name = "ChatFrame", children = {}, events = {}, scripts = {}, hooks = {} })
SlashCmdList = {}
UIParent = newFrame("Frame", "UIParent")

function wipe(t) for k in pairs(t) do t[k] = nil end end
unpack = unpack or table.unpack -- the client has unpack, fengari has table.unpack
function GetTime() return clock end
frameCount = 0
function GetFrameCount() return frameCount end
function GetBuildInfo() return 1, 2, 3, "16.0.1" end
C_Timer = { After = function(_, fn) C_Timer.__p = C_Timer.__p or {}; C_Timer.__p[#C_Timer.__p + 1] = fn end }
function hooksecurefunc() return true end

WOW_PROJECT_ID = 7
WOW_PROJECT_CAMELOT = 7
NUM_CONTAINER_FRAMES = 13
BANK_CONTAINER = -1

local SETS = {
  { id = 21, name = "PvP Gear", icon = "interface\\icons\\inv_chest_cloth_42", items = { 1001, 1002 } },
  { id = 22, name = "raid", icon = "interface\\icons\\inv_sword_04", items = { 1002, 2000 } },
}
C_EquipmentSet = {
  GetEquipmentSetIDs = function() local t = {}; for i = 1, #SETS do t[i] = SETS[i].id end; return t end,
  GetEquipmentSetInfo = function(id)
    for _, s in ipairs(SETS) do if s.id == id then return s.name, s.icon, false, false, 0, 0 end end
  end,
  GetItemIDs = function(id)
    for _, s in ipairs(SETS) do if s.id == id then return s.items end end
  end,
  GetEquipmentSetID = function(name)
    for _, s in ipairs(SETS) do if s.name == name then return s.id end end
  end,
}

BAG = {}
C_Container = {
  GetContainerItemInfo = function(bag, slot)
    local itemID = BAG[bag] and BAG[bag][slot]
    if not itemID then return nil end
    return { itemID = itemID, hyperlink = "|cff808080item:" .. itemID .. "|r" }
  end,
  GetContainerNumSlots = function() return 20 end,
}
C_Item = {
  GetItemIDFromLink = function(link) return type(link) == "string" and tonumber(link:match("item:(%d+)")) end,
  GetInventoryItemID = function(_, slot) return EQUIPPED[slot] end,
}
EQUIPPED = {}

-- what the marker is expected to draw, per icon shape the client might hand back
local expectedIcon = "interface\\icons\\inv_chest_cloth_42"
local FALLBACK = "Interface/OptionsFrame/UI-OptionsFrame-NewFeatureIcon"
local beltIcon = "interface\\icons\\inv_belt_leather_02"

if scenario == "numicon" then
  -- modern builds hand back a texture data id instead of a path
  C_EquipmentSet.GetEquipmentSetInfo = function(id)
    for _, s in ipairs(SETS) do if s.id == id then return s.name, 132741, false, false, 3, 0 end end
  end
  expectedIcon = 132741
elseif scenario == "slotapi" then
  -- the set info has no icon at all, only the per slot api does
  C_EquipmentSet.GetEquipmentSetInfo = function(id)
    for _, s in ipairs(SETS) do if s.id == id then return s.name, false, false, 3, 0 end end
  end
  GetContainerItemEquipmentSetInfo = function(bag, slot)
    local itemID = BAG[bag] and BAG[bag][slot]
    for _, s in ipairs(SETS) do
      for _, it in ipairs(s.items) do
        if it == itemID then return s.name, beltIcon, false, false, s.id end
      end
    end
  end
  expectedIcon = beltIcon
elseif scenario == "swapped" then
  -- icon path first, name second
  C_EquipmentSet.GetEquipmentSetInfo = function(id)
    for _, s in ipairs(SETS) do if s.id == id then return s.icon, s.name, false, false, 3, 0 end end
  end
elseif scenario == "noicon" then
  -- no icon anywhere, and small numbers that must not be mistaken for a texture id
  C_EquipmentSet.GetEquipmentSetInfo = function(id)
    for _, s in ipairs(SETS) do if s.id == id then return s.name, 0, false, false, 8, 0 end end
  end
  expectedIcon = FALLBACK
end
GetInventorySlotInfo = function(name)
  return ({ HeadSlot = 1, NeckSlot = 2, ChestSlot = 5, MainHandSlot = 16 })[name]
end

-- the five slots the scenario puts items in: 1 in a set, 2 not in a set, 3 empty,
-- 4 in two sets, 5 in a set
local buttons = {}

local function makeButton(name, parent, slot, bagID)
  local b = newFrame("Button", name, parent)
  b:SetID(slot)
  if bagID then
    function b:GetBagID() return bagID end
    function b:GetItemLocation() return { GetBagAndSlot = function() return bagID, slot end } end
  end
  return b
end

newFrame("Button", "CharacterHeadSlot", UIParent)
EQUIPPED[1] = 2000

local tooltip = newFrame("GameTooltip", "GameTooltip", UIParent)
function tooltip:GetItem() return "Some Item", self.itemLink end

local bagShape = (scenario == "gw2") and "gw2" or "blizzard"
if bagShape == "gw2" then
  -- GW2_UI: unnamed container frame under ItemFrame.Containers, buttons only in gw_items
  local bagFrame = CreateFrame("Frame", "GwBagFrame", UIParent)
  bagFrame.ItemFrame = CreateFrame("Frame", nil, bagFrame)
  local cf = CreateFrame("Frame", nil, bagFrame.ItemFrame)
  cf:SetID(0)
  cf.gw_items = {}
  bagFrame.ItemFrame.Containers = { [0] = cf }
  for slot = 1, 5 do
    local b = CreateFrame("ItemButton", "GwContainerItem0_" .. slot, cf)
    b:SetID(slot)
    cf.gw_items[slot] = b
    buttons[slot] = b
  end
else
  local bagFrame = newFrame("Frame", "ContainerFrame1", UIParent)
  bagFrame:SetID(0)
  bagFrame.Items = {}
  for slot = 1, 5 do
    local b = makeButton("ContainerFrame1Item" .. slot, bagFrame, slot, 0)
    bagFrame.Items[slot] = b
    buttons[slot] = b
  end
  -- what BetterVendorPrice and SharpiesGearJudge call on this client, so the primary button
  -- path is the one under test
  function bagFrame:EnumerateValidItems()
    local i = 0
    return function()
      i = i + 1
      local button = self.Items[i]
      if button then return i, button end
    end
  end
  if scenario == "stale" then
    -- and the older shape, so the Items fallback stays covered
    bagFrame.EnumerateValidItems = nil
  end
  ContainerFrameContainer = { ContainerFrames = { bagFrame } }
end

if scenario == "broken" then
  C_EquipmentSet.GetEquipmentSetIDs = function() error("boom from the client") end
end

if scenario == "stale" then
  -- saved variables left behind by the version that was still called EquipSetMarker.
  -- the rename has to carry these over: saved variables are only filled where a key is
  -- missing, so a fresh default would silently win and the users settings would be gone
  EquipSetMarkerDB = { anchor = "TOP", scale = 0.9, enabled = true, version = 1 }
end

--------------------------------------------------------------------------------
-- wrap the per slot calls so the idle cost can be measured
--------------------------------------------------------------------------------
count("bagItemInfo", C_Container, "GetContainerItemInfo")
count("bagLink", _G, "GetContainerItemLink")
count("playerItem", C_Item, "GetInventoryItemID")

local parents = {}
local parentSeen = {}
for _, b in ipairs(buttons) do
  count("location", b, "GetItemLocation")
  count("buttonItem", b, "GetItem")
  local p = b:GetParent()
  if p and not parentSeen[p] then
    parentSeen[p] = true
    parents[#parents + 1] = p
    count("enum", p, "EnumerateValidItems")
  end
end

--------------------------------------------------------------------------------
-- load and drive
--------------------------------------------------------------------------------

local chunk, err = load(_G.__addonSrc, "EquipmentSetMarker.lua")
if not chunk then error("the addon does not even compile: " .. tostring(err)) end
chunk("EquipmentSetMarker")

ok(#allFrames > 1, "loader frame exists at load time")

fireEvent("ADDON_LOADED", "OtherAddon", true)
ok(SlashCmdList["EQUIPMENTSETMARKER"] == nil, "another addon loading does not initialize us")
fireEvent("ADDON_LOADED", "EquipmentSetMarker", true)
ok(SlashCmdList["EQUIPMENTSETMARKER"] ~= nil, "/esm registered on our ADDON_LOADED")

BAG[0] = { [1] = 1001, [2] = 3000, [4] = 1002, [5] = 1001 }
fireEvent("BAG_UPDATE", 0)
tick()

local function marker(button) return button.textures[1] end
local function marked(button) return (marker(button) and marker(button).shown == true) and true or false end

-- the login status line arrives through C_Timer.After
fireEvent("PLAYER_ENTERING_WORLD")
tick()
messages = {}
for _, fn in ipairs(C_Timer.__p or {}) do pcall(fn) end
ok(#messages >= 1, "login status line printed: " .. tostring(messages[1]))

if scenario == "broken" then
  ok(#messages >= 0, "a throwing client api does not stop the update loop")
  ok(SlashCmdList["EQUIPMENTSETMARKER"] ~= nil, "/esm still answers when the api throws")
  messages = {}
  local safe = pcall(SlashCmdList["EQUIPMENTSETMARKER"], "dump")
  ok(safe, "/esm dump survives a throwing api")
  ok(#messages > 0, "dump still printed something")
  local text = table.concat(messages, "\n")
  ok(text:find("boom from the client") ~= nil, "dump names the api that threw")
else
  ok(buttons[1].esmMarker ~= nil or #buttons[1].textures > 0,
    "the " .. bagShape .. " container buttons were learned")
  ok(marked(buttons[1]), "slot 1 (item 1001, in a set) is marked")
  ok(not marked(buttons[2]), "slot 2 (item 3000, no set) is not marked")
  ok(not marked(buttons[3]), "empty slot 3 is not marked")
  ok(marked(buttons[4]), "slot 4 (item 1002, in two sets) is marked")
  ok(marked(_G["CharacterHeadSlot"]), "equipped head slot (item 2000) is marked")
  ok(marker(buttons[1]).texture == expectedIcon,
    "marker draws the expected icon, got " .. tostring(marker(buttons[1]).texture))
  if scenario == "blizzard" or scenario == "gw2" or scenario == "stale" then
    ok(marker(buttons[4]).texture == "interface\\icons\\inv_chest_cloth_42",
      "an item in two sets takes the first set that claimed it")
  end
  ok(marker(buttons[1]).layer == "OVERLAY" and marker(buttons[1]).drawLevel == 7,
    "marker draws above the icon and the count")

  if scenario == "stale" then
    ok(marker(buttons[1]).anchor.point == "TOPRIGHT",
      "a stale anchor in saved variables is migrated, got " .. tostring(marker(buttons[1]).anchor.point))
    ok(marker(buttons[1]):GetWidth() > 30,
      "the users own scale survives the migration (" .. marker(buttons[1]):GetWidth() .. ")")
    ok(type(EquipmentSetMarkerDB) == "table" and EquipmentSetMarkerDB.scale == 0.9,
      "the renamed saved variables carry the settings over, got " .. tostring(EquipmentSetMarkerDB and EquipmentSetMarkerDB.scale))
    ok(EquipSetMarkerDB == nil or next(EquipSetMarkerDB) == nil,
      "the old saved variable is emptied so it cannot come back later")
  end

  -- tooltip line. each hover is a new frame; the two hook paths for one hover are the
  -- same frame and must produce exactly one line
  frameCount = frameCount + 1
  messages = {}
  tooltip.itemLink = "|cff808080item:1001|r"
  tooltip:Fire("OnTooltipSetItem")
  local tipText = table.concat(messages, "\n")
  ok(tipText:find("Equipment set") ~= nil, "tooltip names the set for a set item")
  if scenario == "blizzard" or scenario == "gw2" or scenario == "stale" or scenario == "swapped" then
    ok(tipText:find("PvP Gear") ~= nil, "tooltip prints the set name, not the icon path")
  end

  frameCount = frameCount + 1
  messages = {}
  tooltip.itemLink = "|cff808080item:3000|r"
  tooltip:Fire("OnTooltipSetItem")
  ok(#messages == 0, "no tooltip line for an item in no set")

  frameCount = frameCount + 1
  messages = {}
  tooltip.itemLink = "|cff808080item:1001|r"
  tooltip:Fire("OnTooltipSetItem")
  tooltip:Fire("OnTooltipSetItem")
  ok(#messages == 1, "two hook paths in one frame give one line, got " .. #messages)

  frameCount = frameCount + 1
  tooltip:Fire("OnTooltipSetItem")
  ok(#messages == 2, "hovering the same slot again later shows the line again, got " .. #messages)

  -- the set loses an item
  SETS[1].items = {}
  fireEvent("EQUIPMENT_SETS_CHANGED")
  tick()
  ok(not marked(buttons[1]), "slot 1 unmarked after its set dropped the item")
  ok(marked(buttons[4]), "slot 4 keeps its mark, 1002 is still in a set")
  ok(not marked(buttons[2]), "slot 2 was never marked and still is not")

  -- the item leaves the bag
  BAG[0][4] = nil
  fireEvent("BAG_UPDATE", 0)
  tick()
  ok(not marked(buttons[4]), "slot 4 unmarked after the item left the bag")
  BAG[0][4] = 1002
  fireEvent("BAG_UPDATE", 0)
  tick()
  ok(marked(buttons[4]), "slot 4 marked again when the item comes back")

  -- on / off
  SlashCmdList["EQUIPMENTSETMARKER"]("off")
  tick()
  ok(not marked(buttons[4]), "/esm off hides the markers")
  SlashCmdList["EQUIPMENTSETMARKER"]("on")
  tick()
  ok(marked(buttons[4]), "/esm on brings them back")

  -- where the marker sits
  SlashCmdList["EQUIPMENTSETMARKER"]("corner")
  tick()
  ok(marker(buttons[4]).anchor.point == "TOPRIGHT", "corner sits inside the slot")
  SlashCmdList["EQUIPMENTSETMARKER"]("top")
  tick()
  ok(marker(buttons[4]).anchor.point == "BOTTOM", "top floats above the slot")
  ok(marker(buttons[4]).anchorCount <= 8,
    "the anchor is replaced, not stacked (" .. marker(buttons[4]).anchorCount .. " re-sets)")

  -- size and icon override
  SlashCmdList["EQUIPMENTSETMARKER"]("size 1")
  tick()
  local big = marker(buttons[4]):GetWidth()
  SlashCmdList["EQUIPMENTSETMARKER"]("size 0.2")
  tick()
  ok(marker(buttons[4]):GetWidth() < big, "size 0.2 is smaller than size 1")
  SlashCmdList["EQUIPMENTSETMARKER"]("icon Interface\\Icons\\INV_Misc_QuestionMark")
  tick()
  ok(marker(buttons[4]).texture == "Interface\\Icons\\INV_Misc_QuestionMark", "/esm icon overrides the set icon")
  SlashCmdList["EQUIPMENTSETMARKER"]("icon reset")
  tick()
  if scenario == "blizzard" or scenario == "gw2" or scenario == "stale" then
    -- set 21 was emptied earlier, so 1002 is only claimed by set 22 by now
    ok(marker(buttons[4]).texture == "interface\\icons\\inv_sword_04",
      "icon reset goes back to the set icon, got " .. tostring(marker(buttons[4]).texture))
  end

  -- dump
  messages = {}
  SlashCmdList["EQUIPMENTSETMARKER"]("dump")
  local text = table.concat(messages, "\n")
  realprint(text)
  realprint("---- end dump ----")
  ok(#messages >= 4, "dump printed " .. #messages .. " lines")
  ok(text:find("sets 2") ~= nil, "dump counts the sets")
  ok(text:find("  step failed:") == nil, "dump reports no failed step")
  ok(text:find("CAMELOT 7") ~= nil, "dump names the client")
  ok(text:find("refreshes") ~= nil, "dump reports how much work it has done")

  messages = {}
  SlashCmdList["EQUIPMENTSETMARKER"]("bogus")
  ok(#messages == 1, "an unknown command prints one help line")

  --------------------------------------------------------------------------
  -- idle cost: the reported 2% cpu. nothing is visible, so a refresh must not
  -- touch the client at all, and the updater must not stay attached
  --------------------------------------------------------------------------
  local core = _G["EquipmentSetMarkerCore"]
  ok(type(core) == "table", "the core frame is reachable by name")

  -- bags open, nothing changed: the picture is already right, so nothing gets drawn twice
  resetCalls()
  fireEvent("BAG_UPDATE")
  tick()
  ok(texWrites == nil or texWrites == 0,
    "a refresh with nothing changed writes no texture (" .. callReport() .. ")")

  -- state for the wake test, set up here rather than inherited from the steps above: set 21
  -- owns those items again and one marked slot is picked out of the current picture
  SETS[1].items = { 1001, 1002, 1003 }
  fireEvent("EQUIPMENT_SETS_CHANGED")
  tick()
  local wakeButton
  for _, b in ipairs(buttons) do
    if marked(b) then wakeButton = b break end
  end
  ok(wakeButton ~= nil, "a slot is marked before it goes out of sight")
  local wakeBag = (type(wakeButton.GetBagID) == "function" and wakeButton:GetBagID())
    or wakeButton:GetParent():GetID()
  local wakeSlot = wakeButton:GetID()

  -- bags closed: the buttons keep their own shown flag, only the container goes away, so a
  -- gate that asks the button "are you shown" would still walk all one hundred and ten slots
  for _, f in ipairs(parents) do f:Hide() end
  resetCalls()
  fireEvent("BAG_UPDATE")
  tick()
  ok(calls.enum == nil or calls.enum == 0,
    "a refresh with every container hidden does not enumerate its items (" .. callReport() .. ")")
  ok(calls.location == nil or calls.location == 0,
    "hidden buttons are not resolved for an item (" .. callReport() .. ")")
  ok((calls.bagItemInfo or 0) + (calls.bagLink or 0) == 0,
    "hidden buttons do not query the bag api (" .. callReport() .. ")")
  ok(marked(wakeButton), "a marker drawn while visible is left alone, it is out of sight")

  -- quiet for a while: the per frame callback has to go away on its own
  tick()
  tick()
  ok(core.scripts ~= nil and core.scripts.OnUpdate == nil,
    "the updater detaches its OnUpdate once nothing has changed for a while")
  runTimers()
  tick()
  ok(core.scripts.OnUpdate == nil, "the watchdog does not wake the updater for nothing")
  resetCalls()
  runTimers()
  runTimers()
  ok(total() == 0, "staying parked costs no client calls (" .. callReport() .. ")")

  -- the number itself, printed so it is visible instead of argued about: how many lua
  -- callbacks and client calls 300 idle frames cost
  local updateCalls = 0
  local attached = core.scripts.OnUpdate
  if attached then
    core.scripts.OnUpdate = function(...) updateCalls = updateCalls + 1 return attached(...) end
  end
  resetCalls()
  for _ = 1, 300 do tick() end
  realprint(("idle cost: %d updater callbacks, %d client calls per 300 frames"):format(updateCalls, total()))
  ok(updateCalls == 0, "300 idle frames cost no updater callbacks (" .. updateCalls .. ")")
  ok(total() == 0, "300 idle frames cost no client calls (" .. callReport() .. ")")

  -- the character pane is not a container frame. if opening it cannot wake a parked updater,
  -- the markers on equipped items would never appear at all
  local head = _G["CharacterHeadSlot"]
  head:Hide()
  tick()
  head:Show()
  head:Fire("OnShow")
  tick()
  ok(core.scripts.OnUpdate ~= nil, "showing an equipment slot wakes the updater")
  tick()
  ok(core.scripts.OnUpdate == nil, "and it parks again, so the container wake below is what is under test")

  -- open a bag again. while it was parked the item left the slot, so the first pass after
  -- waking has to see current bag contents, not what was there when it went to sleep
  BAG[wakeBag][wakeSlot] = nil
  fireEvent("BAG_UPDATE")
  tick()
  tick()
  ok(marked(wakeButton), "nothing was repainted behind a closed bag")
  for _, f in ipairs(parents) do f:Show(); f:Fire("OnShow") end
  tick()
  ok(core.scripts.OnUpdate ~= nil, "showing a container wakes the updater")
  tick()
  ok(not marked(wakeButton),
    "the pass after waking repaints from current bag contents, still marked: " .. tostring(marked(wakeButton)))

  -- empty equipment manager must not divide by zero or throw
  SETS[1].items = {}
  SETS[2].items = {}
  SETS[2].name = ""
  fireEvent("EQUIPMENT_SETS_CHANGED")
  tick()
  ok(not marked(buttons[4]), "everything unmarked once no set holds any item")
end

-- the client says so itself in chat when an event name is dead, so this is the fence that
-- keeps an unverifiable name out of a release
local eventNoise
for _, m in ipairs(messages) do
  if m:find("unknown event", 1, true) or m:find("ESM event ", 1, true) then
    eventNoise = m
    break
  end
end
ok(not eventNoise, "no dead event name was registered" .. (eventNoise and (": " .. eventNoise) or ""))

print(table.concat(report, "\n"))
local reds = 0
for _, r in ipairs(report) do if r:find("^RED") then reds = reds + 1 end end
print(("\n%s: %s (%d checks)"):format(scenario, reds == 0 and "ALL GREEN" or (reds .. " RED"), #report))
