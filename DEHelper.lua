local ADDON = ...
DE_HelperDB = DE_HelperDB or { ignore = {} }

-- Container API shims (Classic vs Retail)
local GetNumSlots = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
local GetItemLink = C_Container and C_Container.GetContainerItemLink or GetContainerItemLink
local GetContItemInfo = C_Container and C_Container.GetContainerItemInfo or GetContainerItemInfo

-- Localized class names
local ARMOR_NAME  = GetItemClassInfo(LE_ITEM_CLASS_ARMOR)
local WEAPON_NAME = GetItemClassInfo(LE_ITEM_CLASS_WEAPON)

-- Frame/event setup
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("BAG_UPDATE_DELAYED")
f:RegisterEvent("BAG_UPDATE")
f:RegisterEvent("UNIT_SPELLCAST_START")
f:RegisterEvent("UNIT_SPELLCAST_STOP")

-- ===== debounce/skip for current item after click =====
local lastAction = { itemID = nil, untilTime = 0 }
local function ShouldSkip(itemID)
  return itemID and itemID == lastAction.itemID and GetTime() < (lastAction.untilTime or 0)
end

-- ==== UI: secure prompt ====
local Prompt = CreateFrame("Frame", "DEHelperPrompt", UIParent, "BackdropTemplate")
Prompt:SetSize(360, 140)
Prompt:SetPoint("CENTER")
Prompt:SetBackdrop({
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
Prompt:Hide()
Prompt:EnableMouse(true)
Prompt:SetMovable(true)
Prompt:RegisterForDrag("LeftButton")
Prompt:SetScript("OnDragStart", Prompt.StartMoving)
Prompt:SetScript("OnDragStop", Prompt.StopMovingOrSizing)

Prompt.title = Prompt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
Prompt.title:SetPoint("TOP", 0, -16)
Prompt.title:SetText("Disenchant this item?")

-- Item icon + tooltip
Prompt.itemBtn = CreateFrame("Button", "DEHelperItemBtn", Prompt, "ItemButtonTemplate")
Prompt.itemBtn:SetSize(36, 36)
Prompt.itemBtn:SetPoint("TOPLEFT", 20, -40)
Prompt.itemBtn.icon = _G["DEHelperItemBtnIconTexture"] or Prompt.itemBtn:CreateTexture(nil, "BORDER")
if not _G["DEHelperItemBtnIconTexture"] then Prompt.itemBtn.icon:SetAllPoints() end
Prompt.itemBtn.Count = _G["DEHelperItemBtnCount"]

Prompt.text = Prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
Prompt.text:SetPoint("LEFT", Prompt.itemBtn, "RIGHT", 12, 0)
Prompt.text:SetWidth(240)
Prompt.text:SetJustifyH("LEFT")
Prompt.text:SetText("")

-- Secure action button for Disenchant (player must physically click)
Prompt.disenchant = CreateFrame("Button", "DEHelperSecureDisenchant", Prompt, "SecureActionButtonTemplate,UIPanelButtonTemplate")
Prompt.disenchant:SetSize(110, 22)
Prompt.disenchant:SetPoint("BOTTOMLEFT", 20, 20)
Prompt.disenchant:SetText("Disenchant")
Prompt.disenchant:SetAttribute("type", "macro")

-- Regular buttons
Prompt.later = CreateFrame("Button", nil, Prompt, "UIPanelButtonTemplate")
Prompt.later:SetSize(80, 22)
Prompt.later:SetPoint("BOTTOM", 0, 20)
Prompt.later:SetText("Later")

Prompt.ignore = CreateFrame("Button", nil, Prompt, "UIPanelButtonTemplate")
Prompt.ignore:SetSize(110, 22)
Prompt.ignore:SetPoint("BOTTOMRIGHT", -20, 20)
Prompt.ignore:SetText("Ignore/Never")

-- State carried while shown
Prompt.current = { bag = nil, slot = nil, itemID = nil }

-- Tooltip for the item
Prompt.itemBtn:SetScript("OnEnter", function(self)
  local c = Prompt.current
  if c.bag and c.slot then
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetBagItem(c.bag, c.slot)
    GameTooltip:Show()
  end
end)
Prompt.itemBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ==== Helpers ====
local function HasDisenchant()
  local name = GetSpellInfo and GetSpellInfo("Disenchant")
  return name ~= nil
end

local function GetIconAndCount(bag, slot)
  local info = GetContItemInfo(bag, slot)
  if type(info) == "table" then
    return info.iconFileID, info.stackCount
  else
    local texture, count = GetContItemInfo(bag, slot) -- old API return list
    return texture, count
  end
end

local function ItemIDFromBagSlot(bag, slot)
  local link = GetItemLink(bag, slot)
  return link and tonumber(link:match("item:(%d+)")) or nil, link
end

local function IsLikelyDisenchantable(bag, slot)
  local id, link = ItemIDFromBagSlot(bag, slot)
  if not id or not link then return false end
  if DE_HelperDB.ignore[id] then return false end
  if ShouldSkip(id) then return false end

  local _, _, quality, _, _, class = GetItemInfo(link)
  if not quality or not class then return false end
  local isArmorOrWeapon = (class == ARMOR_NAME or class == WEAPON_NAME)
  local isGreenOrBetter = quality >= (LE_ITEM_QUALITY_UNCOMMON or 2) and quality <= (LE_ITEM_QUALITY_EPIC or 4)

  return isArmorOrWeapon and isGreenOrBetter, id, link
end

local function FindCandidate()
  for bag = 0, 4 do
    local slots = GetNumSlots(bag)
    if slots then
      for slot = 1, slots do
        local ok, id, link = IsLikelyDisenchantable(bag, slot)
        if ok then
          return bag, slot, id, link
        end
      end
    end
  end
end

local function ItemStillInBag(bag, slot, itemID)
  local idNow = ItemIDFromBagSlot(bag, slot)
  return idNow == itemID
end

-- Gather all disenchantable items currently in bags
local function GatherCandidates()
  local items = {}
  for bag = 0, 4 do
    local slots = GetNumSlots(bag)
    if slots then
      for slot = 1, slots do
        local ok, id, link = IsLikelyDisenchantable(bag, slot)
        if ok then
          table.insert(items, { bag = bag, slot = slot, id = id, link = link })
        end
      end
    end
  end
  return items
end

-- Show prompt and configure secure button
local function ShowPrompt(bag, slot, itemID, link)
  if InCombatLockdown() then return end
  if not HasDisenchant() then return end
  if not ItemStillInBag(bag, slot, itemID) then return end

  local itemName = GetItemInfo(link) or link
  Prompt.text:SetText(itemName or "This item")

  local icon, count = GetIconAndCount(bag, slot)
  if Prompt.itemBtn.icon then Prompt.itemBtn.icon:SetTexture(icon or nil) end
  if Prompt.itemBtn.Count then Prompt.itemBtn.Count:SetText(count and count > 1 and count or "") end

  Prompt.current.bag, Prompt.current.slot, Prompt.current.itemID = bag, slot, itemID

  local macro = string.format("/cast Disenchant\n/use %d %d", bag, slot)
  Prompt.disenchant:SetAttribute("type", "macro")
  Prompt.disenchant:SetAttribute("macrotext", macro)

  Prompt:Show()
end

-- TryPrompt scans and (re)shows the next candidate
local function TryPrompt()
  if InCombatLockdown() then return end
  if not HasDisenchant() then return end
  if Prompt:IsShown() then return end
  local bag, slot, itemID, link = FindCandidate()
  if bag then
    ShowPrompt(bag, slot, itemID, link)
  else
    Prompt:Hide()
  end
end

-- ==== List view ==== 
local ITEMS_PER_PAGE = 7
local List = CreateFrame("Frame", "DEHelperList", UIParent, "BackdropTemplate")
List:SetSize(360, 300)
List:SetPoint("CENTER")
List:SetBackdrop({
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
List:Hide()
List.items, List.page = {}, 1

List.rows = {}
for i = 1, ITEMS_PER_PAGE do
  local row = CreateFrame("Frame", nil, List)
  row:SetSize(320, 32)
  row:SetPoint("TOPLEFT", 20, -20 - (i - 1) * 34)
  row.icon = row:CreateTexture(nil, "BORDER")
  row.icon:SetSize(32, 32)
  row.icon:SetPoint("LEFT")
  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
  row.name:SetWidth(180)
  row.name:SetJustifyH("LEFT")
  row.disenchant = CreateFrame("Button", nil, row, "SecureActionButtonTemplate,UIPanelButtonTemplate")
  row.disenchant:SetSize(90, 22)
  row.disenchant:SetPoint("RIGHT")
  row.disenchant:SetText("Disenchant")
  List.rows[i] = row
end

List.prev = CreateFrame("Button", nil, List, "UIPanelButtonTemplate")
List.prev:SetSize(80, 22)
List.prev:SetPoint("BOTTOMLEFT", 20, 20)
List.prev:SetText("Prev")
List.next = CreateFrame("Button", nil, List, "UIPanelButtonTemplate")
List.next:SetSize(80, 22)
List.next:SetPoint("BOTTOMRIGHT", -20, 20)
List.next:SetText("Next")

local function IsCastingDisenchant()
  local name = UnitCastingInfo and UnitCastingInfo("player")
  return name == GetSpellInfo("Disenchant")
end

function List:RefreshButtons()
  local disable = IsCastingDisenchant()
  for _, row in ipairs(self.rows) do
    if disable then row.disenchant:Disable() else row.disenchant:Enable() end
  end
end

function List:Update()
  local start = (self.page - 1) * ITEMS_PER_PAGE + 1
  for i = 1, ITEMS_PER_PAGE do
    local item = self.items[start + i - 1]
    local row = self.rows[i]
    if item then
      local icon = GetIconAndCount(item.bag, item.slot)
      if type(icon) == "table" then icon = icon[1] end -- compatibility just in case
      row.icon:SetTexture(icon or nil)
      row.name:SetText(GetItemInfo(item.link) or item.link)
      local macro = string.format("/cast Disenchant\n/use %d %d", item.bag, item.slot)
      row.disenchant:SetAttribute("type", "macro")
      row.disenchant:SetAttribute("macrotext", macro)
      row.item = item
      row:Show()
    else
      row.item = nil
      row:Hide()
    end
  end
  self.prev:SetEnabled(self.page > 1)
  self.next:SetEnabled(self.page * ITEMS_PER_PAGE < #self.items)
  self:RefreshButtons()
end

function List:Rescan()
  self.items = GatherCandidates()
  local maxPage = math.max(1, math.ceil(#self.items / ITEMS_PER_PAGE))
  if self.page > maxPage then self.page = maxPage end
  self:Update()
end

List.prev:SetScript("OnClick", function()
  List.page = math.max(1, List.page - 1)
  List:Update()
end)
List.next:SetScript("OnClick", function()
  local maxPage = math.ceil(#List.items / ITEMS_PER_PAGE)
  List.page = math.min(maxPage, List.page + 1)
  List:Update()
end)

for _, row in ipairs(List.rows) do
  row.disenchant:SetScript("PostClick", function(self)
    local item = self:GetParent().item
    if item and item.id then
      lastAction.itemID = item.id
      lastAction.untilTime = GetTime() + 2
    end
    if C_Timer and C_Timer.After then
      C_Timer.After(0.2, function() if List:IsShown() then List:Rescan() end end)
      C_Timer.After(1.0, function() if List:IsShown() then List:Rescan() end end)
    else
      if List:IsShown() then List:Rescan() end
    end
  end)
end

SLASH_DEHELPERLIST1 = "/dehelperlist"
SlashCmdList.DEHELPERLIST = function()
  if List:IsShown() then
    List:Hide()
  else
    List.page = 1
    List:Rescan()
    List:Show()
  end
end

-- ===== click handlers that rescan =====

-- After Disenchant: hide, mark skip for this item briefly, then rescan soon
Prompt.disenchant:SetScript("PostClick", function()
  local id = Prompt.current.itemID
  if id then
    lastAction.itemID = id
    lastAction.untilTime = GetTime() + 2 -- 2s window to avoid immediate re-prompt
  end
  Prompt:Hide()
  -- rescan quickly (bags may update slightly later)
  if C_Timer and C_Timer.After then
    C_Timer.After(0.2, TryPrompt)
    C_Timer.After(1.0, TryPrompt)
  else
    TryPrompt()
  end
end)

-- Later: hide and rescan immediately
Prompt.later:SetScript("OnClick", function()
  Prompt:Hide()
  TryPrompt()
end)

-- Ignore/Never: add to ignore, hide and rescan
Prompt.ignore:SetScript("OnClick", function()
  local id = Prompt.current.itemID
  if id then
    DE_HelperDB.ignore[id] = true
    print("|cff33ff99DE Helper:|r ignoring itemID", id)
  end
  Prompt:Hide()
  TryPrompt()
end)

-- Slash to rescan manually
SLASH_DEHELPER1 = "/dehelper"
SlashCmdList.DEHELPER = function() TryPrompt() end

-- Events
f:SetScript("OnEvent", function(self, event, arg1)
  if event == "PLAYER_LOGIN" then
    print("|cff33ff99DE Helper loaded.|r Hover the icon for tooltip. Type /dehelper to rescan.")
    C_Timer.After(1, TryPrompt)
  elseif event == "BAG_UPDATE_DELAYED" or event == "BAG_UPDATE" then
    TryPrompt()
    if List:IsShown() then List:Rescan() end
  elseif (event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_STOP") and arg1 == "player" then
    if List:IsShown() then List:RefreshButtons() end
  end
end)
