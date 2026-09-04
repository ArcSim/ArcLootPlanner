-- ═══════════════════════════════════════════════════════════════════════════
-- Arc Bonus Roll — roll ledger + Adventure Guide markers + coin protection
--
-- Standalone twin (an ArcUI module version mirrors this file; keep in sync).
--
-- SAFETY INVARIANTS (the reason this addon exists over the alternatives):
--   * This addon NEVER calls AcceptSpellConfirmationPrompt or
--     DeclineSpellConfirmationPrompt. Under any code path. The only thing
--     that can roll or pass is the player's own click on Blizzard's own
--     LIVE button — so rolling the wrong boss from stale addon state is
--     structurally impossible, not merely guarded.
--   * Protection is a CLICK-BLOCKING COVER over Blizzard's button, purely
--     subtractive. Worst possible failure = a cover shown or hidden
--     wrongly (an inconvenience), never an action.
--   * No SetScript on Blizzard frames (replaces their handlers, taints the
--     binding). Only hooksecurefunc + our own child frames.
--   * Identity = encounterID + difficultyID + weekly-reset bucket, per
--     character. Never localized name strings.
--
-- Marking model (per Arc's design):
--   * BOSS rows in the Adventure Guide carry the PLANNED-BOSS picker (a
--     coin; click = save this week's coin for that boss; star = planned;
--     a small check badge = rolled this week, from the automatic ledger).
--   * LOOT rows carry the item-level state: bright check = won from a
--     recorded roll, cyan check = manually checked off ("I already got
--     this from a roll" — the only possible backfill, there is no history
--     API), faint coin = click to check it off. Un-collected items show
--     an estimated share (1 in N eligible drops under the current filter).
--     The roll's overall success rate is server-side and never shown.
--
-- /abr — options window (Arc theme). /abr mock — cover test. No pcall.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, NS = ...
local AT = NS.AT

local COLOR = "|cff33ccff"
local function Print(msg)
    print(COLOR .. "Arc Bonus Roll|r: " .. msg)
end

local TEX_CHECK = "common-icon-checkmark"                       -- atlas
local TEX_COIN  = "Interface\\Buttons\\UI-GroupLoot-Coin-Up"    -- last-resort fallback
local TEX_LOCK  = "Interface\\PetBattles\\PetBattle-LockIcon"

-- Nebulous Voidcore, the 12.1 bonus roll currency (Arc-confirmed in-game;
-- the FrameXML BONUS_ROLL_REQUIRED_CURRENCY constant still says 697, the
-- legacy Seal, so do not trust it). A prompt-learned ID overrides this.
local BONUS_CURRENCY = 3418

-- fake spellID for /abr test prompts: recognizably not a real spell, and
-- AcceptSpellConfirmationPrompt on it is a server-side no-op (no pending
-- confirmation exists), so clicking through a test prompt does NOTHING
local TEST_SPELL_ID = 999999901

-- ── DB ──────────────────────────────────────────────────────────────────────
local db, char   -- set in InitDB at login

local function CharKey()
    local name, realm = UnitFullName("player")
    if not realm or realm == "" then
        realm = (GetRealmName() or ""):gsub("%s", "")
    end
    return (name or "Unknown") .. "-" .. realm
end

-- The upcoming weekly reset's timestamp IDs the week (constant all week,
-- jumps at reset). Rounded to the hour to absorb clock skew.
local function CurrentWeek()
    local untilReset = C_DateAndTime.GetSecondsUntilWeeklyReset() or 0
    local reset = GetServerTime() + untilReset
    return math.floor((reset + 1800) / 3600) * 3600
end

-- Per-spec stores: the live aliases every reader/writer uses.
-- RelinkSpecStores points them at the current spec's saved buckets (see
-- the InitDB comment). Until a spec is known (early-login race) they are
-- detached empties, and the first import/prime relinks before writing.
local simStore, poolStore, poolPrimed = {}, {}, {}
local storesLinked = false

local function CurrentSpecID()
    local idx = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization
        and C_SpecializationInfo.GetSpecialization() or nil
    return idx and C_SpecializationInfo.GetSpecializationInfo(idx) or nil
end

local function CurrentSpecName()
    local idx = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization
        and C_SpecializationInfo.GetSpecialization() or nil
    if not idx then return "?" end
    local _, name = C_SpecializationInfo.GetSpecializationInfo(idx)
    return name or "?"
end

local function RelinkSpecStores()
    if not (db and char) then return end
    local specID = CurrentSpecID()
    if not specID then return end
    char.specData = char.specData or {}
    local mine = char.specData[specID] or {}
    char.specData[specID] = mine
    db.poolBySpec = db.poolBySpec or {}
    local shared = db.poolBySpec[specID] or {}
    db.poolBySpec[specID] = shared
    -- one-time adoption of the pre-per-spec stores into today's spec
    if char.simEV and next(char.simEV) and not mine.simEV then mine.simEV = char.simEV end
    if char.poolCache and next(char.poolCache) and not shared.cache then shared.cache = char.poolCache end
    if char.poolPrimedAt and next(char.poolPrimedAt) and not shared.primedAt then shared.primedAt = char.poolPrimedAt end
    char.simEV, char.poolCache, char.poolPrimedAt = nil, nil, nil
    mine.simEV = mine.simEV or {}
    shared.cache = shared.cache or {}
    shared.primedAt = shared.primedAt or {}
    simStore = mine.simEV
    poolStore = shared.cache
    poolPrimed = shared.primedAt
    storesLinked = true
end

local function InitDB()
    ArcBonusRollDB = ArcBonusRollDB or {}
    db = ArcBonusRollDB
    db.chars = db.chars or {}
    local key = CharKey()
    db.chars[key] = db.chars[key] or {}
    char = db.chars[key]
    char.rolls = char.rolls or {}         -- ledger, newest first
    -- [itemID] = { [difficultyID] = time() } manual "already got it". The
    -- Voidcore tooltip says items are received ONCE PER DIFFICULTY LEVEL,
    -- so ownership is difficulty-scoped (0 = any, from legacy marks).
    char.itemMarks = char.itemMarks or {}
    for itemID, v in pairs(char.itemMarks) do
        if type(v) ~= "table" then char.itemMarks[itemID] = { [0] = v } end
    end
    -- [encounterID .. ":" .. difficultyID] = true - bosses the player has
    -- CHECKED OFF (done rolling: got everything, or just not interested).
    -- Persistent, per difficulty, toggled by right-clicking the boss coin.
    char.doneBosses = char.doneBosses or {}
    -- [week] = { ["enc:diff"] = true, ... } - planned bosses are PER
    -- DIFFICULTY (Heroic and Mythic planned separately), several allowed.
    -- Legacy shapes (single {encounterID=X}, and boss-level numeric keys)
    -- are dropped: plans are weekly and trivial to re-click.
    char.plan  = char.plan or {}
    for week, p in pairs(char.plan) do
        if type(p) ~= "table" then
            char.plan[week] = nil
        else
            if p.encounterID ~= nil then char.plan[week] = nil end
            if char.plan[week] then
                for k in pairs(p) do
                    if type(k) ~= "string" then p[k] = nil end
                end
                if not next(p) then char.plan[week] = nil end
            end
        end
    end
    char.marks = nil                      -- legacy weekly boss marks, removed
    char.settings = char.settings or {}
    local s = char.settings
    if s.protection == nil then s.protection = false end  -- opt-in
    if s.passGuard  == nil then s.passGuard  = true  end  -- sub-toggle of protection
    if s.ejOverlay  == nil then s.ejOverlay  = true  end
    if s.tooltips   == nil then s.tooltips   = true  end
    s.detectOwned = nil    -- legacy gate: a saved "false" from the old toggle
                           -- silently killed detection forever; it is gone
    s.stripPos = nil       -- legacy position picker: inside-top is THE spot now
    if s.showStrip == nil then s.showStrip = true end     -- journal info bar
    if s.stripCounter == nil then s.stripCounter = "total" end -- "total" | "week"
    if s.evPercent == nil then s.evPercent = false end    -- EV as % of baseline DPS
    if s.minimap == nil then s.minimap = true end         -- the launcher button
    if s.minimapAngle == nil then s.minimapAngle = 210 end
    if s.planReminder == nil then s.planReminder = true end -- new-week plan nudge
    if s.showOnRaids == nil then s.showOnRaids = true end     -- journal raid pages
    if s.showOnDungeons == nil then s.showOnDungeons = false end -- dungeon/M+ pages
    if char.rollBaseline == nil then char.rollBaseline = 0 end -- pre-install rolls
    -- sim EVs and confirmed pools are PER SPEC and PERSISTENT. Sims are
    -- gear-dependent, so they live per character: char.specData[specID]
    -- .simEV[diff] = { base, t, gains = { [enc] = { [itemID] = gain } } }.
    -- The journal pool is identical for every character of a spec, so it
    -- lives ACCOUNT-wide: db.poolBySpec[specID].cache[diff][enc] =
    -- { [itemID] = true }, .primedAt[diff] = journal instanceID. Primed
    -- ONCE, saved, and re-harvested only for a raid or spec this account
    -- has never confirmed. RelinkSpecStores aliases the live stores.
    RelinkSpecStores()

    local cutoff = CurrentWeek() - 8 * 7 * 24 * 3600
    for week in pairs(char.plan) do
        if type(week) ~= "number" or week < cutoff then char.plan[week] = nil end
    end
    while #char.rolls > 200 do table.remove(char.rolls) end
end

-- ── State queries ───────────────────────────────────────────────────────────
local lastKnownCurrencyID

local function BonusCurrencyID()
    return (char and char.lastCurrencyID) or lastKnownCurrencyID or BONUS_CURRENCY
end

local function CoinIconTexture()
    local id = BonusCurrencyID()
    if id then
        local info = C_CurrencyInfo.GetCurrencyInfo(id)
        if info and info.iconFileID then return info.iconFileID end
    end
    return TEX_COIN
end

local function BonusRollsAvailable()
    local id = BonusCurrencyID()
    if id then
        local info = C_CurrencyInfo.GetCurrencyInfo(id)
        if info then return info.quantity or 0, info.name end
    end
    return nil, nil
end

local wonItems = {}   -- [itemID] = { [difficultyID] = ledger record }

local function ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

local function RememberWonItem(rec)
    local id = ItemIDFromLink(rec.link)
    if not id then return end
    wonItems[id] = wonItems[id] or {}
    if not wonItems[id][rec.diff or 0] then
        wonItems[id][rec.diff or 0] = rec
    end
end

local function RebuildWonItems()
    wipe(wonItems)
    for i = 1, #char.rolls do
        RememberWonItem(char.rolls[i])
    end
end

-- owned FOR A DIFFICULTY = won from a recorded roll on it, or checked off
-- (difficulty 0 = legacy "any difficulty" marks count everywhere)
local function IsOwnedItem(itemID, diff)
    if not itemID then return false, nil end
    local won = wonItems[itemID]
    if won and (won[diff] or won[0]) then return true, "auto", won[diff] or won[0] end
    local marks = char.itemMarks[itemID]
    if marks and (marks[diff] or marks[0]) then return true, "manual", nil end
    return false, nil, nil
end

-- RETRO-ESTIMATION (the Raidbots trick): figure out already-received pieces
-- without any roll history API. The EJ loot link carries THIS difficulty's
-- bonusIDs, so the transmog collection answers per difficulty version and
-- remembers forever, even for deleted gear. Non-transmoggable pieces
-- (trinkets, rings, necks) fall back to equipped+bags at the drop's base
-- item level or higher. Runs ONLY when the player presses Estimate looted,
-- and its hits are written as ORDINARY manual checks (same check, and the
-- player can un-click any of them) - never a passive overlay.
local detectCache = {}

local function WipeDetectCache()
    wipe(detectCache)
end

local function DetectOwnedByLink(link, itemID)
    if not link then return false end
    local hit = detectCache[link]
    if hit ~= nil then return hit end
    local owned = false
    if C_TransmogCollection and C_TransmogCollection.PlayerHasTransmogByItemInfo then
        owned = C_TransmogCollection.PlayerHasTransmogByItemInfo(link) or false
    end
    if not owned and itemID then
        -- equipped/bags: match the item, and accept the drop's base item
        -- level OR HIGHER (owned pieces are usually upgraded, an exact
        -- match almost never fires). A lower-difficulty version stays
        -- below the higher difficulty's base, so >= is the right gate.
        local wantIlvl = C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link) or nil
        local function SameItem(foundLink)
            if not foundLink then return false end
            if ItemIDFromLink(foundLink) ~= itemID then return false end
            -- same itemID = probably looted (the SimC approach); when both
            -- item levels are readable, require the drop's base or higher
            -- so a lower difficulty's copy does not claim this one
            if not wantIlvl then return true end
            local il = C_Item.GetDetailedItemLevelInfo(foundLink)
            return il == nil or il >= wantIlvl
        end
        for slot = 1, 19 do
            if SameItem(GetInventoryItemLink("player", slot)) then
                owned = true
                break
            end
        end
        if not owned and C_Container then
            for bag = 0, 4 do
                local n = C_Container.GetContainerNumSlots(bag) or 0
                for s = 1, n do
                    if SameItem(C_Container.GetContainerItemLink(bag, s)) then
                        owned = true
                        break
                    end
                end
                if owned then break end
            end
        end
    end
    detectCache[link] = owned
    return owned
end


local function GetRollRecord(week, enc, diff)
    for i = 1, #char.rolls do
        local r = char.rolls[i]
        if r.week == week and r.enc == enc and r.diff == diff then
            return r
        end
    end
    return nil
end

local function BossKey(enc, diff)
    return tostring(enc) .. ":" .. tostring(diff or 0)
end

local function IsPlanned(week, enc, diff)
    local p = char.plan[week]
    return (p and enc and p[BossKey(enc, diff)]) and true or false
end

local function HasAnyPlan(week)
    local p = char.plan[week]
    return (p and next(p)) and true or false
end

local function PlannedNames(week)
    local p = char.plan[week]
    if not p then return nil end
    local names
    for key in pairs(p) do
        local enc, diff = key:match("^(%d+):(%d+)$")
        enc, diff = tonumber(enc), tonumber(diff)
        if enc then
            local n = (EJ_GetEncounterInfo(enc) or ("encounter " .. enc))
            local dn = diff and diff ~= 0 and GetDifficultyInfo(diff) or nil
            if dn then n = n .. " (" .. dn .. ")" end
            names = names and (names .. ", " .. n) or n
        end
    end
    return names
end

