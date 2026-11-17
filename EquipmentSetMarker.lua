--[[
EquipmentSetMarker - marks inventory slots whose item is part of a saved Equipment Manager set.

Forever runs on the 11.x derived engine, and a lot of the classic container globals are
gone there. What actually works on this client (learned from BetterVendorPrice and
SharpiesGearJudge, both of which do this same job in this addon folder):

  container frames  ContainerFrameContainer.ContainerFrames (array of frames),
                    ContainerFrameCombinedBags, legacy ContainerFrame<N> up to
                    NUM_CONTAINER_FRAMES, and ItemFrame.Containers tables for bag addons
                    that draw their own containers (GW2_UI hides blizzards and does exactly
                    that, so ignoring it means drawing on frames that are off screen)
  slot buttons      frame:EnumerateValidItems(), fallback frame.Items[i] / <name>Item<i>
  which slot        button:GetBagID() (the combined bag frame spans several bags), fallback
                    frame:GetID(); the slot is always button:GetID()
  what is gone      ContainerFrame_Update and the classic per slot update helpers, so there
                    is no global to hook. the frames own OnShow / UpdateItems are the trigger

Every change is reported in chat, so a silent failure is not possible. /esm dump prints the
whole picture.
]]

local ADDON = ...

local ESM = {}

local FALLBACK_ICON = "Interface/OptionsFrame/UI-OptionsFrame-NewFeatureIcon"
local REFRESH_DELAY = 0.2
local SWEEP_DELAY = 1.5
local MAX_BUTTON_SCAN = 40
-- an OnUpdate attached to a frame runs every frame the client draws, so an addon that polls
-- costs a slice of a core even with the bags shut. the updater therefore detaches itself once
-- it has had nothing to do for IDLE_PARK seconds, and a parked addon only takes one cheap look
-- around every IDLE_WATCHDOG seconds (opening a bag wakes it immediately through the frames
-- own OnShow)
local IDLE_PARK = 1.0
local IDLE_WATCHDOG = 2.0

local defaults = {
  enabled = true,
  scale = 0.42, -- marker size as a fraction of the slot width
  anchor = "CORNER", -- CORNER inside the slot, TOP floats it above the slot
  tooltip = true,
  icon = false, -- false = use each sets own icon, otherwise a texture path
  equipSlots = true,
  verbose = true,
}

-- saved variables from an older version are only filled with defaults, never corrected, so a
-- setting that turned out to be a bad default has to be migrated by hand. version 1 defaulted
-- to TOP, which draws outside the slot and disappears when a frame clips its children.
local DB_VERSION = 2

local db
local index = {} -- itemID -> set
local sets = {} -- { id, name, icon }
local targets = {} -- button -> { frame = container } or { invSlot = n }
local order = {} -- buttons in insertion order, so a refresh never grows while iterating
local hooked = {} -- container frames whose UpdateItems is hooked
local showHooked = {} -- frames whose OnShow wakes the updater
local containers = {} -- container frames found by the last sweep
local failures = {} -- every step that threw, printed at login and by /esm dump
local failuresShown = 0
local MAX_FAILURE_MESSAGES = 6
local stats = { painted = 0, refreshes = 0, passes = 0, parked = 0 }
local dirty, needRebuild, lastSweep = true, true, 0
local core, tooltipBy
-- set up in the lifecycle section, forward declared because events and frame hooks call them
local wake, awake, watchdogQueued, lastWork = nil, false, false, 0

--------------------------------------------------------------------------------
-- reporting
--------------------------------------------------------------------------------

local function say(msg)
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffffd100ESM|r " .. tostring(msg)) end
end

local function note_failure(where, err)
  failures[#failures + 1] = where .. ": " .. tostring(err)
  if failuresShown < MAX_FAILURE_MESSAGES then
    failuresShown = failuresShown + 1
    say("|cffff4040" .. where .. " failed|r " .. tostring(err))
    if failuresShown == MAX_FAILURE_MESSAGES then say("|cffff4040more failures are only in /esm dump|r") end
  end
end

-- runs a step and turns a throw into a chat line instead of a dead addon
local function step(where, fn)
  local ok, err = pcall(fn)
  if not ok then note_failure(where, err) end
  return ok
end

--------------------------------------------------------------------------------
-- api shims
--------------------------------------------------------------------------------

local function slotItem(bagID, slotID)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bagID, slotID)
    return info and info.itemID
  end
  if GetContainerItemInfo then
    local _, _, _, _, _, _, itemID = GetContainerItemInfo(bagID, slotID)
    return itemID
  end
