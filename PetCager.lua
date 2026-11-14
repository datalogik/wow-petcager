local CAGE_DELAY = 0.2
local ROW_HEIGHT = 22
local LIST_ROW_COUNT = 10
local NUM_BAG_SLOTS = 5 -- backpack (0) + 4 bags (1-4)

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local scannedPets = {}
local isCaging = false

local scanDirty = true
local batchToken = 0
local StopCaging
local MarkFiltersChanged
local controls = {}
local sortColumn = "level"   -- current sort key
local sortAscending = false  -- default: descending

-- Filter defaults
local filters = {
    protectNamed = true,
    search = "",
    keepCount = 1,
    minDuplicates = 2,
    levelMin = 1,
    levelMax = 25,
    quality = {
        [1] = false,
        [2] = false,
        [3] = true,
        [4] = true,
    },
    families = {},
    sources = {},
}

---------------------------------------------------------------------------
-- Quality / Family / Source labels
---------------------------------------------------------------------------
local QUALITY_NAMES  = { "Poor", "Common", "Uncommon", "Rare" }
local QUALITY_COLORS = {
    { 0.62, 0.62, 0.62 },
    { 1.00, 1.00, 1.00 },
    { 0.12, 1.00, 0.00 },
    { 0.25, 0.65, 1.00 },
}

local FAMILY_NAMES = {
    "Humanoid", "Dragonkin", "Flying", "Undead", "Critter",
    "Magic", "Elemental", "Beast", "Aquatic", "Mechanical",
}

local SOURCE_NAMES = {
    "Drop", "Quest", "Vendor", "Profession", "Pet Battle",
    "Achievement", "World Event", "Promotion", "Trading Card", "In-Game Shop", "Discovery",
}

-- Use Blizzard's localized labels and include newly exposed source filters.
for i = 1, C_PetJournal.GetNumPetSources() do
    SOURCE_NAMES[i] = _G["BATTLE_PET_SOURCE_" .. i] or SOURCE_NAMES[i] or ("Source " .. i)
end
local extraSourceHeight = math.max(0, math.ceil(#SOURCE_NAMES / 4) - 3) * 24

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function CreateSectionHeader(parent, text, anchorTo, yOff)
    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", anchorTo or parent, anchorTo and "BOTTOMLEFT" or "TOPLEFT", anchorTo and 0 or 15, yOff or -8)
    header:SetText("|cffffd100" .. text .. "|r")
    return header
end

local function CreateSmallCheck(parent, label, checked, onClick, colorR, colorG, colorB)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetChecked(checked)
    cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 0, 0)
    cb.label:SetText(label)
    if colorR then
        cb.label:SetTextColor(colorR, colorG, colorB)
    end
    cb:SetScript("OnClick", function(self)
        onClick(self)
        if MarkFiltersChanged then MarkFiltersChanged() end
    end)
    controls[#controls + 1] = cb
    return cb
end

local function CreateNumberInput(parent, labelText, width, initialValue, onChanged)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width + 60, 24)

    local lbl = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", container, "LEFT", 0, 0)
    lbl:SetText(labelText)

    local box = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
    box:SetSize(40, 20)
    box:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(3)
    box:SetNumber(initialValue)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", function(self)
        local val = self:GetNumber()
        local normalized = onChanged(val)
        self:SetNumber(normalized or val)
        if MarkFiltersChanged then MarkFiltersChanged() end
    end)

    controls[#controls + 1] = box
    container.box = box
    return container
end

---------------------------------------------------------------------------
-- Inventory helpers
---------------------------------------------------------------------------
local function GetFreeBagSlots()
    local free = 0
    for bag = 0, NUM_BAG_SLOTS - 1 do
        local freeSlots, bagFamily = C_Container.GetContainerNumFreeSlots(bag)
        if bagFamily == 0 then free = free + (freeSlots or 0) end
    end
    return free
end

---------------------------------------------------------------------------
-- Counting helpers
---------------------------------------------------------------------------
local function GetSelectedCount()
    local count = 0
    for _, pet in ipairs(scannedPets) do
        if pet.selected then count = count + 1 end
    end
    return count
end

local function GetSelectedPets()
    local list = {}
    for _, pet in ipairs(scannedPets) do
        if pet.selected then
            table.insert(list, pet)
        end
    end
    return list
end

---------------------------------------------------------------------------
-- Forward declarations
---------------------------------------------------------------------------
local UpdateListRows
local UpdateSelectionCount
local CheckBagSpace
local ScanPets
local CageAllSelected
local SortScannedPets
local UpdateColumnHeaders

---------------------------------------------------------------------------
-- Sorting
---------------------------------------------------------------------------
SortScannedPets = function()
    table.sort(scannedPets, function(a, b)
        local valA, valB
        if sortColumn == "name" then
            valA, valB = (a.name or ""):lower(), (b.name or ""):lower()
        elseif sortColumn == "level" then
            valA, valB = a.level or 0, b.level or 0
        elseif sortColumn == "owned" then
            valA, valB = a.owned or 0, b.owned or 0
        elseif sortColumn == "quality" then
            valA, valB = a.rarity or 0, b.rarity or 0
        elseif sortColumn == "family" then
            valA = FAMILY_NAMES[a.petType] or ""
            valB = FAMILY_NAMES[b.petType] or ""
        else
            valA, valB = a.level or 0, b.level or 0
        end
        if valA == valB then return false end
        if sortAscending then
            return valA < valB
        else
            return valA > valB
        end
    end)
end

---------------------------------------------------------------------------
-- Main Frame
---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "PetCagerFrame", UIParent, "BasicFrameTemplateWithInset")
frame:SetSize(640, 760 + extraSourceHeight)
frame:SetClampedToScreen(true)
frame:SetScale(math.min(1, (UIParent:GetHeight() - 40) / (760 + extraSourceHeight), (UIParent:GetWidth() - 40) / 640))
table.insert(UISpecialFrames, "PetCagerFrame")
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetFrameStrata("DIALOG")
frame.TitleBg:SetHeight(30)
frame:Hide()

frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
frame.title:SetPoint("TOPLEFT", frame.TitleBg, "TOPLEFT", 5, -3)
frame.title:SetText("Pet Cager")

-- Status / progress
local statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
statusText:SetPoint("TOP", frame, "TOP", 0, -40)
statusText:SetWidth(600)
statusText:SetText("Scan your collection, review the list, then cage selected pets.")

local progressText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
progressText:SetPoint("TOP", statusText, "BOTTOM", 0, -4)
progressText:SetWidth(600)
progressText:SetText("")

---------------------------------------------------------------------------
-- Single content frame
---------------------------------------------------------------------------
local content = CreateFrame("Frame", nil, frame)
content:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -70)
content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 10)

---------------------------------------------------------------------------
-- Filter panel (always visible)
---------------------------------------------------------------------------
local FILTER_PANEL_HEIGHT = 310 + extraSourceHeight
local filterPanel = CreateFrame("Frame", nil, content)
filterPanel:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -2)
filterPanel:SetPoint("RIGHT", content, "RIGHT", -2, 0)
filterPanel:SetHeight(FILTER_PANEL_HEIGHT)

-- Quality row
local qualChecks = {}
local qualLabel = filterPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
qualLabel:SetPoint("TOPLEFT", filterPanel, "TOPLEFT", 0, -34)
qualLabel:SetText("|cffffd100Quality:|r")

for i = 1, 4 do
    local c = QUALITY_COLORS[i]
    local cb = CreateSmallCheck(filterPanel, QUALITY_NAMES[i], filters.quality[i],
        function(self) filters.quality[i] = self:GetChecked() end,
        c[1], c[2], c[3])
    if i == 1 then
        cb:SetPoint("LEFT", qualLabel, "RIGHT", 6, 0)
    else
        cb:SetPoint("LEFT", qualChecks[i - 1], "RIGHT", 60, 0)
    end
    qualChecks[i] = cb
end

-- Level + Ownership row
local levelLabel = filterPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
levelLabel:SetPoint("TOPLEFT", qualLabel, "BOTTOMLEFT", 0, -8)
levelLabel:SetText("|cffffd100Level:|r")

local levelMinInput = CreateNumberInput(filterPanel, "Min:", 40, filters.levelMin, function(val)
    filters.levelMin = math.max(1, math.min(val, filters.levelMax))
    return filters.levelMin
end)
levelMinInput:SetPoint("LEFT", levelLabel, "RIGHT", 6, 0)

local levelMaxInput = CreateNumberInput(filterPanel, "Max:", 40, filters.levelMax, function(val)
    filters.levelMax = math.max(filters.levelMin, math.min(val, 25))
    return filters.levelMax
end)
levelMaxInput:SetPoint("LEFT", levelMinInput, "RIGHT", 10, 0)

local keepCountInput = CreateNumberInput(filterPanel, "Keep per species:", 40, filters.keepCount, function(val)
    filters.keepCount = math.max(0, math.min(999, val))
    return filters.keepCount
end)
keepCountInput:SetPoint("TOPLEFT", levelLabel, "BOTTOMLEFT", 0, -8)