-- compact display form: one entry per boss with letter codes for its
-- planned difficulties - "The Coiled Altar (H)(M), Sszorak (N)"
local DIFF_CODE = { [14] = "N", [15] = "H", [16] = "M", [17] = "L" }
local function PlannedShort(week)
    local p = char.plan[week]
    if not p then return nil, 0 end
    local byBoss, order = {}, {}
    for key in pairs(p) do
        local enc, diff = key:match("^(%d+):(%d+)$")
        enc, diff = tonumber(enc), tonumber(diff)
        if enc then
            if not byBoss[enc] then
                byBoss[enc] = {}
                order[#order + 1] = enc
            end
            local code = DIFF_CODE[diff]
            if not code and diff and diff ~= 0 then
                local dn = GetDifficultyInfo(diff)
                code = dn and dn:sub(1, 1) or "?"
            end
            table.insert(byBoss[enc], code or "?")
        end
    end
    local parts, count = {}, 0
    for _, enc in ipairs(order) do
        table.sort(byBoss[enc])
        local codes = ""
        for _, c in ipairs(byBoss[enc]) do codes = codes .. "(" .. c .. ")" end
        parts[#parts + 1] = (EJ_GetEncounterInfo(enc) or ("boss " .. enc)) .. " " .. codes
        count = count + 1
    end
    return table.concat(parts, ", "), count
end

local function EncounterName(encounterID)
    if not encounterID or encounterID == 0 then return "unknown boss" end
    local name = EJ_GetEncounterInfo(encounterID)
    return name or ("encounter " .. encounterID)
end

local function DifficultyName(diff)
    if not diff or diff == 0 then return "?" end
    local name = GetDifficultyInfo(diff)
    return name or ("difficulty " .. diff)
end

-- forward declarations (defined below, used by the recording engine)
local RefreshEJ
local UpdateCovers
local RefreshWindow
local WipeLootPool
local ApplyMinimapButton
local MaybePlanReminder
local HidePlanReminder
local InstallVaultHook
local simStatusMsg = ""   -- Sims tab status line (writers live above the window code)

-- ── Recording engine ────────────────────────────────────────────────────────
-- BONUS_ROLL_STARTED = the player committed the coin: record NOW, with the
-- boss identity read live from Blizzard's own frame fields at that instant
-- (set by BonusRollFrame_StartBonusRoll; reading Blizzard fields is safe).
local pendingRoll

local function OnRollStarted()
    if not char then return end
    local f = BonusRollFrame
    local rec = {
        week = CurrentWeek(),
        enc  = (f and f.encounterID) or 0,
        diff = (f and f.difficultyID) or 0,
        inst = (f and f.instanceID) or 0,
        t = time(),
        result = "pending",
    }
    table.insert(char.rolls, 1, rec)
    while #char.rolls > 200 do table.remove(char.rolls) end
    pendingRoll = rec
    if RefreshEJ then RefreshEJ() end
    if RefreshWindow then RefreshWindow() end
end

local function OnRollResult(typeIdentifier, itemLink, quantity, _, _, _, currencyID)
    if not char or not pendingRoll then return end
    pendingRoll.result = typeIdentifier or "?"
    pendingRoll.link = itemLink
    pendingRoll.qty = quantity
    pendingRoll.currencyID = currencyID
    RememberWonItem(pendingRoll)
    pendingRoll = nil
    if WipeLootPool then WipeLootPool() end
    if RefreshEJ then RefreshEJ() end
    if RefreshWindow then RefreshWindow() end
end

local function OnRollFailed()
    if pendingRoll then
        pendingRoll.result = "failed"
        pendingRoll = nil
        if RefreshWindow then RefreshWindow() end
    end
end

-- ── Coin protection covers ──────────────────────────────────────────────────
-- Our own child frames over Blizzard's buttons. We never write to, disable,
-- or re-script the real buttons — Blizzard's own OnShow re-enables the dice
-- button anyway, so covering is both safer and the only stable approach.
local rollCover, passCover
local promptToken, unlockedRoll, unlockedPass

local function MakeCover(anchorButton, unlockKind)
    local c = CreateFrame("Button", nil, BonusRollFrame.PromptFrame)
    c:SetPoint("TOPLEFT", anchorButton, "TOPLEFT", -3, 3)
    c:SetPoint("BOTTOMRIGHT", anchorButton, "BOTTOMRIGHT", 3, -3)
    c:SetFrameLevel(anchorButton:GetFrameLevel() + 5)
    c:EnableMouse(true)
    c:RegisterForClicks("AnyUp")
    local bg = c:CreateTexture(nil, "ARTWORK")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.78)
    local lock = c:CreateTexture(nil, "OVERLAY")
    lock:SetSize(16, 16)
    lock:SetPoint("CENTER")
    lock:SetTexture(TEX_LOCK)
    c.reason = ""
    c:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Arc Bonus Roll protection", 0.2, 0.8, 1)
        GameTooltip:AddLine(self.reason, 1, 1, 1, true)
        GameTooltip:AddLine("Click this cover once to unlock the button underneath for this prompt.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    c:SetScript("OnClick", function()
        if unlockKind == "roll" then unlockedRoll = true else unlockedPass = true end
        GameTooltip:Hide()
        UpdateCovers()
    end)
    c:Hide()
    return c
end

local function EnsureCovers()
    if rollCover then return true end
    local pf = BonusRollFrame and BonusRollFrame.PromptFrame
    if not (pf and pf.RollButton and pf.PassButton) then return false end
    rollCover = MakeCover(pf.RollButton, "roll")
    passCover = MakeCover(pf.PassButton, "pass")
    return true
end

UpdateCovers = function()
    if not char then return end
    -- every plan toggle routes through here: the moment a plan exists, the
    -- "plan your week" reminder has done its job
    if HidePlanReminder and HasAnyPlan(CurrentWeek()) then HidePlanReminder() end
    if not EnsureCovers() then return end
    local showRoll, showPass = false, false
    local rollReason, passReason = "", ""
    local pf = BonusRollFrame.PromptFrame
    if char.settings.protection and pf:IsShown() then
        local week = CurrentWeek()
        local enc = BonusRollFrame.encounterID
        local diff = BonusRollFrame.difficultyID
        if not HasAnyPlan(week) then
            showRoll = not unlockedRoll
            rollReason = "No planned bosses are set for this week. Pick them in the Adventure Guide (click the coin on a boss), or unlock to roll anyway."
        elseif enc and IsPlanned(week, enc, diff) then
            showPass = char.settings.passGuard and not unlockedPass
            passReason = ("This is one of your planned bosses (%s) — passing would throw away the roll you saved your coin for."):format(EncounterName(enc))
        else
            showRoll = not unlockedRoll
            rollReason = ("Your coins are saved for: %s. Unlock to roll this boss anyway."):format(PlannedNames(week) or "?")
        end
    end
    rollCover.reason = rollReason
    passCover.reason = passReason
    rollCover:SetShown(showRoll)
    passCover:SetShown(showPass)
end

local function OnPromptShown()
    local f = BonusRollFrame
    if not f then return end
    -- a /abr test prompt must not pollute the learned currency/instance
    if f.spellID ~= TEST_SPELL_ID then
        if f.CurrentCountFrame and f.CurrentCountFrame.currencyID then
            lastKnownCurrencyID = f.CurrentCountFrame.currencyID
            if char then char.lastCurrencyID = lastKnownCurrencyID end
        end
        if char and f.instanceID and f.instanceID ~= 0 then
            char.lastInstanceID = f.instanceID   -- "open the journal here" target
        end
    end
    local token = tostring(f.spellID) .. ":" .. tostring(f.encounterID) .. ":" .. tostring(f.difficultyID)
    if token ~= promptToken then
        promptToken = token
        unlockedRoll, unlockedPass = nil, nil
    end
    UpdateCovers()
    -- a roll is up with nothing planned: protection is covering nothing,
    -- which is exactly when the plan reminder earns its keep
    if MaybePlanReminder then MaybePlanReminder("prompt") end
end

-- ── Sim EVs (Raidbots Droptimizer CSV paste) ────────────────────────────────
-- The report's data.csv is ~20KB of "profileset,dps" lines - small enough
-- to copy straight out of the browser, no converter tool needed. Names
-- encode instanceID/encounterID/source-difficulty/itemID/..., so one paste
-- gives per-item DPS gains keyed exactly like our journal markers.
local DIFF_FROM_SOURCE = { normal = 14, heroic = 15, mythic = 16, lfr = 17 }

local function ParseDroptimizerCSV(text)
    if type(text) ~= "string" or text == "" then return nil end
    local baseline
    local rows = {}
    for line in text:gmatch("[^\r\n]+") do
        local name, mean = line:match("^([^,]+),([%d%.]+)")
        local meanN = mean and tonumber(mean) or nil
        if name and meanN then
            if not name:find("/") then
                -- the first non-profileset numeric row is the baseline actor
                if not baseline then baseline = meanN end
            else
                local f = {}
                for part in (name .. "/"):gmatch("([^/]*)/") do f[#f + 1] = part end
                local src = f[3] or ""
                if src:find("raid") then
                    local diff
                    for word, id in pairs(DIFF_FROM_SOURCE) do
                        if src:find(word) then diff = id break end
                    end
                    -- a trailing item field means the simmed piece is a
                    -- CONVERSION (tier token / catalyst) of that DROP:
                    -- credit the gain to the item that actually drops,
                    -- so the journal row shows its best use
                    local enc = tonumber(f[2])
                    local item = tonumber(f[11]) or tonumber(f[4])
                    if diff and enc and item then
                        rows[#rows + 1] = { diff = diff, enc = enc, item = item, mean = meanN }
                    end
                end
            end
        end
    end
    if not baseline or #rows == 0 then return nil end
    -- an item can be simmed several ways (trinket1/trinket2, ring slots,
    -- tier pairings): keep the BEST gain per (difficulty, boss, item)
    local out = {}
    for _, r in ipairs(rows) do
        local gain = r.mean - baseline
        out[r.diff] = out[r.diff] or {}
        out[r.diff][r.enc] = out[r.diff][r.enc] or {}
        local cur = out[r.diff][r.enc][r.item]
        if not cur or gain > cur then out[r.diff][r.enc][r.item] = gain end
    end
    return baseline, out
end

-- returns: importedDiffCount, itemCount (nil = parse failed)
local function ApplySimImport(text)
    if not storesLinked then RelinkSpecStores() end
    if not char then return nil end
    local baseline, byDiff = ParseDroptimizerCSV(text)
    if not baseline then return nil end
    local diffs, items = 0, 0
    for diff, gains in pairs(byDiff) do
        simStore[diff] = { base = baseline, t = time(), gains = gains }
        diffs = diffs + 1
        for _, encGains in pairs(gains) do
            for _ in pairs(encGains) do items = items + 1 end
        end
    end
    return diffs, items
end

-- ZERO-PASTE import from the WoWUtils companion addon: it stores fully
-- parsed droptimizer data in its SavedVariables -
--   WowUtilsDB.droptimizerData["<name lower>-<realmId>"]
--     .specs[specId][simId] = { items, baseline, simmedAt }
--   items[itemId] = array of { difficultyId (14/15/16, same journal IDs
--   we use), gain (already baseline-relative), encounterId (journal;
--   negative = non-raid), sourceItem { itemId, encounterId } when the
--   piece comes from converting a DROP (tier token / catalyst) }.
-- Rows read from another addon's DB are data, never trusted blindly:
-- every field is type-guarded. Newest sim per difficulty wins.
local function ImportFromWowUtils()
    if not char then return nil, "not ready" end
    if not storesLinked then RelinkSpecStores() end
    local db = _G.WowUtilsDB
    local data = db and db.droptimizerData
    if type(data) ~= "table" then
        return nil, "WoWUtils addon (or its droptimizer data) not found."
    end
    local rec
    local myName = (UnitName("player") or ""):lower()
    local realmId = GetRealmID and GetRealmID() or nil
    if realmId then rec = data[myName .. "-" .. tostring(realmId)] end
    if not rec then
        for _, d in pairs(data) do
            if type(d) == "table" and type(d.characterName) == "string"
                and d.characterName:lower() == myName then
                rec = d
                break
            end
        end
    end
    if not (rec and type(rec.specs) == "table") then
        return nil, "WoWUtils has no droptimizer data for this character."
    end
    local specIndex = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization
        and C_SpecializationInfo.GetSpecialization() or nil
    local specId = specIndex and C_SpecializationInfo.GetSpecializationInfo(specIndex) or nil
    local sims = specId and rec.specs[specId] or nil
    if not sims then
        return nil, "WoWUtils has no sims stored for your current spec."
    end
    -- pick the newest sim per difficulty
    local newest = {}
    for _, sim in pairs(sims) do
        if type(sim) == "table" and type(sim.items) == "table" and type(sim.baseline) == "number" then
            local diffsIn = {}
            for _, entries in pairs(sim.items) do
                if type(entries) == "table" then
                    for _, e in ipairs(entries) do
                        local enc = (type(e.sourceItem) == "table" and e.sourceItem.encounterId) or e.encounterId
                        if type(enc) == "number" and enc > 0 and type(e.difficultyId) == "number" then
                            diffsIn[e.difficultyId] = true
                        end
                    end
                end
            end
            for d in pairs(diffsIn) do
                if not newest[d] or (sim.simmedAt or 0) > (newest[d].simmedAt or 0) then
                    newest[d] = sim
                end
            end
        end
    end
    local diffs, items = 0, 0
    for d, sim in pairs(newest) do
        local gains = {}
        for itemId, entries in pairs(sim.items) do
            if type(entries) == "table" then
                for _, e in ipairs(entries) do
                    if e.difficultyId == d and type(e.gain) == "number" then
                        local src = type(e.sourceItem) == "table" and e.sourceItem or nil
                        local enc = (src and src.encounterId) or e.encounterId
                        local dropItem = (src and src.itemId) or itemId
                        if type(enc) == "number" and enc > 0 and type(dropItem) == "number" then
                            gains[enc] = gains[enc] or {}
                            local cur = gains[enc][dropItem]
                            if not cur or e.gain > cur then gains[enc][dropItem] = e.gain end
                        end
                    end
                end
            end
        end
        if next(gains) then
            simStore[d] = { base = sim.baseline, t = sim.simmedAt or time(), gains = gains }
            diffs = diffs + 1
            for _, eg in pairs(gains) do
                for _ in pairs(eg) do items = items + 1 end
            end
        end
    end
    if diffs == 0 then
        return nil, "WoWUtils data held no usable raid gains."
    end
    return diffs, items
end

-- Fill the CURRENT spec's sim bucket from the WoWUtils companion when it
-- is empty - never overwrites an existing import. Runs at login and on
-- every spec swap, and it must ANNOUNCE itself on the Sims tab: the silent
-- version re-imported sims seconds after /abr wipe and looked exactly like
-- the wipe failing (WoWUtils keeps its own saved data, which is the point).
local function AutoImportSims()
    if not char or next(simStore) then return end
    local diffs, items = ImportFromWowUtils()
    if diffs then
        simStatusMsg = ("|cff4cde4cAuto-imported %d item gains for %s from the WoWUtils addon's saved sims.|r"):format(
            items, CurrentSpecName())
    end
end

local function SimGainFor(diff, enc, itemID)
    local ev = char and simStore[diff]
    local g = ev and ev.gains[enc]
    return g and g[itemID] or nil
end

-- THE one authority for a boss's roll EV: computed from the sim data
-- alone (sum of un-collected positive gains / count of un-collected sim
-- items). Never from the journal's shown list - the two disagree (tier
-- rows carry token itemIDs while sims carry the resulting pieces), which
-- made a boss's EV change depending on which page was open.
local function BossSimEV(enc, diff)
    local ev = char and simStore[diff]
    local gains = ev and ev.gains[enc]
    if not gains then return nil end
    -- with a cached journal pool, intersect: only items the boss actually
    -- drops count as outcomes (sim-only phantoms are excluded); a pool
    -- item the sim did not value contributes 0 but still dilutes
    local cache = poolStore[diff] and poolStore[diff][enc]
    local sum, remaining = 0, 0
    if cache and next(cache) then
        for itemID in pairs(cache) do
            if not IsOwnedItem(itemID, diff) then
                remaining = remaining + 1
                local g = gains[itemID]
                if g and g > 0 then sum = sum + g end
            end
        end
    else
        for itemID, g in pairs(gains) do
            if not IsOwnedItem(itemID, diff) then
                remaining = remaining + 1
                if g > 0 then sum = sum + g end
            end
        end
    end
    if remaining > 0 and sum > 0 then
        return sum / remaining, remaining
    end
    return nil
end

local function SimBaseFor(diff)
    local ev = char and simStore[diff]
    return ev and ev.base or nil
end

-- "+3,478" or, in percent mode, "+1.9%" (Raidbots' Relative DPS view)
local function FormatGainNumber(v, diff)
    if char and char.settings.evPercent then
        local base = SimBaseFor(diff)
        if base and base > 0 then
            return ("%+.1f%%"):format(v / base * 100)
        end
    end
    local sign = v >= 0 and "+" or "-"
    return sign .. BreakUpLargeNumbers(math.floor(math.abs(v) + 0.5))
end

-- ── Loot pool (estimated share per un-collected item) ───────────────────────
-- Pool = the loot list as the journal currently filters it (class/spec/slot/
-- difficulty), grouped per boss, per-player Bonus Loot excluded (separate
-- mechanic, not part of the roll table). Owned items (won or checked off)
-- shrink the pool. Estimated share = 1 / remaining, and it is clearly labeled
-- an estimate: the roll's gold-vs-loot rate is server-side and unknowable.
local lootPool

WipeLootPool = function()
    lootPool = nil
end

local function GetEncounterPool(encID)
    if not encID then return nil end
    if not lootPool then
        lootPool = {}
        local diffNow = (EJ_GetDifficulty and EJ_GetDifficulty()) or 0
        -- record the journal pool only when the view is trustworthy: the
        -- player's own class and no slot filter (a narrowed or foreign
        -- view must never overwrite the cached truth)
        local canCache = char ~= nil and diffNow ~= 0
        if canCache and EJ_GetLootFilter then
            -- the pool bucket is per SPEC (account-wide): only a view
            -- filtered to exactly the player's current spec may write it
            local cls, spec = EJ_GetLootFilter()
            if cls ~= select(3, UnitClass("player")) then canCache = false end
            local mySpec = CurrentSpecID()
            if not mySpec or (spec or 0) ~= mySpec then canCache = false end
        end
        if canCache and C_EncounterJournal.GetSlotFilter and Enum and Enum.ItemSlotFilterType then
            local sf = C_EncounterJournal.GetSlotFilter()
            if sf and sf ~= Enum.ItemSlotFilterType.NoFilter then canCache = false end
        end
        local fresh = canCache and {} or nil
        local n = (EJ_GetNumLoot and EJ_GetNumLoot()) or 0
        for i = 1, n do
            local info = C_EncounterJournal.GetLootInfoByIndex(i)
            -- pool = EQUIPMENT only: the Voidcore "transmutes into powerful
            -- equipment", so per-player Bonus Loot rows and slotless items
            -- (mounts, curios, quest pieces) are not part of the roll table
            if info and info.encounterID and not info.displayAsPerPlayerLoot
                and info.slot and info.slot ~= "" then
                local pool = lootPool[info.encounterID]
                if not pool then
                    pool = { total = 0, owned = 0, gainSum = 0 }
                    lootPool[info.encounterID] = pool
                end
                pool.total = pool.total + 1
                if info.itemID and fresh then
                    fresh[info.encounterID] = fresh[info.encounterID] or {}
                    fresh[info.encounterID][info.itemID] = true
                end
                if info.itemID and IsOwnedItem(info.itemID, diffNow) then
                    pool.owned = pool.owned + 1
                elseif info.itemID then
                    -- un-collected: its sim gain feeds the boss's EV
                    local gain = SimGainFor(diffNow, info.encounterID, info.itemID)
                    if gain and gain > 0 then
                        pool.gainSum = pool.gainSum + gain
                    end
                end
            end
        end
        if fresh then
            for enc, set in pairs(fresh) do
                -- only replace a boss's cached pool with a COMPLETE view of
                -- it (the list always carries a boss's full table when the
                -- boss is present at all)
                poolStore[diffNow] = poolStore[diffNow] or {}
                poolStore[diffNow][enc] = set
            end
        end
    end
    return lootPool[encID]
end

-- ── Adventure Guide markers ─────────────────────────────────────────────────
local bossMarkers = {}   -- [bossButton] = marker
local itemMarkers = {}   -- [itemButton] = marker

local function CurrentEJDifficulty()
    local diff = EJ_GetDifficulty and EJ_GetDifficulty() or 0
    return diff or 0
end

-- Would ANY auto rule re-check this boss the moment its done-flag clears?
-- Un-checking must store FALSE exactly when this is true, so the player's
-- override ALWAYS sticks even where the addon's auto-check is wrong. The
-- old per-site guesses each saw only one source (live journal list here,
-- same-refresh state there) and could store nil - auto then silently
-- re-checked the boss from the source they did not look at.
local function AutoWouldCheck(enc, diff)
    -- confirmed pool fully collected (persisted cache, works everywhere)
    local pool = poolStore[diff] and poolStore[diff][enc]
    if pool and next(pool) then
        local left = 0
        for itemID in pairs(pool) do
            if not IsOwnedItem(itemID, diff) then left = left + 1 end
        end
        if left == 0 then return true end
    end
    -- live journal loot list (session view of the same rule)
    local live = GetEncounterPool(enc)
    if live and live.total > 0 and live.owned >= live.total then return true end
    -- sim list fully owned (the Overview's sim-based auto rule)
    local ev = simStore[diff]
    local gains = ev and ev.gains[enc]
    if gains and next(gains) then
        local anyLeft = false
        for itemID in pairs(gains) do
            if not IsOwnedItem(itemID, diff) then anyLeft = true break end
        end
        if not anyLeft then return true end
    end
    return false
end

-- Which journal content shows our overlays: bonus rolls are a RAID system,
-- so raid pages are on by default and dungeon/M+ pages are opt-in.
local function EJViewAllowed()
    if not char then return false end
    local isRaid = EJ_InstanceIsRaid and EJ_InstanceIsRaid() or false
    if isRaid then return char.settings.showOnRaids ~= false end
    return char.settings.showOnDungeons == true
end

-- BOSS rows: the planned-boss picker. Coin = click to save your coin for
-- this boss this week; star = planned; small check badge = rolled this week.
local function BossMarkerUpdate(m)
    local btn = m:GetParent()
    local enc = btn and btn.encounterID
    if not char or not enc or not char.settings.ejOverlay or not EJViewAllowed() then
        m:Hide()
        return
    end
    m:Show()
    local week = CurrentWeek()
    local diff = CurrentEJDifficulty()
    local rec = GetRollRecord(week, enc, diff)
    local planned = IsPlanned(week, enc, diff)
    -- done = manually checked off, or the whole pool is collected (auto,
    -- only computable while this boss's loot is in the journal's list).
    -- An explicit FALSE suppresses auto-done: the player un-checked a
    -- fully-collected boss and that choice must stick.
    local doneFlag = char.doneBosses[BossKey(enc, diff)]
    local doneManual = doneFlag == true
    local doneAuto = false
    if doneFlag == nil then
        local pool = GetEncounterPool(enc)
        doneAuto = (pool and pool.total > 0 and pool.owned >= pool.total) and true or false
    end
    m.state = { enc = enc, diff = diff, week = week, rec = rec, planned = planned,
                done = doneManual or doneAuto, doneManual = doneManual }
    if m.state.done then
        -- done = the Voidcore at FULL COLOR with a big green check on top
        -- (Arc's design: reads as "this bonus roll is finished")
        m.icon:SetTexture(CoinIconTexture())
        m.icon:SetDesaturated(false)
        m:SetAlpha(1)
        m.badge:Hide()
        m.planRing:Hide()
        m.doneCheck:Show()
        return
    end
    m.doneCheck:Hide()
    -- same Voidcore icon in both states, always SOLID: desaturated = not
    -- picked, full color = on this week's bonus roll list (Arc's design)
    m.icon:SetTexture(CoinIconTexture())
    m.icon:SetDesaturated(not planned)
    m.planRing:SetShown(planned)
    m:SetAlpha(1)
    m.badge:SetShown(rec ~= nil)
    -- sim EV per coin: expected DPS gain of rolling this boss right now,
    -- ALWAYS from BossSimEV so the number is identical on every page
    local evValue = BossSimEV(enc, diff)
    m.ev:SetText(evValue and FormatGainNumber(evValue, diff) or "")
end

local function BossMarkerClick(m, mouseButton)
    if not char or not m.state then return end
    local s = m.state
    if mouseButton == "RightButton" then
        -- check off / un-check this boss (this difficulty). Un-checking
        -- stores FALSE whenever any auto rule would re-check it, so the
        -- player's override sticks; nil (clean DB) otherwise.
        local key = BossKey(s.enc, s.diff)
        if s.done then
            char.doneBosses[key] = AutoWouldCheck(s.enc, s.diff) and false or nil
        else
            char.doneBosses[key] = true
        end
    else
        if s.done then return end   -- finished bosses are not plannable
        local key = BossKey(s.enc, s.diff)   -- plans are PER DIFFICULTY
        local p = char.plan[s.week]
        if p and p[key] then
            p[key] = nil
            if not next(p) then char.plan[s.week] = nil end
        else
            char.plan[s.week] = p or {}
            char.plan[s.week][key] = true
        end
    end
    RefreshEJ()
    UpdateCovers()
    if RefreshWindow then RefreshWindow() end
end

local function BossMarkerEnter(m)
    if not m.state then return end
    local s = m.state
    GameTooltip:SetOwner(m, "ANCHOR_RIGHT")
    GameTooltip:SetText("Arc Bonus Roll", 0.2, 0.8, 1)
    local diff = DifficultyName(s.diff)
    if s.done then
        GameTooltip:AddLine(s.doneManual
            and ("Checked off (%s)."):format(diff)
            or ("All roll loot collected (%s)."):format(diff), 0.3, 1, 0.3, true)
        GameTooltip:AddLine("Right-click: un-check.", 0.7, 0.7, 0.7)
    elseif s.planned then
        GameTooltip:AddLine(("Planned this week (%s)."):format(diff), 1, 0.85, 0.1)
        GameTooltip:AddLine("Click: unplan.  Right-click: check off.", 0.7, 0.7, 0.7)
    else
        GameTooltip:AddLine(("Click: plan this boss (%s)."):format(diff), 1, 1, 1)
        GameTooltip:AddLine("Right-click: check off (done rolling it).", 0.7, 0.7, 0.7)
    end
    if s.rec then
        GameTooltip:AddLine(("Rolled this week: %s"):format(s.rec.link or s.rec.result or "?"), 0.3, 1, 0.3, true)
    end
    if not s.done then
        local evValue, remaining = BossSimEV(s.enc, s.diff)
        if evValue then
            GameTooltip:AddLine(("Roll EV: |cff4cde4c%s|r per coin, across the %d drops left."):format(
                FormatGainNumber(evValue, s.diff), remaining), 0.7, 0.7, 0.7, true)
        end
    end
    GameTooltip:Show()
end

local function DecorateBoss(btn)
    if not char then return end
    local m = bossMarkers[btn]
    if not m then
        m = CreateFrame("Button", nil, btn)
        m:SetSize(24, 24)
        -- raised above center so the coin + EV pair sits symmetrically
        -- in the row's right area (coin on top, value centered under it)
        m:SetPoint("RIGHT", btn, "RIGHT", -22, 7)
        m:SetFrameLevel(btn:GetFrameLevel() + 3)
        m:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        m.icon = m:CreateTexture(nil, "OVERLAY")
        m.icon:SetAllPoints()
        m.badge = m:CreateTexture(nil, "OVERLAY", nil, 2)
        m.badge:SetAtlas(TEX_CHECK)
        m.badge:SetSize(13, 13)
        m.badge:SetPoint("BOTTOMRIGHT", 4, -3)
        -- big centered check laid OVER the coin for the done state
        -- planned = Blizzard's own "selected" look: CheckButtonHilight,
        -- the yellow additive glow a checked action button wears (current
        -- stance, active form). Reads as selection at a glance.
        m.planRing = m:CreateTexture(nil, "OVERLAY", nil, 2)
        m.planRing:SetTexture("Interface\\Buttons\\CheckButtonHilight")
        m.planRing:SetBlendMode("ADD")
        -- CheckButtonHilight fills its whole texture edge to edge: keep it
        -- BARELY larger than the 24px coin so it hugs the icon tightly
        m.planRing:SetSize(26, 26)
        m.planRing:SetPoint("CENTER")
        m.planRing:Hide()
        m.doneCheck = m:CreateTexture(nil, "OVERLAY", nil, 3)
        m.doneCheck:SetAtlas(TEX_CHECK)
        m.doneCheck:SetSize(26, 26)
        m.doneCheck:SetPoint("CENTER", 1, -1)
        m.doneCheck:Hide()
        -- sim EV readout: number only (the little voidcore lives on LOOT
        -- rows, never here), CENTERED under the coin so the pair reads as
        -- one symmetric block
        m.ev = m:CreateFontString(nil, "OVERLAY")
        m.ev:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
        m.ev:SetPoint("TOP", m, "BOTTOM", 0, -1)
        m.ev:SetTextColor(0.3, 0.87, 0.3, 1)
        m:SetScript("OnClick", BossMarkerClick)
        m:SetScript("OnEnter", BossMarkerEnter)
        m:SetScript("OnLeave", function() GameTooltip:Hide() end)
        bossMarkers[btn] = m
    end
    BossMarkerUpdate(m)
end

-- LOOT rows: item-level state + estimated share.
local function ItemMarkerUpdate(m)
    local btn = m:GetParent()
    if not char or not char.settings.ejOverlay or not btn or not btn.itemID
        or not EJViewAllowed() then
        m:Hide()
        m.pct:Hide()
        return
    end
    -- rows outside the roll table get NO overlay at all: per-player Bonus
    -- Loot, slotless non-equipment, and rows whose data is still loading
    local info = btn.index and C_EncounterJournal.GetLootInfoByIndex(btn.index) or nil
    if not info or not info.name or info.displayAsPerPlayerLoot
        or not info.slot or info.slot == "" then
        m:Hide()
        m.pct:Hide()
        if btn.name then btn.name:SetWidth(250) end   -- rows are pool-reused
        return
    end
    m:Show()
    local diff = CurrentEJDifficulty()
    local owned, source = IsOwnedItem(btn.itemID, diff)
    m.state = { itemID = btn.itemID, enc = btn.encounterID, diff = diff,
                owned = owned, source = source }
    if owned then
        -- owned = SAME visual as a finished boss: the Voidcore at full
        -- color with the green check overlaid on top
        m.icon:SetTexture(CoinIconTexture())
        m.icon:SetDesaturated(false)
        m.icon:SetVertexColor(1, 1, 1, 1)
        m.check:Show()
        m:SetAlpha(1)
        m.pct:Hide()
        m.pctIcon:Hide()
        if btn.name then btn.name:SetWidth(250) end
    else
        -- not looted yet = GRAYED coin (still rollable, still pending);
        -- owned pieces carry the full-color coin + green check
        m.icon:SetTexture(CoinIconTexture())
        m.icon:SetDesaturated(true)
        m.icon:SetVertexColor(1, 1, 1, 1)
        m.check:Hide()
        m:SetAlpha(1)
        local pool = btn.encounterID and GetEncounterPool(btn.encounterID) or nil
        local remaining = pool and (pool.total - pool.owned) or 0
        if remaining > 0 then
            local txt = ("~%.0f%%"):format(100 / remaining)
            local gain = SimGainFor(diff, btn.encounterID, btn.itemID)
            if gain and gain >= 0.5 then
                txt = ("|cff4cde4c%s|r  "):format(FormatGainNumber(gain, diff)) .. txt
            elseif gain and gain <= -0.5 then
                txt = ("|cff8ca0b8%s|r  "):format(FormatGainNumber(gain, diff)) .. txt
            end
            m.pct:SetText(txt)
            m.pct:Show()
            m.pctIcon:SetTexture(CoinIconTexture())
            m.pctIcon:Show()
            if btn.name then btn.name:SetWidth(168) end
        else
            m.pct:Hide()
            m.pctIcon:Hide()
            if btn.name then btn.name:SetWidth(250) end
        end
    end
end

local function ItemMarkerClick(m)
    if not char or not m.state then return end
    local s = m.state
    if s.owned and s.source == "auto" then return end   -- ledger-recorded, not togglable
    local marks = char.itemMarks[s.itemID]
    if marks and (marks[s.diff] or marks[0]) then
        marks[s.diff], marks[0] = nil, nil
        if not next(marks) then char.itemMarks[s.itemID] = nil end
    else
        char.itemMarks[s.itemID] = marks or {}
        char.itemMarks[s.itemID][s.diff] = time()
    end
    WipeLootPool()
    RefreshEJ()
    if RefreshWindow then RefreshWindow() end
end

local function ItemMarkerEnter(m)
    if not m.state then return end
    local s = m.state
    GameTooltip:SetOwner(m, "ANCHOR_RIGHT")
    GameTooltip:SetText("Arc Bonus Roll", 0.2, 0.8, 1)
    if s.owned then
        if s.source == "auto" then
            local won = wonItems[s.itemID]
            local rec = won and (won[s.diff] or won[0])
            GameTooltip:AddLine(("Won from a bonus roll (%s)."):format(date("%Y-%m-%d", rec and rec.t or 0)), 0.3, 1, 0.3, true)
        else
            GameTooltip:AddLine(("Checked off: already received (%s)."):format(DifficultyName(s.diff)), 0.3, 1, 0.3, true)
            GameTooltip:AddLine("Click: un-check.", 0.7, 0.7, 0.7)
        end
    else
        GameTooltip:AddLine(("Click: check off as received (%s)."):format(DifficultyName(s.diff)), 1, 1, 1)
        local pool = s.enc and GetEncounterPool(s.enc) or nil
        local remaining = pool and (pool.total - pool.owned) or 0
        if remaining > 0 then
            GameTooltip:AddLine(("One of %d drops you can still receive here (once per difficulty)."):format(remaining), 0.7, 0.7, 0.7, true)
        end
    end
    GameTooltip:Show()
end

local function DecorateItem(btn)
    if not char then return end
    local m = itemMarkers[btn]
    if not m then
        m = CreateFrame("Button", nil, btn)
        m:SetSize(16, 16)
        local anchor = btn.icon or btn
        m:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, 0)
        m:SetFrameLevel(btn:GetFrameLevel() + 3)
        m:RegisterForClicks("LeftButtonUp")
        m.icon = m:CreateTexture(nil, "OVERLAY")
        m.icon:SetAllPoints()
        -- green check overlay for owned items (same look as a done boss)
        m.check = m:CreateTexture(nil, "OVERLAY", nil, 3)
        m.check:SetAtlas(TEX_CHECK)
        m.check:SetSize(18, 18)
        m.check:SetPoint("CENTER", 1, -1)
        m.check:Hide()
        -- the gain + share readout: ONE fixed right-aligned column on the
        -- NAME line (the name is width-clipped to make room - its template
        -- is TOPLEFT + fixed 250px, so SetWidth shortens it cleanly),
        -- with a mini voidcore tag - consistent, nothing floats
        m.pct = m:CreateFontString(nil, "OVERLAY")
        m.pct:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE")
        m.pct:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -8, -6)
        m.pct:SetJustifyH("RIGHT")
        m.pct:SetTextColor(0.25, 0.79, 0.95, 1)
        m.pctIcon = m:CreateTexture(nil, "OVERLAY")
        m.pctIcon:SetSize(13, 13)
        m.pctIcon:SetPoint("RIGHT", m.pct, "LEFT", -4, 0)
        m.pctIcon:Hide()
        m:SetScript("OnClick", ItemMarkerClick)
        m:SetScript("OnEnter", ItemMarkerEnter)
        m:SetScript("OnLeave", function() GameTooltip:Hide() end)
        itemMarkers[btn] = m
    end
    ItemMarkerUpdate(m)
end

-- Arc-styled info strip on the Adventure Guide: rolls available + planned
-- bosses + rolls used this week. Built once at journal load; position per
-- settings.stripPos (defined below, forward-declared for the refresher).
local ejStrip
local ApplyStripPosition
local EstimateLootedScan

local function RefreshEJStrip()
    if not (ejStrip and char) then return end
    if not char.settings.showStrip or not EJViewAllowed() then
        ejStrip:Hide()
        return
    end
    ejStrip:Show()
    if ejStrip.syncPctBtn then ejStrip.syncPctBtn() end
    -- re-anchor every refresh: cheap, and it picks up Raider.IO's shortcut
    -- button even though that addon creates it lazily after we first placed
    ApplyStripPosition()
    local count = BonusRollsAvailable()
    ejStrip.icon:SetTexture(CoinIconTexture())
    ejStrip.count:SetText(count and ("|cffffd100" .. count .. "|r bonus rolls") or "bonus rolls: ?")
    local week = CurrentWeek()
    -- compact boss+letter-code form; NEVER show an ellipsis: if even the
    -- compact form cannot fit, fall back to a count (hover has the list)
    local short, plannedCount = PlannedShort(week)
    if short then
        ejStrip.plan:SetText("Planned: |cffffd100" .. short .. "|r")
        if ejStrip.plan:IsTruncated() then
            ejStrip.plan:SetText(("Planned: |cffffd100%d bosses|r"):format(plannedCount))
        end
    else
        ejStrip.plan:SetText("Planned: |cff8ca0b8none - click a boss's coin|r")
    end
    if char.settings.stripCounter == "week" then
        local n = 0
        for i = 1, #char.rolls do
            if char.rolls[i].week == week then n = n + 1 end
        end
        ejStrip.used:SetText(("Rolled this week: |cffffd100%d|r"):format(n))
    else
        ejStrip.used:SetText(("Rolled: |cffffd100%d|r"):format(#char.rolls + (char.rollBaseline or 0)))
    end
end

-- three placements, Arc-picked: inside-top (under the nav bar, stops short
-- of the Raider.IO-style buttons), inside-bottom (slim band above the tab
-- row), or floating above the whole guide
ApplyStripPosition = function()
    if not (ejStrip and EncounterJournal) then return end
    local s = ejStrip
    s:ClearAllPoints()
    local dd = EncounterJournalEncounterFrameInfoDifficulty
    if dd then
        -- the Raider.IO pattern: live on the DIFFICULTY DROPDOWN, in the
        -- band above it. Parenting to the dropdown makes the strip show
        -- ONLY on an instance's encounter page (never Home/search/other
        -- tabs) with zero visibility code of our own. When Raider.IO's
        -- shortcut occupies the same band, sit to its left.
        s:SetParent(dd)
        s:SetFrameLevel(dd:GetFrameLevel() + 2)
        -- stay inside the ~23px band above the dropdown (the info panel
        -- clips its children: a taller banner gets its top shaved off)
        s:SetHeight(22)
        s:SetWidth(560)
        local ri = _G["RaiderIO_TalentBuildsEncounterJournalShortcut"]
        if ri then
            s:SetPoint("BOTTOMRIGHT", ri, "BOTTOMLEFT", -8, 0)
        else
            s:SetPoint("BOTTOMRIGHT", dd, "TOPRIGHT", 0, 1)
        end
    else -- dropdown not created yet: under the nav bar until it exists
        s:SetParent(EncounterJournal)
        s:SetFrameLevel(EncounterJournal:GetFrameLevel() + 10)
        s:SetHeight(26)
        if EncounterJournal.navBar then
            s:SetPoint("TOPLEFT", EncounterJournal.navBar, "BOTTOMLEFT", 2, -2)
        else
            s:SetPoint("TOPLEFT", EncounterJournal, "TOPLEFT", 10, -74)
        end
        s:SetPoint("RIGHT", EncounterJournal, "RIGHT", -330, 0)
    end
end

local function BuildEJStrip()
    if ejStrip or not EncounterJournal or not AT then return end
    local s = CreateFrame("Frame", nil, EncounterJournal, "BackdropTemplate")
    s:SetFrameLevel(EncounterJournal:GetFrameLevel() + 10)
    AT.Skin(s, AT.COL.bg, AT.COL.line2)
    local tag = s:CreateFontString(nil, "OVERLAY")
    tag:SetFont(STANDARD_TEXT_FONT, 12, "")
    tag:SetPoint("LEFT", 10, 0)
    tag:SetText("|cff3fc9f2Arc|r|cffd5e2f2 Bonus Roll|r")
    s.icon = s:CreateTexture(nil, "ARTWORK")
    s.icon:SetSize(18, 18)
    s.icon:SetPoint("LEFT", tag, "RIGHT", 12, 0)
    s.count = s:CreateFontString(nil, "OVERLAY")
    s.count:SetFont(STANDARD_TEXT_FONT, 12, "")
    s.count:SetPoint("LEFT", s.icon, "RIGHT", 5, 0)
    s.count:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    s.plan = s:CreateFontString(nil, "OVERLAY")
    s.plan:SetFont(STANDARD_TEXT_FONT, 12, "")
    s.plan:SetPoint("LEFT", s.count, "RIGHT", 18, 0)
    s.plan:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    -- scans the shown loot list and CHECKS OFF what you already have.
    -- Shorter than the strip so its border never kisses the strip's edge
    -- (the clipping Arc saw when both were the same height).
    -- absolute vs percent EV, right on the guide (mirrors the /abr toggle)
    local pctBtn = AT.MakeSmallButton(s, "%", 24)
    pctBtn:SetHeight(16)
    pctBtn:SetPoint("RIGHT", -6, 0)
    local function SyncPctBtn()
        pctBtn.fs:SetText(char and char.settings.evPercent and "#" or "%")
    end
    pctBtn:SetScript("OnClick", function()
        char.settings.evPercent = not char.settings.evPercent
        SyncPctBtn()
        RefreshEJ()
        if RefreshWindow then RefreshWindow() end
    end)
    pctBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("EV display", 0.2, 0.8, 1)
        GameTooltip:AddLine("Switch the gains and roll EVs between raw DPS and percent of your simmed DPS.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    pctBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    s.syncPctBtn = SyncPctBtn

    local detect = AT.MakeSmallButton(s, "Scan gear", 78)
    detect:SetHeight(16)
    detect:SetPoint("RIGHT", pctBtn, "LEFT", -5, 0)
    detect:SetScript("OnClick", function() EstimateLootedScan() end)
    detect:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Scan gear", 0.2, 0.8, 1)
        GameTooltip:AddLine("Checks your equipped gear, bags, and transmog collection against the selected boss's loot on this difficulty, and checks off what you already have.", 1, 1, 1, true)
        GameTooltip:AddLine("An estimate - click any check it makes to undo it.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    detect:HookScript("OnLeave", function() GameTooltip:Hide() end)
    s.used = s:CreateFontString(nil, "OVERLAY")
    s.used:SetFont(STANDARD_TEXT_FONT, 12, "")
    s.used:SetPoint("RIGHT", detect, "LEFT", -14, 0)
    s.used:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    -- the planned list is the flex element: bound it on the right so a
    -- narrow placement TRUNCATES it instead of overlapping its neighbors
    s.plan:SetPoint("RIGHT", s.used, "LEFT", -14, 0)
    s.plan:SetJustifyH("LEFT")
    s.plan:SetWordWrap(false)
    -- hover = the full planned list, ONLY over the Planned text itself
    -- (a whole-strip hover zone annoyed more than it helped)
    local planHover = CreateFrame("Frame", nil, s)
    planHover:SetAllPoints(s.plan)
    planHover:EnableMouse(true)
    planHover:SetScript("OnEnter", function(self)
        if not char then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Planned this week", 0.2, 0.8, 1)
        local names = PlannedNames(CurrentWeek())
        GameTooltip:AddLine(names or "none", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    planHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ejStrip = s
    ApplyStripPosition()
    EncounterJournal:HookScript("OnShow", RefreshEJStrip)
    RefreshEJStrip()
end

RefreshEJ = function()
    for _, m in pairs(bossMarkers) do
        if m:GetParent() and m:GetParent():IsVisible() then BossMarkerUpdate(m) end
    end
    for _, m in pairs(itemMarkers) do
        if m:GetParent() and m:GetParent():IsVisible() then ItemMarkerUpdate(m) end
    end
    RefreshEJStrip()
end

-- The Scan gear button: scan the loot the journal is showing - scoped to
-- the SELECTED BOSS when one is selected (instance overview scans the
-- visible list) - against equipped gear, bags, and the transmog
-- collection, and write a normal check mark for every item found on the
-- player. Same mark as a manual click, so any of them can be un-clicked.
EstimateLootedScan = function()
    if not char then return end
    if not (EncounterJournal and EncounterJournal:IsShown()) then return end
    local diff = (EJ_GetDifficulty and EJ_GetDifficulty()) or 0
    local selectedBoss = EncounterJournal.encounterID
    WipeDetectCache()
    local n = (EJ_GetNumLoot and EJ_GetNumLoot()) or 0
    for i = 1, n do
        local info = C_EncounterJournal.GetLootInfoByIndex(i)
        if info and info.itemID and info.link and not info.displayAsPerPlayerLoot
            and info.slot and info.slot ~= ""
            and (not selectedBoss or info.encounterID == selectedBoss) then
            if not IsOwnedItem(info.itemID, diff)
                and DetectOwnedByLink(info.link, info.itemID) then
                char.itemMarks[info.itemID] = char.itemMarks[info.itemID] or {}
                char.itemMarks[info.itemID][diff] = time()
            end
        end
    end
    WipeLootPool()
    RefreshEJ()
    if RefreshWindow then RefreshWindow() end
end

-- SETTLE PASS: journal loot data streams in asynchronously, so a repaint
-- fired inside the change event can run against half-settled state (the
-- "% vanishes on the first boss switch" bug). One debounced repaint after
-- things land makes the final state authoritative.
local ejSettlePending = false
local function EJSettle()
    ejSettlePending = false
    if not (EncounterJournal and EncounterJournal:IsShown()) then return end
    WipeLootPool()
    RefreshEJ()
end
local function ScheduleEJSettle()
    if ejSettlePending then return end
    ejSettlePending = true
    C_Timer.After(0.25, EJSettle)
end

local ejHooked = false
local function InstallEJHooks()
    if ejHooked then return end
    if not (EncounterJournalItemMixin and EncounterBossButtonMixin) then return end
    ejHooked = true
    hooksecurefunc(EncounterBossButtonMixin, "Init", function(self) DecorateBoss(self) end)
    hooksecurefunc(EncounterJournalItemMixin, "Init", function(self) DecorateItem(self) end)
    if EncounterJournal_LootUpdate then
        hooksecurefunc("EncounterJournal_LootUpdate", function()
            WipeLootPool()
            ScheduleEJSettle()
        end)
    end
    -- difficulty dropdown / boss select run a full journal refresh; repaint
    -- AFTER it so per-difficulty badges and pools track the dropdown
    if EncounterJournal_Refresh then
        hooksecurefunc("EncounterJournal_Refresh", function()
            WipeLootPool()
            RefreshEJ()
            ScheduleEJSettle()
        end)
    end
    BuildEJStrip()
end

-- ── Item tooltips (anywhere): flag items won from a roll ────────────────────
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip ~= GameTooltip then return end
        if not char or not char.settings.tooltips then return end
        local rec = data and data.id and wonItems[data.id]
        if rec then
            tooltip:AddLine(COLOR .. "Arc Bonus Roll:|r won from a bonus roll " .. date("%Y-%m-%d", rec.t or 0), 0.4, 0.8, 1)
        end
    end)
end

-- ── Sim import window ───────────────────────────────────────────────────────
local simWin

-- a pasted CSV carries NO spec identity: it stores for the spec you are
-- ON, so the window must say so in your face
local function SpecNoteText()
    return ("Importing for |cff3fc9f2%s|r - sims are per spec, so paste a Droptimizer run FOR this spec."):format(CurrentSpecName())
end

local function ShowSimImport()
    if simWin then
        simWin.status:SetText("")
        simWin.specNote:SetText(SpecNoteText())
        simWin:Show()
        return
    end
    simWin = AT.CreateWindow("ArcBonusRollSimImport", {
        title = "|cff3fc9f2Arc|r|cffd5e2f2 Sim Import|r",
        w = 540, h = 440, minW = 480, minH = 380, resizable = false,
    })
    simWin.specNote = simWin:CreateFontString(nil, "OVERLAY")
    simWin.specNote:SetFont(STANDARD_TEXT_FONT, 11, "")
    simWin.specNote:SetPoint("TOPLEFT", 14, -28)
    simWin.specNote:SetTextColor(1, 0.85, 0.1)
    simWin.specNote:SetText(SpecNoteText())
    local step1 = simWin:CreateFontString(nil, "OVERLAY")
    step1:SetFont(STANDARD_TEXT_FONT, 11, "")
    step1:SetPoint("TOPLEFT", 14, -46)
    step1:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    step1:SetText("|cff3fc9f21.|r Run a Raidbots Droptimizer, then paste the report link here:")
    local linkBox = CreateFrame("EditBox", nil, simWin, "BackdropTemplate")
    linkBox:SetSize(500, 20)
    linkBox:SetPoint("TOPLEFT", 14, -62)
    AT.Skin(linkBox, AT.COL.well)
    linkBox:SetFont(STANDARD_TEXT_FONT, 11, "")
    linkBox:SetTextInsets(6, 6, 0, 0)
    linkBox:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    linkBox:SetAutoFocus(false)
    linkBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local step2 = simWin:CreateFontString(nil, "OVERLAY")
    step2:SetFont(STANDARD_TEXT_FONT, 11, "")
    step2:SetPoint("TOPLEFT", 14, -90)
    step2:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    step2:SetText("|cff3fc9f22.|r Open THIS address in your browser (click it, Ctrl+C, paste in Chrome):")
    local csvBox = CreateFrame("EditBox", nil, simWin, "BackdropTemplate")
    csvBox:SetSize(500, 20)
    csvBox:SetPoint("TOPLEFT", 14, -106)
    AT.Skin(csvBox, AT.COL.well)
    csvBox:SetFont(STANDARD_TEXT_FONT, 11, "")
    csvBox:SetTextInsets(6, 6, 0, 0)
    csvBox:SetTextColor(AT.COL.arc[1], AT.COL.arc[2], AT.COL.arc[3])
    csvBox:SetAutoFocus(false)
    csvBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- read-only in spirit: any edit re-derives from the link box, and
    -- clicking selects the whole address for Ctrl+C
    csvBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    local function SyncCsvBox()
        local id = (linkBox:GetText() or ""):match("simbot/report/(%w+)")
            or (linkBox:GetText() or ""):match("/reports/(%w+)")
        if id then
            csvBox:SetText("https://www.raidbots.com/reports/" .. id .. "/data.csv")
        else
            csvBox:SetText("")
        end
    end
    linkBox:SetScript("OnTextChanged", SyncCsvBox)
    csvBox:SetScript("OnTextChanged", function(self, userInput) if userInput then SyncCsvBox() end end)
    local step3 = simWin:CreateFontString(nil, "OVERLAY")
    step3:SetFont(STANDARD_TEXT_FONT, 11, "")
    step3:SetPoint("TOPLEFT", 14, -134)
    step3:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    step3:SetText("|cff3fc9f23.|r On that page: select all (Ctrl+A), copy (Ctrl+C), paste it below, Import:")
    local boxFrame = CreateFrame("Frame", nil, simWin, "BackdropTemplate")
    boxFrame:SetPoint("TOPLEFT", 14, -150)
    boxFrame:SetPoint("BOTTOMRIGHT", -14, 76)
    AT.Skin(boxFrame, AT.COL.well)
    local eb = CreateFrame("EditBox")
    eb:SetMultiLine(true)
    eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(470)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local scroll = AT.MakeScroll(boxFrame, eb)
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -10, 4)
    eb:SetScript("OnTextChanged", function() scroll:UpdateScroll() end)
    simWin.eb = eb
    boxFrame:EnableMouse(true)
    boxFrame:SetScript("OnMouseUp", function() eb:SetFocus() end)
    local importBtn = AT.MakeSmallButton(simWin, "Import", 100)
    importBtn:SetPoint("BOTTOMLEFT", 14, 42)
    -- zero-paste path when the WoWUtils companion addon is installed
    local wuBtn = AT.MakeSmallButton(simWin, "From WoWUtils", 110)
    wuBtn:SetPoint("LEFT", importBtn, "RIGHT", 8, 0)
    simWin.status = simWin:CreateFontString(nil, "OVERLAY")
    simWin.status:SetFont(STANDARD_TEXT_FONT, 11, "")
    simWin.status:SetPoint("LEFT", wuBtn, "RIGHT", 12, 0)
    simWin.status:SetPoint("RIGHT", simWin, "RIGHT", -14, 0)
    simWin.status:SetJustifyH("LEFT")
    wuBtn:SetScript("OnClick", function()
        local diffs, itemsOrErr = ImportFromWowUtils()
        if diffs then
            simWin.status:SetText(("|cff4cde4cImported %d item gains (%d difficulty set%s) for %s from WoWUtils.|r"):format(
                itemsOrErr, diffs, diffs == 1 and "" or "s", CurrentSpecName()))
            WipeLootPool()
            RefreshEJ()
            if RefreshWindow then RefreshWindow() end
        else
            simWin.status:SetText("|cffff6060" .. tostring(itemsOrErr) .. "|r")
        end
    end)
    AT.Tooltip(wuBtn, "From WoWUtils",
        "Reads the droptimizer data the WoWUtils addon already holds for this character and spec - no pasting needed. Newest sim per difficulty wins.")
    importBtn:SetScript("OnClick", function()
        local diffs, items = ApplySimImport(simWin.eb:GetText())
        if diffs then
            simWin.status:SetText(("|cff4cde4cImported %d item gains (%d difficulty set%s) for %s. The journal now shows EVs.|r"):format(
                items, diffs, diffs == 1 and "" or "s", CurrentSpecName()))
            simWin.eb:SetText("")
            WipeLootPool()
            RefreshEJ()
            if RefreshWindow then RefreshWindow() end
        else
            simWin.status:SetText("|cffff6060Could not read that. Paste the FULL text of the data.csv page.|r")
        end
    end)
    simWin:Show()
end

-- The season's current raid: the instance we last saw a roll prompt in,
-- or the newest raid of the latest journal tier.
local function GetCurrentRaidInstanceID()
    local inst = char and char.lastInstanceID
    if not inst and EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex then
        EJ_SelectTier(EJ_GetNumTiers())
        local i = 1
        while true do
            local id = EJ_GetInstanceByIndex(i, true)
            if not id then break end
            inst = id
            i = i + 1
        end
    end
    return inst
end

local function OpenJournalToCurrentRaid()
    if not EncounterJournal then C_AddOns.LoadAddOn("Blizzard_EncounterJournal") end
    local inst = GetCurrentRaidInstanceID()
    if inst and EncounterJournal_OpenJournal then
        EncounterJournal_OpenJournal(nil, inst)
    elseif ToggleEncounterJournal then
        ToggleEncounterJournal()
    end
end

-- ── Background pool primer ──────────────────────────────────────────────────
-- Confirm every boss's coin pool WITHOUT the player ever opening the
-- guide: drive the journal's data engine directly (tier, instance, the
-- player's own class+spec loot filter, each raid difficulty in turn),
-- wait for the async loot data, and harvest it into poolCache. Runs only
-- while the journal window is closed so it never fights the real UI.
local primerActive = false
local primerRetryQueued = false
local PrimePoolCache   -- forward: the retry closure below re-enters it
local PRIME_DIFFS = { 15, 16, 14, 17 }   -- 17 = Raid Finder rolls too

local function HarvestJournalLoot(diff)
    local n = (EJ_GetNumLoot and EJ_GetNumLoot()) or 0
    local fresh, got = {}, 0
    for i = 1, n do
        local info = C_EncounterJournal.GetLootInfoByIndex(i)
        if info and info.name and info.encounterID and info.itemID
            and not info.displayAsPerPlayerLoot
            and info.slot and info.slot ~= "" then
            fresh[info.encounterID] = fresh[info.encounterID] or {}
            fresh[info.encounterID][info.itemID] = true
            got = got + 1
        end
    end
    if got > 0 then
        poolStore[diff] = poolStore[diff] or {}
        for enc, set in pairs(fresh) do
            poolStore[diff][enc] = set
        end
    end
    return got
end

-- Complete = a full headless pass ran, OR every boss of the raid already has
-- a cached pool. A pool recorded from real journal views covers only the
-- bosses the player clicked, so "poolCache non-empty" is NOT completeness -
-- that early-out left every unvisited boss unconfirmed forever.
local function PoolNeedsPrime(d, inst)
    if poolPrimed[d] == inst then return false end
    if not EJ_GetEncounterInfoByIndex then return false end
    local i = 1
    while true do
        local name, _, bossID = EJ_GetEncounterInfoByIndex(i, inst)
        if not name or not bossID then break end
        if not (poolStore[d] and poolStore[d][bossID]) then return true end
        i = i + 1
    end
    return i == 1   -- no boss list yet either: the primer's select loads it
end

-- the primer must not steer the journal's data engine while the real UI is
-- using it - but "come back later" instead of giving up, so a first-install
-- session still ends fully confirmed
local function QueuePrimerRetry()
    if primerRetryQueued then return end
    primerRetryQueued = true
    C_Timer.After(15, function()
        primerRetryQueued = false
        PrimePoolCache()
    end)
end

PrimePoolCache = function()
    if primerActive or not char then return end
    if not storesLinked then RelinkSpecStores() end
    if EncounterJournal and EncounterJournal:IsShown() then QueuePrimerRetry() return end
    local inst = GetCurrentRaidInstanceID()
    if not inst then return end
    local missing = {}
    for _, d in ipairs(PRIME_DIFFS) do
        if PoolNeedsPrime(d, inst) then
            missing[#missing + 1] = d
        end
    end
    if #missing == 0 then return end
    primerActive = true
    if EJ_SetLootFilter then
        local classID = select(3, UnitClass("player"))
        local specIndex = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization
            and C_SpecializationInfo.GetSpecialization() or nil
        local specID = specIndex and C_SpecializationInfo.GetSpecializationInfo(specIndex) or 0
        EJ_SetLootFilter(classID or 0, specID or 0)
    end
    if EJ_SelectTier and EJ_GetNumTiers then EJ_SelectTier(EJ_GetNumTiers()) end
    if EJ_SelectInstance then EJ_SelectInstance(inst) end
    local idx, tries = 0, 0
    local function step()
        if EncounterJournal and EncounterJournal:IsShown() then
            primerActive = false   -- the real UI took over; back off
            QueuePrimerRetry()     -- and finish once it is closed again
            return
        end
        if tries > 0 then
            local got = HarvestJournalLoot(missing[idx])
            if got == 0 and tries < 5 then
                tries = tries + 1
                C_Timer.After(0.7, step)   -- loot data is async; wait more
                return
            end
            if got > 0 then
                -- a headless pass lists the WHOLE instance at once: this
                -- difficulty is complete for THIS raid, not just the bosses
                -- someone happened to click in the journal
                poolPrimed[missing[idx]] = inst
            end
            tries = 0
        end
        idx = idx + 1
        local d = missing[idx]
        if not d then
            primerActive = false
            WipeLootPool()
            RefreshEJ()
            if RefreshWindow then RefreshWindow() end
            return
        end
        EJ_SetDifficulty(d)
        tries = 1
        C_Timer.After(0.7, step)
    end
    step()
end

-- ── Options window (Arc theme, tabbed) ──────────────────────────────────────
-- Overview = a standalone replacement for the Adventure Guide view: the
-- whole raid's bosses with plan/done/rolled state and roll EVs, workable
-- without ever opening the journal. Protection / Journal / Sims hold the
-- settings; History is the ledger, bounded inside the window (the old
-- single-page layout let it spill past the frame).
local win

local OVERVIEW_DIFFS = {
    { value = 17, text = "Raid Finder" },
    { value = 14, text = "Normal" },
    { value = 15, text = "Heroic" },
    { value = 16, text = "Mythic" },
}

local function StatusRow(pg, textFn, h)
    local row = AT.AddRow(pg, h or 20)
    local fs = row:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, 11, "")
    fs:SetPoint("LEFT", 10, 0)
    fs:SetPoint("RIGHT", -10, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    fs:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    row._sync = function() fs:SetText(textFn()) end
    return row
end

-- two actions share one row: reads cleaner than stacked full-width rows
local function RowButtonPair(pg, l1, f1, l2, f2)
    local row = AT.AddRow(pg, 26)
    local b1 = AT.MakeSmallButton(row, l1, 172)
    b1:SetPoint("LEFT", 12, 0)
    b1:SetScript("OnClick", function() AT.CloseDropdown(); f1() end)
    local b2 = AT.MakeSmallButton(row, l2, 172)
    b2:SetPoint("LEFT", b1, "RIGHT", 10, 0)
    b2:SetScript("OnClick", function() AT.CloseDropdown(); f2() end)
    return row
end

-- compact right-aligned numeric field (the theme's full-width input reads
-- wrong for a two-digit number)
local function SmallNumberRow(pg, label, get, set, visibleFn, desc)
    local row = AT.AddRow(pg, 26, visibleFn)
    local lbl = AT.RowLabel(row, label)
    local box = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    box:SetSize(64, 20)
    -- control column, same as every dropdown/swatch: the old RIGHT pin
    -- floated the box a full row-width away from its label
    box:SetPoint("LEFT", row._ctrlX, 0)
    row._colLabel, row._colCtrl = lbl, box
    AT.Skin(box, AT.COL.well)
    box:SetFont(STANDARD_TEXT_FONT, 11, "")
    box:SetTextInsets(6, 6, 0, 0)
    box:SetJustifyH("CENTER")
    box:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetText(get())
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:SetText(get()); self:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(AT.COL.arcDeep[1], AT.COL.arcDeep[2], AT.COL.arcDeep[3], 1)
    end)
    box:SetScript("OnEditFocusLost", function(self)
        set(self:GetText())
        self:SetText(get())
        self:SetBackdropBorderColor(AT.COL.line[1], AT.COL.line[2], AT.COL.line[3], 1)
    end)
    if desc then AT.Tooltip(row, label, desc) end
    row._sync = function() if not box:HasFocus() then box:SetText(get()) end end
    return row
end

-- ── Overview tab (the journal replacement) ──────────────────────────────────
-- A boss list with portraits, exactly like the guide: click a boss row to
-- expand its gear (names, icons, sim gains, drop shares, owned checks);
-- the coin is its own button (left = plan, right = check off).
local itemNameRequested = {}

local function OverviewItemName(pg, itemID)
    local nm = C_Item.GetItemInfo(itemID)
    if nm then return nm end
    if not itemNameRequested[itemID] then
        itemNameRequested[itemID] = true
        local it = Item:CreateFromItemID(itemID)
        it:ContinueOnItemLoad(function()
            if pg:IsShown() and pg.Refresh then pg:Refresh() end
        end)
    end
    return "loading..."
end

local function OverviewCoinClick(self, mouseButton)
    local s = self.row and self.row.state
    if not (char and s) then return end
    local key = BossKey(s.enc, s.diff)
    if mouseButton == "RightButton" then
        if s.done then
            char.doneBosses[key] = AutoWouldCheck(s.enc, s.diff) and false or nil
        else
            char.doneBosses[key] = true
        end
    else
        if s.done then return end
        local p = char.plan[s.week]
        if p and p[key] then
            p[key] = nil
            if not next(p) then char.plan[s.week] = nil end
        else
            char.plan[s.week] = p or {}
            char.plan[s.week][key] = true
        end
    end
    UpdateCovers()
    RefreshEJ()
    if RefreshWindow then RefreshWindow() end
end

local function OverviewCoinTooltip(self)
    local s = self.row and self.row.state
    if not s then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(s.name or "boss", 0.2, 0.8, 1)
    local diff = DifficultyName(s.diff)
    if s.done then
        GameTooltip:AddLine(s.autoWould
            and ("All roll loot collected (%s)."):format(diff)
            or ("Checked off (%s)."):format(diff), 0.3, 1, 0.3, true)
        GameTooltip:AddLine("Right-click: un-check.", 0.7, 0.7, 0.7)
    elseif s.planned then
        GameTooltip:AddLine(("Planned this week (%s)."):format(diff), 1, 0.85, 0.1)
        GameTooltip:AddLine("Click: unplan.  Right-click: check off.", 0.7, 0.7, 0.7)
    else
        GameTooltip:AddLine(("Click: plan this boss (%s)."):format(diff), 1, 1, 1)
        GameTooltip:AddLine("Right-click: check off (done rolling it).", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

local function OverviewRowClick(self)
    local pg = self.pg
    local s = self.state
    if not (pg and s) then return end
    pg.selectedEnc = (pg.selectedEnc ~= s.enc) and s.enc or nil
    if pg.Refresh then pg:Refresh() end
end

local function OverviewItemClick(self)
    local s = self.state
    if not (char and s) then return end
    if s.owned and s.source ~= "manual" then return end   -- ledger wins stay
    local marks = char.itemMarks[s.itemID]
    if marks and (marks[s.diff] or marks[0]) then
        marks[s.diff], marks[0] = nil, nil
        if not next(marks) then char.itemMarks[s.itemID] = nil end
    else
        char.itemMarks[s.itemID] = marks or {}
        char.itemMarks[s.itemID][s.diff] = time()
    end
    WipeLootPool()
    RefreshEJ()
    if RefreshWindow then RefreshWindow() end
end

local function OverviewItemTooltip(self)
    local s = self.state
    if not s then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(s.itemID)
    if s.owned then
        GameTooltip:AddLine(s.source == "manual"
            and "Checked off. Click to un-check." or "Won from a recorded roll.", 0.3, 1, 0.3, true)
    else
        GameTooltip:AddLine("Click: check off as already received on this difficulty.", 0.7, 0.7, 0.7, true)
    end
    GameTooltip:Show()
end

local function CreateOverviewRow(pg, idx)
    local row = CreateFrame("Button", nil, pg.listContent, "BackdropTemplate")
    row.pg = pg
    row:SetHeight(28)
    AT.Skin(row, AT.COL.box, AT.COL.line)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", OverviewRowClick)
    row.portrait = row:CreateTexture(nil, "ARTWORK")
    row.portrait:SetSize(22, 22)
    row.portrait:SetPoint("LEFT", 4, 0)
    row.portrait:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    row.name = row:CreateFontString(nil, "OVERLAY")
    row.name:SetFont(STANDARD_TEXT_FONT, 12, "")
    row.name:SetPoint("LEFT", 32, 0)
    row.name:SetPoint("RIGHT", row, "RIGHT", -160, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.coin = CreateFrame("Button", nil, row)
    row.coin:SetSize(20, 20)
    row.coin:SetPoint("RIGHT", -6, 0)
    row.coin:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.coin.row = row
    row.coin:SetScript("OnClick", OverviewCoinClick)
    row.coin:SetScript("OnEnter", OverviewCoinTooltip)
    row.coin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.coin.icon = row.coin:CreateTexture(nil, "ARTWORK")
    row.coin.icon:SetAllPoints()
    -- same tight yellow selected-glow as the journal's planned coin
    row.coin.planRing = row.coin:CreateTexture(nil, "OVERLAY", nil, 1)
    row.coin.planRing:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    row.coin.planRing:SetBlendMode("ADD")
    row.coin.planRing:SetSize(22, 22)
    row.coin.planRing:SetPoint("CENTER")
    row.coin.planRing:Hide()
    row.coin.doneCheck = row.coin:CreateTexture(nil, "OVERLAY")
    row.coin.doneCheck:SetAtlas(TEX_CHECK)
    row.coin.doneCheck:SetSize(22, 22)
    row.coin.doneCheck:SetPoint("CENTER", 1, -1)
    row.ev = row:CreateFontString(nil, "OVERLAY")
    row.ev:SetFont(STANDARD_TEXT_FONT, 12, "")
    row.ev:SetPoint("RIGHT", -34, 0)
    row.ev:SetTextColor(0.3, 0.87, 0.3, 1)
    -- the EV number is itself a toggle: clicking it flips percent/raw
    -- (shown only while a value is displayed, so it never eats row clicks)
    row.evBtn = CreateFrame("Button", nil, row)
    row.evBtn:SetPoint("TOPLEFT", row.ev, "TOPLEFT", -2, 2)
    row.evBtn:SetPoint("BOTTOMRIGHT", row.ev, "BOTTOMRIGHT", 2, -2)
    row.evBtn:RegisterForClicks("LeftButtonUp")
    row.evBtn:SetScript("OnClick", function(self)
        if not char then return end
        char.settings.evPercent = not char.settings.evPercent
        RefreshEJ()
        RefreshEJStrip()
        local r = self:GetParent()
        if r.pg and r.pg.Refresh then r.pg:Refresh() end
    end)
    row.evBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Roll EV", 0.2, 0.8, 1)
        GameTooltip:AddLine("Expected DPS gain per coin on this boss. Click: switch between percent and raw DPS.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row.evBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- unpriced boss: a muted info mark holds the EV's seat so people see a
    -- value BELONGS here - hover explains, click opens the importer
    row.simHint = CreateFrame("Button", nil, row)
    row.simHint:SetSize(16, 16)
    row.simHint:SetPoint("RIGHT", -34, 0)
    row.simHint:RegisterForClicks("LeftButtonUp")
    local hintTex = row.simHint:CreateTexture(nil, "ARTWORK")
    hintTex:SetAllPoints()
    hintTex:SetTexture("Interface\\Common\\help-i")
    hintTex:SetVertexColor(0.5, 0.62, 0.78, 0.8)
    row.simHint:SetScript("OnClick", function() ShowSimImport() end)
    row.simHint:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("No sim value yet", 0.2, 0.8, 1)
        GameTooltip:AddLine("Import a Droptimizer sim and this boss shows its real roll value in DPS. Click to open the importer.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row.simHint:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.best = row:CreateFontString(nil, "OVERLAY")
    row.best:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    row.best:SetPoint("RIGHT", row.ev, "LEFT", -8, 0)
    row.best:SetText("|cffffd100BEST|r")
    row.rolled = row:CreateTexture(nil, "OVERLAY")
    row.rolled:SetAtlas(TEX_CHECK)
    row.rolled:SetSize(14, 14)
    row.rolled:SetPoint("RIGHT", row.best, "LEFT", -6, 0)
    pg.rows[idx] = row
    return row
end

local function CreateOverviewItemRow(pg, idx)
    local it = CreateFrame("Button", nil, pg.listContent, "BackdropTemplate")
    it.pg = pg
    it:SetHeight(24)
    AT.Skin(it, AT.COL.well, AT.COL.line)
    it:RegisterForClicks("LeftButtonUp")
    it:SetScript("OnClick", OverviewItemClick)
    it:SetScript("OnEnter", OverviewItemTooltip)
    it:SetScript("OnLeave", function() GameTooltip:Hide() end)
    it.icon = it:CreateTexture(nil, "ARTWORK")
    it.icon:SetSize(18, 18)
    it.icon:SetPoint("LEFT", 4, 0)
    it.check = it:CreateTexture(nil, "OVERLAY")
    it.check:SetAtlas(TEX_CHECK)
    it.check:SetSize(18, 18)
    it.check:SetPoint("CENTER", it.icon, "CENTER", 1, -1)
    it.name = it:CreateFontString(nil, "OVERLAY")
    it.name:SetFont(STANDARD_TEXT_FONT, 11, "")
    it.name:SetPoint("LEFT", 28, 0)
    it.name:SetPoint("RIGHT", it, "RIGHT", -130, 0)
    it.name:SetJustifyH("LEFT")
    it.name:SetWordWrap(false)
    it.share = it:CreateFontString(nil, "OVERLAY")
    it.share:SetFont(STANDARD_TEXT_FONT, 11, "")
    it.share:SetPoint("RIGHT", -74, 0)
    it.share:SetTextColor(0.25, 0.79, 0.95, 1)
    it.gain = it:CreateFontString(nil, "OVERLAY")
    it.gain:SetFont(STANDARD_TEXT_FONT, 11, "")
    it.gain:SetPoint("RIGHT", -8, 0)
    pg.itemRows[idx] = it
    return it
end

local function OverviewRefresh(pg)
    if not char then return end
    PrimePoolCache()   -- self-heals a missing pool in the background
    local diff = char.settings.ovDiff or 15
    local week = CurrentWeek()
    local count = BonusRollsAvailable()
    pg.rolls:SetText(count and ("Bonus rolls: |cffffd100%d|r"):format(count) or "Bonus rolls: ?")
    if pg.pctCb then pg.pctCb:SetOn(char.settings.evPercent) end
    -- no sim for this difficulty: pull the list down a notch and show the
    -- import banner in the gap (clicking it opens the importer)
    local haveSim = simStore[diff] ~= nil
    if pg.simNotice then
        pg.simNotice:SetShown(not haveSim)
        if not haveSim then
            pg.simNotice.fs:SetText(("|T%d:14|t |cff3fc9f2Sim your character|r to price this page - no %s sim for %s yet. Click to import one."):format(
                CoinIconTexture(), DifficultyName(diff), CurrentSpecName()))
        end
        pg.listScroll:SetPoint("TOPLEFT", 0, haveSim and -34 or -62)
    end
    pg.listContent:SetWidth(math.max(200, pg.listScroll:GetWidth() or 0))
    local inst = GetCurrentRaidInstanceID()
    local shown, itemsShown = 0, 0
    local bestIdx, bestEV
    local y = 0
    if inst and EJ_GetEncounterInfoByIndex then
        local i = 1
        while true do
            local bossName, _, bossID = EJ_GetEncounterInfoByIndex(i, inst)
            if not bossName or not bossID then break end
            shown = shown + 1
            local row = pg.rows[shown] or CreateOverviewRow(pg, shown)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, y)
            row:SetPoint("TOPRIGHT", 0, y)
            y = y - 30
            local key = BossKey(bossID, diff)
            local flag = char.doneBosses[key]
            local doneManual = flag == true
            local evValue = BossSimEV(bossID, diff)
            -- the confirmed pool works with no sim at all: it counts what
            -- this boss's coin can still give (once-per-difficulty rule)
            local pool = poolStore[diff] and poolStore[diff][bossID]
            local poolTotal, poolLeft = 0, 0
            if pool then
                for itemID in pairs(pool) do
                    poolTotal = poolTotal + 1
                    if not IsOwnedItem(itemID, diff) then poolLeft = poolLeft + 1 end
                end
            end
            local doneAuto = false
            if flag == nil and not evValue and simStore[diff] then
                local gains = simStore[diff].gains[bossID]
                if gains and next(gains) then
                    local anyLeft = false
                    for itemID in pairs(gains) do
                        if not IsOwnedItem(itemID, diff) then anyLeft = true break end
                    end
                    doneAuto = not anyLeft
                end
            end
            if flag == nil and poolTotal > 0 and poolLeft == 0 then
                doneAuto = true   -- pool exhausted = the coin has nothing left
            end
            local done = doneManual or doneAuto
            local planned = IsPlanned(week, bossID, diff)
            local selected = pg.selectedEnc == bossID
            row.state = { enc = bossID, diff = diff, week = week, name = bossName,
                          planned = planned, done = done, autoWould = doneAuto }
            local img = select(5, EJ_GetCreatureInfo(1, bossID))
            row.portrait:SetTexture(img or "Interface\\EncounterJournal\\UI-EJ-BOSS-Default")
            AT.Skin(row, selected and AT.COL.panel or AT.COL.box, selected and AT.COL.arcDeep or AT.COL.line)
            row.coin.icon:SetTexture(CoinIconTexture())
            row.coin.icon:SetDesaturated(not (planned or done))
            row.coin.planRing:SetShown(planned and not done)
            row.coin.doneCheck:SetShown(done)
            row.name:SetText(bossName)
            if planned then
                row.name:SetTextColor(1, 0.85, 0.1, 1)
            else
                row.name:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3], 1)
            end
            row.rolled:SetShown(GetRollRecord(week, bossID, diff) ~= nil)
            if evValue then
                row.ev:SetText(FormatGainNumber(evValue, diff))
                row.evBtn:Show()
                row.simHint:Hide()
            else
                -- unpriced: the muted info mark holds the EV seat (hover
                -- explains, click imports) - except on collected bosses,
                -- where there is nothing left to price
                row.ev:SetText("")
                row.evBtn:Hide()
                row.simHint:SetShown(not done)
            end
            row.best:Hide()
            if evValue and not done and (not bestEV or evValue > bestEV) then
                bestEV, bestIdx = evValue, shown
            end
            row:Show()
            -- expanded: this boss's gear - the cached JOURNAL pool when we
            -- have one (the coin's real table), priced by the sim; the sim
            -- list alone otherwise. Best gain first.
            if selected then
                local ev = simStore[diff]
                local gains = ev and ev.gains[bossID]
                local cache = poolStore[diff] and poolStore[diff][bossID]
                local list, remaining = {}, 0
                if cache and next(cache) then
                    for itemID in pairs(cache) do
                        list[#list + 1] = { itemID = itemID, gain = gains and gains[itemID] or nil }
                        if not IsOwnedItem(itemID, diff) then remaining = remaining + 1 end
                    end
                elseif gains and next(gains) then
                    for itemID, g in pairs(gains) do
                        list[#list + 1] = { itemID = itemID, gain = g }
                        if not IsOwnedItem(itemID, diff) then remaining = remaining + 1 end
                    end
                end
                if #list > 0 then
                    table.sort(list, function(a, b)
                        return (a.gain or -math.huge) > (b.gain or -math.huge)
                    end)
                    for _, entry in ipairs(list) do
                        itemsShown = itemsShown + 1
                        local it = pg.itemRows[itemsShown] or CreateOverviewItemRow(pg, itemsShown)
                        it:ClearAllPoints()
                        it:SetPoint("TOPLEFT", 24, y)
                        it:SetPoint("TOPRIGHT", 0, y)
                        y = y - 26
                        local owned, source = IsOwnedItem(entry.itemID, diff)
                        it.state = { itemID = entry.itemID, diff = diff, owned = owned, source = source }
                        it.icon:SetTexture(C_Item.GetItemIconByID(entry.itemID) or 134400)
                        it.check:SetShown(owned)
                        it.name:SetText(OverviewItemName(pg, entry.itemID))
                        if owned then
                            it.share:SetText("")
                            it.gain:SetText("")
                        else
                            it.share:SetText(remaining > 0 and ("~%.0f%%"):format(100 / remaining) or "")
                            if entry.gain then
                                it.gain:SetText(FormatGainNumber(entry.gain, diff))
                                if entry.gain >= 0.5 then
                                    it.gain:SetTextColor(0.3, 0.87, 0.3, 1)
                                else
                                    it.gain:SetTextColor(0.55, 0.63, 0.76, 1)
                                end
                            else
                                it.gain:SetText("-")
                                it.gain:SetTextColor(0.55, 0.63, 0.76, 1)
                            end
                        end
                        it:Show()
                    end
                else
                    itemsShown = itemsShown + 1
                    local it = pg.itemRows[itemsShown] or CreateOverviewItemRow(pg, itemsShown)
                    it:ClearAllPoints()
                    it:SetPoint("TOPLEFT", 24, y)
                    it:SetPoint("TOPRIGHT", 0, y)
                    y = y - 26
                    it.state = nil
                    it.icon:SetTexture(134400)
                    it.check:Hide()
                    it.name:SetText("|cff8ca0b8No data for this boss yet - import a sim, or open the Adventure Guide once.|r")
                    it.share:SetText("")
                    it.gain:SetText("")
                    it:Show()
                end
                if not (cache and next(cache)) and #list > 0 then
                    -- sim-only list: the primer is already confirming the
                    -- real pool in the background (kicked at the top of this
                    -- refresh), so this is a moments-long status, not a chore
                    itemsShown = itemsShown + 1
                    local it = pg.itemRows[itemsShown] or CreateOverviewItemRow(pg, itemsShown)
                    it:ClearAllPoints()
                    it:SetPoint("TOPLEFT", 24, y)
                    it:SetPoint("TOPRIGHT", 0, y)
                    y = y - 26
                    it.state = nil
                    it.icon:SetTexture(CoinIconTexture())
                    it.check:Hide()
                    it.name:SetText("|cff8ca0b8Confirming this pool from the game's journal data - a few seconds...|r")
                    it.share:SetText("")
                    it.gain:SetText("")
                    it:Show()
                end
            end
            i = i + 1
        end
    end
    if bestIdx and pg.rows[bestIdx] then pg.rows[bestIdx].best:Show() end
    for k = shown + 1, #pg.rows do pg.rows[k]:Hide() end
    for k = itemsShown + 1, #pg.itemRows do pg.itemRows[k]:Hide() end
    pg.listContent:SetHeight(math.max(1, -y + 4))
    pg.listScroll:UpdateScroll()
    if shown == 0 and inst then
        -- right after login the journal's data engine has not streamed the
        -- boss list yet: kick it awake (never while the real journal is
        -- open) and repaint shortly - the page was staying blank until a
        -- tab change forced a refresh
        if not (EncounterJournal and EncounterJournal:IsShown())
            and EJ_SelectTier and EJ_GetNumTiers and EJ_SelectInstance then
            EJ_SelectTier(EJ_GetNumTiers())
            EJ_SelectInstance(inst)
        end
        pg._loadRetries = (pg._loadRetries or 0) + 1
        if pg._loadRetries <= 6 then
            C_Timer.After(0.8, function()
                if pg:IsShown() then OverviewRefresh(pg) end
            end)
        end
        pg.hint:SetText("Loading the raid list...")
    else
        pg._loadRetries = nil
        pg.hint:SetText(shown > 0
            and "Click a boss to see its gear. Coin: click plans it, right-click checks it off. Per difficulty."
            or "No raid found yet - open the Adventure Guide once, or import a sim.")
    end
end

local function BuildOverviewPage(parent)
    local pg = CreateFrame("Frame", nil, parent)
    pg:Hide()
    pg.rows = {}
    pg.itemRows = {}
    -- the boss/gear list lives in an Arc scroll region (slim cyan thumb)
    -- so it can NEVER run over the hint or out of the window
    local scroll, content = AT.MakeScroll(pg)
    scroll:SetPoint("TOPLEFT", 0, -34)
    scroll:SetPoint("BOTTOMRIGHT", -6, 18)
    pg.listScroll = scroll
    pg.listContent = content
    local dd = AT.MakeDropdown(win, pg, 130,
        function() return OVERVIEW_DIFFS end,
        function() return char.settings.ovDiff or 15 end,
        function(v) char.settings.ovDiff = v; OverviewRefresh(pg) end)
    dd:SetPoint("TOPLEFT", 0, -4)
    -- "Show EV as percent": a real labeled toggle (the bare %/# chip read
    -- as noise) driving the ONE shared setting with the strip and Sims tab
    local pctCb = AT.MakeCheckbox(pg)
    pctCb:SetPoint("LEFT", dd, "RIGHT", 12, 0)
    local pctLbl = pg:CreateFontString(nil, "OVERLAY")
    pctLbl:SetFont(STANDARD_TEXT_FONT, 11, "")
    pctLbl:SetPoint("LEFT", pctCb, "RIGHT", 6, 0)
    pctLbl:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    pctLbl:SetText("Show EV as percent")
    local function FlipPct()
        AT.CloseDropdown()
        char.settings.evPercent = not char.settings.evPercent
        PlaySound(char.settings.evPercent and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                                           or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF, "Master")
        RefreshEJ()
        RefreshEJStrip()
        OverviewRefresh(pg)
    end
    pctCb:SetScript("OnClick", FlipPct)
    pctCb:HookScript("OnEnter", function() pctCb:SetHover(true) end)
    pctCb:HookScript("OnLeave", function() pctCb:SetHover(false) end)
    -- the label is part of the control: clicking it flips too
    local pctLblBtn = CreateFrame("Button", nil, pg)
    pctLblBtn:SetPoint("TOPLEFT", pctLbl, "TOPLEFT", -2, 2)
    pctLblBtn:SetPoint("BOTTOMRIGHT", pctLbl, "BOTTOMRIGHT", 2, -2)
    pctLblBtn:RegisterForClicks("LeftButtonUp")
    pctLblBtn:SetScript("OnClick", FlipPct)
    pctLblBtn:HookScript("OnEnter", function() pctCb:SetHover(true) end)
    pctLblBtn:HookScript("OnLeave", function() pctCb:SetHover(false) end)
    AT.Tooltip(pctLblBtn, "Show EV as percent",
        "Show gains and roll EVs as a percent of your simmed DPS instead of raw numbers. Clicking any green EV number flips this too.")
    pg.pctCb = pctCb
    -- sim call-to-action: whenever the selected difficulty has no sim, a
    -- banner above the list says why the EV column is empty and opens the
    -- importer on click. It vanishes the moment a sim lands.
    local notice = CreateFrame("Button", nil, pg, "BackdropTemplate")
    notice:SetHeight(24)
    notice:SetPoint("TOPLEFT", 0, -32)
    notice:SetPoint("TOPRIGHT", -6, -32)
    AT.Skin(notice, AT.COL.panel, AT.COL.arcDeep)
    notice.fs = notice:CreateFontString(nil, "OVERLAY")
    notice.fs:SetFont(STANDARD_TEXT_FONT, 11, "")
    notice.fs:SetPoint("LEFT", 8, 0)
    notice.fs:SetPoint("RIGHT", -8, 0)
    notice.fs:SetJustifyH("LEFT")
    notice.fs:SetWordWrap(false)
    notice:SetScript("OnClick", function() AT.CloseDropdown(); ShowSimImport() end)
    notice:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(AT.COL.arc[1], AT.COL.arc[2], AT.COL.arc[3], 1)
    end)
    notice:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(AT.COL.arcDeep[1], AT.COL.arcDeep[2], AT.COL.arcDeep[3], 1)
    end)
    AT.Tooltip(notice, "Import a sim",
        "Run a Raidbots Droptimizer (or use the WoWUtils addon) and import it here: every boss and item on this page gets a real DPS value, so the addon can point at the best coin.")
    pg.simNotice = notice
    local journalBtn = AT.MakeSmallButton(pg, "Adventure Guide", 120)
    journalBtn:SetPoint("TOPRIGHT", 0, -3)
    journalBtn:SetScript("OnClick", function() OpenJournalToCurrentRaid() end)
    pg.rolls = pg:CreateFontString(nil, "OVERLAY")
    pg.rolls:SetFont(STANDARD_TEXT_FONT, 12, "")
    pg.rolls:SetPoint("RIGHT", journalBtn, "LEFT", -12, 0)
    pg.rolls:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    pg.hint = pg:CreateFontString(nil, "OVERLAY")
    pg.hint:SetFont(STANDARD_TEXT_FONT, 10, "")
    pg.hint:SetPoint("BOTTOMLEFT", 4, 4)
    pg.hint:SetPoint("BOTTOMRIGHT", -4, 4)
    pg.hint:SetJustifyH("LEFT")
    pg.hint:SetTextColor(AT.COL.dim[1], AT.COL.dim[2], AT.COL.dim[3])
    function pg:Refresh()
        OverviewRefresh(self)
        C_Timer.After(0, function()
            if self:IsShown() then OverviewRefresh(self) end
        end)
    end
    return pg
end

-- ── History tab (bounded scroll, can never outgrow the window) ──────────────
local function BuildHistoryPage(parent)
    local pg = CreateFrame("Frame", nil, parent)
    pg:Hide()
    local boxFrame = CreateFrame("Frame", nil, pg, "BackdropTemplate")
    boxFrame:SetPoint("TOPLEFT", 0, -4)
    boxFrame:SetPoint("BOTTOMRIGHT", 0, 0)
    AT.Skin(boxFrame, AT.COL.box, AT.COL.line)
    local scroll, content = AT.MakeScroll(boxFrame)
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -10, 6)
    local hist = content:CreateFontString(nil, "OVERLAY")
    hist:SetFont(STANDARD_TEXT_FONT, 11, "")
    hist:SetPoint("TOPLEFT", 4, 0)
    hist:SetWidth(420)
    hist:SetJustifyH("LEFT")
    hist:SetSpacing(3)
    hist:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    function pg:Refresh()
        if not char then return end
        local lines = {}
        for i = 1, math.min(#char.rolls, 60) do
            local r = char.rolls[i]
            local what = r.link or r.result or "?"
            if r.qty and r.qty > 1 and r.link then what = what .. " x" .. r.qty end
            lines[#lines + 1] = ("|cff8ca0b8%s|r  %s (%s)\n    %s"):format(
                date("%m-%d %H:%M", r.t or 0), EncounterName(r.enc), DifficultyName(r.diff), what)
        end
        if #lines == 0 then
            lines[1] = "|cff8ca0b8No rolls recorded yet. They record automatically when you spend a coin.|r"
        end
        hist:SetText(table.concat(lines, "\n"))
        content:SetHeight(math.max(24, hist:GetStringHeight() + 8))
        scroll:UpdateScroll()
    end
    return pg
end

local function EnsureWindow()
    if win then return win end
    win = AT.CreateWindow("ArcBonusRollWindow", {
        title = "|cff3fc9f2Arc|r|cffd5e2f2 Bonus Roll|r",
        version = C_AddOns.GetAddOnMetadata(ADDON, "Version"),
        w = 530, h = 590, minW = 500, minH = 500,
    })

    local pages = {}

    -- Overview + History are hand-built; the rest use the row engine
    pages.Overview = BuildOverviewPage(win)
    pages.History = BuildHistoryPage(win)

    local prot = AT.NewPage(win)
    pages.Protection = prot
    AT.Section(prot, "Coin Protection")
    AT.RowToggle(prot, "Enable coin protection",
        function() return char.settings.protection end,
        function(v) char.settings.protection = v; UpdateCovers() end,
        nil,
        "With planned bosses set (pick as many as you like, per difficulty), the roll button on every OTHER boss's prompt is covered by a lock. One click on the lock unlocks it, so it is a speed bump, never a wall. This addon never rolls or passes for you.")
    AT.RowToggle(prot, "Guard Pass on your planned bosses",
        function() return char.settings.passGuard end,
        function(v) char.settings.passGuard = v; UpdateCovers() end,
        function() return char.settings.protection end,
        "On your planned bosses the PASS button gets the lock instead, so you cannot misclick away the roll you saved your coin for.")
    AT.RowToggle(prot, "New week plan reminder",
        function() return char.settings.planReminder end,
        function(v) char.settings.planReminder = v end,
        nil,
        "When a raid week starts with an empty plan and you have used plans or protection before, a small popup reminds you to pick your bosses - at login, when a coin drops, or when a roll prompt appears uncovered. Not this week silences it for the week; planning any boss dismisses it.")
    AT.Section(prot, "This Week")
    StatusRow(prot, function()
        local names = PlannedNames(CurrentWeek())
        return "Planned: " .. (names and ("|cffffd100" .. names .. "|r") or "|cff8ca0b8none|r")
    end)
    StatusRow(prot, function()
        local week, n = CurrentWeek(), 0
        for i = 1, #char.rolls do
            if char.rolls[i].week == week then n = n + 1 end
        end
        return ("Rolls recorded this week: |cffffd100%d|r"):format(n)
    end)
    AT.RowButton(prot, "Clear this week's plan", function()
        char.plan[CurrentWeek()] = nil
        UpdateCovers()
        RefreshEJ()
        if RefreshWindow then RefreshWindow() end
    end, nil, 180)

    local jour = AT.NewPage(win)
    pages.Journal = jour
    AT.Section(jour, "Adventure Guide Markers")
    AT.RowToggle(jour, "Boss and loot markers",
        function() return char.settings.ejOverlay end,
        function(v) char.settings.ejOverlay = v; RefreshEJ() end,
        nil,
        "Coin on each boss row = plan your rolls. Checks on loot rows = items already received. Un-collected items show their sim gain and drop share.")
    AT.RowToggle(jour, "Show on raid pages",
        function() return char.settings.showOnRaids end,
        function(v) char.settings.showOnRaids = v; RefreshEJ(); RefreshEJStrip() end,
        function() return char.settings.ejOverlay end,
        "Markers and the info bar on the Adventure Guide's raid pages - where bonus rolls happen.")
    AT.RowToggle(jour, "Show on dungeon pages",
        function() return char.settings.showOnDungeons end,
        function(v) char.settings.showOnDungeons = v; RefreshEJ(); RefreshEJStrip() end,
        function() return char.settings.ejOverlay end,
        "Also decorate dungeon (Mythic+) journal pages. Off by default: bonus roll coins drop from raid bosses.")
    AT.RowToggle(jour, "Item tooltip notes",
        function() return char.settings.tooltips end,
        function(v) char.settings.tooltips = v end,
        nil,
        "Adds a line to any item's tooltip when you won that item from a recorded bonus roll.")
    RowButtonPair(jour,
        "Scan gear for looted items", EstimateLootedScan,
        "Open Adventure Guide", OpenJournalToCurrentRaid)
    AT.Section(jour, "Info Bar")
    AT.RowToggle(jour, "Journal info bar",
        function() return char.settings.showStrip end,
        function(v) char.settings.showStrip = v; RefreshEJ() end,
        nil,
        "The Arc Bonus Roll bar inside the Adventure Guide: rolls available, planned bosses, the roll counter, and the Scan gear button.")
    AT.RowDropdown(jour, win, "Counter shows",
        function() return char.settings.stripCounter end,
        function(v) char.settings.stripCounter = v; RefreshEJ() end,
        function()
            return {
                { value = "total", text = "Total bonus rolls" },
                { value = "week",  text = "Rolled this week" },
            }
        end,
        function() return char.settings.showStrip end)
    SmallNumberRow(jour, "Rolls before install",
        function() return tostring(char.rollBaseline or 0) end,
        function(v)
            char.rollBaseline = math.max(0, math.floor(tonumber(v) or 0))
            RefreshEJ()
        end,
        function() return char.settings.showStrip and char.settings.stripCounter == "total" end,
        "The addon only sees rolls made after it was installed. Add the rolls you made before, and the total counter includes them.")
    AT.Section(jour, "Minimap")
    AT.RowToggle(jour, "Minimap button",
        function() return char.settings.minimap end,
        function(v)
            char.settings.minimap = v
            if ApplyMinimapButton then ApplyMinimapButton() end
        end,
        nil,
        "The coin button on the minimap. Click it to open this window; drag it around the rim to move it.")

    local sims = AT.NewPage(win)
    pages.Sims = sims
    AT.Section(sims, "Import")
    StatusRow(sims, function()
        return ("Sims are |cffffd100per spec|r. Importing now stores for: |cff3fc9f2%s|r"):format(CurrentSpecName())
    end)
    RowButtonPair(sims,
        "Paste a Droptimizer CSV", ShowSimImport,
        "Import from WoWUtils", function()
            local diffs, itemsOrErr = ImportFromWowUtils()
            if diffs then
                simStatusMsg = ("|cff4cde4cImported %d item gains (%d difficulty set%s) for %s from WoWUtils.|r"):format(
                    itemsOrErr, diffs, diffs == 1 and "" or "s", CurrentSpecName())
                WipeLootPool()
                RefreshEJ()
            else
                simStatusMsg = "|cffff6060" .. tostring(itemsOrErr) .. "|r"
            end
            if RefreshWindow then RefreshWindow() end
        end)
    StatusRow(sims, function() return simStatusMsg end)
    AT.RowButton(sims, "Clear this spec's sims", function()
        wipe(simStore)
        simStatusMsg = ("|cffffd100Cleared all imported sims for %s.|r"):format(CurrentSpecName())
        WipeLootPool()
        RefreshEJ()
        RefreshEJStrip()
        if RefreshWindow then RefreshWindow() end
    end, nil, 180)
    AT.RowToggle(sims, "Show EV as percent",
        function() return char.settings.evPercent end,
        function(v) char.settings.evPercent = v; RefreshEJ() end,
        nil,
        "Raidbots' Relative DPS view: gains and roll EVs show as a percent of your simmed DPS instead of raw numbers.")
    AT.Section(sims, "Imported Data")
    StatusRow(sims, function()
        return ("For |cff3fc9f2%s|r:"):format(CurrentSpecName())
    end)
    for _, d in ipairs({ 17, 14, 15, 16 }) do
        StatusRow(sims, function()
            local ev = simStore[d]
            if not ev then
                return ("%s: |cff8ca0b8no sim imported|r"):format(DifficultyName(d))
            end
            local n = 0
            for _, encGains in pairs(ev.gains) do
                for _ in pairs(encGains) do n = n + 1 end
            end
            return ("%s: |cffffd100%d|r item gains, imported %s"):format(
                DifficultyName(d), n, date("%m-%d %H:%M", ev.t or 0))
        end)
    end

    -- row-engine pages lay out twice: the synchronous pass on a chip click
    -- can run before font widths settle, which blanked the toggle labels -
    -- a deferred second pass paints from real measurements
    for _, pg in ipairs({ prot, jour, sims }) do
        function pg:Refresh()
            AT.LayoutPage(self)
            C_Timer.After(0, function()
                if self:IsShown() then AT.LayoutPage(self) end
            end)
        end
    end

    for _, pg in pairs(pages) do
        pg:SetPoint("TOPLEFT", 10, -61)
        pg:SetPoint("BOTTOMRIGHT", -10, 40)
    end
    AT.AddTabs(win, { "Overview", "Protection", "Journal", "Sims", "History" }, pages)
    AT.AddDiscordFooter(win, "ArcBonusRollDiscordCopy")
    win.SelectTab("Overview")
    win:Hide()
    return win
end

RefreshWindow = function()
    if win and win:IsShown() then win:RefreshActive() end
end

local function ToggleWindow()
    local w = EnsureWindow()
    if w:IsShown() then w:Hide() return end
    w:Show()
    w.SelectTab(w._activeTab or "Overview")
    -- settle relayout: first-open runs before rects and font widths land
    C_Timer.After(0, RefreshWindow)
end

-- ── Minimap button (no libraries: classic rim-riding button) ────────────────
local mmBtn
local function MMUpdatePos()
    if not mmBtn then return end
    local angle = math.rad(tonumber(char and char.settings.minimapAngle) or 210)
    local r = (Minimap:GetWidth() / 2) + 5
    mmBtn:ClearAllPoints()
    mmBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function BuildMinimapButton()
    if mmBtn then return mmBtn end
    mmBtn = CreateFrame("Button", "ArcBonusRollMinimapButton", Minimap)
    mmBtn:SetSize(31, 31)
    mmBtn:SetFrameStrata("MEDIUM")
    mmBtn:SetFrameLevel(8)
    mmBtn:RegisterForClicks("LeftButtonUp")
    mmBtn:RegisterForDrag("LeftButton")
    mmBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local overlay = mmBtn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")
    -- the TrackingBorder ring is OFFSET inside its 53px texture - background
    -- and icon must use the LibDBIcon geometry to sit inside its circle
    local bg = mmBtn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = mmBtn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(19, 19)
    -- the coin currency's own art; it is square and the ring is round, so
    -- mask the corners off with the portrait alpha circle
    icon:SetTexture(CoinIconTexture())
    icon:SetPoint("TOPLEFT", 6, -5)
    local mask = mmBtn:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)
    mmBtn.icon = icon
    mmBtn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            char.settings.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            MMUpdatePos()
        end)
    end)
    mmBtn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    mmBtn:SetScript("OnClick", function() ToggleWindow() end)
    mmBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff3fc9f2Arc|r|cffd5e2f2 Bonus Roll|r")
        local count = BonusRollsAvailable()
        if count then GameTooltip:AddLine(("Bonus rolls: %d"):format(count), 1, 0.82, 0) end
        GameTooltip:AddLine("Click: open.  Drag: move this button.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    mmBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    MMUpdatePos()
    mmBtn:SetShown(char.settings.minimap ~= false)
    return mmBtn
end

ApplyMinimapButton = function()
    if not mmBtn then return end
    mmBtn.icon:SetTexture(CoinIconTexture())
    mmBtn:SetShown(char and char.settings.minimap ~= false)
    MMUpdatePos()
end

-- ── New-week plan reminder ──────────────────────────────────────────────────
-- The plan is per raid week, so every reset silently empties it. People who
-- actually use planning (protection on, or a plan in a past week) get ONE
-- popup per moment that matters: a new week starting with no plan (login),
-- a coin landing in the bags unplanned, or a roll prompt appearing while
-- protection has nothing to protect. "Not this week" silences the week;
-- setting any plan dismisses it instantly (via UpdateCovers).
local planPopup
local planReminderSession = false

HidePlanReminder = function()
    -- auto-dismiss is for the EMPTY-plan nudge (planning something means
    -- it did its job); the vault's plan recap shows WITH a plan set, so
    -- it must not be swept away by the next covers update
    if planPopup and planPopup:IsShown() and not planPopup.recapMode then
        planPopup:Hide()
    end
end

local function BuildPlanPopup()
    if planPopup then return planPopup end
    planPopup = CreateFrame("Frame", "ArcBonusRollPlanReminder", UIParent, "BackdropTemplate")
    planPopup:SetSize(400, 104)
    planPopup:SetPoint("TOP", 0, -160)
    planPopup:SetFrameStrata("DIALOG")
    planPopup:EnableMouse(true)
    AT.Skin(planPopup, AT.COL.bg, AT.COL.arcDeep)
    local title = planPopup:CreateFontString(nil, "OVERLAY")
    title:SetFont(STANDARD_TEXT_FONT, 12, "")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("|cff3fc9f2Arc|r|cffd5e2f2 Bonus Roll|r")
    local body = planPopup:CreateFontString(nil, "OVERLAY")
    body:SetFont(STANDARD_TEXT_FONT, 11, "")
    body:SetPoint("TOPLEFT", 12, -30)
    body:SetPoint("TOPRIGHT", -12, -30)
    body:SetJustifyH("LEFT")
    body:SetWordWrap(true)
    body:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    planPopup.body = body
    local planBtn = AT.MakeSmallButton(planPopup, "Plan now", 110)
    planBtn:SetPoint("BOTTOMLEFT", 12, 10)
    planBtn:SetScript("OnClick", function()
        planPopup:Hide()
        local w = EnsureWindow()
        if not w:IsShown() then w:Show() end
        w.SelectTab("Overview")
        C_Timer.After(0, RefreshWindow)
    end)
    local skipBtn = AT.MakeSmallButton(planPopup, "Not this week", 110)
    skipBtn:SetPoint("LEFT", planBtn, "RIGHT", 8, 0)
    skipBtn:SetScript("OnClick", function()
        char.planSkipWeek = CurrentWeek()
        planPopup:Hide()
    end)
    planPopup.skipBtn = skipBtn
    local close = AT.MakeSmallButton(planPopup, "x", 20)
    close:SetPoint("TOPRIGHT", -8, -8)
    close:SetScript("OnClick", function() planPopup:Hide() end)
    return planPopup
end

-- The Great Vault UI lives in Blizzard_WeeklyRewards, loaded on demand:
-- hook its frame's OnShow whenever the addon appears (or already exists)
local vaultHooked = false
InstallVaultHook = function()
    if vaultHooked then return end
    local f = _G.WeeklyRewardsFrame
    if not (f and f.HookScript) then return end
    vaultHooked = true
    f:HookScript("OnShow", function()
        if MaybePlanReminder then MaybePlanReminder("vault") end
    end)
end

MaybePlanReminder = function(kind)
    if not char or not char.settings.planReminder then return end
    local week = CurrentWeek()
    if char.planSkipWeek == week then return end
    local planned = HasAnyPlan(week)
    -- an existing plan silences the coin/prompt alarms (protection is
    -- armed, nothing to warn about) - but the vault briefing still shows:
    -- its job with a plan set is "here are your picks, change or keep them"
    if planned and kind ~= "vault" then return end
    -- never nag someone who has never used planning at all
    local planner = planned or char.settings.protection
    if not planner then
        for wk, set in pairs(char.plan) do
            if type(wk) == "number" and wk < week and type(set) == "table" and next(set) then
                planner = true
                break
            end
        end
    end
    if not planner then return end
    if kind == "vault" then
        -- opening the Great Vault = the player is starting their raid week:
        -- the natural moment for the plan briefing, once per week
        if char.planPromptWeek == week then return end
        char.planPromptWeek = week
    else
        -- prompt/coin: the sharper in-the-moment nudges, once per session;
        -- the prompt one only matters when protection would be covering
        if planReminderSession then return end
        if kind == "prompt" and not char.settings.protection then return end
    end
    planReminderSession = true
    BuildPlanPopup()
    if kind == "prompt" then
        planPopup.body:SetText("A bonus roll is up but nothing is planned this week, so coin protection is not covering anything. Pick your bosses when you get a moment.")
    elseif kind == "coin" then
        planPopup.body:SetText("You just received a bonus roll coin and nothing is planned this week. Pick the bosses you want to spend it on.")
    elseif planned then
        local short = PlannedShort(week)
        planPopup.body:SetText(("This raid week's bonus roll plan: |cffffd100%s|r. Your picks are safe - open the planner if you want to change them."):format(short or "?"))
    else
        planPopup.body:SetText("New raid week: your bonus roll plan is empty. Pick the bosses you will spend coins on, and protection covers the rest.")
    end
    planPopup.recapMode = (planned and kind == "vault") or false
    planPopup.skipBtn.fs:SetText(planPopup.recapMode and "Keep it" or "Not this week")
    planPopup:Show()
end

-- ── Mock prompt (visual test without a boss kill) ───────────────────────────
-- Builds OUR OWN replica of the prompt (never touches Blizzard's frame) so
-- the covers' look and click flow can be verified anywhere.
local mock
local function ShowMock()
    if mock then mock:SetShown(not mock:IsShown()) return end
    mock = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    mock:SetSize(300, 90)
    mock:SetPoint("CENTER", 0, -180)
    AT.Skin(mock, AT.COL.bg, AT.COL.line2)
    local label = mock:CreateFontString(nil, "OVERLAY")
    label:SetFont(STANDARD_TEXT_FONT, 12, "")
    label:SetPoint("TOP", 0, -8)
    label:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    label:SetText("MOCK bonus roll prompt (test only)")
    local dice = AT.MakeSmallButton(mock, "Roll (mock)", 100)
    dice:SetPoint("BOTTOMLEFT", 20, 12)
    dice:SetScript("OnClick", function() Print("mock: the REAL dice would have been clicked.") end)
    local cover = CreateFrame("Button", nil, mock)
    cover:SetPoint("TOPLEFT", dice, "TOPLEFT", -3, 3)
    cover:SetPoint("BOTTOMRIGHT", dice, "BOTTOMRIGHT", 3, -3)
    cover:SetFrameLevel(dice:GetFrameLevel() + 5)
    cover:RegisterForClicks("AnyUp")
    local bg = cover:CreateTexture(nil, "ARTWORK")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.78)
    local lock = cover:CreateTexture(nil, "OVERLAY")
    lock:SetSize(16, 16)
    lock:SetPoint("CENTER")
    lock:SetTexture(TEX_LOCK)
    cover:SetScript("OnClick", function(self)
        self:Hide()
        Print("mock: cover unlocked; the mock dice button is now clickable.")
    end)
    local hint = mock:CreateFontString(nil, "OVERLAY")
    hint:SetFont(STANDARD_TEXT_FONT, 10, "")
    hint:SetPoint("BOTTOMRIGHT", -14, 16)
    hint:SetTextColor(AT.COL.dim[1], AT.COL.dim[2], AT.COL.dim[3])
    hint:SetText("click the lock,\nthen the button")
end

-- ── Events + slash ──────────────────────────────────────────────────────────
local loginAt = 0   -- login currency sync must not read as "got a coin"
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("BONUS_ROLL_STARTED")
ev:RegisterEvent("BONUS_ROLL_RESULT")
ev:RegisterEvent("BONUS_ROLL_FAILED")
ev:RegisterEvent("BONUS_ROLL_ACTIVATE")
ev:RegisterEvent("BONUS_ROLL_DEACTIVATE")
ev:RegisterEvent("EJ_DIFFICULTY_UPDATE")
ev:RegisterEvent("EJ_LOOT_DATA_RECIEVED")   -- Blizzard's typo, really spelled this way
ev:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
ev:RegisterEvent("TRANSMOG_COLLECTION_UPDATED")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterUnitEvent("PLAYER_SPECIALIZATION_CHANGED", "player")

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local which = ...
        if which == "Blizzard_EncounterJournal" then
            InstallEJHooks()
        elseif which == "Blizzard_WeeklyRewards" then
            InstallVaultHook()
        end
        return
    end
    if event == "PLAYER_LOGIN" then
        InitDB()
        RebuildWonItems()
        if BonusRollFrame_StartBonusRoll then
            hooksecurefunc("BonusRollFrame_StartBonusRoll", OnPromptShown)
        end
        InstallEJHooks()   -- in case the journal loaded before us
        BuildMinimapButton()
        loginAt = GetTime()
        -- confirm the coin pools in the background once the world settles,
        -- and fill an empty sim bucket from WoWUtils (same as a spec swap)
        C_Timer.After(8, PrimePoolCache)
        C_Timer.After(10, function()
            AutoImportSims()
            if RefreshWindow then RefreshWindow() end
            RefreshEJ()
            RefreshEJStrip()
        end)
        InstallVaultHook()   -- in case the vault UI loaded before us
        return
    end
    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- pools and sims are per-spec and SAVED: swap the live stores to
        -- the new spec's buckets. Returning to a spec brings its confirmed
        -- pools and sims straight back; nothing re-harvests unless this
        -- spec has never been primed on this raid.
        if char then
            RelinkSpecStores()
            WipeDetectCache()
            AutoImportSims()
            WipeLootPool()
            RefreshEJ()
            RefreshEJStrip()
            if RefreshWindow then RefreshWindow() end
            C_Timer.After(4, PrimePoolCache)
        end
        return
    end
    if event == "BONUS_ROLL_STARTED" then
        OnRollStarted()
        return
    end
    if event == "BONUS_ROLL_RESULT" then
        OnRollResult(...)
        return
    end
    if event == "BONUS_ROLL_FAILED" then
        OnRollFailed()
        return
    end
    if event == "BONUS_ROLL_ACTIVATE" or event == "BONUS_ROLL_DEACTIVATE" then
        UpdateCovers()
        return
    end
    if event == "EJ_DIFFICULTY_UPDATE" or event == "EJ_LOOT_DATA_RECIEVED" then
        -- loot data arrives ASYNC after a page/boss switch: any pool built
        -- from the partial list is wrong, so wipe, repaint, and settle
        WipeLootPool()
        RefreshEJ()
        ScheduleEJSettle()
        return
    end
    if event == "CURRENCY_DISPLAY_UPDATE" then
        RefreshEJStrip()
        if ApplyMinimapButton then ApplyMinimapButton() end
        if RefreshWindow then RefreshWindow() end
        local currencyType, _, quantityChange = ...
        -- a coin just LANDED (past the login sync storm): the natural
        -- moment to remind an unplanned week
        if currencyType and currencyType == BonusCurrencyID()
            and (quantityChange or 0) > 0 and (GetTime() - loginAt) > 30 then
            MaybePlanReminder("coin")
        end
        return
    end
    if event == "TRANSMOG_COLLECTION_UPDATED" or event == "PLAYER_EQUIPMENT_CHANGED"
        or event == "BAG_UPDATE_DELAYED" then
        -- estimation only runs from the button now; just invalidate its
        -- cache so the next press sees current gear
        WipeDetectCache()
        return
    end
end)

-- /abr test: bring up the REAL BonusRollFrame prompt through Blizzard's
-- own entry function so the covers are exercised on the exact production
-- frame. Safe by construction: the fake spellID has no pending server
-- confirmation, so even clicking the real dice does nothing, and the
-- prompt times out on its own. Blizzard refuses to show the prompt at 0
-- currency, so the test borrows the first currency the character owns.
local function FindOwnedCurrencyForTest()
    -- prefer the real Voidcore when the character has any
    local vc = BonusCurrencyID()
    if vc then
        local info = C_CurrencyInfo.GetCurrencyInfo(vc)
        if info and (info.quantity or 0) > 0 then return vc end
    end
    if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
        for i = 1, C_CurrencyInfo.GetCurrencyListSize() do
            local info = C_CurrencyInfo.GetCurrencyListInfo(i)
            if info and not info.isHeader and (info.quantity or 0) > 0 then
                local link = C_CurrencyInfo.GetCurrencyListLink(i)
                local id = link and C_CurrencyInfo.GetCurrencyIDFromLink(link)
                if id then return id end
            end
        end
    end
    return vc
end

local function HideTestPrompt()
    if BonusRollFrame and BonusRollFrame.spellID == TEST_SPELL_ID
        and BonusRollFrame_CloseBonusRoll then
        BonusRollFrame_CloseBonusRoll()
    end
end

local function ShowTestPrompt()
    if not BonusRollFrame_StartBonusRoll then return end
    local pf = BonusRollFrame and BonusRollFrame.PromptFrame
    if pf and pf:IsShown() and BonusRollFrame.spellID ~= TEST_SPELL_ID then
        return   -- never stomp a REAL prompt
    end
    BonusRollFrame_StartBonusRoll(TEST_SPELL_ID, "", 30,
        FindOwnedCurrencyForTest(), 1, 15, 0, 0, 0)
    UpdateCovers()
    -- a REAL prompt is closed by the server's confirmation-timeout event;
    -- a fake one has no server side, so nothing would EVER close it (and
    -- roll/pass clicks are no-ops that leave it up too) - close it
    -- ourselves. Safe if a real prompt took over meanwhile: HideTestPrompt
    -- only acts while the frame still shows OUR test spellID.
    C_Timer.After(31, HideTestPrompt)
end

-- /abr wipe: erase EVERYTHING saved (all characters, all specs, the
-- account-wide pools) and reload = a true fresh-install state. Behind a
-- confirm dialog: a typo must never nuke a real ledger.
StaticPopupDialogs["ARCBONUSROLL_WIPE"] = {
    text = "Arc Bonus Roll: erase ALL saved data (roll history, plans, owned marks, sims, pools - every character) and reload for a fresh-install state?",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        ArcBonusRollDB = nil   -- nil survives the reload's save = clean slate
        C_UI.Reload()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

SLASH_ARCBONUSROLL1 = "/arcbonusroll"
SLASH_ARCBONUSROLL2 = "/abr"
SlashCmdList["ARCBONUSROLL"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "wipe" then
        StaticPopup_Show("ARCBONUSROLL_WIPE")
        return
    end
    if msg == "mock" then
        ShowMock()
        return
    end
    if msg == "test" then
        ShowTestPrompt()
        return
    end
    if msg == "testoff" then
        HideTestPrompt()
        return
    end
    if msg == "sim" then
        ShowSimImport()
        return
    end
    ToggleWindow()
end
