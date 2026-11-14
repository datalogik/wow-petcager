-- Run from this directory's parent: luajit tests/petcager_test.lua
local widgets, timers, now, pets, calls = {}, {}, 0, {}, {}
local methods = {}
local noop = function() end
local function widget(kind, name, parent)
    local w = setmetatable({kind=kind, name=name, parent=parent, scripts={}, shown=true, enabled=true}, {__index=function(_, k) return methods[k] or noop end})
    widgets[#widgets+1] = w
    if name then _G[name] = w end
    return w
end
function methods:SetScript(k, v) self.scripts[k]=v end
function methods:HookScript(k, v)
    local old=self.scripts[k]
    self.scripts[k]=function(...) if old then old(...) end; v(...) end
end
function methods:Show() self.shown=true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
function methods:Hide() self.shown=false; if self.scripts.OnHide then self.scripts.OnHide(self) end end
function methods:SetShown(v) if v then self:Show() else self:Hide() end end
function methods:IsShown() return self.shown end
function methods:SetText(t) self.text=t end
function methods:GetText() return self.text or '' end
function methods:SetNumber(n) self.number=n end
function methods:GetNumber() return self.number end
function methods:SetChecked(v) self.checked=v end
function methods:GetChecked() return self.checked end
function methods:SetEnabled(v) self.enabled=v end
function methods:Enable() self.enabled=true end
function methods:Disable() self.enabled=false end
function methods:GetHeight() return 1080 end
function methods:GetWidth() return 590 end
function methods:CreateFontString() return widget('FontString',nil,self) end
function methods:CreateTexture() return widget('Texture',nil,self) end
function CreateFrame(kind,name,parent)
    local w=widget(kind,name,parent)
    if name=='PetCagerFrame' then w.TitleBg=widget('Texture') end
    return w
end
UIParent=widget('Frame'); UISpecialFrames={}; SlashCmdList={}; GameTooltip=widget('Tooltip')
local combat=false
function InCombatLockdown() return combat end
function GetTime() return now end
C_Timer={After=function(delay, fn) timers[#timers+1]={at=now+delay,fn=fn} end}
local function drain()
    local loops=0
    while #timers>0 do
        table.sort(timers,function(a,b) return a.at<b.at end)
        local t=table.remove(timers,1); now=t.at; t.fn()
        loops=loops+1; assert(loops<100,'unbounded timer loop')
    end
end
local bagFamily, free=0,20
C_Container={GetContainerNumFreeSlots=function(bag) return bag==0 and free or 0, bagFamily end}
LE_PET_JOURNAL_FILTER_COLLECTED=1; LE_PET_JOURNAL_FILTER_NOT_COLLECTED=2; LE_PET_JOURNAL_FILTER_FAVORITES=3
local team, failure, timeout={},false,false
local journal={search='original search', flags={false,true,true}, types={}, sources={}}
for i=1,10 do journal.types[i]=false end
for i=1,11 do journal.sources[i]=false end
C_PetJournal={
 GetOwnedPetIDs=function() local ids={} for id in pairs(pets) do ids[#ids+1]=id end return ids end,
 GetPetInfoTableByPetID=function(id) return pets[id] end,
 GetPetStats=function(id) local p=pets[id]; return 100,100,20,30,p.rarity end,
 GetPetLoadOutInfo=function(slot) return team[slot] end,
 PetIsTradable=function(id) return pets[id] and not pets[id].untradable end,
 GetNumPetSources=function() return 11 end, GetNumPetTypes=function() return 10 end,
 GetSearchFilter=function() return journal.search end,
 ClearSearchFilter=function() journal.search='' end,
 SetSearchFilter=function(v) journal.search=v end,
 IsFilterChecked=function(i) return journal.flags[i] end,
 SetFilterChecked=function(i,v) journal.flags[i]=v end,
 IsPetTypeChecked=function(i) return journal.types[i] end,
 SetPetTypeFilter=function(i,v) journal.types[i]=v end,
 IsPetSourceChecked=function(i) return journal.sources[i] end,
 SetPetSourceChecked=function(i,v) journal.sources[i]=v end,
 GetNumPets=function() return #C_PetJournal.GetOwnedPetIDs() end,
 GetPetInfoByIndex=function(i) local id=C_PetJournal.GetOwnedPetIDs()[i]; if journal.sources[pets[id].source or 1] then return id end end,
 CagePetByID=function(id)
    calls[#calls+1]=id
    if failure then PetCagerFrame.scripts.OnEvent(PetCagerFrame,'PET_JOURNAL_CAGE_FAILED')
    elseif not timeout then C_Timer.After(0.3,function() pets[id]=nil end) end
 end,
}
assert(loadfile('PetCager.lua'))()
local function find(text)
 for _,w in ipairs(widgets) do if w.text==text then return w end end
 error('Missing widget '..text)
end
local function click(w) assert(w.enabled,'disabled control'); w.scripts.OnClick(w) end
local function pet(id,level,rarity,extra)
 pets[id]={speciesID=1,name=id,petLevel=level,rarity=rarity or 4,petType=1,sourceText='Drop'}
 for k,v in pairs(extra or {}) do pets[id][k]=v end
end
local function scan() click(find('Scan Pets')) end
local function selectedRows()
 local rows={}
 for _,w in ipairs(widgets) do if w.kind=='Frame' and rawget(w,'petIndex') and w.shown then rows[#rows+1]=w end end
 return rows
end
local function reset()
 pets={}; calls={}; team={}; failure=false; timeout=false; bagFamily=0; free=20; combat=false
end
-- Keep highest level and use rarity as a tie breaker.
pet('best',25,4); pet('second',25,3); pet('third',1,4)
scan(); assert(#selectedRows()==2)
assert(selectedRows()[1].nameText.text=='second')
-- Explicit deselection must survive batch completion, with no rescan/auto-cage.
local rows=selectedRows(); rows[2].check:SetChecked(false); click(rows[2].check)
click(find('Cage 1 Selected')); drain()
assert(#calls==1 and calls[1]=='second'); assert(pets.third and pets.best)
-- Favorite, team and custom names are always protected by default.
reset(); pet('favorite',1,4,{isFavorite=true}); pet('team',5); pet('named',6,4,{customName='Buddy'}); pet('sale',25); team[1]='team'
scan(); assert(#selectedRows()==1 and selectedRows()[1].nameText.text=='sale')
-- Strongest copy is reserved even if excluded by the quality filter.
reset(); pet('best',25,2); pet('sale',1,4); scan(); assert(#selectedRows()==1)
-- Failure must stop immediately and not count an attempted request as success.
failure=true; click(find('Cage 1 Selected')); drain(); assert(#calls==1 and pets.sale)
assert(find('0 confirmed / 1 selected'))
-- Timeout also stops, without an automatic retry.
scan(); failure=false; timeout=true; click(find('Cage 1 Selected')); drain(); assert(#calls==2 and pets.sale)
-- Stop followed by a new batch cannot revive an older timer.
scan(); timeout=true; click(find('Cage 1 Selected')); click(find('Stop'))
scan(); timeout=false; click(find('Cage 1 Selected')); drain(); assert(#calls==4 and not pets.sale)
-- Specialized bag slots cannot hold cages.
reset(); pet('best',25); pet('sale',1); bagFamily=32; scan(); assert(not find('Cage 1 Selected').enabled)
-- Source-filter scan restores search, favorites, collection, family and source state.
bagFamily=0
for _,w in ipairs(widgets) do
 if w.kind=='CheckButton' and rawget(w,'label') and w.label.text=='Quest' then w:SetChecked(false); click(w); break end
end
scan(); assert(journal.search=='original search' and journal.flags[1]==false and journal.flags[2] and journal.flags[3])
for _,v in ipairs(journal.types) do assert(v==false) end
for _,v in ipairs(journal.sources) do assert(v==false) end
-- Combat and closing the window prevent queued work from continuing.
click(find('Cage 1 Selected')); PetCagerFrame:Hide(); drain(); assert(#calls==1)
-- Revalidation prevents acting on a pet favorited after preview.
reset(); pet('best',25); pet('sale',1); scan(); pets.sale.isFavorite=true
click(find('Cage 1 Selected')); drain(); assert(#calls==0)
-- Combat prevents starting a batch and stops an active one.
pets.sale.isFavorite=false; scan(); combat=true
PetCagerFrame.scripts.OnEvent(PetCagerFrame,'PLAYER_REGEN_DISABLED')
-- The hidden frame need not update its button; the action itself must refuse.
find('Cage 1 Selected').scripts.OnClick(); assert(#calls==0)
combat=false; scan(); click(find('Cage 1 Selected')); combat=true
PetCagerFrame.scripts.OnEvent(PetCagerFrame,'PLAYER_REGEN_DISABLED'); drain(); assert(#calls==1)
-- Source enumeration errors must restore the user's journal before reporting failure.
reset(); pet('best',25); pet('sale',1)
local originalIndex=C_PetJournal.GetPetInfoByIndex
C_PetJournal.GetPetInfoByIndex=function() error('journal not ready') end
scan(); assert(journal.search=='original search' and journal.flags[3])
for _,v in ipairs(journal.sources) do assert(v==false) end
C_PetJournal.GetPetInfoByIndex=originalIndex
print('PASS: keep rules, protections, deselection, failures, timeout, cancellation, bag families, filter restoration')