local minDupeInput = CreateNumberInput(filterPanel, "Min owned:", 40, filters.minDuplicates, function(val)
    filters.minDuplicates = math.max(1, math.min(999, val))
    return filters.minDuplicates
end)
minDupeInput:SetPoint("LEFT", keepCountInput, "RIGHT", 50, 0)

-- Pet Families
local famHeader = filterPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
famHeader:SetPoint("TOPLEFT", keepCountInput, "BOTTOMLEFT", 0, -4)
famHeader:SetText("|cffffd100Pet Families:|r")

for i = 1, #FAMILY_NAMES do
    filters.families[i] = true
end

local famChecks = {}
local famSelAll = CreateFrame("Button", nil, filterPanel)
famSelAll:SetSize(80, 14)
famSelAll:SetPoint("LEFT", famHeader, "RIGHT", 8, 0)
famSelAll.text = famSelAll:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
famSelAll.text:SetPoint("LEFT")
famSelAll.text:SetText("|cff888888[All / None]|r")
famSelAll.allSelected = true
famSelAll:SetScript("OnClick", function(self)
    self.allSelected = false
    for _, check in ipairs(famChecks) do
        if not check:GetChecked() then self.allSelected = true; break end
    end
    for i = 1, #FAMILY_NAMES do
        filters.families[i] = self.allSelected
        famChecks[i]:SetChecked(self.allSelected)
    end
    MarkFiltersChanged()
end)

for i = 1, #FAMILY_NAMES do
    local cb = CreateSmallCheck(filterPanel, FAMILY_NAMES[i], true,
        function(self) filters.families[i] = self:GetChecked() end)
    local col = (i - 1) % 5
    local row = math.floor((i - 1) / 5)
    cb:SetPoint("TOPLEFT", famHeader, "BOTTOMLEFT", col * 120, -2 - (row * 24))
    famChecks[i] = cb
end

-- Sources
local srcHeader = filterPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
srcHeader:SetPoint("TOPLEFT", famHeader, "BOTTOMLEFT", 0, -52)
srcHeader:SetText("|cffffd100Sources:|r")

for i = 1, #SOURCE_NAMES do
    filters.sources[i] = true
end

local srcChecks = {}
local srcSelAll = CreateFrame("Button", nil, filterPanel)
srcSelAll:SetSize(80, 14)
srcSelAll:SetPoint("LEFT", srcHeader, "RIGHT", 8, 0)
srcSelAll.text = srcSelAll:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
srcSelAll.text:SetPoint("LEFT")
srcSelAll.text:SetText("|cff888888[All / None]|r")
srcSelAll.allSelected = true
srcSelAll:SetScript("OnClick", function(self)
    self.allSelected = false
    for _, check in ipairs(srcChecks) do
        if not check:GetChecked() then self.allSelected = true; break end
    end
    for i = 1, #SOURCE_NAMES do
        filters.sources[i] = self.allSelected
        srcChecks[i]:SetChecked(self.allSelected)
    end
    MarkFiltersChanged()
end)

for i = 1, #SOURCE_NAMES do
    local cb = CreateSmallCheck(filterPanel, SOURCE_NAMES[i], true,
        function(self) filters.sources[i] = self:GetChecked() end)
    local col = (i - 1) % 4
    local row = math.floor((i - 1) / 4)
    cb:SetPoint("TOPLEFT", srcHeader, "BOTTOMLEFT", col * 150, -2 - (row * 24))
    srcChecks[i] = cb
end

---------------------------------------------------------------------------
-- Pet list section
---------------------------------------------------------------------------
local listHeader = CreateSectionHeader(content, "Pets to Cage", nil, -4)

local listCountText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
listCountText:SetPoint("LEFT", listHeader, "RIGHT", 10, 0)
listCountText:SetText("")

local listSelAll = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
listSelAll:SetSize(70, 18)
listSelAll:SetText("All")
listSelAll:SetNormalFontObject("GameFontNormalSmall")
listSelAll:SetHighlightFontObject("GameFontHighlightSmall")

local listSelNone = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
listSelNone:SetSize(70, 18)
listSelNone:SetText("None")
listSelNone:SetNormalFontObject("GameFontNormalSmall")
listSelNone:SetHighlightFontObject("GameFontHighlightSmall")

-- Column headers (clickable for sorting)
local colHeaderFrame = CreateFrame("Frame", nil, content)
colHeaderFrame:SetSize(590, 20)
colHeaderFrame:SetPoint("TOPLEFT", listHeader, "BOTTOMLEFT", 0, -2)

