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

-- ===== debounce/skip for current item after click =====
local lastAction = { itemID = nil, untilTime = 0 }
local function ShouldSkip(itemID)
  return itemID and itemID == lastAction.itemID and GetTime() < (lastAction.untilTime or 0)
end

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
    local texture, count = GetContItemInfo(bag, slot)
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

local function GatherCandidates()
  local items = {}
  for bag = 0, 4 do
    local slots = GetNumSlots(bag)
    if slots then
      for slot = 1, slots do
        local ok, id, link = IsLikelyDisenchantable(bag, slot)
        if ok then
          table.insert(items, { bag = bag, slot = slot, itemID = id, link = link })
        end
      end
    end
  end
  return items
end

-- ==== UI: list of items ====
local DEHelper_ShowList -- forward declaration

local ListFrame = CreateFrame("Frame", "DEHelperList", UIParent, "BackdropTemplate")
ListFrame:SetSize(400, 360)
ListFrame:SetPoint("CENTER")
ListFrame:SetBackdrop({
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
ListFrame:Hide()
ListFrame:EnableMouse(true)
ListFrame:SetMovable(true)
ListFrame:RegisterForDrag("LeftButton")
ListFrame:SetScript("OnDragStart", ListFrame.StartMoving)
ListFrame:SetScript("OnDragStop", ListFrame.StopMovingOrSizing)

ListFrame.title = ListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
ListFrame.title:SetPoint("TOP", 0, -16)
ListFrame.title:SetText("Disenchantable Items")

ListFrame.close = CreateFrame("Button", nil, ListFrame, "UIPanelCloseButton")
ListFrame.close:SetPoint("TOPRIGHT", -5, -5)
ListFrame.close:SetScript("OnClick", function()
  ListFrame:Hide()
end)

ListFrame.rows = {}
for i = 1, 7 do
  local row = CreateFrame("Frame", nil, ListFrame)
  row:SetSize(360, 36)
  row:SetPoint("TOPLEFT", 20, -40 - (i - 1) * 40)

  row.itemBtn = CreateFrame("Button", nil, row, "ItemButtonTemplate")
  row.itemBtn:SetSize(36, 36)
  row.itemBtn:SetPoint("LEFT", 0, 0)
  row.itemBtn.icon = _G[row.itemBtn:GetName() .. "IconTexture"] or row.itemBtn:CreateTexture(nil, "BORDER")
  if not _G[row.itemBtn:GetName() .. "IconTexture"] then row.itemBtn.icon:SetAllPoints() end
  row.itemBtn.Count = _G[row.itemBtn:GetName() .. "Count"]

  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.text:SetPoint("LEFT", row.itemBtn, "RIGHT", 12, 0)
  row.text:SetWidth(200)
  row.text:SetJustifyH("LEFT")

  row.disenchant = CreateFrame("Button", nil, row, "SecureActionButtonTemplate,UIPanelButtonTemplate")
  row.disenchant:SetSize(80, 22)
  row.disenchant:SetPoint("LEFT", row.text, "RIGHT", 8, 0)
  row.disenchant:SetText("Disenchant")
  row.disenchant:SetAttribute("type", "macro")

  row.current = { bag = nil, slot = nil, itemID = nil }

  row.itemBtn:SetScript("OnEnter", function(self)
    local c = row.current
    if c.bag and c.slot then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetBagItem(c.bag, c.slot)
      GameTooltip:Show()
    end
  end)
  row.itemBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  row.disenchant:SetScript("PostClick", function()
    local id = row.current.itemID
    if id then
      lastAction.itemID = id
      lastAction.untilTime = GetTime() + 2
    end
    if C_Timer and C_Timer.After then
      C_Timer.After(0.2, function() DEHelper_ShowList(ListFrame.page) end)
    else
      DEHelper_ShowList(ListFrame.page)
    end
  end)

  ListFrame.rows[i] = row
end

ListFrame.prev = CreateFrame("Button", nil, ListFrame, "UIPanelButtonTemplate")
ListFrame.prev:SetSize(80, 22)
ListFrame.prev:SetPoint("BOTTOMLEFT", 20, 20)
ListFrame.prev:SetText("Prev")

ListFrame.next = CreateFrame("Button", nil, ListFrame, "UIPanelButtonTemplate")
ListFrame.next:SetSize(80, 22)
ListFrame.next:SetPoint("BOTTOMRIGHT", -20, 20)
ListFrame.next:SetText("Next")

ListFrame.pageText = ListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
ListFrame.pageText:SetPoint("BOTTOM", 0, 24)

ListFrame.page = 1
ListFrame.items = {}

local function UpdatePagination()
  local totalPages = math.ceil(#ListFrame.items / 7)
  if totalPages == 0 then totalPages = 1 end
  ListFrame.page = math.max(1, math.min(ListFrame.page, totalPages))
  ListFrame.prev:SetEnabled(ListFrame.page > 1)
  ListFrame.next:SetEnabled(ListFrame.page < totalPages)
  ListFrame.pageText:SetText(string.format("Page %d/%d", ListFrame.page, totalPages))
end

function DEHelper_ShowList(page)
  if InCombatLockdown() then return end
  if not HasDisenchant() then return end
  ListFrame.items = GatherCandidates()
  ListFrame.page = page or 1
  UpdatePagination()
  local start = (ListFrame.page - 1) * 7 + 1
  for i = 1, 7 do
    local item = ListFrame.items[start + i - 1]
    local row = ListFrame.rows[i]
    if item then
      row:Show()
      row.current = item
      local icon, count = GetIconAndCount(item.bag, item.slot)
      if row.itemBtn.icon then row.itemBtn.icon:SetTexture(icon or nil) end
      if row.itemBtn.Count then row.itemBtn.Count:SetText(count and count > 1 and count or "") end
      local name = GetItemInfo(item.link) or item.link
      row.text:SetText(name or "")
      row.disenchant:SetAttribute("macrotext", string.format("/cast Disenchant\n/use %d %d", item.bag, item.slot))
    else
      row:Hide()
    end
  end
  ListFrame:Show()
end

ListFrame.prev:SetScript("OnClick", function()
  if ListFrame.page > 1 then
    ListFrame.page = ListFrame.page - 1
    DEHelper_ShowList(ListFrame.page)
  end
end)

ListFrame.next:SetScript("OnClick", function()
  ListFrame.page = ListFrame.page + 1
  DEHelper_ShowList(ListFrame.page)
end)

-- Slash command to show list
SLASH_DEHELPER1 = "/dehelper"
SlashCmdList.DEHELPER = function() DEHelper_ShowList(1) end

-- Events
f:SetScript("OnEvent", function(self, event)
  if event == "PLAYER_LOGIN" then
    print("|cff33ff99DE Helper loaded.|r Type /dehelper to list items.")
  elseif (event == "BAG_UPDATE_DELAYED" or event == "BAG_UPDATE") and ListFrame:IsShown() then
    DEHelper_ShowList(ListFrame.page)
  end
end)