end

local function itemIDFromLink(link)
  if type(link) ~= "string" then return end
  if C_Item and C_Item.GetItemIDFromLink then return C_Item.GetItemIDFromLink(link) end
  return tonumber(link:match("item:(%d+)"))
end

local function equipmentSlotItem(invSlot)
  if C_Item and C_Item.GetInventoryItemID then return C_Item.GetInventoryItemID("player", invSlot) end
  if GetInventoryItemID then return GetInventoryItemID("player", invSlot) end
end

--------------------------------------------------------------------------------
-- set index
--------------------------------------------------------------------------------

-- the return order of the set info call is not trusted. values are classified instead:
-- a string with a slash is a texture path, any other string is the name, and a big number
-- is a texture data id (modern builds hand back an id instead of a path). the size check is
-- what keeps an item count from being painted as an icon.
local MIN_TEXTURE_ID = 1000

local function textureValue(v)
  if type(v) == "string" and (v:find("/", 1, true) or v:find("\\", 1, true)) then return v end
  if type(v) == "number" and v >= MIN_TEXTURE_ID then return v end
end

local function classify(...)
  local name, icon
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if not icon and textureValue(v) then icon = v
    elseif type(v) == "string" and v ~= "" and not name and not textureValue(v) then name = v end
  end
  return name, icon
end

-- the set info call is reached through pcall, so the success flag leads and gets dropped.
-- unpack(..., 2) skips it: select(2, ...) would "return everything from 2 on" and the
-- parentheses around it would then truncate that straight back to a single value, which is
-- exactly how the icon (the second value) used to disappear
local function parseInfo(...)
  if select(1, ...) == false then return end
  return classify(unpack({ ... }, 2))
end

-- note: no parentheses around the call, they would cut the returns down to one value and
-- the icon (the second return) would silently disappear
local function fetchSetInfo(setID, listIndex)
  if setID and C_EquipmentSet and C_EquipmentSet.GetEquipmentSetInfo then
    return parseInfo(pcall(C_EquipmentSet.GetEquipmentSetInfo, setID))
  end
  if GetEquipmentSetInfo then
    return parseInfo(pcall(GetEquipmentSetInfo, listIndex or setID))
  end
end