local colCheck = colHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
colCheck:SetPoint("LEFT", colHeaderFrame, "LEFT", 4, 0)
colCheck:SetTextColor(0.8, 0.8, 0.6)
colCheck:SetText("")

local function CreateSortableColumn(parent, label, sortKey, xOffset, width)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width, 16)
    btn:SetPoint("LEFT", parent, "LEFT", xOffset, 0)
    btn.sortKey = sortKey

    btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.label:SetPoint("LEFT", btn, "LEFT", 0, 0)
    btn.label:SetTextColor(0.8, 0.8, 0.6)
    btn.label:SetText(label)
    btn.baseLabel = label

    btn:SetScript("OnClick", function()
        if sortColumn == sortKey then
            sortAscending = not sortAscending
        else
            sortColumn = sortKey
            sortAscending = (sortKey == "name")
        end
        SortScannedPets()
        UpdateListRows()
        UpdateColumnHeaders()
    end)

    btn:SetScript("OnEnter", function(self)
        self.label:SetTextColor(1, 1, 0.8)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Sort by " .. self.baseLabel)
        if sortColumn == self.sortKey then
            GameTooltip:AddLine(sortAscending and "Ascending (+). Click to reverse." or "Descending (-). Click to reverse.", 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if sortColumn == self.sortKey then
            self.label:SetTextColor(1, 0.82, 0)
        else
            self.label:SetTextColor(0.8, 0.8, 0.6)
        end
    end)

    return btn
end

local colName    = CreateSortableColumn(colHeaderFrame, "Name",    "name",    30,  295)
local colLevel   = CreateSortableColumn(colHeaderFrame, "Lv",      "level",   330, 44)
local colOwned   = CreateSortableColumn(colHeaderFrame, "Owned",   "owned",   376, 50)
local colQuality = CreateSortableColumn(colHeaderFrame, "Quality", "quality", 430, 75)
local colFamily  = CreateSortableColumn(colHeaderFrame, "Family",  "family",  510, 80)

local sortableColumns = { colName, colLevel, colOwned, colQuality, colFamily }

UpdateColumnHeaders = function()
    for _, col in ipairs(sortableColumns) do
        if sortColumn == col.sortKey then
            col.label:SetText(col.baseLabel .. (sortAscending and " +" or " -"))
            col.label:SetTextColor(1, 0.82, 0)
        else
            col.label:SetText(col.baseLabel)
            col.label:SetTextColor(0.8, 0.8, 0.6)
        end
    end
end

UpdateColumnHeaders()

-- Scroll frame for pet list
local listBg = CreateFrame("Frame", nil, content, "InsetFrameTemplate")
listBg:SetPoint("TOPLEFT", colHeaderFrame, "BOTTOMLEFT", -2, -2)
listBg:SetPoint("RIGHT", content, "RIGHT", -2, 0)
listBg:SetHeight(LIST_ROW_COUNT * ROW_HEIGHT + 4)

local scrollFrame = CreateFrame("ScrollFrame", "PetCagerScrollFrame", listBg, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", listBg, "TOPLEFT", 4, -2)
scrollFrame:SetPoint("BOTTOMRIGHT", listBg, "BOTTOMRIGHT", -24, 2)

local scrollChild = CreateFrame("Frame", nil, scrollFrame)
scrollChild:SetSize(scrollFrame:GetWidth(), 1)
scrollFrame:SetScrollChild(scrollChild)

-- Row pool
local rowFrames = {}

local function CreateRow(index)
    local row = CreateFrame("Frame", nil, scrollChild)
    row:SetSize(590, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    if index % 2 == 0 then
        row.bg:SetColorTexture(1, 1, 1, 0.03)
    else
        row.bg:SetColorTexture(0, 0, 0, 0.05)
    end

    row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(1, 1, 1, 0.08)

    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(20, 20)
    row.check:SetPoint("LEFT", row, "LEFT", 2, 0)

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.nameText:SetPoint("LEFT", row, "LEFT", 28, 0)
    row.nameText:SetWidth(295)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    row.levelText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.levelText:SetPoint("LEFT", row, "LEFT", 328, 0)
    row.levelText:SetWidth(26)
    row.levelText:SetJustifyH("CENTER")

    row.ownedText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.ownedText:SetPoint("LEFT", row, "LEFT", 374, 0)
    row.ownedText:SetWidth(38)
    row.ownedText:SetJustifyH("CENTER")

    row.qualityText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.qualityText:SetPoint("LEFT", row, "LEFT", 428, 0)
    row.qualityText:SetWidth(65)
    row.qualityText:SetJustifyH("LEFT")

    row.familyText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.familyText:SetPoint("LEFT", row, "LEFT", 508, 0)
    row.familyText:SetWidth(70)
    row.familyText:SetJustifyH("LEFT")

    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        local pet = scannedPets[self.petIndex]
        if not pet then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(pet.name)
        GameTooltip:AddLine(string.format("Level %d • %s • %d owned", pet.level, QUALITY_NAMES[pet.rarity] or "?", pet.owned), 1, 1, 1)
        GameTooltip:AddLine(string.format("Health %d   Power %d   Speed %d", pet.health, pet.power, pet.speed), 1, 1, 1)
        if pet.sourceText then GameTooltip:AddLine(pet.sourceText, 0.8, 0.8, 0.8, true) end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.petIndex = nil

    row.check:SetScript("OnClick", function(self)
        if isCaging then return end
        if row.petIndex and scannedPets[row.petIndex] then
            scannedPets[row.petIndex].selected = self:GetChecked()
            UpdateSelectionCount()
        end
    end)

    return row
end

-- Action buttons
local scanBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
scanBtn:SetSize(100, 28)
scanBtn:SetPoint("TOPLEFT", listBg, "BOTTOMLEFT", 2, -6)
scanBtn:SetText("Scan Pets")

local cageBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
cageBtn:SetSize(130, 28)
cageBtn:SetPoint("LEFT", scanBtn, "RIGHT", 6, 0)
cageBtn:SetText("Cage Selected")
cageBtn:Disable()

local stopBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
stopBtn:SetSize(80, 28)
stopBtn:SetPoint("LEFT", cageBtn, "RIGHT", 6, 0)
stopBtn:SetText("Stop")
stopBtn:Disable()

local warnText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
warnText:SetPoint("TOPLEFT", scanBtn, "BOTTOMLEFT", 0, -4)
warnText:SetWidth(600)
warnText:SetTextColor(1, 0.8, 0)
warnText:SetText("")

---------------------------------------------------------------------------
-- Pet list anchoring (filters always visible)
---------------------------------------------------------------------------
listHeader:ClearAllPoints()
listHeader:SetPoint("TOPLEFT", filterPanel, "BOTTOMLEFT", 0, -4)
listBg:SetHeight(10 * ROW_HEIGHT + 4)

---------------------------------------------------------------------------
-- Update visible rows
---------------------------------------------------------------------------
UpdateListRows = function()
    local totalPets = #scannedPets
    scrollChild:SetHeight(math.max(totalPets * ROW_HEIGHT, 1))

    for i = 1, totalPets do
        if not rowFrames[i] then
            rowFrames[i] = CreateRow(i)
        end
        local row = rowFrames[i]
        local pet = scannedPets[i]

        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -((i - 1) * ROW_HEIGHT))
        row.petIndex = i
        row.check:SetChecked(pet.selected)
        row.nameText:SetText(pet.name)
        row.levelText:SetText(tostring(pet.level))
        row.ownedText:SetText(tostring(pet.owned or "?"))

        local qName = QUALITY_NAMES[pet.rarity] or "?"
        local qc = QUALITY_COLORS[pet.rarity] or { 1, 1, 1 }
        row.qualityText:SetText(qName)
        row.qualityText:SetTextColor(qc[1], qc[2], qc[3])
        row.nameText:SetTextColor(qc[1], qc[2], qc[3])

        row.familyText:SetText(FAMILY_NAMES[pet.petType] or "?")

        row.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.03 or 0)

        row:Show()
    end

    for i = totalPets + 1, #rowFrames do
        rowFrames[i]:Hide()
    end
end

---------------------------------------------------------------------------
-- Bag space check
---------------------------------------------------------------------------
CheckBagSpace = function()
    if isCaging then return end
    if scanDirty then
        cageBtn:Disable()
        warnText:SetText("Scan Pets to refresh the preview before caging.")
        return
    end
    if InCombatLockdown() then
        cageBtn:Disable()
        warnText:SetText("Caging is unavailable during combat.")
        return
    end

    local sel = GetSelectedCount()
    if sel == 0 then
        cageBtn:Disable()
        warnText:SetTextColor(1, 0.8, 0)
        warnText:SetText("")
        return
    end

    local freeSlots = GetFreeBagSlots()

    if freeSlots >= sel then
        cageBtn:Enable()
        warnText:SetTextColor(0.5, 1, 0.5)
        warnText:SetText(string.format("%d free bag slots. Enough space for %d pets.", freeSlots, sel))
    else
        cageBtn:Disable()
        warnText:SetTextColor(1, 0.3, 0.3)
        warnText:SetText(string.format(
            "Not enough bag space! Need %d slots, only %d free. Clear bags and try again.",
            sel, freeSlots))
    end
end

UpdateSelectionCount = function()
    local sel = GetSelectedCount()
    local total = #scannedPets
    cageBtn:SetText(sel > 0 and string.format("Cage %d Selected", sel) or "Cage Selected")
    listCountText:SetText(string.format("|cffffffff%d / %d selected|r", sel, total))

    if sel > 0 and not isCaging then
        progressText:SetText(string.format("%d pets selected. Ready to cage.", sel))
    elseif not isCaging then
        progressText:SetText("No pets selected.")
    end

    CheckBagSpace()
end

-- Position Select All / None buttons relative to the list header
listSelAll:ClearAllPoints()
listSelAll:SetPoint("LEFT", listCountText, "RIGHT", 10, 0)
listSelNone:ClearAllPoints()
listSelNone:SetPoint("LEFT", listSelAll, "RIGHT", 4, 0)

listSelAll:SetScript("OnClick", function()
    if isCaging then return end
    for _, pet in ipairs(scannedPets) do
        pet.selected = true
    end
    UpdateListRows()
    UpdateSelectionCount()
end)

listSelNone:SetScript("OnClick", function()
    if isCaging then return end
    for _, pet in ipairs(scannedPets) do
        pet.selected = false
    end
    UpdateListRows()
    UpdateSelectionCount()
end)

-- Keep the native journal's source classification without leaving its filters changed.
local function SourceMatches()
    local all = true
    for i = 1, C_PetJournal.GetNumPetSources() do
        if filters.sources[i] == false then all = false end
    end
    if all then return nil end
    local saved = { search = C_PetJournal.GetSearchFilter(), types = {}, sources = {}, flags = {} }
    for i = 1, C_PetJournal.GetNumPetTypes() do saved.types[i] = C_PetJournal.IsPetTypeChecked(i) end
    for i = 1, C_PetJournal.GetNumPetSources() do saved.sources[i] = C_PetJournal.IsPetSourceChecked(i) end
    for _, flag in ipairs({ LE_PET_JOURNAL_FILTER_COLLECTED, LE_PET_JOURNAL_FILTER_NOT_COLLECTED, LE_PET_JOURNAL_FILTER_FAVORITES }) do
        saved.flags[flag] = C_PetJournal.IsFilterChecked(flag)
    end
    local matches = {}
    local ok, err = pcall(function()
        C_PetJournal.ClearSearchFilter()
        C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED, true)
        C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_NOT_COLLECTED, false)
        C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_FAVORITES, false)
        for i = 1, #saved.types do C_PetJournal.SetPetTypeFilter(i, true) end
        for i = 1, #saved.sources do C_PetJournal.SetPetSourceChecked(i, filters.sources[i] ~= false) end
        for i = 1, C_PetJournal.GetNumPets() do
            local id = C_PetJournal.GetPetInfoByIndex(i)
            if id then matches[id] = true end
        end
    end)
    C_PetJournal.SetSearchFilter(saved.search)
    for flag, value in pairs(saved.flags) do C_PetJournal.SetFilterChecked(flag, value) end
    for i, value in ipairs(saved.types) do C_PetJournal.SetPetTypeFilter(i, value) end
    for i, value in ipairs(saved.sources) do C_PetJournal.SetPetSourceChecked(i, value) end
    if not ok then error(err) end
    return matches
