local CAGE_DELAY = 0.2
local ROW_HEIGHT = 20
local LIST_ROW_COUNT = 15
local NUM_BAG_SLOTS = 5 -- backpack (0) + 4 bags (1-4)

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local scannedPets = {}
local isCaging = false

local continueCagingAfterScan = false
local isCageLooping = false
local sessionCagedTotal = 0
local sortColumn = "level"   -- current sort key
local sortAscending = false  -- default: descending

-- Filter defaults
local filters = {
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
    { 0.00, 0.44, 0.87 },
}

local FAMILY_NAMES = {
    "Humanoid", "Dragonkin", "Flying", "Undead", "Critter",
    "Magic", "Elemental", "Beast", "Aquatic", "Mechanical",
}

local SOURCE_NAMES = {
    "Drop", "Quest", "Vendor", "Profession", "Pet Battle",
    "Achievement", "World Event", "Promotion", "Trading Card", "In-Game Shop", "Discovery",
}

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
    cb:SetScript("OnClick", onClick)
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
        onChanged(val)
    end)

    container.box = box
    return container
end

---------------------------------------------------------------------------
-- Inventory helpers
---------------------------------------------------------------------------
local function GetFreeBagSlots()
    local free = 0
    for bag = 0, NUM_BAG_SLOTS - 1 do
        local freeSlots = C_Container.GetContainerNumFreeSlots(bag)
        free = free + (freeSlots or 0)
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
frame:SetSize(500, 575)
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
statusText:SetWidth(460)
statusText:SetText("Scanning pets...")

local progressText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
progressText:SetPoint("TOP", statusText, "BOTTOM", 0, -4)
progressText:SetWidth(460)
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
local FILTER_PANEL_HEIGHT = 200
local filterPanel = CreateFrame("Frame", nil, content)
filterPanel:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -2)
filterPanel:SetPoint("RIGHT", content, "RIGHT", -2, 0)
filterPanel:SetHeight(FILTER_PANEL_HEIGHT)

-- Quality row
local qualChecks = {}
local qualLabel = filterPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
qualLabel:SetPoint("TOPLEFT", filterPanel, "TOPLEFT", 0, 0)
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
    filters.levelMin = math.max(1, math.min(val, 25))
end)
levelMinInput:SetPoint("LEFT", levelLabel, "RIGHT", 6, 0)

local levelMaxInput = CreateNumberInput(filterPanel, "Max:", 40, filters.levelMax, function(val)
    filters.levelMax = math.max(1, math.min(val, 25))
end)
levelMaxInput:SetPoint("LEFT", levelMinInput, "RIGHT", 10, 0)

local keepCountInput = CreateNumberInput(filterPanel, "Keep per species:", 40, filters.keepCount, function(val)
    filters.keepCount = math.max(0, val)
end)
keepCountInput:SetPoint("TOPLEFT", levelLabel, "BOTTOMLEFT", 0, -8)

local minDupeInput = CreateNumberInput(filterPanel, "Min owned:", 40, filters.minDuplicates, function(val)
    filters.minDuplicates = math.max(1, val)
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
    self.allSelected = not self.allSelected
    for i = 1, #FAMILY_NAMES do
        filters.families[i] = self.allSelected
        famChecks[i]:SetChecked(self.allSelected)
    end
end)

for i = 1, #FAMILY_NAMES do
    local cb = CreateSmallCheck(filterPanel, FAMILY_NAMES[i], true,
        function(self) filters.families[i] = self:GetChecked() end)
    local col = (i - 1) % 5
    local row = math.floor((i - 1) / 5)
    cb:SetPoint("TOPLEFT", famHeader, "BOTTOMLEFT", col * 92, -2 - (row * 24))
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
    self.allSelected = not self.allSelected
    for i = 1, #SOURCE_NAMES do
        filters.sources[i] = self.allSelected
        srcChecks[i]:SetChecked(self.allSelected)
    end
end)