local function setIDForName(name)
  local getters = {}
  if C_EquipmentSet and C_EquipmentSet.GetEquipmentSetID then getters[#getters + 1] = C_EquipmentSet.GetEquipmentSetID end
  if GetEquipmentSetID then getters[#getters + 1] = GetEquipmentSetID end
  for i = 1, #getters do
    local ok, id = pcall(getters[i], name)
    if ok and id then return id end
  end
end

-- some builds return the item id table, some fill the one handed in, so allow both
local function forEachSetItem(setID, cb)
  local getter = (C_EquipmentSet and (C_EquipmentSet.GetItemIDs or C_EquipmentSet.GetEquipmentSetItemIDs))
    or GetEquipmentSetItemIDs
  if not getter or not setID then return end
  local filled = {}
  local ok, result = pcall(getter, setID, filled)
  local list = (type(result) == "table" and result) or filled
  if type(list) ~= "table" then return end
  for _, itemID in pairs(list) do
    if type(itemID) == "number" and itemID > 0 then cb(itemID) end
  end
end

-- the client also answers "is this slot part of a set" per slot. on builds where the set
-- info call carries no icon this is the only source that has one, so it is consulted for
-- every slot the set index does not know: false in the cache means the client said "no set"
-- for that slot. the cache only lives until the contents change (see onEvent), a slot keeps
-- no memory of the item that used to sit in it
local slotInfoCache = {}
local slotInfoValid = false

local function slotSetInfo(bagID, slotID)
  if not bagID or not slotID or not slotInfoValid then return end
  local getter = (C_Container and C_Container.GetContainerItemEquipmentSetInfo)
    or GetContainerItemEquipmentSetInfo
  if not getter then return end

  local key = tostring(bagID) .. ":" .. tostring(slotID)
  local cached = slotInfoCache[key]
  if cached ~= nil then return cached or nil end

  local ok, a, b, c, d, e = pcall(getter, bagID, slotID)
  local name, icon
  if ok then name, icon = classify(a, b, c, d, e) end
  if name or icon then
    slotInfoCache[key] = { name = name, icon = icon }
    return slotInfoCache[key]
  end
  slotInfoCache[key] = false
end

function ESM.Rebuild()
  wipe(index)
  wipe(sets)
  wipe(slotInfoCache)
  slotInfoValid = true
  needRebuild = false

  local ids = C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs and C_EquipmentSet.GetEquipmentSetIDs()
  if type(ids) == "table" then
    for _, id in ipairs(ids) do
      local name, icon = fetchSetInfo(id)
      sets[#sets + 1] = { id = id, name = name or ("Set " .. tostring(id)), icon = icon }
    end
  elseif GetNumEquipmentSets then
    for i = 1, GetNumEquipmentSets() do
      local name, icon = fetchSetInfo(nil, i)
      if name then sets[#sets + 1] = { id = setIDForName(name), name = name, icon = icon } end
    end
  end

  for _, set in ipairs(sets) do
    forEachSetItem(set.id, function(itemID)
      if not index[itemID] then index[itemID] = set end
    end)
  end
end

local function markerTextureFor(set)
  if type(db.icon) == "string" and db.icon ~= "" then return db.icon end
  local icon = set and set.icon
  if icon ~= nil and icon ~= false then return icon end
  return FALLBACK_ICON
end

--------------------------------------------------------------------------------
-- markers
--------------------------------------------------------------------------------

local function markerFor(button)
  local marker = button.esmMarker
  if not marker then
    -- draw level 7 keeps it above the icon, the count and the quality border
    marker = button:CreateTexture(nil, "OVERLAY", nil, 7)
    marker:SetTexCoord(0.06, 0.94, 0.06, 0.94)
    local edge = button:CreateTexture(nil, "OVERLAY", nil, 6)
    edge:SetColorTexture(0, 0, 0, 0.9)
    edge:SetPoint("TOPLEFT", marker, "TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", marker, "BOTTOMRIGHT", 1, -1)
    button.esmMarker, button.esmEdge = marker, edge
  end
  -- the frames own level can change, so the draw level is re-asserted on every pass
  marker:SetDrawLayer("OVERLAY", 7)
  return marker
end

local function hideMarker(button)
  if button.esmMarker and button.esmMarker:IsShown() then
    button.esmMarker:Hide()
    button.esmMarker.esmShown = false
  end
  if button.esmEdge and button.esmEdge:IsShown() then button.esmEdge:Hide() end
end

local function placeMarker(button, set)
  if not set then
    hideMarker(button)
    return
  end

  local marker = markerFor(button)
  local width = button:GetWidth()
  if type(width) ~= "number" or width <= 0 then width = 36 end
  local size = math.max(9, width * (tonumber(db.scale) or defaults.scale))
  local texture = markerTextureFor(set)
  local anchor = db.anchor == "TOP" and "TOP" or "CORNER"

  -- a pass that would draw exactly what is already drawn draws nothing: with a hundred and
  -- ten slots on screen this is the difference between two client calls and five hundred
  if marker.esmTexture == texture and marker.esmSize == size and marker.esmAnchor == anchor
    and marker.esmShown then
    -- shown again unconditionally: something else (a bag addon, a tooltip scan) can hide a
    -- child, and the values below say this is the right picture already
    marker:Show()
    stats.painted = stats.painted + 1
    return
  end
  marker.esmTexture, marker.esmSize, marker.esmAnchor = texture, size, anchor

  -- the anchor is written on every pass that changes it, so the old points go first
  marker:ClearAllPoints()
  marker:SetSize(size, size)
  marker:SetTexture(texture)
  if anchor == "TOP" then
    marker:SetPoint("BOTTOM", button, "TOP", 0, math.floor(size * 0.35))
  else
    marker:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
  end
  marker:Show()
  marker.esmShown = true

  if button.esmEdge then
    button.esmEdge:SetSize(size + 2, size + 2)
    button.esmEdge:Show()
  end
  stats.painted = stats.painted + 1
end

-- which slot a button shows, in bag/slot form. modern buttons answer through their own
-- ItemLocation, legacy and bag addon buttons inherit the bag from the frame they sit in
local function resolve(button, frame)
  if type(button.GetItemLocation) == "function" then
    local ok, location = pcall(button.GetItemLocation, button)
    if ok and type(location) == "table" and type(location.GetBagAndSlot) == "function" then
      local ok2, bagID, slotID = pcall(location.GetBagAndSlot, location)
      if ok2 and type(bagID) == "number" and type(slotID) == "number" and slotID > 0 then
        return bagID, slotID
      end
    end
  end

  local bagID, slotID
  if type(button.GetBagID) == "function" then
    local ok, id = pcall(button.GetBagID, button)
    if ok and type(id) == "number" then bagID = id end
  end
  if not bagID and frame and type(frame.GetID) == "function" then
    local ok, id = pcall(frame.GetID, frame)
    if ok and type(id) == "number" then bagID = id end
  end
  if type(button.GetID) == "function" then
    local ok, id = pcall(button.GetID, button)
    if ok and type(id) == "number" then slotID = id end
  end
  if not slotID and type(button.GetSlotIndex) == "function" then
    local ok, id = pcall(button.GetSlotIndex, button)
    if ok and type(id) == "number" then slotID = id end
  end
  if bagID and slotID and slotID > 0 then return bagID, slotID end
end

-- last resort, and the one that needs no numbering at all: an ItemButton answers for its
-- own item, whatever frame it happens to live in
local function buttonItemID(button)
  if type(button.GetItem) ~= "function" then return end
  local ok, item = pcall(button.GetItem, button)
  if not ok or type(item) ~= "table" or type(item.GetItemID) ~= "function" then return end
  local ok2, itemID = pcall(item.GetItemID, item)
  if ok2 and type(itemID) == "number" and itemID > 0 then return itemID end
end

local function note(button, target)
  if targets[button] == nil then order[#order + 1] = button end
  targets[button] = target
end

-- one visibility answer per frame per pass, so a hundred and ten slots cost fifteen checks.
-- IsVisible is preferred over IsShown because it walks the parent chain: a closed bag leaves
-- its own buttons flagged as shown, which is exactly the lie that makes a polling addon busy
-- forever with the bags shut
local visCache = {}

local function frameShown(f)
  if type(f) ~= "table" then return false end
  local cached = visCache[f]
  if cached ~= nil then return cached end
  local shown
  if type(f.IsVisible) == "function" then
    local ok, result = pcall(f.IsVisible, f)
    shown = (ok and result) and true or false
  elseif type(f.IsShown) == "function" then
    local ok, result = pcall(f.IsShown, f)
    shown = (ok and result) and true or false
  else
    shown = true -- cannot answer, so assume visible: correct first, quiet second
  end
  visCache[f] = shown
  return shown
end

local function updateButton(button)
  local target = targets[button]
  if type(target) ~= "table" then return end

  local itemID, bagID, slotID
  if target.invSlot then
    if db.equipSlots then itemID = equipmentSlotItem(target.invSlot) end
  else
    bagID, slotID = resolve(button, target.frame)
    if bagID then itemID = slotItem(bagID, slotID) end
  end
  if not itemID then itemID = buttonItemID(button) end

  local set = itemID and index[itemID]
  local info = slotSetInfo(bagID, slotID)
  if info then
    if not set then
      set = info
    elseif (set.icon == nil or set.icon == false) and info.icon then
      -- the set itself has no icon through the set api, this slot told us one: remember it
      -- for the whole set instead of asking again on every item of it
      set.icon = info.icon
    end
  end
  placeMarker(button, set)
end

local function safeUpdate(button)
  -- CreateTexture is the one thing a marker needs, GetID is not (a button can answer for
  -- its item through GetItem alone)
  if type(button) ~= "table" or type(button.CreateTexture) ~= "function" then return end
  local target = targets[button]
  -- a slot that is not on screen cannot show a marker, and asking it what it holds is not
  -- free: resolving one hidden slot costs an item location plus a bag query on the client.
  -- without this gate a refresh walks a hundred and ten dead slots five times a second
  local frame = (type(target) == "table" and target.frame) or button
  if not frameShown(frame) then return end
  stats.passes = stats.passes + 1
  local ok = pcall(updateButton, button)
  if not ok then targets[button] = nil end
end

--------------------------------------------------------------------------------
-- container discovery
--------------------------------------------------------------------------------

local function eachContainerFrame(fn)
  local seen = {}
  local function visit(frame)
    if type(frame) == "table" and type(frame.GetID) == "function" and not seen[frame] then
      seen[frame] = true
      fn(frame)
    end
  end
  if type(ContainerFrameContainer) == "table" and type(ContainerFrameContainer.ContainerFrames) == "table" then
    for _, frame in pairs(ContainerFrameContainer.ContainerFrames) do visit(frame) end
  end
  visit(ContainerFrameCombinedBags)
  for i = 1, (NUM_CONTAINER_FRAMES or 13) do visit(_G["ContainerFrame" .. i]) end
  -- bag addons that draw their own containers keep them under ItemFrame.Containers
  for _, owner in ipairs({ GwBagFrame, BankFrame }) do
    local containersTable = owner and owner.ItemFrame and owner.ItemFrame.Containers
    if type(containersTable) == "table" then
      for _, frame in pairs(containersTable) do visit(frame) end
    end
  end
end

local function eachButton(frame, fn)
  if type(frame.EnumerateValidItems) == "function" then
    local ok = pcall(function()
      for _, button in frame:EnumerateValidItems() do
        if type(button) == "table" then fn(button) end
      end
    end)
    if ok then return true end
  end
  if type(frame.gw_items) == "table" then
    for i = 1, #frame.gw_items do
      local button = frame.gw_items[i]
      if type(button) == "table" then fn(button) end
    end
    return true
  end
  local name = type(frame.GetName) == "function" and frame:GetName() or nil
  local found = 0
  for i = 1, MAX_BUTTON_SCAN do
    local button = (frame.Items and frame.Items[i])
      or (frame.buttons and frame.buttons[i])
      or (name and _G[name .. "Item" .. i])
    if type(button) == "table" then
      fn(button)
      found = found + 1
    end
  end
  return found > 0
end

-- the frames own update trigger: on this engine there is no ContainerFrame_Update global
local function hookShowWake(frame)
  if showHooked[frame] then return end
  showHooked[frame] = true
  -- showing a frame is the one signal that cannot be missed: a bag that opens does not always
  -- fire an event on this engine, and the character pane fires none at all. it is also what
  -- brings a parked updater back to life, so a parked addon costs nothing until something is
  -- actually drawn
  step("hook OnShow", function()
    frame:HookScript("OnShow", function() frame.esmDirty = true if wake then wake() end end)
  end)
end

local function hookFrame(frame)
  if hooked[frame] then return end
  hooked[frame] = true
  -- one flag for the whole frame instead of one wrapper per hook: container frames are
  -- pooled and recreated as bags open and close, and an old hook pointing at a dead frame
  -- would keep firing on every redraw forever
  frame.esmDirty = true
  hookShowWake(frame)
  if type(frame.UpdateItems) == "function" then
    step("hook UpdateItems", function()
      hooksecurefunc(frame, "UpdateItems", function() frame.esmDirty = true if wake then wake() end end)
    end)
  end
end

local EQUIP_SLOT_NAMES = {
  "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "ShirtSlot",
  "TabardSlot", "WristSlot", "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot",
  "Finger0Slot", "Finger1Slot", "Trinket0Slot", "Trinket1Slot",
  "MainHandSlot", "SecondaryHandSlot", "RangedSlot",
}

function ESM.Sweep(force)
  local now = GetTime()
  if not force and now - lastSweep < SWEEP_DELAY then return end
  lastSweep = now

  wipe(containers)
  eachContainerFrame(function(frame)
    containers[#containers + 1] = frame
    hookFrame(frame) -- hooked even while hidden: the hooks are what wake the addon later
    -- only a container that is on screen has buttons worth learning, and enumerating a
    -- hidden one is a client call per slot for nothing
    if frameShown(frame) then
      local learned = 0
      eachButton(frame, function(button)
        note(button, { frame = frame })
        learned = learned + 1
      end)
      frame.esmButtons = learned
    end
  end)

  if db.equipSlots and GetInventorySlotInfo then
    for _, slotName in ipairs(EQUIP_SLOT_NAMES) do
      local ok, invSlot = pcall(GetInventorySlotInfo, slotName)
      local frame = _G["Character" .. slotName]
      if ok and type(invSlot) == "number" and type(frame) == "table" then
        -- the character pane fires no event when it opens, so its slots need the show hook
        -- too or their markers would wait for something else to wake the addon
        hookShowWake(frame)
        if targets[frame] == nil then note(frame, { invSlot = invSlot }) end
      end
    end
  end
end

function ESM.Refresh(force)
  if needRebuild then ESM.Rebuild() end
  wipe(visCache) -- a fresh pass gets fresh visibility answers
  ESM.Sweep(force)
  stats.refreshes = stats.refreshes + 1
  stats.painted = 0
  for i = 1, #order do
    local button = order[i]
    if targets[button] ~= nil then
      if db.enabled then safeUpdate(button) else hideMarker(button) end
    end
  end
end

--------------------------------------------------------------------------------
-- tooltip line (covers bank, void storage and anything else the sweep misses)
--------------------------------------------------------------------------------

local function addSetLine(self, itemID)
  if not db.enabled or not db.tooltip or not itemID then return end
  local set = index[itemID]
  if not set then return end
  -- the processor path and the script path can both fire for one hover, so the same item
  -- is only annotated once per frame. keying it on the link alone would outlive the tooltip
  -- and the line would never come back when the same slot is hovered twice in a row.
  local tick = (type(GetFrameCount) == "function" and GetFrameCount()) or 0
  if self.esmAddedFor == itemID and self.esmAddedTick == tick then return end
  self.esmAddedFor, self.esmAddedTick = itemID, tick
  step("tooltip line", function()
    self:AddLine(("|T%s:14:14:0|t |cffffd100Equipment set:|r %s"):format(markerTextureFor(set), set.name or "?"))
    self:Show()
  end)
end

-- the modern client posts tooltip data through TooltipDataProcessor, and its presence does
-- not guarantee it fires, so the script hook is kept as well. both paths are idempotent.
function ESM.HookTooltips()
  local how = {}
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
    local allTypes = TooltipDataProcessor.AllTypes
      or (Enum and Enum.TooltipDataType and { Enum.TooltipDataType.Item })
    if allTypes then
      local ok = step("TooltipDataProcessor", function()
        TooltipDataProcessor.AddTooltipPostCall(allTypes, function(tooltip, data)
          if type(tooltip) ~= "table" then return end
          local itemID = type(data) == "table" and (data.itemID or (data.Item and data.Item.itemID))
          if type(itemID) ~= "number" then
            local got, _, link = pcall(tooltip.GetItem, tooltip)
            itemID = got and itemIDFromLink(link)
          end
          addSetLine(tooltip, itemID)
        end)
      end)
      if ok then how[#how + 1] = "TooltipDataProcessor" end
    end
  end

  for _, name in ipairs({ "GameTooltip", "ItemRefTooltip" }) do
    local tip = _G[name]
    if type(tip) == "table" and type(tip.HasScript) == "function" and tip:HasScript("OnTooltipSetItem") then
      local ok = step("hook " .. name, function()
        tip:HookScript("OnTooltipSetItem", function(self)
          local got, _, link = pcall(self.GetItem, self)
          addSetLine(self, got and itemIDFromLink(link))
        end)
      end)
      if ok then how[#how + 1] = name end
    end
  end

  tooltipBy = (#how > 0) and table.concat(how, " + ") or "none"
  return how
end

--------------------------------------------------------------------------------
-- commands and diagnostics
--------------------------------------------------------------------------------

local function countIndex()
  local n = 0
  for _ in pairs(index) do n = n + 1 end
  return n
end

local function line(fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  say(ok and msg or tostring(msg))
end

function ESM.Dump()
  local tbl = tostring
  line("build %s  project %s  CAMELOT %s", tbl(select(4, GetBuildInfo())), tbl(WOW_PROJECT_ID), tbl(WOW_PROJECT_CAMELOT))
  line("frames: ContainerFrameContainer %s  ContainerFrames %s  combined %s  NUM_CONTAINER_FRAMES %s",
    tbl(ContainerFrameContainer ~= nil), tbl(type(ContainerFrameContainer) == "table" and type(ContainerFrameContainer.ContainerFrames) == "table"),
    tbl(ContainerFrameCombinedBags ~= nil), tbl(NUM_CONTAINER_FRAMES))
  line("api: C_EquipmentSet %s  GetEquipmentSetIDs %s  GetItemIDs %s  C_Container %s  TooltipDataProcessor %s",
    tbl(C_EquipmentSet ~= nil), tbl(C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs ~= nil),
    tbl(C_EquipmentSet and (C_EquipmentSet.GetItemIDs or C_EquipmentSet.GetEquipmentSetItemIDs) ~= nil),
    tbl(C_Container ~= nil), tbl(TooltipDataProcessor ~= nil))
  line("index: sets %d  items %d  buttons %d  containers %d  marked %d  tooltip %s",
    #sets, countIndex(), #order, #containers, stats.painted, tbl(tooltipBy))
  -- the cost line: refreshes counts passes, slot passes counts only the slots that were on
  -- screen, parked counts how often the updater detached itself
  line("work: refreshes %d  slot passes %d  %s  parked %d times",
    stats.refreshes, stats.passes, awake and "awake" or "parked", stats.parked)
  for i, frame in ipairs(containers) do
    line("  container %d  name %s  bagID %s  buttons %d  shown %s",
      i, tbl(frame.GetName and frame:GetName()), tbl(frame:GetID()), tbl(frame.esmButtons),
      tbl(type(frame.IsShown) ~= "function" or frame:IsShown()))
  end
  for i, set in ipairs(sets) do
    local n = 0
    forEachSetItem(set.id, function() n = n + 1 end)
    line("  set %d  id %s  name %s  icon %s (%s)  items %d", i, tbl(set.id), tbl(set.name), tbl(set.icon), tbl(type(set.icon)), n)
    if C_EquipmentSet and C_EquipmentSet.GetEquipmentSetInfo and set.id then
      local ok, a, b, c, d, e = pcall(C_EquipmentSet.GetEquipmentSetInfo, set.id)
      line("    raw info: %s | %s | %s | %s | %s", tbl(a), tbl(b), tbl(c), tbl(d), tbl(e))
    end
  end
  -- what the per slot api answers for the first slot that holds something: that is where the
  -- set icon lives on builds whose set info call has none
  local getter = (C_Container and C_Container.GetContainerItemEquipmentSetInfo) or GetContainerItemEquipmentSetInfo
  line("slot api: %s", tbl(type(getter) == "function"))
  if type(getter) == "function" then
    local probed
    for bag = BANK_CONTAINER or -1, 6 do
      for slot = 1, 25 do
        local itemID = slotItem(bag, slot)
        if itemID then
          local ok, a, b, c, d, e = pcall(getter, bag, slot)
          line("  slot api raw bag %s slot %s item %s: %s | %s | %s | %s | %s",
            tbl(bag), tbl(slot), tbl(itemID), tbl(a), tbl(b), tbl(c), tbl(d), tbl(e))
          probed = true
          break
        end
      end
      if probed then break end
    end
    if not probed then line("  slot api: nothing in the bags to probe") end
  end
  if #failures > 0 then
    for i = 1, #failures do line("|cffff4040  step failed: %s|r", failures[i]) end
  else
    line("  no step failed")
  end
end

local sub = {
  on = function() db.enabled = true; dirty = true end,
  off = function() db.enabled = false; dirty = true end,
  top = function() db.anchor = "TOP"; dirty = true end,
  corner = function() db.anchor = "CORNER"; dirty = true end,
  tooltip = function(arg) db.tooltip = arg ~= "off" end,
  equip = function(arg) db.equipSlots = arg ~= "off"; lastSweep = 0; dirty = true end,
  verbose = function(arg) db.verbose = arg ~= "off" end,
  size = function(arg)
    local n = tonumber(arg)
    if n then db.scale = math.min(1.5, math.max(0.1, n)); dirty = true end
  end,
  icon = function(arg) db.icon = (arg and arg ~= "" and arg ~= "reset") and arg or false; dirty = true end,
  dump = function() ESM.Dump() end,
  reset = function()
    local keep = db.version
    for k in pairs(db) do db[k] = nil end
    for k, v in pairs(defaults) do db[k] = v end
    db.version = keep or DB_VERSION -- otherwise the next load migrates a second time
    lastSweep, needRebuild, dirty = 0, true, true
  end,
}

local function slash(input)
  local cmd, arg = tostring(input or ""):match("^(%S*)%s*(.-)%s*$")
  local fn = sub[(cmd or ""):lower()]
  if fn then
    step("command " .. tostring(cmd), function() fn(arg) end)
  else
    say("on|off, top|corner, size <0.1-1.5>, icon <path|reset>, tooltip on|off, equip on|off, reset, dump")
  end
end

--------------------------------------------------------------------------------
-- lifecycle
--------------------------------------------------------------------------------

local events = {
  "PLAYER_ENTERING_WORLD", "PLAYER_EQUIPMENT_CHANGED", "EQUIPMENT_SETS_CHANGED",
  "BAG_UPDATE", "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED",
}
local maybeEvents = { "BANKFRAME_OPENED", "BANKFRAME_SHOWN", "PLAYERBANKSLOTS_CHANGED", "PLAYERBANKBAGSLOTS_CHANGED" }

local function onEvent(self, event)
  if event == "EQUIPMENT_SETS_CHANGED" or event == "GET_ITEM_INFO_RECEIVED" or event == "PLAYER_ENTERING_WORLD" then
    needRebuild = true
  end
  if event:find("BAG") or event:find("BANK") or event == "PLAYER_EQUIPMENT_CHANGED" then
    -- whatever a slot belongs to is answered per slot content, so any content change drops
    -- those answers instead of trusting them across a move
    slotInfoValid = false
  end
  if wake then wake() end -- an event is work, and work is what unpapers the updater
  if event == "PLAYER_ENTERING_WORLD" then
    lastSweep = 0
    if db.verbose and C_Timer and C_Timer.After then
      C_Timer.After(3, function()
        step("status", function()
          line("after load: sets %d, items %d, buttons %d, containers %d, marked %d. /esm dump",
            #sets, countIndex(), #order, #containers, stats.painted)
          if #sets == 0 then
            say("|cffffa000no equipment sets found|r - make one in the Equipment Manager, then /esm dump")
          end
        end)
      end)
    end
  end
  dirty = true
end

--------------------------------------------------------------------------------
-- the updater: attached only while there is something to do
--------------------------------------------------------------------------------

local queueWatchdog, watchdog, park

queueWatchdog = function()
  if watchdogQueued or not (core and C_Timer and C_Timer.After) then return end
  watchdogQueued = true
  C_Timer.After(IDLE_WATCHDOG, watchdog)
end

watchdog = function()
  watchdogQueued = false
  local needed = dirty or needRebuild
  if not needed then
    for i = 1, #containers do
      local frame = containers[i]
      if frame and frame.esmDirty then needed = true break end
    end
  end
  -- a flag or an event is the real signal, this timer is only the safety net, so it goes back
  -- to sleep rather than reattaching the per frame callback for nothing
  if needed then wake() else queueWatchdog() end
end

park = function()
  if not awake then return end
  awake = false
  core:SetScript("OnUpdate", nil)
  stats.parked = stats.parked + 1
  queueWatchdog()
end

local function onTick(self, elapsed)
  -- any container that repainted itself asks for a pass through its own flag
  local flagged = false
  for i = 1, #containers do
    local frame = containers[i]
    if frame and frame.esmDirty then dirty, frame.esmDirty, flagged = true, nil, true end
  end
  self.esmElapsed = (self.esmElapsed or 0) + elapsed
  if dirty and self.esmElapsed >= REFRESH_DELAY then
    self.esmElapsed, dirty = 0, false
    lastWork = GetTime()
    step("refresh", function() ESM.Refresh() end)
  end
  if not dirty and not flagged and GetTime() - lastWork >= IDLE_PARK then park() end
end

wake = function()
  if not core then return end
  dirty = true
  if awake then return end
  awake = true
  lastWork = GetTime()
  core:SetScript("OnUpdate", onTick)
end

function ESM.Init()
  -- the command goes in first, so a later failure can never take it with it
  SLASH_EQUIPMENTSETMARKER1 = "/esm"
  SlashCmdList["EQUIPMENTSETMARKER"] = slash

  EquipmentSetMarkerDB = EquipmentSetMarkerDB or {}
  db = EquipmentSetMarkerDB
  -- the addon used to be called EquipSetMarker and its saved variables arrive under that
  -- name. they are adopted here rather than ignored: an existing key is never overwritten by
  -- a default and a missing one silently takes the default, so without this every setting
  -- resets on the rename
  local legacy = EquipSetMarkerDB
  if type(legacy) == "table" then
    for k, v in pairs(legacy) do if db[k] == nil then db[k] = v end end
    for k in pairs(legacy) do legacy[k] = nil end -- emptied, so it cannot come back next load
  end
  for k, v in pairs(defaults) do if db[k] == nil then db[k] = v end end
  if (tonumber(db.version) or 1) < DB_VERSION then
    if (tonumber(db.version) or 1) < 2 then db.anchor = defaults.anchor end
    db.version = DB_VERSION
  end

  core = CreateFrame("Frame", ADDON .. "Core", UIParent)
  core:SetScript("OnEvent", onEvent)
  for _, event in ipairs(events) do core:RegisterEvent(event) end
  for _, event in ipairs(maybeEvents) do step("event " .. event, function() core:RegisterEvent(event) end) end

  step("tooltip hooks", ESM.HookTooltips)
  step("first build", function()
    ESM.Rebuild()
    ESM.Sweep(true)
    ESM.Refresh(true)
  end)
  -- the updater goes on last and takes itself back off once the first passes are done
  wake()

  if db.verbose then
    line("loaded. C_EquipmentSet %s, sets %d, items %d, buttons %d.",
      tostring(C_EquipmentSet ~= nil), #sets, countIndex(), #order)
  end
end

local loader = CreateFrame("Frame", ADDON .. "Loader", UIParent)
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, addonName, loaded)
  if event ~= "ADDON_LOADED" or addonName ~= ADDON then return end
  self:UnregisterEvent("ADDON_LOADED")
  step("init", ESM.Init)
end)
