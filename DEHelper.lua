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

local MIN_WIDTH, MIN_HEIGHT = 360, 140
local Prompt = CreateFrame("Frame", "DEHelperPrompt", UIParent, "BackdropTemplate")
Prompt:SetSize(MIN_WIDTH, MIN_HEIGHT)
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
Prompt.text:Hide()

Prompt.tooltip = CreateFrame("GameTooltip", "DEHelperPromptTooltip", Prompt, "GameTooltipTemplate")
Prompt.tooltip:SetPoint("TOPLEFT", Prompt.itemBtn, "TOPRIGHT", 12, 0)
Prompt.tooltip:SetFrameStrata(Prompt:GetFrameStrata())
Prompt.tooltip:SetFrameLevel(Prompt:GetFrameLevel() + 1)
Prompt.tooltip:EnableMouse(false)
Prompt.tooltip:DisableDrawLayer("BACKGROUND")
Prompt.tooltip:DisableDrawLayer("BORDER")

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

Prompt:SetScript("OnHide", function(self)
  if self.tooltip then self.tooltip:Hide() end
end)

local function ResizePrompt()
  local w, h = MIN_WIDTH, MIN_HEIGHT
  if Prompt.tooltip and Prompt.tooltip:IsShown() then
    local tw, th = Prompt.tooltip:GetSize()
    w = math.max(w, 60 + tw)
    h = math.max(h, 80 + math.max(th, Prompt.itemBtn:GetHeight()))
  end
  Prompt:SetSize(w, h)
end

local function AnchorPrompt()
  local anchor
  local disenchantName = GetSpellInfo and GetSpellInfo("Disenchant")
  if disenchantName then
    local bars = { "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton", "MultiBarRightButton", "MultiBarLeftButton" }
    for _, prefix in ipairs(bars) do
      for i = 1, 12 do
        local btn = _G[prefix .. i]
        if btn and HasAction and HasAction(btn.action) then
          local type, id = GetActionInfo(btn.action)
          if type == "spell" and GetSpellInfo(id) == disenchantName then
            anchor = btn
            break
          end
        end
      end
      if anchor then break end
    end
  end
  Prompt:ClearAllPoints()
  if anchor then
    Prompt:SetPoint("TOPLEFT", anchor, "BOTTOMRIGHT", 0, -4)
  else
    Prompt:SetPoint("CENTER")
  end
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

-- Show prompt and configure secure button
local function ShowPrompt(bag, slot, itemID, link)
  if InCombatLockdown() then return end
  if not HasDisenchant() then return end
  if not ItemStillInBag(bag, slot, itemID) then return end

  local icon, count = GetIconAndCount(bag, slot)
  if Prompt.itemBtn.icon then Prompt.itemBtn.icon:SetTexture(icon or nil) end
  if Prompt.itemBtn.Count then Prompt.itemBtn.Count:SetText(count and count > 1 and count or "") end
  if Prompt.tooltip then
    Prompt.tooltip:SetOwner(Prompt, "ANCHOR_NONE")
    Prompt.tooltip:ClearAllPoints()
    Prompt.tooltip:SetPoint("TOPLEFT", Prompt.itemBtn, "TOPRIGHT", 12, -2)
    Prompt.tooltip:SetBagItem(bag, slot)
    Prompt.tooltip:Show()
  end

  ResizePrompt()
  AnchorPrompt()

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
f:SetScript("OnEvent", function(self, event)
  if event == "PLAYER_LOGIN" then
    print("|cff33ff99DE Helper loaded.|r Hover the icon for tooltip. Type /dehelper to rescan.")
    C_Timer.After(1, TryPrompt)
  elseif event == "BAG_UPDATE_DELAYED" or event == "BAG_UPDATE" then
    TryPrompt()
  end
end)