end

local function GetTeam()
    local team = {}
    for slot = 1, 3 do
        local id = C_PetJournal.GetPetLoadOutInfo(slot)
        if id then team[id] = true end
    end
    return team
end

local function ReadPet(id, team)
    local info = C_PetJournal.GetPetInfoTableByPetID(id)
    if not info then return nil end
    local _, health, power, speed, rarity = C_PetJournal.GetPetStats(id)
    return {
        petID = id, speciesID = info.speciesID,
        name = info.customName or info.name or "Unknown",
        speciesName = info.name or "", level = info.petLevel or 1,
        rarity = rarity or 0, petType = info.petType,
        health = health or 0, power = power or 0, speed = speed or 0,
        sourceText = info.sourceText,
        protected = info.isFavorite or team[id] or
            (filters.protectNamed and info.customName and info.customName ~= "") or
            not C_PetJournal.PetIsTradable(id),
    }
end

local function BuildCandidates()
    local matches = SourceMatches()
    local team, pets, counts, kept = GetTeam(), {}, {}, {}
    for _, id in ipairs(C_PetJournal.GetOwnedPetIDs()) do
        local pet = ReadPet(id, team)
        if pet then
            pets[#pets + 1] = pet
            counts[pet.speciesID] = (counts[pet.speciesID] or 0) + 1
            if pet.protected then kept[pet.speciesID] = (kept[pet.speciesID] or 0) + 1 end
        end
    end
    -- Reserve strongest copies before applying sale filters; ties are stable.
    table.sort(pets, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        if a.rarity ~= b.rarity then return a.rarity > b.rarity end
        return a.petID < b.petID
    end)
    local result = {}
    for _, pet in ipairs(pets) do
        local species = pet.speciesID
        pet.owned = counts[species]
        if not pet.protected then
            if (kept[species] or 0) < filters.keepCount then
                kept[species] = (kept[species] or 0) + 1
            elseif pet.owned >= filters.minDuplicates and filters.quality[pet.rarity]
                and pet.level >= filters.levelMin and pet.level <= filters.levelMax
                and filters.families[pet.petType] and (not matches or matches[pet.petID])
                and (filters.search == "" or string.find(string.lower(pet.name .. " " .. pet.speciesName), filters.search, 1, true)) then
                pet.selected = true
                result[#result + 1] = pet
            end
        end
    end
    return result
end

MarkFiltersChanged = function()
    scanDirty = true
    CheckBagSpace()
end

local searchBox = CreateFrame("EditBox", nil, filterPanel, "InputBoxTemplate")
searchBox:SetSize(260, 22)
searchBox:SetPoint("TOPLEFT", filterPanel, "TOPLEFT", 52, 0)
searchBox:SetAutoFocus(false)
searchBox:SetMaxLetters(80)
local searchLabel = filterPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
searchLabel:SetPoint("RIGHT", searchBox, "LEFT", -8, 0)
searchLabel:SetText("Search:")
searchBox:SetScript("OnTextChanged", function(self)
    filters.search = string.lower(self:GetText())
    MarkFiltersChanged()
end)
searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ScanPets() end)
searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
controls[#controls + 1] = searchBox
local namedCheck = CreateSmallCheck(filterPanel, "Keep custom-named pets", true, function(self)
    filters.protectNamed = self:GetChecked()
end)
namedCheck:SetPoint("BOTTOMLEFT", filterPanel, "BOTTOMLEFT", 0, 26)
local keepHint = filterPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
keepHint:SetPoint("BOTTOMLEFT", filterPanel, "BOTTOMLEFT", 4, 4)
keepHint:SetText("Favorites and battle-team pets are kept. Keep rule: highest level, then quality.")
controls[#controls + 1] = famSelAll
controls[#controls + 1] = srcSelAll
controls[#controls + 1] = listSelAll
controls[#controls + 1] = listSelNone

local emptyText = listBg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
emptyText:SetPoint("CENTER")
emptyText:SetWidth(540)
emptyText:SetText("No matches. Try more qualities, a wider level range, or fewer copies to keep.")
emptyText:Hide()

local function SetBusy(busy)
    for _, control in ipairs(controls) do control:SetEnabled(not busy) end
    for _, row in ipairs(rowFrames) do row.check:SetEnabled(not busy) end
    scanBtn:SetEnabled(not busy)
    stopBtn:SetEnabled(busy)
    if busy then cageBtn:Disable() end
end

ScanPets = function()
    if isCaging then return end
    for _, input in ipairs({ levelMinInput, levelMaxInput, keepCountInput, minDupeInput }) do input.box:ClearFocus() end
    if not C_PetJournal.GetOwnedPetIDs or not C_PetJournal.GetPetInfoTableByPetID then
        statusText:SetText("This version requires the current Retail pet-journal API.")
        cageBtn:Disable()
        return
    end
    local ok, result = pcall(BuildCandidates)
    if not ok then
        scanDirty = true
        cageBtn:Disable()
        statusText:SetText("Could not read the pet journal. Reopen it and scan again.")
        return
    end
    scannedPets = result
    scanDirty = false
    SortScannedPets()
    scrollFrame:SetVerticalScroll(0)
    UpdateListRows()
    emptyText:SetShown(#scannedPets == 0)
    UpdateSelectionCount()
    statusText:SetText(string.format("%d eligible pets. Only checked pets will be caged.", #scannedPets))
end

local activeBatch
local function FinishBatch(message)
    local batch = activeBatch
    batchToken = batchToken + 1
    isCaging = false
    activeBatch = nil
    local remaining = {}
    for _, pet in ipairs(scannedPets) do
        if not pet._caged then remaining[#remaining + 1] = pet end
    end
    scannedPets = remaining
    SetBusy(false)
    UpdateListRows()
    scanDirty = true
    UpdateSelectionCount()
    progressText:SetText(string.format("%d confirmed / %d selected", batch and batch.caged or 0, batch and #batch.pets or 0))
    statusText:SetText(message)
end

StopCaging = function()
    if activeBatch then
        -- A request already sent cannot be recalled. Reconcile it before ending.
        local pet = activeBatch.pending
        if pet and not C_PetJournal.GetPetInfoTableByPetID(pet.petID) then
            pet._caged = true
            activeBatch.caged = activeBatch.caged + 1
        end
        FinishBatch("Stopped. Scan again to refresh your collection.")
    end
end

CageAllSelected = function()
    if isCaging or scanDirty or InCombatLockdown() then return end
    local selected = GetSelectedPets()
    if #selected == 0 or GetFreeBagSlots() < #selected then CheckBagSpace(); return end
    -- Validate against a fresh collection without selecting any additional pets.
    local ok, candidates = pcall(BuildCandidates)
    if not ok then MarkFiltersChanged(); return end
    local eligible = {}
    for _, pet in ipairs(candidates) do eligible[pet.petID] = true end
    for _, pet in ipairs(selected) do
        if not eligible[pet.petID] then
            MarkFiltersChanged()
            statusText:SetText("Your collection changed. Scan and review before caging.")
            return
        end
    end
    batchToken = batchToken + 1
    local token = batchToken
    local batch = { pets = selected, index = 0, caged = 0 }
    activeBatch = batch
    isCaging = true
    SetBusy(true)
    local function NextPet()
        if token ~= batchToken or not isCaging then return end
        if InCombatLockdown() then FinishBatch("Stopped for combat. Scan again when ready."); return end
        if batch.pending then
            if not C_PetJournal.GetPetInfoTableByPetID(batch.pending.petID) then
                batch.pending._caged = true
                batch.caged = batch.caged + 1
                batch.pending = nil
            elseif GetTime() >= batch.deadline then
                FinishBatch("Caging was not confirmed. Stopped; scan before retrying.")
                return
            else
                C_Timer.After(CAGE_DELAY, NextPet)
                return
            end
        end
        batch.index = batch.index + 1
        if batch.index > #selected then FinishBatch("Finished the selected batch. Scan to review more pets."); return end
        local pet = selected[batch.index]
        local current = ReadPet(pet.petID, GetTeam())
        local owned = 0
        for _, id in ipairs(C_PetJournal.GetOwnedPetIDs()) do
            local info = C_PetJournal.GetPetInfoTableByPetID(id)
            if info and info.speciesID == pet.speciesID then owned = owned + 1 end
        end
        if not current or current.protected or owned <= filters.keepCount then
            FinishBatch("A selected pet is no longer eligible. Stopped; scan again.")
            return
        end
        if GetFreeBagSlots() < 1 then FinishBatch("Bags are full. Stopped; make space and scan again."); return end
        batch.pending = pet
        batch.deadline = GetTime() + 5
        progressText:SetText(string.format("%d / %d confirmed | Caging %s", batch.caged, #selected, pet.name))
        local success = pcall(C_PetJournal.CagePetByID, pet.petID)
        if not success and token == batchToken then FinishBatch("Cage request failed. Stopped; scan before retrying."); return end
        C_Timer.After(CAGE_DELAY, NextPet)
    end
    NextPet()
end

frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PET_JOURNAL_CAGE_FAILED")
frame:SetScript("OnEvent", function(_, event)
    if event == "PET_JOURNAL_CAGE_FAILED" and isCaging then
        FinishBatch("Blizzard could not cage this pet. Stopped; scan before retrying.")
    elseif event == "PLAYER_REGEN_DISABLED" and isCaging then
        StopCaging()
    elseif frame:IsShown() then
        CheckBagSpace()
    end
end)
scanBtn:SetScript("OnClick", ScanPets)
cageBtn:SetScript("OnClick", CageAllSelected)
stopBtn:SetScript("OnClick", StopCaging)
frame:HookScript("OnShow", ScanPets)
frame:HookScript("OnHide", StopCaging)
SLASH_PETCAGER1 = "/petcager"
SLASH_PETCAGER2 = "/pc"
SlashCmdList["PETCAGER"] = function() frame:SetShown(not frame:IsShown()) end