for i = 1, #SOURCE_NAMES do
    local cb = CreateSmallCheck(filterPanel, SOURCE_NAMES[i], true,
        function(self) filters.sources[i] = self:GetChecked() end)
    local col = (i - 1) % 4
    local row = math.floor((i - 1) / 4)
    cb:SetPoint("TOPLEFT", srcHeader, "BOTTOMLEFT", col * 112, -2 - (row * 24))
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
colHeaderFrame:SetSize(450, 16)
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
    end)
    btn:SetScript("OnLeave", function(self)
        if sortColumn == self.sortKey then
            self.label:SetTextColor(1, 0.82, 0)
        else
            self.label:SetTextColor(0.8, 0.8, 0.6)
        end
    end)

    return btn
end

local colName    = CreateSortableColumn(colHeaderFrame, "Name",    "name",    30,  195)
local colLevel   = CreateSortableColumn(colHeaderFrame, "Lv",      "level",   230, 24)
local colOwned   = CreateSortableColumn(colHeaderFrame, "Owned",   "owned",   256, 40)
local colQuality = CreateSortableColumn(colHeaderFrame, "Quality", "quality", 300, 65)
local colFamily  = CreateSortableColumn(colHeaderFrame, "Family",  "family",  370, 70)

local sortableColumns = { colName, colLevel, colOwned, colQuality, colFamily }

UpdateColumnHeaders = function()
    for _, col in ipairs(sortableColumns) do
        if sortColumn == col.sortKey then
            col.label:SetTextColor(1, 0.82, 0)
        else
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
    row:SetSize(430, ROW_HEIGHT)
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
    row.nameText:SetWidth(195)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    row.levelText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.levelText:SetPoint("LEFT", row, "LEFT", 228, 0)
    row.levelText:SetWidth(26)
    row.levelText:SetJustifyH("CENTER")

    row.ownedText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.ownedText:SetPoint("LEFT", row, "LEFT", 256, 0)
    row.ownedText:SetWidth(38)
    row.ownedText:SetJustifyH("CENTER")

    row.qualityText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.qualityText:SetPoint("LEFT", row, "LEFT", 298, 0)
    row.qualityText:SetWidth(65)
    row.qualityText:SetJustifyH("LEFT")

    row.familyText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.familyText:SetPoint("LEFT", row, "LEFT", 368, 0)
    row.familyText:SetWidth(70)
    row.familyText:SetJustifyH("LEFT")

    row.petIndex = nil

    row.check:SetScript("OnClick", function(self)
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
warnText:SetWidth(460)
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
    for _, pet in ipairs(scannedPets) do
        pet.selected = true
    end
    UpdateListRows()
    UpdateSelectionCount()
end)

listSelNone:SetScript("OnClick", function()
    for _, pet in ipairs(scannedPets) do
        pet.selected = false
    end
    UpdateListRows()
    UpdateSelectionCount()
end)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local pendingScan = false

frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("PET_JOURNAL_LIST_UPDATE")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "BAG_UPDATE" and self:IsShown() then
        CheckBagSpace()
    elseif event == "PET_JOURNAL_LIST_UPDATE" and pendingScan then
        pendingScan = false
        self:PerformScan()
    end
end)

---------------------------------------------------------------------------
-- Scan Logic
---------------------------------------------------------------------------
function frame:PerformScan()
    local numPets = C_PetJournal.GetNumPets()

    local speciesCount = {}
    local petList = {}

    for i = 1, numPets do
        local petID, speciesID, owned, customName, level, favorite, isRevoked,
              speciesName, icon, petType, companionID, tooltip, description,
              isWild, canBattle, isTradeable, isUnique, obtainable =
              C_PetJournal.GetPetInfoByIndex(i)

        if petID and owned then
            speciesCount[speciesID] = (speciesCount[speciesID] or 0) + 1

            local _, _, _, _, rarity = C_PetJournal.GetPetStats(petID)

            table.insert(petList, {
                petID     = petID,
                speciesID = speciesID,
                name      = customName or speciesName or "Unknown",
                level     = level or 1,
                favorite  = favorite,
                isRevoked = isRevoked,
                rarity    = rarity or 2,
                petType   = petType or 0,
            })
        end
    end

    -- Count how many of each species are UNcageable (favorite, revoked,
    -- non-tradeable) -- these are automatic keeps that count toward keepCount.
    local speciesUncageable = {}
    for _, pet in ipairs(petList) do
        if pet.favorite or pet.isRevoked or not C_PetJournal.PetIsTradable(pet.petID) then
            speciesUncageable[pet.speciesID] = (speciesUncageable[pet.speciesID] or 0) + 1
        end
    end

    -- Stamp owned count onto each pet for display
    for _, pet in ipairs(petList) do
        pet.owned = speciesCount[pet.speciesID] or 0
    end

    -- Sort by level DESCENDING so keepCount preserves the highest-level copies
    table.sort(petList, function(a, b) return a.level > b.level end)

    -- Calculate how many MORE we need to keep beyond the uncageable ones
    -- e.g. keepCount=1, uncageable=0 -> need to reserve 1
    -- e.g. keepCount=1, uncageable=2 -> already covered, reserve 0
    local speciesKeptSoFar = {}

    for _, pet in ipairs(petList) do
        local dominated = false

        -- Skip uncageable pets entirely (they're already kept by nature)
        if pet.favorite or pet.isRevoked then
            dominated = true
        end

        if not dominated then
            if not C_PetJournal.PetIsTradable(pet.petID) then
                dominated = true
            end
        end

        if not dominated then
            if not filters.quality[pet.rarity] then
                dominated = true
            end
        end

        if not dominated then
            if pet.level < filters.levelMin or pet.level > filters.levelMax then
                dominated = true
            end
        end

        -- Use total species count (all owned) for minDuplicates check
        if not dominated then
            if (speciesCount[pet.speciesID] or 0) < filters.minDuplicates then
                dominated = true
            end
        end

        -- keepCount: account for uncageable copies that are already kept
        if not dominated then
            local uncageable = speciesUncageable[pet.speciesID] or 0
            local needToKeep = math.max(0, filters.keepCount - uncageable)
            speciesKeptSoFar[pet.speciesID] = (speciesKeptSoFar[pet.speciesID] or 0)
            if speciesKeptSoFar[pet.speciesID] < needToKeep then
                speciesKeptSoFar[pet.speciesID] = speciesKeptSoFar[pet.speciesID] + 1
                dominated = true
            end
        end

        if not dominated then
            pet.selected = true
            table.insert(scannedPets, pet)
        end
    end

    SortScannedPets()

    UpdateListRows()

    local total = #scannedPets
    if total > 0 then
        statusText:SetText(string.format("Found %d cageable pets. Deselect any to keep.", total))
    else
        statusText:SetText("No cageable pets matched your filters.")
    end

    UpdateSelectionCount()
    scanBtn:Enable()

    -- If we just finished a cage batch, automatically continue caging
    -- any newly eligible pets (e.g. 3 owned -> cage 2 in multiple passes)
    if continueCagingAfterScan then
        continueCagingAfterScan = false
        local newSelected = GetSelectedPets()
        if #newSelected > 0 and GetFreeBagSlots() >= #newSelected then
            statusText:SetText(string.format(
                "Found %d more eligible pets. Caging...", #newSelected))
            C_Timer.After(0.5, function()
                CageAllSelected()
            end)
        else
            isCageLooping = false
            if #newSelected > 0 then
                statusText:SetText(string.format(
                    "Caged %d pets total. %d more found but not enough bag space.",
                    sessionCagedTotal, #newSelected))
            else
                statusText:SetText(string.format(
                    "Done! Caged %d pets total. No more eligible pets.", sessionCagedTotal))
            end
        end
    end
end

ScanPets = function()
    if isCaging then return end

    scannedPets = {}
    scanBtn:Disable()
    statusText:SetText("Scanning...")
    progressText:SetText("")

    C_PetJournal.ClearSearchFilter()
    C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED, true)
    C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_NOT_COLLECTED, false)

    for i = 1, C_PetJournal.GetNumPetTypes() do
        C_PetJournal.SetPetTypeFilter(i, filters.families[i] or false)
    end

    local numSources = C_PetJournal.GetNumPetSources()
    for i = 1, numSources do
        C_PetJournal.SetPetSourceChecked(i, filters.sources[i] or false)
    end

    pendingScan = true

    C_Timer.After(0.5, function()
        if pendingScan then
            pendingScan = false
            frame:PerformScan()
        end
    end)
end

---------------------------------------------------------------------------
-- Cage Logic
---------------------------------------------------------------------------
CageAllSelected = function()
    if isCaging then return end

    -- Reset session counter on first manual call (not during auto-continue loops)
    if not isCageLooping then
        sessionCagedTotal = 0
        isCageLooping = true
    end

    local selected = GetSelectedPets()
    if #selected == 0 then
        statusText:SetText("No pets selected to cage.")
        progressText:SetText("")
        cageBtn:Disable()
        return
    end

    local freeSlots = GetFreeBagSlots()
    if freeSlots < #selected then
        cageBtn:Disable()
        warnText:SetTextColor(1, 0.3, 0.3)
        warnText:SetText(string.format(
            "Not enough bag space! Need %d slots, only %d free.",
            #selected, freeSlots))
        return
    end

    isCaging = true
    scanBtn:Disable()
    cageBtn:Disable()
    stopBtn:Enable()

    local totalToCage = #selected
    local caged = 0
    local cageIndex = 0

    local function CageNext()
        if not isCaging then
            return
        end

        cageIndex = cageIndex + 1

        if cageIndex > #selected then
            isCaging = false
            scanBtn:Enable()
            stopBtn:Disable()

            local remaining = {}
            for _, pet in ipairs(scannedPets) do
                if not pet._caged then
                    table.insert(remaining, pet)
                end
            end
            scannedPets = remaining
            UpdateListRows()
            UpdateSelectionCount()

            sessionCagedTotal = sessionCagedTotal + caged
            progressText:SetText("")
            -- Re-scan after journal settles to pick up newly eligible pets
            -- and automatically cage them if more are found (loop until done)
            statusText:SetText(string.format("Caged %d pets. Re-scanning for more...", sessionCagedTotal))
            continueCagingAfterScan = true
            C_Timer.After(1.0, function()
                ScanPets()
            end)
            return
        end

        local pet = selected[cageIndex]
        if pet and pet.petID then
            local speciesID = C_PetJournal.GetPetInfoByPetID(pet.petID)
            if speciesID then
                C_PetJournal.CagePetByID(pet.petID)
                pet._caged = true
                caged = caged + 1
                progressText:SetText(string.format(
                    "Caging... %d/%d  |  %s (Lv %d)",
                    caged, totalToCage, pet.name, pet.level))
            end
        end

        C_Timer.After(CAGE_DELAY, CageNext)
    end

    CageNext()
end

---------------------------------------------------------------------------
-- Stop
---------------------------------------------------------------------------
local function StopCaging()
    isCaging = false
    isCageLooping = false
    continueCagingAfterScan = false
    scanBtn:Enable()
    stopBtn:Disable()

    local remaining = {}
    for _, pet in ipairs(scannedPets) do
        if not pet._caged then
            table.insert(remaining, pet)
        end
    end
    scannedPets = remaining
    UpdateListRows()
    UpdateSelectionCount()

    statusText:SetText("Stopped.")
end

---------------------------------------------------------------------------
-- Wire up buttons
---------------------------------------------------------------------------
scanBtn:SetScript("OnClick", ScanPets)
cageBtn:SetScript("OnClick", CageAllSelected)
stopBtn:SetScript("OnClick", StopCaging)

-- Auto-scan on show
frame:HookScript("OnShow", function()
    ScanPets()
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_PETCAGER1 = "/petcager"
SLASH_PETCAGER2 = "/pc"
SlashCmdList["PETCAGER"] = function()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end

---------------------------------------------------------------------------
-- Load message
---------------------------------------------------------------------------
C_Timer.After(3, function()
    print("|cff00ccffPet Cager|r loaded. Type |cff00ff00/pc|r or |cff00ff00/petcager|r to open.")
end)
