-- ═══════════════════════════════════════════════════════════════════════════
-- Arc Loot Planner - roll ledger + Adventure Guide markers + bonus roll protection
--
-- Standalone twin (an ArcUI module version mirrors this file; keep in sync).
--
-- SAFETY INVARIANTS (the reason this addon exists over the alternatives):
--   * This addon NEVER calls AcceptSpellConfirmationPrompt or
--     DeclineSpellConfirmationPrompt. Under any code path. The only thing
--     that can roll or pass is the player's own click on Blizzard's own
--     LIVE button - so rolling the wrong boss from stale addon state is
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
--     this from a roll" - the only possible backfill, there is no history
--     API), faint coin = click to check it off. Un-collected items show
--     an estimated share (1 in N eligible drops under the current filter).
--     The roll's overall success rate is server-side and never shown.
--
-- /alp (or /abr) - options window (Arc theme). /alp mock - cover test. No pcall.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, NS = ...
local AT = NS.AT

local COLOR = "|cff33ccff"
local function Print(msg)
    print(COLOR .. "Arc Loot Planner|r: " .. msg)
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
    char.lastSpecID = specID   -- default spec for the cross-character sim picker
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

-- ── Shipped pool seed ───────────────────────────────────────────────────────
-- NS.PoolSeed (the generated data file) carries every class and spec's
-- loot tables, extracted once via TokenLab from the game's own journal
-- database. At login the player's OWN class specs are expanded into the
-- account pool store (presence only - never overwriting a link the
-- primer has attached), so every page renders fully on the very first
-- open. The background primer stays on as the verifier: it attaches
-- real links and reconciles anything Blizzard changed.
local function SeedPools()
    local seed = NS.PoolSeed
    if not (seed and type(seed.specs) == "table" and db) then return end
    local classID = select(3, UnitClass("player"))
    local getNum = C_SpecializationInfo and C_SpecializationInfo.GetNumSpecializationsForClassID
        or GetNumSpecializationsForClassID
    local getInfo = GetSpecializationInfoForClassID
        or (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoForClassID)
    local n = (classID and getNum) and getNum(classID) or 0
    db.poolBySpec = db.poolBySpec or {}
    for i = 1, n do
        local specID = getInfo and getInfo(classID, i)
        local sp = specID and seed.specs[specID]
        if sp then
            local store = db.poolBySpec[specID] or {}
            db.poolBySpec[specID] = store
            store.cache = store.cache or {}
            local cache = store.cache
            for _, d in ipairs({ 14, 15, 16, 17 }) do
                local bucket = cache[d] or {}
                cache[d] = bucket
                for inst, encs in pairs(sp.r or {}) do
                    for enc, ids in pairs(encs) do
                        local set = bucket[enc] or {}
                        bucket[enc] = set
                        for id in ids:gmatch("%d+") do
                            id = tonumber(id)
                            if set[id] == nil then set[id] = true end
                        end
                    end
                end
            end
            if type(sp.d) == "table" and next(sp.d) then
                cache.mplusBonus = cache.mplusBonus or {}
                for inst, ids in pairs(sp.d) do
                    local set = cache.mplusBonus[inst] or {}
                    cache.mplusBonus[inst] = set
                    for id in ids:gmatch("%d+") do
                        id = tonumber(id)
                        if set[id] == nil then set[id] = true end
                    end
                end
            end
        end
    end
end

local function InitDB()
    ArcLootPlannerDB = ArcLootPlannerDB or {}
    db = ArcLootPlannerDB
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
    -- the two halves of the journal overlay, separately hideable: raw item
    -- DPS gains, and the bonus-roll dressing (coins, shares, planning)
    if s.showGains == nil then s.showGains = true end
    if s.showShares == nil then s.showShares = true end
    if s.lootRollSim == nil then s.lootRollSim = true end -- need/greed sim tag
    if char.rollBaseline == nil then char.rollBaseline = 0 end -- pre-install rolls
    -- class stamp: the Sims tab's cross-character import picker needs it to
    -- list an alt's specs while that alt is offline
    char.classID = select(3, UnitClass("player")) or char.classID
    -- sim EVs and confirmed pools are PER SPEC and PERSISTENT. Sims are
    -- gear-dependent, so they live per character: char.specData[specID]
    -- .simEV[diff] = { base, t, gains = { [enc] = { [itemID] = gain } } }.
    -- The journal pool is identical for every character of a spec, so it
    -- lives ACCOUNT-wide: db.poolBySpec[specID].cache[diff][enc] =
    -- { [itemID] = true }, .primedAt[diff] = journal instanceID. Primed
    -- ONCE, saved, and re-harvested only for a raid or spec this account
    -- has never confirmed. RelinkSpecStores aliases the live stores.
    RelinkSpecStores()
    SeedPools()

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
    -- transmog: SOURCE-level, never appearance-level. An alt's Normal copy
    -- shares the appearance and false-marked the Heroic drop (user report:
    -- Amani Summoning Shawl). PlayerKnowsSource answers for THIS
    -- difficulty's version of the item only.
    if C_TransmogCollection and C_TransmogCollection.GetItemInfo
        and C_TransmogCollection.PlayerKnowsSource then
        local _appearance, sourceID = C_TransmogCollection.GetItemInfo(link)
        if sourceID then
            owned = C_TransmogCollection.PlayerKnowsSource(sourceID) or false
        end
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
            -- STRICT on both ends (user report: a champion-track M+ copy
            -- claimed the raid drop while item levels were unreadable):
            -- when either item level cannot be read, claim NOTHING
            if not wantIlvl then return false end
            local il = C_Item.GetDetailedItemLevelInfo(foundLink)
            return il ~= nil and il >= wantIlvl
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

-- Mythic+ bonus rolls are planned per DUNGEON with ONE pool (all bosses'
-- loot together). Plans/marks/records reuse the boss machinery with the
-- dungeon's journal instanceID in the encounter slot under this canonical
-- difficulty key - instance IDs and encounter IDs never collide.
local MPLUS_DIFF = 8   -- Mythic Keystone

-- the journal's "Keystone Dungeons" AGGREGATE page (journal instance 1319
-- per wago.tools JournalInstance; no API flag marks it): it repeats loot
-- the real dungeons already list, so every M+ surface skips it - a coin
-- there would double-count the season's pool
local MPLUS_AGGREGATE_INSTANCE = 1319

local function PlanEntryName(enc, diff)
    if diff == MPLUS_DIFF and EJ_GetInstanceInfo then
        local n = EJ_GetInstanceInfo(enc)
        if n then return n end
    end
    return EJ_GetEncounterInfo(enc) or ("encounter " .. enc)
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
            local n = PlanEntryName(enc, diff)
            local dn = diff and diff ~= 0 and GetDifficultyInfo(diff) or nil
            if dn then n = n .. " (" .. dn .. ")" end
            names = names and (names .. ", " .. n) or n
        end
    end
    return names
end

-- compact display form: one entry per boss with letter codes for its
-- planned difficulties - "The Coiled Altar (H)(M), Sszorak (N)"
local DIFF_CODE = { [14] = "N", [15] = "H", [16] = "M", [17] = "L", [MPLUS_DIFF] = "M+" }
local function PlannedShort(week)
    local p = char.plan[week]
    if not p then return nil, 0 end
    local byBoss, order, entryNames = {}, {}, {}
    for key in pairs(p) do
        local enc, diff = key:match("^(%d+):(%d+)$")
        enc, diff = tonumber(enc), tonumber(diff)
        if enc then
            if not byBoss[enc] then
                byBoss[enc] = {}
                order[#order + 1] = enc
            end
            if not entryNames[enc] then entryNames[enc] = PlanEntryName(enc, diff) end
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
        parts[#parts + 1] = (entryNames[enc] or ("boss " .. enc)) .. " " .. codes
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

-- ── Bonus roll protection covers ────────────────────────────────────────────
-- Our own child frames over Blizzard's buttons. We never write to, disable,
-- or re-script the real buttons - Blizzard's own OnShow re-enables the dice
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
        GameTooltip:SetText("Arc Loot Planner protection", 0.2, 0.8, 1)
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
        -- an M+ bonus roll is planned per DUNGEON: match the prompt's
        -- instance against the dungeon plan too (raid instances can never
        -- carry a :8 key - only dungeon coins write those)
        local inst = BonusRollFrame.instanceID
        local isPlannedHere = (enc and IsPlanned(week, enc, diff))
            or (inst and IsPlanned(week, inst, MPLUS_DIFF))
        if not HasAnyPlan(week) then
            showRoll = not unlockedRoll
            rollReason = "No planned bosses are set for this week. Pick them in the Adventure Guide (click the coin on a boss), or unlock to roll anyway."
        elseif isPlannedHere then
            showPass = char.settings.passGuard and not unlockedPass
            local target
            if enc and IsPlanned(week, enc, diff) then
                target = EncounterName(enc)
            else
                target = inst and PlanEntryName(inst, MPLUS_DIFF) or "this dungeon"
            end
            passReason = ("This is on your planned list (%s) - passing would throw away the roll you saved your coin for."):format(target)
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

-- slotless = a tier token / non-equipment journal item
local function IsTokenItem(itemID)
    if not itemID or not C_Item or not C_Item.GetItemInventoryTypeByID then return false end
    local inv = C_Item.GetItemInventoryTypeByID(itemID)
    return inv == (Enum.InventoryType and Enum.InventoryType.IndexNonEquipType or 0)
end

-- The season's OMNI token: the ONE tier token a bonus roll can never grant
-- (Arc-confirmed in-game; the four slot tokens DO roll). Its gain still
-- prices the DROPS surfaces like any token. Update per raid tier.
-- TOKENS HAVE A DIFFERENT ITEM ID PER DIFFICULTY TRACK (live-confirmed:
-- heroic Venomcast Icon 270928 vs the myth-track 268223 a Droptimizer
-- sims). So live journal rows and sim rows NEVER share token ids - the
-- design below is journal-first: the boss's token comes from the journal
-- (right id for the shown difficulty), the sim only prices it.
local OMNI_TOKENS = {
    [271876] = true,   -- Venomous Abyss omni token, myth track (sim id)
    [270909] = true,   -- Venomous Abyss omni token, heroic (live id)
}

-- TokenLab-proven (2026-09-08): the journal reports filterType 14 (Other)
-- for EVERY token - slot tokens, the omni AND per-player items alike - so
-- filterType can NOT identify or slot tokens. What IS reliable: the sim's
-- vault rows carry the GENERATED PIECE directly (Arc's model), and those
-- piece ids match C_LootJournal's set items exactly.
-- Known token slots (Enum.ItemSlotFilterType values), for the old-import
-- fallback where the gain was credited to a sim-side token id:
local TOKEN_SLOTS = {
    [268230] = 0,   -- head token (myth track / sim id)
    [268231] = 2,   -- shoulder token (myth track / sim id)
    [268223] = 4,   -- chest token (myth track / sim id)
    [268238] = 6,   -- hands token (myth track / sim id)
    [270928] = 4,   -- Venomcast Icon: chest token, heroic (live id)
}

local tokenPieceCache = {}   -- [specID] = { [tokenID] = pieceItemID | false }
local tierPieceCache = {}    -- [classID*1000+specID] = { [itemID] = true }

local function InvMatchesFilter(invType, ft)
    local F, I = Enum.ItemSlotFilterType, Enum.InventoryType
    if not (F and I) then return false end
    if ft == F.Head then return invType == I.IndexHeadType + 1 end
    if ft == F.Shoulder then return invType == I.IndexShoulderType + 1 end
    if ft == F.Chest then
        return invType == I.IndexChestType + 1 or invType == I.IndexRobeType + 1
    end
    if ft == F.Hand then return invType == I.IndexHandType + 1 end
    if ft == F.Legs then return invType == I.IndexLegsType + 1 end
    return false
end

-- every set-piece item id C_LootJournal knows for this class/spec, ALL
-- sets unioned. TokenLab proved (a) these ids match the sim's tier rows
-- EXACTLY, and (b) newest-by-itemLevel picks a non-tier armor set - so
-- membership across every set is the safe test (sims only carry the
-- current raid's pieces anyway).
local function TierPieceSet()
    local classID = select(3, UnitClass("player"))
    local specID = CurrentSpecID()
    if not (classID and specID) then return nil end
    local key = classID * 1000 + specID
    local cached = tierPieceCache[key]
    if cached then return cached end
    if not (C_LootJournal and C_LootJournal.GetItemSets
        and C_LootJournal.GetItemSetItems) then return nil end
    local sets = C_LootJournal.GetItemSets(classID, specID)
    if not sets or #sets == 0 then return nil end     -- data not ready: no cache
    -- TIER-SHAPED sets only: every piece in a tier slot (head, shoulder,
    -- chest/robe, hands, legs). Armor sets carry wrist/waist/feet and must
    -- NOT leak in - their pieces are REGULAR boss drops, and unioning them
    -- re-added pool items as fake token outcomes (Arc's duplicate rows).
    local I = Enum.InventoryType
    local tierInv = I and {
        [I.IndexHeadType + 1] = true, [I.IndexShoulderType + 1] = true,
        [I.IndexChestType + 1] = true, [I.IndexRobeType + 1] = true,
        [I.IndexHandType + 1] = true, [I.IndexLegsType + 1] = true,
    } or nil
    if not tierInv then return nil end
    local out, any = {}, false
    for _i, s in ipairs(sets) do
        local items = C_LootJournal.GetItemSetItems(s.setID) or {}
        local tierShaped = #items > 0
        for _j, it in ipairs(items) do
            if not tierInv[it.invType] then
                tierShaped = false
                break
            end
        end
        if tierShaped then
            for _j, it in ipairs(items) do
                out[it.itemID] = true
                any = true
            end
        end
    end
    if not any then return nil end
    tierPieceCache[key] = out
    return out
end

local function TokenPieceFor(tokenID)
    local specID = CurrentSpecID()
    local ft = TOKEN_SLOTS[tokenID]
    if ft == nil then ft = db and db.tokenSlots and db.tokenSlots[tokenID] end
    if not specID or ft == nil then return nil end
    local perSpec = tokenPieceCache[specID]
    if perSpec and perSpec[tokenID] ~= nil then return perSpec[tokenID] or nil end
    local classID = select(3, UnitClass("player"))
    if not (classID and C_LootJournal and C_LootJournal.GetItemSets
        and C_LootJournal.GetItemSetItems) then return nil end
    local sets = C_LootJournal.GetItemSets(classID, specID)
    if not sets or #sets == 0 then return nil end     -- data not ready: no cache
    -- highest setID with a slot match: set ids grow with releases, and the
    -- TokenLab dump proved itemLevel ranking picks a non-tier armor set
    local piece, bestSet = false, -1
    for _i, s in ipairs(sets) do
        if (s.setID or 0) > bestSet then
            for _j, it in ipairs(C_LootJournal.GetItemSetItems(s.setID) or {}) do
                if InvMatchesFilter(it.invType, ft) then
                    piece, bestSet = it.itemID, s.setID
                    break
                end
            end
        end
    end
    tokenPieceCache[specID] = tokenPieceCache[specID] or {}
    tokenPieceCache[specID][tokenID] = piece
    return piece or nil
end

-- THE boss token outcome (Arc's model, TokenLab-proven): the boss's set
-- token becomes ONE specific piece for your class/spec, and the SIM's
-- vault rows already carry that PIECE as a plain gains entry - the
-- journal pool just never lists it (the boss drops the slotless token),
-- which is what kept it out of the roll surfaces. Primary: the best
-- tier-set-piece key in gains (ids match C_LootJournal exactly).
-- Fallback for OLD imports whose parser credited the gain to the sim's
-- token id: map that token to the piece. The omni never rolls (its rows
-- are dropped at parse; old omni-credited entries are skipped here).
-- Returns piece, gain, owned, ownedSource, inGains (piece key present in
-- gains - the no-cache listings already show those as plain rows).
local function GetBossTokenOutcome(enc, simKey, ownedDiff)
    local ev = char and simStore[simKey]
    local gains = ev and ev.gains and ev.gains[enc]
    if not gains then return nil end
    local pieces = TierPieceSet()
    local piece, gain, tokenID
    for id, g in pairs(gains) do
        if pieces and pieces[id] then
            if not gain or g > gain then piece, gain = id, g end
        elseif IsTokenItem(id) and not OMNI_TOKENS[id] then
            tokenID = id
        end
    end
    if not piece and tokenID then
        gain = gains[tokenID]
        piece = TokenPieceFor(tokenID) or tokenID
    end
    if not piece then return nil end
    local owned, source = IsOwnedItem(piece, ownedDiff)
    if not owned and tokenID then owned, source = IsOwnedItem(tokenID, ownedDiff) end
    return piece, gain, owned, source, (gains[piece] ~= nil)
end

local function ParseDroptimizerCSV(text)
    if type(text) ~= "string" or text == "" then return nil end
    local baseline, actorName
    local rows = {}
    for line in text:gmatch("[^\r\n]+") do
        local name, mean = line:match("^([^,]+),([%d%.]+)")
        local meanN = mean and tonumber(mean) or nil
        if name and meanN then
            if not name:find("/") then
                -- the first non-profileset numeric row is the baseline
                -- actor - its NAME is the simmed character
                if not baseline then
                    baseline = meanN
                    actorName = name
                end
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
                    local tokenID = tonumber(f[11])
                    local isVault = src:find("vault") ~= nil
                    -- "raid-vault-*" rows are the BONUS ROLL track and get
                    -- their own bucket. VAULT conversion rows keep the
                    -- GENERATED PIECE as the key (Arc's model: the coin
                    -- grants the piece; the piece ids match C_LootJournal),
                    -- and omni conversions are dropped - the omni never
                    -- rolls. DROPS rows keep crediting the token: the
                    -- guide's token row is what gets priced there.
                    local item
                    if isVault then
                        -- (plain if, NOT `and nil or`: that idiom always
                        -- falls through to the or-branch)
                        if tokenID and OMNI_TOKENS[tokenID] then
                            -- omni conversion: the omni never rolls
                        elseif tokenID and not IsTokenItem(tokenID) then
                            -- CATALYST conversion of a REAL drop (the source
                            -- has an equip slot): the coin grants the SOURCE
                            -- item, catalyzing is the player's later choice -
                            -- credit the source so one drop is ONE row at its
                            -- best use (Arc's Soulslither/Hissing Mantle
                            -- double-count)
                            item = tokenID
                        else
                            -- true slotless TOKEN (or a plain row): the coin
                            -- grants token -> piece; key the piece
                            item = tonumber(f[4])
                        end
                    else
                        item = tokenID or tonumber(f[4])
                    end
                    if diff and enc and item then
                        local key = isVault and ("vault" .. diff) or diff
                        -- when the credited item differs from the simmed
                        -- piece, this row is a CONVERSION - remember what
                        -- the drop becomes (catalyst piece / token piece)
                        local simmed = tonumber(f[4])
                        rows[#rows + 1] = { diff = key, enc = enc, item = item, mean = meanN,
                                            lv = tonumber(f[5]),
                                            conv = (simmed and simmed ~= item) and simmed or nil }
                    end
                elseif src:find("dungeon") then
                    -- Dungeon rows carry no per-boss identity (the leading IDs
                    -- are -1; the bonus-roll "weekly" track puts the DUNGEON's
                    -- journal instance in slot 2 instead). Pool them under enc
                    -- -1 in their own STRING diff buckets - journal readers
                    -- look up numeric diffs, so these stay invisible to the
                    -- raid overlay and nothing can cross-contaminate.
                    local diff = src:find("weekly") and "mplusBonus" or "mplus"
                    -- bonus-roll rows DO carry the dungeon (journal instance
                    -- in slot 2), and the M+ bonus roll pool is all of a
                    -- dungeon's bosses in ONE pool - so key those per
                    -- dungeon. Run rows carry nothing there: pooled under -1.
                    local enc = (diff == "mplusBonus") and tonumber(f[2]) or nil
                    if not enc or enc <= 0 then enc = -1 end
                    local item = tonumber(f[11]) or tonumber(f[4])
                    if item then
                        local simmed = tonumber(f[4])
                        rows[#rows + 1] = { diff = diff, enc = enc, item = item, mean = meanN,
                                            lv = tonumber(f[5]),
                                            conv = (simmed and simmed ~= item) and simmed or nil }
                    end
                end
            end
        end
    end
    if not baseline or #rows == 0 then return nil end
    -- an item can be simmed several ways (trinket1/trinket2, ring slots,
    -- tier pairings): keep the BEST gain per (difficulty, boss, item).
    -- The SIMMED ITEM LEVEL rides along per bucket (highest wins): the
    -- tooltip says what level the sim actually priced, since a bare
    -- itemID tooltip can only preview the base version.
    local out, lvOut, convOut, plainOut = {}, {}, {}, {}
    for _, r in ipairs(rows) do
        local gain = r.mean - baseline
        out[r.diff] = out[r.diff] or {}
        out[r.diff][r.enc] = out[r.diff][r.enc] or {}
        local cur = out[r.diff][r.enc][r.item]
        if not cur or gain > cur then
            out[r.diff][r.enc][r.item] = gain
            -- the WINNING row decides the story: a conversion row winning
            -- means "this drop is best used as <piece>"; an as-is row
            -- winning clears it
            convOut[r.diff] = convOut[r.diff] or {}
            convOut[r.diff][r.item] = r.conv or nil
        end
        -- keep the best AS-DROPPED gain separately: when the catalyzed
        -- use wins, the tooltip shows both numbers side by side
        if not r.conv then
            plainOut[r.diff] = plainOut[r.diff] or {}
            local cp = plainOut[r.diff][r.item]
            if not cp or gain > cp then plainOut[r.diff][r.item] = gain end
        end
        if r.lv then
            lvOut[r.diff] = lvOut[r.diff] or {}
            local clv = lvOut[r.diff][r.item]
            if not clv or r.lv > clv then lvOut[r.diff][r.item] = r.lv end
        end
    end
    return baseline, out, lvOut, actorName, convOut, plainOut
end

-- ── Cross-character sim import ──────────────────────────────────────────────
-- The Sims tab can store a paste into ANY character/spec bucket the addon has
-- seen (db.chars) - sit on one character and import every alt's Droptimizer.
-- nil fields mean "this character" / "current (or last-played) spec".
local simTarget = {}

local function SimTargetKey()
    return simTarget.charKey or CharKey()
end

local function SimTargetSpec()
    if simTarget.specID then return simTarget.specID end
    local key = SimTargetKey()
    if key == CharKey() then return CurrentSpecID() end
    local c = db and db.chars and db.chars[key]
    return c and c.lastSpecID or nil
end

local function SpecLabel(specID)
    if not specID then return "?" end
    local _, name = GetSpecializationInfoForSpecID(specID)
    return name or tostring(specID)
end

local function SimBucketFor(charKey, specID)
    db.chars[charKey] = db.chars[charKey] or {}
    local c = db.chars[charKey]
    c.specData = c.specData or {}
    c.specData[specID] = c.specData[specID] or {}
    c.specData[specID].simEV = c.specData[specID].simEV or {}
    return c.specData[specID].simEV
end

-- ── QE Live upgrade report paste (healers) ──────────────────────────────────
-- questionablyepic.com/live/upgradereport/<id> has a public raw endpoint:
--   https://questionablyepic.com/api/getUpgradeReport.php?reportID=<id>
-- The JSON is double-encoded, and entries carry NO boss ids (QE resolves
-- those client-side) - bosses are attributed through OUR pool caches.
-- Entry shape (verified against two live reports):
--   {"item":268196,"dropLoc":"Raid","dropType":"bonus","dropDifficulty":2,
--    "level":334,...,"rawDiff":1043,"percDiff":0.298}
--   dropLoc  Raid | Dungeon | Crafted | Delves
--   dropType drop (base track) | max (6/6 projection, skipped) | bonus
--   dropDifficulty (raid) = QE's own enum, 0 LFR / 1 Normal / 2 Heroic /
--   3 Mythic (their source: ["Raid Finder","Normal","Heroic","Mythic"]);
--   for dungeons it is the M+ key level.
-- Gains = percDiff -> percent-native buckets, like the WoWUtils QE path.
local QE_RAID_DIFF = { [0] = 17, [1] = 14, [2] = 15, [3] = 16 }

local function ParseQEReport(text)
    if type(text) ~= "string" then return nil end
    if not (text:find("dropLoc") and text:find("percDiff")) then return nil end
    local s = text:gsub('\\"', '"')   -- the raw endpoint serves it double-encoded
    -- report identity: QE stamps the owner's spec and name in the header
    local repSpec = s:match('"spec":"([^"]+)"')
    local repPlayer = s:match('"playername":"([^"]+)"')
    local buckets = {}
    local lvs = {}
    local placed = 0
    local entryLv
    local function put(diffKey, enc, itemID, perc)
        buckets[diffKey] = buckets[diffKey] or {}
        buckets[diffKey][enc] = buckets[diffKey][enc] or {}
        local cur = buckets[diffKey][enc][itemID]
        if not cur or perc > cur then buckets[diffKey][enc][itemID] = perc end
        if entryLv then
            lvs[diffKey] = lvs[diffKey] or {}
            local clv = lvs[diffKey][itemID]
            if not clv or entryLv > clv then lvs[diffKey][itemID] = entryLv end
        end
        placed = placed + 1
    end
    for entry in s:gmatch("%{(.-)%}") do
        local itemID = tonumber(entry:match('"item":(%d+)'))
        local loc = entry:match('"dropLoc":"(%a+)"')
        local typ = entry:match('"dropType":"(%a+)"')
        local dd = tonumber(entry:match('"dropDifficulty":(%d+)') or "")
        local perc = tonumber(entry:match('"percDiff":([%-%d%.eE]+)') or "")
        entryLv = tonumber(entry:match('"level":(%d+)') or "")
        if itemID and loc and typ and perc then
            if loc == "Raid" and (typ == "drop" or typ == "bonus") and QE_RAID_DIFF[dd] then
                local diff = QE_RAID_DIFF[dd]
                -- boss attribution through the journal pool cache (the
                -- background primer keeps it filled); items the pool does
                -- not know - tokens included - are skipped
                local enc
                local pools = poolStore[diff]
                if pools then
                    for e, set in pairs(pools) do
                        if set[itemID] then enc = e break end
                    end
                end
                if enc then
                    put(typ == "bonus" and ("vault" .. diff) or diff, enc, itemID, perc)
                end
            elseif loc == "Dungeon" and typ == "drop" then
                put("mplus", -1, itemID, perc)
            elseif loc == "Dungeon" and typ == "bonus" then
                local inst
                if poolStore.mplusBonus then
                    for id, set in pairs(poolStore.mplusBonus) do
                        if set[itemID] then inst = id break end
                    end
                end
                if inst then put("mplusBonus", inst, itemID, perc) end
            end
            -- "max" rows (6/6 projections) and Crafted/Delves are not drops
        end
    end
    if placed == 0 then return nil end
    return buckets, lvs, repSpec, repPlayer
end

-- QE reports stamp the owner's spec ("Restoration Druid"). Resolve that
-- string against the client's own class/spec roster - the class token
-- disambiguates the two Restorations. Localized names, so a non-matching
-- locale simply resolves nothing and stays permissive.
local function ResolveSpecFromQEString(str)
    if type(str) ~= "string" or str == "" then return nil end
    local needle = str:lower()
    local getNum = C_SpecializationInfo and C_SpecializationInfo.GetNumSpecializationsForClassID
        or GetNumSpecializationsForClassID
    local getInfo = GetSpecializationInfoForClassID
        or (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoForClassID)
    if not (getNum and getInfo) then return nil end
    for classID = 1, (GetNumClasses and GetNumClasses() or 13) do
        local ci = C_CreatureInfo and C_CreatureInfo.GetClassInfo
            and C_CreatureInfo.GetClassInfo(classID)
        local className = ci and ci.className
        if className and needle:find(className:lower(), 1, true) then
            for i = 1, getNum(classID) or 0 do
                local id, name = getInfo(classID, i)
                if id and name and needle:find(name:lower(), 1, true) then
                    return id
                end
            end
        end
    end
    return nil
end

-- The seed's per-spec loot sets double as a SPEC FINGERPRINT: a
-- Droptimizer CSV carries no spec identity, but its item list IS the
-- spec's eligible loot - overlapping it against each seed spec of the
-- class identifies which spec was simmed. Confident only on a strict
-- lead, so near-identical loot lists (ele vs resto) resolve to nil and
-- fall back to the chosen target instead of guessing.
local specSeedSets
local function SeedSetFor(specID)
    local seed = NS.PoolSeed
    local sp = seed and seed.specs and seed.specs[specID]
    if not sp then return nil end
    specSeedSets = specSeedSets or {}
    local set = specSeedSets[specID]
    if set then return set end
    set = {}
    for _, encs in pairs(sp.r or {}) do
        for _, ids in pairs(encs) do
            for id in ids:gmatch("%d+") do set[tonumber(id)] = true end
        end
    end
    for _, ids in pairs(sp.d or {}) do
        for id in ids:gmatch("%d+") do set[tonumber(id)] = true end
    end
    specSeedSets[specID] = set
    return set
end

local function DetectSpecFromSimItems(byDiff, classID)
    if not (classID and NS.PoolSeed and byDiff) then return nil end
    local items = {}
    for _, encs in pairs(byDiff) do
        for _, gains in pairs(encs) do
            for itemID in pairs(gains) do items[itemID] = true end
        end
    end
    local getNum = C_SpecializationInfo and C_SpecializationInfo.GetNumSpecializationsForClassID
        or GetNumSpecializationsForClassID
    local getInfo = GetSpecializationInfoForClassID
        or (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoForClassID)
    if not (getNum and getInfo) then return nil end
    local best, bestHits, secondHits
    for i = 1, getNum(classID) or 0 do
        local specID = getInfo(classID, i)
        local set = specID and SeedSetFor(specID)
        if set then
            local hits = 0
            for itemID in pairs(items) do
                if set[itemID] then hits = hits + 1 end
            end
            if not bestHits or hits > bestHits then
                secondHits = bestHits
                best, bestHits = specID, hits
            elseif not secondHits or hits > secondHits then
                secondHits = hits
            end
        end
    end
    if best and bestHits >= 8 and bestHits > (secondHits or 0) then
        return best
    end
    return nil
end

-- returns: importedDiffCount, itemCount, err, usedSpec. The sim decides
-- where it lands: a sim for another CHARACTER is refused by name; a sim
-- for another SPEC of the target character is routed into that spec's
-- bucket (CSV: seed fingerprint; QE: the report's own spec stamp).
local function ApplySimImport(text, bucket, targetSpec, targetName, targetClassID, bucketForSpec)
    if not storesLinked then RelinkSpecStores() end
    if not char then return nil end
    bucket = bucket or simStore
    local baseline, byDiff, byLv, actorName, byConv, byPlain = ParseDroptimizerCSV(text)
    if not baseline then
        -- QE Live upgrade report (healers): percent-native buckets
        local qe, qeLv, repSpec, repPlayer = ParseQEReport(text)
        if qe then
            -- another character's report poisons the buckets - refuse
            if repPlayer and targetName and repPlayer:lower() ~= targetName:lower() then
                return nil, nil, ("This QE report belongs to %s (%s) - not to %s. Import it on that character."):format(
                    repPlayer, repSpec or "?", targetName)
            end
            -- same character, another spec: the report says which - route it
            local usedSpec = targetSpec
            local repID = ResolveSpecFromQEString(repSpec)
            if repID and targetSpec and repID ~= targetSpec and bucketForSpec then
                bucket = bucketForSpec(repID)
                usedSpec = repID
            end
            local diffs, items = 0, 0
            for diff, gains in pairs(qe) do
                bucket[diff] = { base = nil, t = time(), gains = gains, pct = true,
                                 lv = qeLv and qeLv[diff] or nil }
                diffs = diffs + 1
                for _, eg in pairs(gains) do
                    for _ in pairs(eg) do items = items + 1 end
                end
            end
            return diffs, items, nil, usedSpec
        end
        return nil
    end
    if actorName and targetName and actorName:lower() ~= targetName:lower() then
        return nil, nil, ("This sim is for %s - not for %s. Import it on that character."):format(
            actorName, targetName)
    end
    local usedSpec = targetSpec
    local det = DetectSpecFromSimItems(byDiff, targetClassID)
    if det and targetSpec and det ~= targetSpec and bucketForSpec then
        bucket = bucketForSpec(det)
        usedSpec = det
    end
    local diffs, items = 0, 0
    for diff, gains in pairs(byDiff) do
        bucket[diff] = { base = baseline, t = time(), gains = gains,
                         lv = byLv and byLv[diff] or nil,
                         cv = byConv and byConv[diff] or nil,
                         ca = byPlain and byPlain[diff] or nil }
        diffs = diffs + 1
        for _, encGains in pairs(gains) do
            for _ in pairs(encGains) do items = items + 1 end
        end
    end
    return diffs, items, nil, usedSpec
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
    -- pick the newest sim per difficulty. Two sim types live here:
    -- raidbots (absolute gains + baseline) and QE LIVE (healers: percent
    -- gains in gainPercent, NO baseline - simType 2 in WoWUtils' enum).
    local newest = {}
    for _, sim in pairs(sims) do
        if type(sim) == "table" and type(sim.items) == "table"
            and (type(sim.baseline) == "number" or sim.simType == 2) then
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
        local lvs = {}
        for itemId, entries in pairs(sim.items) do
            if type(entries) == "table" then
                for _, e in ipairs(entries) do
                    -- raidbots entries carry `gain` (absolute DPS), QE Live
                    -- entries carry `gainPercent` (healers) - accept either
                    local g = (type(e.gain) == "number" and e.gain)
                        or (type(e.gainPercent) == "number" and e.gainPercent) or nil
                    if e.difficultyId == d and g then
                        local src = type(e.sourceItem) == "table" and e.sourceItem or nil
                        local enc = (src and src.encounterId) or e.encounterId
                        local dropItem = (src and src.itemId) or itemId
                        if type(enc) == "number" and enc > 0 and type(dropItem) == "number" then
                            gains[enc] = gains[enc] or {}
                            local cur = gains[enc][dropItem]
                            if not cur or g > cur then gains[enc][dropItem] = g end
                            -- field name varies by WoWUtils version; all guarded
                            local elv = (type(e.itemLevel) == "number" and e.itemLevel)
                                or (type(e.level) == "number" and e.level)
                                or (type(e.ilvl) == "number" and e.ilvl) or nil
                            if elv then
                                local clv = lvs[dropItem]
                                if not clv or elv > clv then lvs[dropItem] = elv end
                            end
                        end
                    end
                end
            end
        end
        if next(gains) then
            -- QE Live buckets are percent-native: flag them so every
            -- readout formats "+1.2%" (there is no raw DPS to show)
            local isPct = (sim.simType == 2) or type(sim.baseline) ~= "number"
            simStore[d] = { base = type(sim.baseline) == "number" and sim.baseline or nil,
                            t = sim.simmedAt or time(), gains = gains, pct = isPct or nil,
                            lv = next(lvs) and lvs or nil }
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

-- NO auto-import from WoWUtils. It ran at login and on spec swap when the
-- spec's bucket was empty, and its "empty" check could not tell "the user
-- never imported" from "the user's manual import went to another bucket"
-- - it overwrote Arc's manual paste. WoWUtils data now arrives ONLY from
-- the explicit "Import from WoWUtils" button (Arc's call, 2026-09-06).

local function SimGainFor(diff, enc, itemID)
    local ev = char and simStore[diff]
    local g = ev and ev.gains[enc]
    return g and g[itemID] or nil
end

-- Set/tier TOKENS: the journal lists the token, but the Droptimizer often
-- prices only the RESULTING piece with no source reference (class-generic
-- "Use: create a set item" tokens). A simmed item at a boss that is NOT in
-- the boss's visible pool is by definition such a conversion result - its
-- best gain is the token's value.
local function OrphanTokenGain(diff, enc, poolDiff, ownedDiff)
    local ev = char and simStore[diff]
    local gains = ev and ev.gains[enc]
    if not gains then return nil end
    local pool = poolStore[poolDiff or diff] and poolStore[poolDiff or diff][enc]
    if not (pool and next(pool)) then return nil end
    local best
    for itemID, g in pairs(gains) do
        if pool[itemID] == nil and not IsOwnedItem(itemID, ownedDiff or diff)
            and (not best or g > best) then
            best = g
        end
    end
    return best
end

-- direct gain, else the token fallback (non-equipment journal items only).
-- poolDiff: the journal-pool bucket when the sim bucket is a vault one.
local function ItemGainFor(diff, enc, itemID, poolDiff, ownedDiff)
    local g = SimGainFor(diff, enc, itemID)
    if g == nil and IsTokenItem(itemID) then
        g = OrphanTokenGain(diff, enc, poolDiff, ownedDiff)
    end
    return g
end

-- THE one authority for a boss's roll EV: computed from the sim data
-- alone (sum of un-collected positive gains / count of un-collected sim
-- items). Never from the journal's shown list - the two disagree (tier
-- rows carry token itemIDs while sims carry the resulting pieces), which
-- made a boss's EV change depending on which page was open.
local function BossSimEV(enc, diff, ownedDiff, poolDiff)
    -- ownedDiff: the marks/won bucket when it differs from the sim bucket
    -- (M+ dungeons: sims under "mplusBonus", ownership under MPLUS_DIFF).
    -- poolDiff: the journal-pool bucket (vault sim buckets have no pools of
    -- their own - the coin draws from the REAL difficulty's loot table).
    ownedDiff = ownedDiff or diff
    poolDiff = poolDiff or diff
    local ev = char and simStore[diff]
    local gains = ev and ev.gains[enc]
    if not gains then return nil end
    -- with a cached journal pool, intersect: only items the boss actually
    -- drops count as outcomes (sim-only phantoms are excluded); a pool
    -- item the sim did not value contributes 0 but still dilutes
    local cache = poolStore[poolDiff] and poolStore[poolDiff][enc]
    local hadCache = cache and next(cache) ~= nil
    local sum, remaining = 0, 0
    if hadCache then
        for itemID in pairs(cache) do
            if not IsOwnedItem(itemID, ownedDiff) then
                remaining = remaining + 1
                local g = gains[itemID]
                if g and g > 0 then sum = sum + g end
            end
        end
    else
        for itemID, g in pairs(gains) do
            -- token-credited entries are handled once below as the boss
            -- token outcome; the omni never rolls at all
            if not IsTokenItem(itemID) then
                if not IsOwnedItem(itemID, ownedDiff) then
                    remaining = remaining + 1
                    if g > 0 then sum = sum + g end
                end
            end
        end
    end
    -- THE BOSS TOKEN outcome joins the pool (Arc's correction): the tier
    -- piece the coin can grant, which the journal pool never lists. In
    -- the no-cache branch a piece-keyed entry was already counted above.
    local piece, tGain, tOwned, _src, inGains = GetBossTokenOutcome(enc, diff, ownedDiff)
    -- never double-count: a piece that IS a pool item (or already counted
    -- from gains in the no-cache branch) is not an extra outcome
    if piece and not tOwned
        and ((hadCache and not cache[piece]) or (not hadCache and not inGains)) then
        remaining = remaining + 1
        if tGain and tGain > 0 then sum = sum + tGain end
    end
    if remaining > 0 and sum > 0 then
        return sum / remaining, remaining
    end
    return nil
end

-- Bonus-roll surfaces prefer the BONUS TRACK sim ("vaultN" bucket, from a
-- raid-vault Droptimizer) and fall back to the drop sim when none exists.
-- Drops surfaces always read the plain numeric bucket.
local function RollSimKey(diff)
    if type(diff) == "number" and simStore["vault" .. diff] then
        return "vault" .. diff
    end
    return diff
end

local function SimBaseFor(diff)
    local ev = char and simStore[diff]
    return ev and ev.base or nil
end

-- "+3,478" or, in percent mode, "+1.9%" (Raidbots' Relative DPS view)
local function FormatGainNumber(v, diff)
    -- QE Live buckets (healers) are percent-native: always show percent,
    -- there is no raw DPS number behind them
    local ev = char and simStore[diff]
    if ev and ev.pct then
        return ("%+.1f%%"):format(v)
    end
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

-- M+ mode: on DUNGEON journal pages every overlay is the Mythic+ bonus
-- roll layer - one pool for the whole dungeon - regardless of which
-- dungeon difficulty the journal is showing.
local function EJDungeonMode()
    return (EncounterJournal and EncounterJournal:IsShown()
        and EJ_InstanceIsRaid and not EJ_InstanceIsRaid()) and true or false
end

local function EJCurrentInstanceID()
    return EncounterJournal and EncounterJournal.instanceID or nil
end

local function EnsureLootPool()
    if lootPool then return end
    do
        lootPool = {}
        local dungeonMode = EJDungeonMode()
        local instID = dungeonMode and EJCurrentInstanceID() or nil
        local diffNow = (EJ_GetDifficulty and EJ_GetDifficulty()) or 0
        -- ownership in M+ mode lives under the canonical keystone key
        local ownDiff = dungeonMode and MPLUS_DIFF or diffNow
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
                    -- link, not just true: tooltips + the gear scan need it
                    fresh[info.encounterID][info.itemID] = info.link or true
                end
                if info.itemID and IsOwnedItem(info.itemID, ownDiff) then
                    pool.owned = pool.owned + 1
                elseif info.itemID then
                    -- un-collected: its sim gain feeds the boss's EV. M+
                    -- gains live in the per-dungeon "mplusBonus" bucket.
                    local gain
                    if dungeonMode then
                        gain = instID and SimGainFor("mplusBonus", instID, info.itemID) or nil
                    else
                        gain = SimGainFor(diffNow, info.encounterID, info.itemID)
                    end
                    if gain and gain > 0 then
                        pool.gainSum = pool.gainSum + gain
                    end
                end
            elseif info and info.encounterID and not info.displayAsPerPlayerLoot
                and info.itemID and IsTokenItem(info.itemID) and not OMNI_TOKENS[info.itemID] then
                -- SLOT TOKEN rows are coin outcomes too (only the omni never
                -- rolls), so the boss's token counts toward the live share
                -- (user report: two gear pieces read 50% and the token
                -- nothing). It stays OUT of the cached per-spec pool on
                -- purpose: BossSimEV adds the token's PIECE as its own
                -- outcome, and a token entry there would count it twice.
                local pool = lootPool[info.encounterID]
                if not pool then
                    pool = { total = 0, owned = 0, gainSum = 0 }
                    lootPool[info.encounterID] = pool
                end
                pool.total = pool.total + 1
                local owned = IsOwnedItem(info.itemID, ownDiff)
                if not owned then
                    local piece = TokenPieceFor(info.itemID)
                    if piece then owned = IsOwnedItem(piece, ownDiff) end
                end
                if owned then pool.owned = pool.owned + 1 end
            end
        end
        if fresh then
            if dungeonMode then
                -- dungeon pages list the whole dungeon's loot - but the loot
                -- list can BRIEFLY still hold another page's items while an
                -- instance switch streams in, and the Keystone aggregate
                -- page lists EVERY season dungeon at once. A blind merge
                -- accumulated all of that forever (the "dungeon wearing the
                -- whole season's loot" bug). So: validate every item against
                -- THIS dungeon's own boss list, REPLACE the pool on a
                -- full-dungeon view (self-heals old pollution), and only
                -- merge from single-boss (partial) views.
                if instID and instID ~= MPLUS_AGGREGATE_INSTANCE and next(fresh) then
                    local valid = {}
                    local vi = 1
                    while true do
                        local _, _, bossID = EJ_GetEncounterInfoByIndex(vi, instID)
                        if not bossID then break end
                        valid[bossID] = true
                        vi = vi + 1
                    end
                    if next(valid) then
                        local vetted = {}
                        for enc, set in pairs(fresh) do
                            if valid[enc] then
                                for itemID, v in pairs(set) do vetted[itemID] = v end
                            end
                        end
                        if next(vetted) then
                            poolStore.mplusBonus = poolStore.mplusBonus or {}
                            local fullView = not (EncounterJournal and EncounterJournal.encounterID)
                            local union = (not fullView) and (poolStore.mplusBonus[instID] or {}) or {}
                            for itemID, v in pairs(vetted) do
                                -- keep a link once we have one; never downgrade
                                if type(v) == "string" or not union[itemID] then
                                    union[itemID] = v
                                end
                            end
                            poolStore.mplusBonus[instID] = union
                        end
                    end
                end
            else
                -- CURRENT-raid pages only, raid difficulties only: browsing
                -- an old raid (or an oddball difficulty) must never write
                -- into the season pools - that is exactly how Kings' Rest
                -- bosses and a difficulty-2 bucket ended up inside them
                local viewInst = EJCurrentInstanceID()
                if viewInst and db and viewInst == db.currentRaidInst
                    and (diffNow == 14 or diffNow == 15 or diffNow == 16 or diffNow == 17) then
                    for enc, set in pairs(fresh) do
                        -- only replace a boss's cached pool with a COMPLETE
                        -- view of it (the list always carries a boss's full
                        -- table when the boss is present at all)
                        poolStore[diffNow] = poolStore[diffNow] or {}
                        poolStore[diffNow][enc] = set
                    end
                end
            end
        end
    end
end

local function GetEncounterPool(encID)
    if not encID then return nil end
    EnsureLootPool()
    return lootPool[encID]
end

-- the whole-dungeon pool: every boss's rollable loot summed - the M+
-- bonus roll draws from all of it at once
local function GetDungeonPool()
    EnsureLootPool()
    local agg = { total = 0, owned = 0 }
    for _, pool in pairs(lootPool) do
        agg.total = agg.total + pool.total
        agg.owned = agg.owned + pool.owned
    end
    return agg.total > 0 and agg or nil
end

-- ── Adventure Guide markers ─────────────────────────────────────────────────
local bossMarkers = {}   -- [bossButton] = marker
local itemMarkers = {}   -- [itemButton] = marker

-- icon split (Arc's call): the LOOT BAG tags drop-EV lines in the
-- Adventure Guide; the ALP BADGE (media\arc.tga) is the loot roll
-- window's mark ONLY
local LOOT_EV_ICON = "Interface\\GroupFrame\\UI-Group-MasterLooter"
-- the glowing chest logo (glow-keyed alpha; media\arc is the older ALP disc)
local ROLL_BADGE_ICON = "Interface\\AddOns\\ArcLootPlanner\\media\\arc_chest"

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
    if not char or not enc or not char.settings.ejOverlay or not EJViewAllowed()
        or char.settings.showShares == false then
        m:Hide()
        return
    end
    -- M+ plans are per DUNGEON (one pool, all bosses): the dungeon page's
    -- title coin owns planning there; boss rows carry no coins
    if EJDungeonMode() then
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
    -- ALWAYS from BossSimEV so the number is identical on every page.
    -- Bonus-roll surface: the vault-track sim wins when imported.
    local simKey = RollSimKey(diff)
    local evValue = BossSimEV(enc, simKey, diff, diff)
    m.ev:SetText(evValue and FormatGainNumber(evValue, simKey) or "")
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
    GameTooltip:SetText("Arc Loot Planner", 0.2, 0.8, 1)
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
        local simKey = RollSimKey(s.diff)
        local evValue, remaining = BossSimEV(s.enc, simKey, s.diff, s.diff)
        if evValue then
            GameTooltip:AddLine(("Roll EV: |cff4cde4c%s|r per coin, across the %d drops left."):format(
                FormatGainNumber(evValue, simKey), remaining), 0.7, 0.7, 0.7, true)
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
    -- Loot, slotless non-equipment, and rows whose data is still loading.
    -- EXCEPTION: a slotless TIER TOKEN row still prices - the sim values
    -- its conversion pieces, and the token is worth the best of them.
    local info = btn.index and C_EncounterJournal.GetLootInfoByIndex(btn.index) or nil
    local slotless = info and (not info.slot or info.slot == "")
    if not info or not info.name or info.displayAsPerPlayerLoot
        or (slotless and not IsTokenItem(btn.itemID)) then
        m:Hide()
        m.pct:Hide()
        if btn.name then btn.name:SetWidth(250) end   -- rows are pool-reused
        return
    end
    m:Show()
    local dungeonMode = EJDungeonMode()
    local diff = dungeonMode and MPLUS_DIFF or CurrentEJDifficulty()
    local owned, source = IsOwnedItem(btn.itemID, diff)
    m.state = { itemID = btn.itemID, enc = btn.encounterID, diff = diff,
                owned = owned, source = source, mplus = dungeonMode }
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
        m.pct2:Hide()
        m.pctIcon2:Hide()
        if btn.name then btn.name:SetWidth(250) end
    else
        -- not looted yet = GRAYED coin (still rollable, still pending);
        -- owned pieces carry the full-color coin + green check
        m.icon:SetTexture(CoinIconTexture())
        m.icon:SetDesaturated(true)
        m.icon:SetVertexColor(1, 1, 1, 1)
        m.check:Hide()
        m:SetAlpha(1)
        -- TWO tagged readouts so they can never be confused (Arc's call):
        -- [loot bag] drop EV from the DROPS sim, and [coin] the bonus-roll
        -- part - its EV from the vault/bonus sim when imported, plus the
        -- share (M+ share = 1 / drops left across the WHOLE dungeon). Each
        -- half follows its own Journal toggle.
        local showShares = char.settings.showShares ~= false
        local showGains = char.settings.showGains ~= false
        local pool = showShares and (dungeonMode and GetDungeonPool()
            or (btn.encounterID and GetEncounterPool(btn.encounterID) or nil)) or nil
        local remaining = pool and (pool.total - pool.owned) or 0
        local dropTxt = ""
        if showGains then
            local gain, gainDiff
            if dungeonMode then
                gain = SimGainFor("mplus", -1, btn.itemID)
                gainDiff = "mplus"
            else
                gain = ItemGainFor(diff, btn.encounterID, btn.itemID)
                gainDiff = diff
            end
            if gain and (gain >= 0.5 or gain <= -0.5) then
                local col = gain >= 0.5 and "|cff4cde4c" or "|cff8ca0b8"
                dropTxt = ("%s%s|r"):format(col, FormatGainNumber(gain, gainDiff))
            end
        end
        local bonusTxt = ""
        -- SLOT TOKEN rows wear the coin line too (Arc's in-game correction:
        -- each token boss's roll can grant its one token; only the OMNI
        -- never rolls, and it stays drop-priced only)
        local bKeyRaid = (not dungeonMode) and RollSimKey(diff) or nil
        -- a slot token IS a coin outcome. filterType is USELESS for this
        -- (TokenLab: every token reports Other/14) - the live signal is
        -- "slotless token, not per-player, not the omni"
        local rollsToken = (slotless and IsTokenItem(btn.itemID)
            and info and not info.displayAsPerPlayerLoot
            and not OMNI_TOKENS[btn.itemID]) or false
        if showShares and (not slotless or rollsToken) then
            local bGain, bKey
            if dungeonMode then
                local instID = EJCurrentInstanceID()
                bGain = instID and SimGainFor("mplusBonus", instID, btn.itemID) or nil
                bKey = "mplusBonus"
            else
                bKey = bKeyRaid
                -- only a real vault/bonus sim prices the coin part: the drop
                -- sim's number must never wear the coin
                if bKey ~= diff then bGain = SimGainFor(bKey, btn.encounterID, btn.itemID) end
                if rollsToken and not bGain and bKey ~= diff and btn.encounterID then
                    -- the token's value = the piece outcome's gain
                    local _pc, g = GetBossTokenOutcome(btn.encounterID, bKey, diff)
                    bGain = g
                end
            end
            if bGain and (bGain >= 0.5 or bGain <= -0.5) then
                local col = bGain >= 0.5 and "|cff4cde4c" or "|cff8ca0b8"
                bonusTxt = ("%s%s|r"):format(col, FormatGainNumber(bGain, bKey))
            end
            -- share: the LIVE journal pool (slot token included) follows the
            -- guide's class/spec filter, so it is the denominator whenever the
            -- boss has one; the sim's remaining count only stands in when the
            -- journal gave us no pool at all (user report: with a sim loaded
            -- the share ignored the loot-spec filter)
            local shareDen = remaining
            if not pool and not dungeonMode and btn.encounterID then
                local _bev, rr = BossSimEV(btn.encounterID, bKey, diff, diff)
                if rr and rr > 0 then shareDen = rr end
            end
            if shareDen > 0 then
                bonusTxt = bonusTxt .. (bonusTxt ~= "" and " " or "")
                    .. ("~%.0f%%"):format(100 / shareDen)
            end
        end
        -- fill the two column slots top-down: coin line first, bag line
        -- below - the icons stay in one aligned lane either way
        local lines = {}
        if bonusTxt ~= "" then lines[#lines + 1] = { icon = CoinIconTexture(), text = bonusTxt } end
        if dropTxt ~= "" then lines[#lines + 1] = { icon = LOOT_EV_ICON, text = dropTxt } end
        local slots = { { m.pctIcon, m.pct }, { m.pctIcon2, m.pct2 } }
        for i = 1, 2 do
            local e = lines[i]
            local icon, fs = slots[i][1], slots[i][2]
            if e then
                icon:SetTexture(e.icon)
                fs:SetText(e.text)
                icon:Show()
                fs:Show()
            else
                icon:Hide()
                fs:Hide()
            end
        end
        if btn.name then btn.name:SetWidth(lines[1] and 170 or 250) end
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
    GameTooltip:SetText("Arc Loot Planner", 0.2, 0.8, 1)
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
        local pool = s.mplus and GetDungeonPool()
            or (s.enc and GetEncounterPool(s.enc) or nil)
        local remaining = pool and (pool.total - pool.owned) or 0
        if remaining > 0 then
            GameTooltip:AddLine(s.mplus
                and ("One of %d drops left across the whole dungeon - the M+ bonus roll pool is every boss together."):format(remaining)
                or ("One of %d drops you can still receive here (once per difficulty)."):format(remaining), 0.7, 0.7, 0.7, true)
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
        -- the readout is a clean two-line COLUMN: icons aligned in their own
        -- lane (coin above, loot bag directly below), values beside them
        m.pctIcon = m:CreateTexture(nil, "OVERLAY")
        m.pctIcon:SetSize(13, 13)
        m.pctIcon:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -104, -6)
        m.pctIcon:Hide()
        m.pct = m:CreateFontString(nil, "OVERLAY")
        m.pct:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE")
        m.pct:SetPoint("LEFT", m.pctIcon, "RIGHT", 3, 0)
        m.pct:SetJustifyH("LEFT")
        m.pct:SetTextColor(0.25, 0.79, 0.95, 1)
        m.pctIcon2 = m:CreateTexture(nil, "OVERLAY")
        m.pctIcon2:SetSize(13, 13)
        m.pctIcon2:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -104, -22)
        m.pctIcon2:Hide()
        m.pct2 = m:CreateFontString(nil, "OVERLAY")
        m.pct2:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE")
        m.pct2:SetPoint("LEFT", m.pctIcon2, "RIGHT", 3, 0)
        m.pct2:SetJustifyH("LEFT")
        m.pct2:SetTextColor(0.25, 0.79, 0.95, 1)
        m:SetScript("OnClick", ItemMarkerClick)
        m:SetScript("OnEnter", ItemMarkerEnter)
        m:SetScript("OnLeave", function() GameTooltip:Hide() end)
        itemMarkers[btn] = m
    end
    ItemMarkerUpdate(m)
end

-- ── DUNGEON markers (Mythic+ bonus roll) ────────────────────────────────────
-- The M+ roll target is the DUNGEON: one coin next to the dungeon page's
-- title, and one on each tile of the Dungeons grid. Same verbs as a boss
-- coin - click plans the dungeon, right-click checks it off.
local dungeonMarker
local tileMarkers = {}   -- [instanceTileButton] = coin

local function DungeonAutoWouldCheck(instID)
    local pool = poolStore.mplusBonus and poolStore.mplusBonus[instID]
    if not (pool and next(pool)) then return false end
    for itemID in pairs(pool) do
        if not IsOwnedItem(itemID, MPLUS_DIFF) then return false end
    end
    return true
end

local function DungeonPlanState(instID)
    local week = CurrentWeek()
    local doneFlag = char.doneBosses[BossKey(instID, MPLUS_DIFF)]
    local doneManual = doneFlag == true
    local doneAuto = doneFlag == nil and DungeonAutoWouldCheck(instID)
    return { enc = instID, diff = MPLUS_DIFF, week = week,
             planned = IsPlanned(week, instID, MPLUS_DIFF),
             done = doneManual or doneAuto, doneManual = doneManual }
end

local function DungeonMarkerPaint(m, s)
    m.icon:SetTexture(CoinIconTexture())
    if s.done then
        m.icon:SetDesaturated(false)
        m.planRing:Hide()
        m.doneCheck:Show()
    else
        m.icon:SetDesaturated(not s.planned)
        m.planRing:SetShown(s.planned)
        m.doneCheck:Hide()
    end
end

local function DungeonMarkerClick(m, mouseButton)
    if not char or not m.state then return end
    local s = m.state
    local key = BossKey(s.enc, s.diff)
    if mouseButton == "RightButton" then
        if s.done then
            -- un-checking stores FALSE when the auto rule would instantly
            -- re-check, so the player's override sticks (the boss-coin rule)
            char.doneBosses[key] = DungeonAutoWouldCheck(s.enc) and false or nil
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
    RefreshEJ()
    UpdateCovers()
    if RefreshWindow then RefreshWindow() end
end

local function DungeonMarkerEnter(m)
    if not m.state then return end
    local s = m.state
    GameTooltip:SetOwner(m, "ANCHOR_RIGHT")
    GameTooltip:SetText("Arc Loot Planner", 0.2, 0.8, 1)
    if s.done then
        GameTooltip:AddLine(s.doneManual and "Checked off (Mythic+)."
            or "All M+ roll loot collected.", 0.3, 1, 0.3, true)
        GameTooltip:AddLine("Right-click: un-check.", 0.7, 0.7, 0.7)
    elseif s.planned then
        GameTooltip:AddLine("Planned this week (Mythic+ bonus roll).", 1, 0.85, 0.1)
        GameTooltip:AddLine("Click: unplan.  Right-click: check off.", 0.7, 0.7, 0.7)
    else
        GameTooltip:AddLine(("Click: plan %s for your M+ bonus rolls."):format(
            PlanEntryName(s.enc, MPLUS_DIFF)), 1, 1, 1, true)
        GameTooltip:AddLine("One pool: every boss's loot in this dungeon counts.", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("Right-click: check off (done rolling it).", 0.7, 0.7, 0.7)
    end
    if not s.done then
        local evValue, remaining = BossSimEV(s.enc, "mplusBonus", MPLUS_DIFF)
        if evValue then
            GameTooltip:AddLine(("Roll EV: |cff4cde4c%s|r per coin, across the %d drops left."):format(
                FormatGainNumber(evValue, "mplusBonus"), remaining), 0.7, 0.7, 0.7, true)
        end
    end
    GameTooltip:Show()
end

local function MakeDungeonCoin(parent, size)
    local m = CreateFrame("Button", nil, parent)
    m:SetSize(size, size)
    m:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    m.icon = m:CreateTexture(nil, "OVERLAY")
    m.icon:SetAllPoints()
    m.planRing = m:CreateTexture(nil, "OVERLAY", nil, 2)
    m.planRing:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    m.planRing:SetBlendMode("ADD")
    m.planRing:SetSize(size + 2, size + 2)
    m.planRing:SetPoint("CENTER")
    m.planRing:Hide()
    m.doneCheck = m:CreateTexture(nil, "OVERLAY", nil, 3)
    m.doneCheck:SetAtlas(TEX_CHECK)
    m.doneCheck:SetSize(size + 2, size + 2)
    m.doneCheck:SetPoint("CENTER", 1, -1)
    m.doneCheck:Hide()
    -- roll EV readout, boss-coin style: green number centered under the
    -- coin (the title marker re-anchors its own to the coin's right)
    m.ev = m:CreateFontString(nil, "OVERLAY")
    m.ev:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    m.ev:SetPoint("TOP", m, "BOTTOM", 0, -1)
    m.ev:SetTextColor(0.3, 0.87, 0.3, 1)
    m:SetScript("OnClick", DungeonMarkerClick)
    m:SetScript("OnEnter", DungeonMarkerEnter)
    m:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return m
end

local function UpdateDungeonMarker()
    local info = EncounterJournal and EncounterJournal.encounter
        and EncounterJournal.encounter.info
    local host = info and info.instanceTitle
    if not host then
        if dungeonMarker then dungeonMarker:Hide() end
        return
    end
    if not dungeonMarker then
        dungeonMarker = MakeDungeonCoin(info, 26)
        dungeonMarker:SetFrameLevel(info:GetFrameLevel() + 5)
        -- beside the coin here, not under it: the boss list starts right
        -- below the title line
        dungeonMarker.ev:ClearAllPoints()
        dungeonMarker.ev:SetPoint("LEFT", dungeonMarker, "RIGHT", 5, 0)
    end
    local instID = EJCurrentInstanceID()
    if not (char and instID and char.settings.ejOverlay
        and EJViewAllowed() and EJDungeonMode())
        or char.settings.showShares == false
        or instID == MPLUS_AGGREGATE_INSTANCE then
        dungeonMarker:Hide()
        dungeonMarker.ev:SetText("")
        return
    end
    dungeonMarker.state = DungeonPlanState(instID)
    -- hug the END of the dungeon's name: the title fontstring's RECT can be
    -- far wider than its text, so measure the string and anchor past it
    local nameW = (host.GetUnboundedStringWidth and host:GetUnboundedStringWidth())
        or host:GetStringWidth() or 0
    dungeonMarker:ClearAllPoints()
    dungeonMarker:SetPoint("LEFT", host, "LEFT", nameW + 12, 0)
    dungeonMarker:Show()
    DungeonMarkerPaint(dungeonMarker, dungeonMarker.state)
    local evValue = BossSimEV(instID, "mplusBonus", MPLUS_DIFF)
    dungeonMarker.ev:SetText(evValue and FormatGainNumber(evValue, "mplusBonus") or "")
end

-- the Dungeons GRID (instance select): a coin on every dungeon tile, so a
-- week can be planned straight from the season overview. Raid tiles keep
-- their per-boss planning and get nothing here.
local function DecorateInstanceTiles()
    local sel = EncounterJournal and EncounterJournal.instanceSelect
    local box = sel and sel.ScrollBox
    if not box then return end
    local raidTab = EncounterJournal_IsRaidTabSelected
        and EncounterJournal_IsRaidTabSelected(EncounterJournal)
    local show = char and char.settings.ejOverlay
        and char.settings.showOnDungeons == true and not raidTab
        and char.settings.showShares ~= false
    box:ForEachFrame(function(btn)
        local m = tileMarkers[btn]
        if not show or not btn.instanceID
            or btn.instanceID == MPLUS_AGGREGATE_INSTANCE then
            if m then m:Hide() end
            return
        end
        if not m then
            m = MakeDungeonCoin(btn, 22)
            -- below the name band (Arc's call: "second row"), so the coin
            -- never covers the end of a long dungeon name
            m:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -8, -36)
            m:SetFrameLevel(btn:GetFrameLevel() + 5)
            tileMarkers[btn] = m
        end
        m.state = DungeonPlanState(btn.instanceID)
        m:Show()
        DungeonMarkerPaint(m, m.state)
        -- per-dungeon roll EV, boss-coin style, straight from the imported
        -- M+ bonus roll Droptimizer for THIS dungeon
        local evValue = BossSimEV(btn.instanceID, "mplusBonus", MPLUS_DIFF)
        m.ev:SetText(evValue and FormatGainNumber(evValue, "mplusBonus") or "")
    end)
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
    tag:SetText("|cff3fc9f2Arc|r|cffd5e2f2 Loot Planner|r")
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
    UpdateDungeonMarker()
    DecorateInstanceTiles()
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
    -- the Dungeons/Raids grid: decorate its tiles whenever the list is
    -- (re)built - After(0) lets the ScrollBox finish laying frames out
    if EncounterJournal_ListInstances then
        hooksecurefunc("EncounterJournal_ListInstances", function()
            C_Timer.After(0, DecorateInstanceTiles)
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
            tooltip:AddLine(COLOR .. "Arc Loot Planner:|r won from a bonus roll " .. date("%Y-%m-%d", rec.t or 0), 0.4, 0.8, 1)
        end
    end)
end

-- ── Sim value on the group loot roll window ─────────────────────────────────
-- The [loot bag] drop value from the DROPS sim, painted onto the real
-- need/greed frames (GroupLootFrame1-4) when a roll is up - priced by the
-- instance you are standing in (raid difficulty bucket, or the M+ runs
-- bucket in a keystone). Read-only decoration: our own FontString on
-- Blizzard's frame, hooked OnShow, never touching their fields.
local lootRollTags = {}   -- [GroupLootFrame] = badge holder
local mockLootFrame       -- /alp lootroll placement tester
local lootRollForce = false   -- "/alp lootroll force": fake value on real
                              -- rolls with no sim data (resets on reload)
local rollMeasureFS       -- shared ruler for the wrap simulation below

-- Where does the item name's VISIBLE text end? A wrapped FontString only
-- reports its unwrapped width, so simulate the 125px greedy word wrap the
-- Name box performs and measure the LAST line. Returns width, lineCount.
local function NameLastLineWidth(nameFS, boxW)
    local text = nameFS and nameFS:GetText()
    if not text or text == "" then return 0, 1 end
    if not rollMeasureFS then
        rollMeasureFS = UIParent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        rollMeasureFS:Hide()
    end
    local fs = rollMeasureFS
    local function width(s)
        fs:SetText(s)
        return (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth())
            or fs:GetStringWidth() or 0
    end
    if width(text) <= boxW then return width(text), 1 end
    local lines, cur = 1, ""
    for word in text:gmatch("%S+") do
        local trial = (cur == "") and word or (cur .. " " .. word)
        if width(trial) <= boxW or cur == "" then
            cur = trial
        else
            lines = lines + 1
            cur = word
        end
    end
    return width(cur), lines
end

local function DropGainForHere(itemID)
    if not itemID or not char then return nil end
    local _, instanceType, difficultyID = GetInstanceInfo()
    if type(difficultyID) ~= "number" then return nil end
    if instanceType == "party" then
        local ev = simStore.mplus
        local g = ev and ev.gains[-1]
        local gain = g and g[itemID] or nil
        return gain, "mplus"
    end
    local ev = simStore[difficultyID]
    if ev then
        for _, gains in pairs(ev.gains) do
            local g = gains[itemID]
            if g then return g, difficultyID end
        end
        -- a TIER TOKEN roll: the token itself is never simmed - price it as
        -- the best un-collected conversion piece. Without a pool entry the
        -- token cannot be tied to one boss, so take the best orphan across
        -- this difficulty's bosses (close enough for a live roll readout).
        if IsTokenItem(itemID) then
            local pools = poolStore[difficultyID]
            if pools then
                local best
                for enc in pairs(pools) do
                    local g = OrphanTokenGain(difficultyID, enc)
                    if g and (not best or g > best) then best = g end
                end
                if best then return best, difficultyID end
            end
        end
    end
    return nil
end

local function DecorateLootRoll(frame)
    if not char then return end
    local plq = lootRollTags[frame]
    if char.settings.lootRollSim == false then
        if plq then plq:Hide() end
        return
    end
    if not plq then
        -- the ALP BADGE + value, floating right after the item name's text
        -- (no backdrop - the badge disc is the brand mark, Arc's call)
        plq = CreateFrame("Frame", nil, frame)
        plq:SetHeight(20)
        plq.icon = plq:CreateTexture(nil, "OVERLAY")
        plq.icon:SetSize(20, 20)   -- the chest needs a touch more room than the disc
        plq.icon:SetPoint("LEFT", 0, 0)
        plq.icon:SetTexture(ROLL_BADGE_ICON)
        plq.text = plq:CreateFontString(nil, "OVERLAY")
        plq.text:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE")
        plq.text:SetPoint("LEFT", plq.icon, "RIGHT", 4, 0)
        lootRollTags[frame] = plq
    end
    local gain = frame._arcTestGain
    local key = frame._arcTestGain and 15 or nil
    if gain == nil then
        local link = frame.rollID and GetLootRollItemLink
            and GetLootRollItemLink(frame.rollID) or nil
        gain, key = DropGainForHere(ItemIDFromLink(link))
    end
    if gain == nil and lootRollForce and frame.rollID then
        gain, key = 1234, 15   -- force mode: prove the tag on a REAL roll
    end
    if gain and (gain >= 0.5 or gain <= -0.5) then
        local col = gain >= 0.5 and "|cff4cde4c" or "|cff8ca0b8"
        plq.text:SetText(("%s%s|r"):format(col, FormatGainNumber(gain, key)))
        local tw = (plq.text.GetUnboundedStringWidth and plq.text:GetUnboundedStringWidth())
            or plq.text:GetStringWidth() or 40
        plq:SetWidth(20 + 4 + tw)
        -- hug the END of the item name's VISIBLE text: the wrap simulation
        -- finds the last rendered line's width, and a two-line name drops
        -- the badge to the second line's level
        plq:ClearAllPoints()
        if frame.Name then
            local lw, lines = NameLastLineWidth(frame.Name, 125)
            plq:SetPoint("LEFT", frame.Name, "LEFT",
                math.min(lw, 125) + 5, (lines >= 2) and -8 or 0)
        else
            plq:SetPoint("LEFT", frame, "LEFT", 190, 4)
        end
        plq:Show()
    else
        plq:Hide()
    end
end

for i = 1, 4 do
    local frame = _G["GroupLootFrame" .. i]
    if frame then
        frame:HookScript("OnShow", DecorateLootRoll)
    end
end

-- /alp lootroll: a REPLICA roll window for placement testing. The real
-- frame cannot be driven with a fake rollID (Blizzard's OnShow removes it
-- when the item lookup returns nothing), so the mock is built from the
-- same template with the scripts stripped and the buttons disabled.
local function ToggleMockLootRoll()
    if mockLootFrame and mockLootFrame:IsShown() then
        mockLootFrame:Hide()
        return
    end
    if not mockLootFrame then
        local f = CreateFrame("Frame", nil, UIParent, "GroupLootFrameTemplate")
        f:SetScript("OnShow", nil)
        f:SetScript("OnHide", nil)
        f:SetScript("OnEvent", nil)
        f:SetScript("OnUpdate", nil)
        f:UnregisterAllEvents()
        f:SetPoint("CENTER", 0, 120)
        f:SetFrameStrata("DIALOG")
        -- REAL look, neutered behavior: the buttons keep their full art
        -- (disabling desaturates them) but click nothing, and the icon's
        -- tooltip scripts go because they dereference a live rollID
        for _, b in ipairs({ f.NeedButton, f.GreedButton, f.PassButton, f.TransmogButton }) do
            if b then b:SetScript("OnClick", nil) end
        end
        if f.IconFrame then
            f.IconFrame:SetScript("OnEnter", nil)
            f.IconFrame:SetScript("OnLeave", nil)
            f.IconFrame:SetScript("OnUpdate", nil)
            f.IconFrame:SetScript("OnClick", nil)
        end
        -- a live frame shows Greed OR Transmog, never both
        if f.TransmogButton then f.TransmogButton:Hide() end
        if f.GreedButton then f.GreedButton:Show() end
        if f.Timer then
            f.Timer:SetMinMaxValues(0, 60000)
            f.Timer:SetValue(41000)
        end
        mockLootFrame = f
    end
    local f = mockLootFrame
    -- price it with the best real sim item we hold, so the readout is live
    local itemID, gain = nil, nil
    for _, d in ipairs({ 15, 16, 14, 17, "mplus" }) do
        local ev = simStore[d]
        if ev then
            for _, gains in pairs(ev.gains) do
                for id, g in pairs(gains) do
                    if g and (not gain or g > gain) then itemID, gain = id, g end
                end
            end
            if itemID then break end
        end
    end
    itemID = itemID or 6948   -- Hearthstone, when no sims are in yet
    f.IconFrame.Icon:SetTexture(C_Item.GetItemIconByID(itemID) or 134400)
    if f.IconFrame.Count then f.IconFrame.Count:Hide() end
    f.Name:SetText(C_Item.GetItemInfo(itemID) or "Test Item")
    -- the exact quality dressing Blizzard's OnShow applies (epic here)
    local quality = Enum.ItemQuality and Enum.ItemQuality.Epic or 4
    if ColorManager and ColorManager.GetAtlasDataForLootBorderItemQuality then
        local atlas = ColorManager.GetAtlasDataForLootBorderItemQuality(quality)
        if atlas and f.IconFrame.Border then f.IconFrame.Border:SetAtlas(atlas) end
    end
    local colorData = ColorManager and ColorManager.GetColorDataForItemQuality
        and ColorManager.GetColorDataForItemQuality(quality) or nil
    if colorData then
        f.Name:SetVertexColor(colorData.r, colorData.g, colorData.b)
        if f.Border then f.Border:SetVertexColor(colorData.r, colorData.g, colorData.b) end
    end
    f._arcTestGain = gain or 1234
    f:Show()
    DecorateLootRoll(f)
end

-- ── Sim import window ───────────────────────────────────────────────────────
-- The season's current raid: the instance we last saw a roll prompt in,
-- or the newest raid of the latest journal tier.
local function GetCurrentRaidInstanceID()
    -- the newest tier's raids ARE the season; the last roll-prompt
    -- instance is trusted only when it is one of them. A bonus roll in
    -- OLD content (farming Kings' Rest) used to hijack the whole page to
    -- that instance - TokenLab-proven: lastInstanceID=1041 put four
    -- Kings' Rest bosses where the Venomous Abyss belonged.
    local last = char and char.lastInstanceID
    local newest, lastIsCurrent
    if EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex then
        EJ_SelectTier(EJ_GetNumTiers())
        local i = 1
        while true do
            local id = EJ_GetInstanceByIndex(i, true)
            if not id then break end
            newest = id
            if last and id == last then lastIsCurrent = true end
            i = i + 1
        end
    end
    if lastIsCurrent then
        if db then db.currentRaidInst = last end
        return last
    end
    -- remember the season's raid whenever the walk is warm: the passive
    -- journal recorder gates its raid writes on this (browsing an OLD
    -- raid must never pollute the season pools)
    if newest and db then db.currentRaidInst = newest end
    -- cold data engine: fall back to last so the kick+retry cycle can
    -- heal us into the newest raid on a later pass
    return newest or last
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
-- The journal data engine IS the sources database - the same Journal
-- tables Raidbots' scripts extract from the client, live in-game. The
-- primer walks ALL of it headlessly at load: every newest-tier raid at
-- the four raid difficulties, every season dungeon at Mythic Keystone,
-- for EVERY spec of the player's class - so both overviews and the
-- journal overlays always have a confirmed pool without anyone opening
-- the guide. Runs only while the journal window is closed so it never
-- fights the real UI.
local PrimePoolCache   -- forward: refreshes, login timers and retries call it
do
    local primerActive = false
    local primerRetryQueued = false
    local primerScrubbed = false
    local primeFailed = {}      -- per-session: pages that served nothing; retried next login
    local primeLinkTried = {}   -- per-session: one link-upgrade visit per stamped page
    local PRIME_DIFFS = { 15, 16, 14, 17 }   -- 17 = Raid Finder rolls too
    -- bump to force one global re-prime after a harvest fix (":l3" = the
    -- stability-rule rework: a stamp only lands when a pass stops growing)
    local PRIME_EPOCH = ":l3"
    -- dungeon pages are asked at Keystone first, but some old-expansion
    -- season dungeons only serve loot at Mythic or Heroic headlessly
    -- (TokenLab-proven: Kings' Rest returns nothing at 8, everything at
    -- 23) - the item SET is identical across dungeon difficulties
    local DUNGEON_DIFFS = { 8, 23, 2 }

    -- the primer must not steer the journal's data engine while the real
    -- UI is using it - but "come back later" instead of giving up, so a
    -- first-install session still ends fully confirmed
    local function QueuePrimerRetry()
        if primerRetryQueued then return end
        primerRetryQueued = true
        C_Timer.After(15, function()
            primerRetryQueued = false
            PrimePoolCache()
        end)
    end

    local function EnsureSpecStore(specID)
        db.poolBySpec = db.poolBySpec or {}
        local s = db.poolBySpec[specID] or {}
        db.poolBySpec[specID] = s
        s.cache = s.cache or {}
        s.primedAt = s.primedAt or {}
        return s
    end

    -- every spec of the player's class, the current one first (the pages
    -- being looked at fill before the offspec stores do)
    local function ClassSpecList()
        local classID = select(3, UnitClass("player"))
        local cur = CurrentSpecID()
        local list = {}
        if cur then list[#list + 1] = cur end
        local getNum = C_SpecializationInfo and C_SpecializationInfo.GetNumSpecializationsForClassID
            or GetNumSpecializationsForClassID
        local getInfo = GetSpecializationInfoForClassID
            or (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoForClassID)
        local n = (classID and getNum) and getNum(classID) or 0
        for i = 1, n do
            local id = getInfo and getInfo(classID, i)
            if id and id ~= cur then list[#list + 1] = id end
        end
        return classID, list
    end

    local function SetJournalLootFilter(classID, specID)
        if EJ_SetLootFilter then EJ_SetLootFilter(classID or 0, specID or 0) end
    end

    -- a pool entry is `true` until a harvest attaches its LINK (the real
    -- per-difficulty item: tooltips, quality, the gear scan). Seeded and
    -- old entries start linkless - a STAMPED page that still holds any is
    -- re-visited once per session so links land on it too.
    local function HasLinkless(bucket, encsFilter)
        if not bucket then return false end
        if encsFilter then
            for enc in pairs(encsFilter) do
                local set = bucket[enc]
                if set then
                    for _, v in pairs(set) do
                        if v == true then return true end
                    end
                end
            end
            return false
        end
        for _, v in pairs(bucket) do
            if v == true then return true end
        end
        return false
    end

    -- one harvest PASS: read what the engine has streamed so far and merge
    -- it into the destination store (links preferred, never downgraded to
    -- true). Returns accepted gear rows, rows whose item data has not
    -- streamed yet (name still nil), and the set of what THIS pass saw -
    -- the stability rule and the reconcile both need them.
    local function PrimerHarvest(job)
        local n = (EJ_GetNumLoot and EJ_GetNumLoot()) or 0
        local accepted, coldRows = 0, 0
        local seen = {}
        local dest
        for i = 1, n do
            local info = C_EncounterJournal.GetLootInfoByIndex(i)
            if info and info.itemID then
                if not info.name then
                    coldRows = coldRows + 1
                elseif info.encounterID and not info.displayAsPerPlayerLoot
                    and info.slot and info.slot ~= "" then
                    accepted = accepted + 1
                    local cache = job.store.cache
                    if not dest then
                        if job.dungeon then
                            -- one flat pool per dungeon: every boss together
                            cache.mplusBonus = cache.mplusBonus or {}
                            dest = cache.mplusBonus[job.inst] or {}
                            cache.mplusBonus[job.inst] = dest
                        else
                            cache[job.diff] = cache[job.diff] or {}
                            dest = cache[job.diff]
                        end
                    end
                    -- MERGE, never wholesale-replace: the journal streams
                    -- loot in and a pass can catch a boss half-loaded -
                    -- replacing froze 3-of-4 pools forever
                    local slot = dest
                    if job.dungeon then
                        seen[info.itemID] = true
                    else
                        slot = dest[info.encounterID]
                        if not slot then
                            slot = {}
                            dest[info.encounterID] = slot
                        end
                        local se = seen[info.encounterID]
                        if not se then
                            se = {}
                            seen[info.encounterID] = se
                        end
                        se[info.itemID] = true
                    end
                    local v = info.link or true
                    if type(v) == "string" or slot[info.itemID] == nil then
                        slot[info.itemID] = v
                    end
                end
            end
        end
        return accepted, coldRows, seen
    end

    -- once a page proves FULLY streamed (stable pass, nothing cold), the
    -- pool is reconciled to exactly what the journal lists: stale items
    -- (removed by Blizzard, or junk merged in long ago) cannot linger.
    -- Raid reconciles only THIS instance's bosses - the difficulty bucket
    -- is shared by every raid of the tier.
    local function ReconcileJob(job, seen)
        local cache = job.store.cache
        if job.dungeon then
            local dest = cache.mplusBonus and cache.mplusBonus[job.inst]
            if dest then
                for itemID in pairs(dest) do
                    if not seen[itemID] then dest[itemID] = nil end
                end
            end
            return
        end
        local dest = cache[job.diff]
        if not (dest and job.encs) then return end
        for enc in pairs(job.encs) do
            local set = dest[enc]
            if set then
                local seenSet = seen[enc]
                if not seenSet then
                    dest[enc] = nil
                else
                    for itemID in pairs(set) do
                        if not seenSet[itemID] then set[itemID] = nil end
                    end
                end
            end
        end
    end

    -- one-time login scrub: the instance-hijack era and old recorder gaps
    -- left junk behind (Kings' Rest bosses inside the raid pools, stray
    -- difficulty buckets, stale stamps). Only runs against a WARM walk.
    local function ScrubStores(raidEncSet, raidSet, dungeonSet)
        for _, store in pairs(db.poolBySpec or {}) do
            local cache = type(store) == "table" and store.cache or nil
            if type(cache) == "table" then
                for k in pairs(cache) do
                    if not (k == "mplusBonus" or k == 14 or k == 15 or k == 16 or k == 17) then
                        cache[k] = nil
                    end
                end
                for _, d in ipairs(PRIME_DIFFS) do
                    local encs = cache[d]
                    if encs then
                        for enc in pairs(encs) do
                            if not raidEncSet[enc] then encs[enc] = nil end
                        end
                    end
                end
                if cache.mplusBonus then
                    for instID in pairs(cache.mplusBonus) do
                        if not dungeonSet[instID] then cache.mplusBonus[instID] = nil end
                    end
                end
            end
            if type(store) == "table" and type(store.primedAt) == "table" then
                for k, v in pairs(store.primedAt) do
                    if type(v) ~= "string" or not v:find(PRIME_EPOCH, 1, true) then
                        store.primedAt[k] = nil
                    end
                end
            end
        end
        if type(db.bossList) == "table" then
            for inst in pairs(db.bossList) do
                if not raidSet[inst] then db.bossList[inst] = nil end
            end
        end
    end

    PrimePoolCache = function()
        if primerActive or not char then return end
        if not storesLinked then RelinkSpecStores() end
        if EncounterJournal and EncounterJournal:IsShown() then QueuePrimerRetry() return end
        if not (EJ_SelectTier and EJ_GetNumTiers and EJ_GetInstanceByIndex
            and EJ_SelectInstance and EJ_SetDifficulty and C_EncounterJournal) then return end
        -- the newest tier IS the season: its raids plus its dungeon rotation
        EJ_SelectTier(EJ_GetNumTiers())
        local raids, dungeons, dungeonSet = {}, {}, {}
        local i = 1
        while true do
            local id = EJ_GetInstanceByIndex(i, true)
            if not id then break end
            raids[#raids + 1] = id
            i = i + 1
        end
        i = 1
        while true do
            local id = EJ_GetInstanceByIndex(i, false)
            if not id then break end
            if id ~= MPLUS_AGGREGATE_INSTANCE then
                dungeons[#dungeons + 1] = id
                dungeonSet[id] = true
            end
            i = i + 1
        end
        if #raids == 0 and #dungeons == 0 then QueuePrimerRetry() return end
        table.sort(dungeons)
        -- the dungeon stamps carry the season's rotation: a rotation change
        -- automatically invalidates every dungeon pool
        local seasonKey = table.concat(dungeons, "-") .. PRIME_EPOCH
        -- per-raid encounter walks: job building and the scrub both need
        -- them; a raid the engine has not streamed yet (0 bosses) is
        -- skipped this pass and picked up by a later primer call
        local raidSet, raidEncSet, raidEncCount, raidEncsByInst = {}, {}, {}, {}
        for _, inst in ipairs(raids) do
            raidSet[inst] = true
            local mine = {}
            raidEncsByInst[inst] = mine
            local c, bi = 0, 1
            while true do
                local nm, _, bid = EJ_GetEncounterInfoByIndex(bi, inst)
                if not nm or not bid then break end
                raidEncSet[bid] = true
                mine[bid] = true
                c = c + 1
                bi = bi + 1
            end
            raidEncCount[inst] = c
        end
        local currentRaid = GetCurrentRaidInstanceID()
        if not primerScrubbed and currentRaid and (raidEncCount[currentRaid] or 0) > 0 then
            primerScrubbed = true
            ScrubStores(raidEncSet, raidSet, dungeonSet)
        end
        local classID, specs = ClassSpecList()
        if #specs == 0 then return end
        local jobs = {}
        for _, specID in ipairs(specs) do
            local store = EnsureSpecStore(specID)
            for _, inst in ipairs(raids) do
                if (raidEncCount[inst] or 0) > 0 then
                    for _, d in ipairs(PRIME_DIFFS) do
                        local key = inst .. ":" .. d
                        local sk = specID .. ":" .. key
                        local fresh = store.primedAt[key] ~= PRIME_EPOCH
                        local relink = not fresh and not primeLinkTried[sk]
                            and HasLinkless(store.cache[d], raidEncsByInst[inst])
                        if (fresh or relink) and not primeFailed[sk] then
                            if relink then primeLinkTried[sk] = true end
                            jobs[#jobs + 1] = { spec = specID, store = store,
                                                inst = inst, diff = d, stamp = key,
                                                encs = raidEncsByInst[inst] }
                        end
                    end
                end
            end
            for _, instID in ipairs(dungeons) do
                local key = "m" .. instID
                local sk = specID .. ":" .. key
                local fresh = store.primedAt[key] ~= seasonKey
                local relink = not fresh and not primeLinkTried[sk]
                    and HasLinkless(store.cache.mplusBonus and store.cache.mplusBonus[instID])
                if (fresh or relink) and not primeFailed[sk] then
                    if relink then primeLinkTried[sk] = true end
                    jobs[#jobs + 1] = { spec = specID, store = store,
                                        inst = instID, diff = MPLUS_DIFF, dungeon = true,
                                        stamp = key, stampVal = seasonKey }
                end
            end
        end
        if #jobs == 0 then return end
        primerActive = true
        -- announce a real fill ONLY when the shipped seed does not cover
        -- this season (fresh season before the addon update lands): with a
        -- current seed the pages are already full and the fill is just
        -- silent link/verify housekeeping
        local seedCurrent = NS.PoolSeed and NS.PoolSeed.dungeons == table.concat(dungeons, "-")
        if #jobs >= 10 and not seedCurrent then
            print(("|cff3fc9f2Arc Loot Planner|r building the loot database in the background (%d journal pages) - it will report when done."):format(#jobs))
        end
        local idx = 0
        local stamped = 0
        local passes, lastAccepted = 0, -1
        local curFilterSpec
        local job
        local nextJob, passStep
        nextJob = function()
            idx = idx + 1
            job = jobs[idx]
            if not job then
                primerActive = false
                -- leave the journal's loot filter on the player's own spec
                SetJournalLootFilter(classID, CurrentSpecID())
                WipeLootPool()
                RefreshEJ()
                if RefreshWindow then RefreshWindow() end
                if stamped > 0 and not seedCurrent then
                    print(("|cff3fc9f2Arc Loot Planner|r loot database confirmed - %d journal pages across your specs."):format(stamped))
                end
                return
            end
            if curFilterSpec ~= job.spec then
                SetJournalLootFilter(classID, job.spec)
                curFilterSpec = job.spec
            end
            EJ_SelectInstance(job.inst)
            EJ_SetDifficulty(job.diff)
            passes, lastAccepted = 0, -1
            C_Timer.After(0.7, passStep)
        end
        passStep = function()
            if EncounterJournal and EncounterJournal:IsShown() then
                primerActive = false   -- the real UI took over; back off
                QueuePrimerRetry()     -- and finish once it is closed again
                return
            end
            passes = passes + 1
            local accepted, coldRows, seen = PrimerHarvest(job)
            -- STABILITY RULE (TokenLab-proven): loot streams in over
            -- several passes - names, slots, whole rows arrive late
            -- (Kings' Rest served ONE row on its first probe pass). A page
            -- is only stamped confirmed when a pass stops growing and
            -- nothing is left unstreamed; stamping on first contact is how
            -- pools froze half-full before.
            local stable = accepted > 0 and accepted == lastAccepted and coldRows == 0
            -- a page that is confidently EMPTY (no gear rows, nothing still
            -- streaming, three passes running) needs no full cap - move on
            -- to the difficulty fallback / next job early
            local emptyDone = accepted == 0 and coldRows == 0 and passes >= 3
            if not stable and not emptyDone and passes < 8 then
                lastAccepted = accepted
                C_Timer.After(0.7, passStep)
                return
            end
            if accepted > 0 then
                -- a cap-stamp (page never went stable) skips the reconcile:
                -- deleting against a half-streamed list would eat real loot
                if stable then ReconcileJob(job, seen) end
                job.store.primedAt[job.stamp] = job.stampVal or PRIME_EPOCH
                stamped = stamped + 1
                -- the open page fills in progressively as its spec's
                -- pools land
                if job.spec == CurrentSpecID() and RefreshWindow then RefreshWindow() end
            else
                -- dungeon page served nothing: walk the difficulty
                -- fallback chain before giving up on it
                if job.dungeon then
                    job.dt = (job.dt or 1) + 1
                    local fb = DUNGEON_DIFFS[job.dt]
                    if fb then
                        EJ_SetDifficulty(fb)
                        passes, lastAccepted = 0, -1
                        C_Timer.After(0.7, passStep)
                        return
                    end
                end
                -- nothing on any difficulty: leave unstamped, do not
                -- hammer it again this session
                primeFailed[job.spec .. ":" .. job.stamp] = true
            end
            C_Timer.After(0.2, nextJob)
        end
        nextJob()
    end
end

-- ── Options window (Arc theme, tabbed) ──────────────────────────────────────
-- Overview = a standalone replacement for the Adventure Guide view: the
-- whole raid's bosses with plan/done/rolled state and roll EVs, workable
-- without ever opening the journal. Protection / Journal / Sims hold the
-- settings; History is the ledger, bounded inside the window (the old
-- single-page layout let it spill past the frame).
local win
local pasteEB            -- Sims tab in-tab import (the pop-out window is gone)
local linkInput = ""

local OVERVIEW_DIFFS = {
    { value = 17, text = "Raid Finder" },
    { value = 14, text = "Normal" },
    { value = 15, text = "Heroic" },
    { value = 16, text = "Mythic" },
    { value = "mplusBonus", text = "Mythic+" },
}

-- the Drops Overview prices RAW drops: raid difficulties share the same sim
-- buckets (a drop and a coin give the identical item), Mythic+ uses the
-- end-of-run sim instead of the bonus track
local DROPS_DIFFS = {
    { value = 17, text = "Raid Finder" },
    { value = 14, text = "Normal" },
    { value = 15, text = "Heroic" },
    { value = 16, text = "Mythic" },
    { value = "mplus", text = "Mythic+ runs" },
}

-- ── Drops Overview slot filter (feature-want 1552310662) ─────────────────
-- One table: the ordered slot list (dropdown items) plus the matcher. A slot
-- other than "all" makes the Drops list expand EVERY boss and show only that
-- slot's items, hiding bosses with none. Inventory types come from
-- C_Item.GetItemInventoryTypeByID (InventoryType enum, Head = 1); "token"
-- catches slotless tier tokens via IsTokenItem. Twin of ArcUI's SlotFilter.
local SlotFilter = {
    list = {
        { key = "all",      text = "All Slots" },
        { key = "head",     text = "Head",     inv = { "IndexHeadType" } },
        { key = "neck",     text = "Neck",     inv = { "IndexNeckType" } },
        { key = "shoulder", text = "Shoulder", inv = { "IndexShoulderType" } },
        { key = "back",     text = "Back",     inv = { "IndexCloakType" } },
        { key = "chest",    text = "Chest",    inv = { "IndexChestType", "IndexRobeType" } },
        { key = "wrist",    text = "Wrist",    inv = { "IndexWristType" } },
        { key = "hands",    text = "Hands",    inv = { "IndexHandType" } },
        { key = "waist",    text = "Waist",    inv = { "IndexWaistType" } },
        { key = "legs",     text = "Legs",     inv = { "IndexLegsType" } },
        { key = "feet",     text = "Feet",     inv = { "IndexFeetType" } },
        { key = "finger",   text = "Finger",   inv = { "IndexFingerType" } },
        { key = "trinket",  text = "Trinket",  inv = { "IndexTrinketType" } },
        { key = "weapon",   text = "Weapons",
          inv = { "IndexWeaponType", "Index2HweaponType", "IndexWeaponmainhandType",
                  "IndexWeaponoffhandType", "IndexRangedType", "IndexRangedrightType",
                  "IndexThrownType" } },
        { key = "offhand",  text = "Off Hand", inv = { "IndexShieldType", "IndexHoldableType" } },
        { key = "token",    text = "Tier Tokens", token = true },
    },
    items = {},   -- { value = key, text = text } for AT.MakeDropdown
}
for _, d in ipairs(SlotFilter.list) do
    SlotFilter.items[#SlotFilter.items + 1] = { value = d.key, text = d.text }
end
function SlotFilter.Matches(itemID, key)
    if not key or key == "all" then return true end
    local def
    for _, d in ipairs(SlotFilter.list) do
        if d.key == key then def = d break end
    end
    if not def then return true end
    if def.token then return IsTokenItem(itemID) end
    if not (itemID and C_Item and C_Item.GetItemInventoryTypeByID and Enum and Enum.InventoryType) then
        return false
    end
    local inv = C_Item.GetItemInventoryTypeByID(itemID)
    if inv == nil then return false end
    for _, name in ipairs(def.inv or {}) do
        if Enum.InventoryType[name] == inv then return true end
    end
    return false
end
function SlotFilter.Current()
    local v = char and char.settings and char.settings.dropsSlot
    return (type(v) == "string" and v ~= "") and v or "all"
end

-- current season dungeon list: live from the journal engine when it is free
-- (we select the newest tier ourselves so an open journal on an old
-- expansion can never mislead it), else the STATIC copy from a past success
local function GetSeasonDungeonList()
    local entries = {}
    if not (EncounterJournal and EncounterJournal:IsShown())
        and EJ_SelectTier and EJ_GetNumTiers and EJ_GetInstanceByIndex then
        EJ_SelectTier(EJ_GetNumTiers())
        local i = 1
        while true do
            local id, nm = EJ_GetInstanceByIndex(i, false)
            if not id then break end
            if id ~= MPLUS_AGGREGATE_INSTANCE then
                entries[#entries + 1] = { id = id, name = nm }
            end
            i = i + 1
        end
    end
    if #entries > 0 then
        db.dungeonList = entries
    elseif db.dungeonList then
        -- scrub the aggregate from cached lists saved before the filter
        entries = {}
        for _, e in ipairs(db.dungeonList) do
            if e.id ~= MPLUS_AGGREGATE_INSTANCE then entries[#entries + 1] = e end
        end
    end
    return entries
end

local function StatusRow(pg, textFn, h, visibleFn)
    local row = AT.AddRow(pg, h or 20, visibleFn)
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
            local wouldAuto
            if s.mplus then
                wouldAuto = DungeonAutoWouldCheck(s.enc)
            else
                wouldAuto = AutoWouldCheck(s.enc, s.diff)
            end
            char.doneBosses[key] = wouldAuto and false or nil
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
        GameTooltip:AddLine(("Click: plan this %s (%s)."):format(
            s.mplus and "dungeon" or "boss", diff), 1, 1, 1)
        if s.mplus then
            GameTooltip:AddLine("One pool: every boss's loot in this dungeon counts.", 0.7, 0.7, 0.7, true)
        end
        GameTooltip:AddLine("Right-click: check off (done rolling it).", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

local function OverviewRowClick(self)
    local pg = self.pg
    local s = self.state
    if not (pg and s) then return end
    if s.topHeader then
        -- the Drops view's Top 5 section opens and shuts on its header
        char.settings.dropsTopShut = not char.settings.dropsTopShut or nil
        if pg.Refresh then pg:Refresh() end
        return
    end
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

-- ── Sim-ilvl tooltip links ──────────────────────────────────────────────────
-- TokenLab-proven: a SINGLE bonus id from the season's level-set family
-- makes any item link render at that exact level (12846 -> 321 on a
-- base-19 probe item), and GetDetailedItemLevelInfo computes synthetic
-- links client-side. The right id per level is DISCOVERED at runtime by
-- asking the client to render candidates - nothing is shipped, nothing
-- can rot; a failed scan just falls back to the base preview.
local ResolveIlvlBonus
do
    local PROBE_ITEM = 159288   -- base ilvl 19: any season-level hit is unambiguous
    local SCAN_RANGES = { { 12700, 13000 }, { 13300, 13950 }, { 12000, 12700 } }
    local cache = {}            -- [lv] = bonusID, or false = scanned, none found
    local probeReady
    ResolveIlvlBonus = function(lv)
        if type(lv) ~= "number" then return nil end
        local hit = cache[lv]
        if hit ~= nil then return hit or nil end
        local getIlvl = C_Item and C_Item.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo
        if not getIlvl then return nil end
        if not probeReady then
            -- the probe item must be item-cached or every render reads nil
            if not getIlvl("item:" .. PROBE_ITEM) then
                local obj = Item:CreateFromItemID(PROBE_ITEM)
                obj:ContinueOnItemLoad(function() probeReady = true end)
                return nil   -- warms in a moment; the next hover resolves
            end
            probeReady = true
        end
        local me = UnitLevel("player") or 80
        for _, range in ipairs(SCAN_RANGES) do
            for b = range[1], range[2] do
                local il = getIlvl(("item:%d::::::::%d::::1:%d"):format(PROBE_ITEM, me, b))
                if il == lv then
                    cache[lv] = b
                    return b
                end
            end
        end
        cache[lv] = false
        return nil
    end
end

local function OverviewItemTooltip(self)
    local s = self.state
    if not s then return end
    -- cursor-anchored: the rows span the whole list, so ANCHOR_RIGHT put
    -- the tooltip a full row-width away from the pointer
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT", 12, -6)
    -- any row with a known sim level gets the REAL tooltip at that level
    -- via a client-verified synthetic link - UNLESS the stored journal
    -- link already renders it (raid drops pages: the link IS the right
    -- version, and its native bonus set beats a synthetic one). Covers
    -- M+ (journal only serves base-Mythic) AND vault-priced raid rows
    -- (the coin grants the vault track, not the page's difficulty).
    local synthetic
    if s.simLv then
        local getIlvl = C_Item and C_Item.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo
        local linkLv = (s.link and getIlvl) and getIlvl(s.link) or nil
        if linkLv ~= s.simLv then
            local b = ResolveIlvlBonus(s.simLv)
            if b then
                -- the link's specialization field decides which primary stat a
                -- multi-stat item highlights; empty = the item's first stat, so
                -- a warrior read Agility/Intellect in white (Discord 1552232083).
                -- Fill it with the player's spec, exactly like an equipped link.
                GameTooltip:SetHyperlink(("item:%d::::::::%d:%d:::1:%d"):format(
                    s.itemID, UnitLevel("player") or 80, CurrentSpecID() or 0, b))
                GameTooltip:AddLine(("Shown at your sim's item level (%d)."):format(s.simLv), 0.25, 0.79, 0.95, true)
                synthetic = true
            end
        end
    end
    if not synthetic then
        -- the stored journal link carries THIS difficulty's real item
        -- level; a bare itemID would show the base (wrong-track) version
        if s.link then
            GameTooltip:SetHyperlink(s.link)
        else
            GameTooltip:SetItemByID(s.itemID)
            -- a bare itemID previews the BASE version only (an
            -- old-expansion dungeon item renders as low-level trash)
            if s.diff == MPLUS_DIFF then
                GameTooltip:AddLine("Base preview - the actual Mythic+ drop is a higher item level.", 0.55, 0.63, 0.76, true)
            end
        end
        if s.simLv then
            GameTooltip:AddLine(("Your sim priced this at item level %d."):format(s.simLv), 0.25, 0.79, 0.95, true)
        end
    end
    if s.simConv then
        -- the shown value comes from CONVERTING this drop (catalyst /
        -- token): say what it becomes, and what it sims uncatalyzed
        local convName = C_Item.GetItemInfo(s.simConv)
        GameTooltip:AddLine(("Best used through the Catalyst - becomes %s."):format(
            convName or "your set piece"), 0.25, 0.79, 0.95, true)
        if s.simAsTxt then
            GameTooltip:AddLine(("As dropped it sims %s - the shown value is the catalyzed use."):format(
                s.simAsTxt), 0.55, 0.63, 0.76, true)
        end
    end
    if s.owned then
        GameTooltip:AddLine(s.source == "manual"
            and "Checked off. Click to un-check." or "Won from a recorded roll.", 0.3, 1, 0.3, true)
    else
        GameTooltip:AddLine("Click: check off as already received on this difficulty.", 0.7, 0.7, 0.7, true)
    end
    GameTooltip:Show()
end

-- Scan gear from the OVERVIEW: works off the STORED pool links (equipped,
-- bags, transmog), so unlike the journal button it needs no open guide and
-- covers every boss/dungeon of the current view at once. Pool entries
-- saved before link storage cannot be scanned until the guide refreshes
-- them - the result line says so.
local function OverviewScan(pg)
    if not char then return end
    local diff = (pg.mode == "drops") and (char.settings.dropsDiff or 15)
        or (char.settings.ovDiff or 15)
    local ownDiff = (diff == "mplusBonus" or diff == "mplus") and MPLUS_DIFF or diff
    WipeDetectCache()
    -- M+ run drops share the bonus pools' item sets (same dungeons)
    local pools = poolStore[diff] or (diff == "mplus" and poolStore.mplusBonus or nil)
    local found, unscannable = 0, 0
    if pools then
        for _, set in pairs(pools) do
            for itemID, v in pairs(set) do
                if not IsOwnedItem(itemID, ownDiff) then
                    if type(v) == "string" then
                        if DetectOwnedByLink(v, itemID) then
                            char.itemMarks[itemID] = char.itemMarks[itemID] or {}
                            char.itemMarks[itemID][ownDiff] = time()
                            found = found + 1
                        end
                    else
                        unscannable = unscannable + 1
                    end
                end
            end
        end
    end
    WipeLootPool()
    RefreshEJ()
    if RefreshWindow then RefreshWindow() end
    local msg = ("Scan: |cff4cde4c%d|r newly checked off%s"):format(found,
        unscannable > 0
            and (" (%d items need a fresh look - browse this content in the Adventure Guide once, then rescan)"):format(unscannable)
            or "")
    C_Timer.After(0.1, function()
        if pg:IsShown() and pg.hint then pg.hint:SetText(msg) end
    end)
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
    row.simHint:SetScript("OnClick", function()
        if win and win.SelectTab then win.SelectTab("Sim Import") end
    end)
    row.simHint:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("No sim value yet", 0.2, 0.8, 1)
        GameTooltip:AddLine("Import a Droptimizer sim and this boss shows its real roll value in DPS. Click to open the Sim Import tab.", 1, 1, 1, true)
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
    it.icon = it:CreateTexture(nil, "ARTWORK")
    it.icon:SetSize(18, 18)
    it.icon:SetPoint("LEFT", 4, 0)
    -- the item tooltip only when hovering the ICON itself (Arc's call);
    -- the hit frame forwards clicks so the whole row still toggles owned
    it.iconHit = CreateFrame("Button", nil, it)
    it.iconHit:SetAllPoints(it.icon)
    it.iconHit:RegisterForClicks("LeftButtonUp")
    it.iconHit:SetScript("OnClick", function() OverviewItemClick(it) end)
    it.iconHit:SetScript("OnEnter", function() OverviewItemTooltip(it) end)
    it.iconHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- hover affordance IN the row, not a floaty tooltip: an unowned row
    -- previews a GHOST check over its icon (the exact mark a click will
    -- set) and the row highlights - the universal "click to check off"
    -- cue. The bottom hint line and the icon tooltip carry the words.
    it:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
    it:GetHighlightTexture():SetVertexColor(
        AT.COL.arcDeep[1], AT.COL.arcDeep[2], AT.COL.arcDeep[3], 0.3)
    it.ghost = it:CreateTexture(nil, "OVERLAY")
    it.ghost:SetAtlas(TEX_CHECK)
    it.ghost:SetSize(18, 18)
    it.ghost:SetPoint("CENTER", it.icon, "CENTER", 1, -1)
    it.ghost:SetAlpha(0.4)
    it.ghost:Hide()
    local function GhostEnter()
        local s = it.state
        if s and not s.owned then it.ghost:Show() end
    end
    local function GhostLeave() it.ghost:Hide() end
    it:SetScript("OnEnter", GhostEnter)
    it:SetScript("OnLeave", GhostLeave)
    -- the icon's own hit frame eats mouse events; mirror the cue there
    it.iconHit:HookScript("OnEnter", GhostEnter)
    it.iconHit:HookScript("OnLeave", GhostLeave)
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
    -- top-upgrade RANK (Drops view): a gold 1-5 left of the gain, the same
    -- language as the boss rows' BEST tag
    it.rank = it:CreateFontString(nil, "OVERLAY")
    it.rank:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    it.rank:SetPoint("RIGHT", it.gain, "LEFT", -8, 0)
    it.rank:SetTextColor(1, 0.85, 0.1, 1)
    it.rank:Hide()
    pg.itemRows[idx] = it
    return it
end

local function OverviewRefresh(pg)
    if not char then return end
    PrimePoolCache()   -- self-heals a missing pool in the background
    local diff = char.settings.ovDiff or 15
    -- Mythic+ mode: rows are DUNGEONS, one pool each. `diff` doubles as the
    -- sim/pool bucket key ("mplusBonus"); plans/marks/ownership live under
    -- the canonical keystone difficulty instead.
    local mplusMode = diff == "mplusBonus"
    local ownDiff = mplusMode and MPLUS_DIFF or diff
    local week = CurrentWeek()
    local count = BonusRollsAvailable()
    pg.rolls:SetText(count and ("Bonus rolls: |cffffd100%d|r"):format(count) or "Bonus rolls: ?")
    if pg.pctCb then pg.pctCb:SetOn(char.settings.evPercent) end
    -- bonus-roll surface: the vault-track sim wins when imported, the drop
    -- sim is the fallback (mplus mode already reads its own bucket)
    local simKey = mplusMode and diff or RollSimKey(diff)
    -- no sim for this difficulty: pull the list down a notch and show the
    -- import banner in the gap (clicking it opens the importer)
    local haveSim = simStore[simKey] ~= nil
    if pg.simNotice then
        pg.simNotice:SetShown(not haveSim)
        if not haveSim then
            pg.simNotice.fs:SetText(("|T%d:14|t |cff3fc9f2Sim your character|r to price this page - no %s sim for %s yet. Click to import one."):format(
                CoinIconTexture(), mplusMode and "Mythic+ bonus roll" or DifficultyName(diff), CurrentSpecName()))
        end
        pg.listScroll:SetPoint("TOPLEFT", 0, haveSim and -34 or -62)
    end
    pg.listContent:SetWidth(math.max(200, pg.listScroll:GetWidth() or 0))
    local inst = (not mplusMode) and GetCurrentRaidInstanceID() or nil
    local shown, itemsShown = 0, 0
    local bestIdx, bestEV
    local y = 0
    -- live list when the journal engine is free, else the STATIC copy saved
    -- from an earlier success - the page must never depend on which tab the
    -- Adventure Guide is parked on
    local entries
    if mplusMode then
        entries = GetSeasonDungeonList()
    elseif inst and EJ_GetEncounterInfoByIndex then
        local bosses = {}
        local i = 1
        while true do
            local nm, _, id = EJ_GetEncounterInfoByIndex(i, inst)
            if not nm or not id then break end
            bosses[#bosses + 1] = { id = id, name = nm }
            i = i + 1
        end
        if #bosses > 0 then
            db.bossList = db.bossList or {}
            db.bossList[inst] = bosses
        elseif db.bossList and db.bossList[inst] then
            bosses = db.bossList[inst]
        end
        entries = bosses
    end
    if entries then
        for _, boss in ipairs(entries) do
            local bossName, bossID = boss.name, boss.id
            shown = shown + 1
            local row = pg.rows[shown] or CreateOverviewRow(pg, shown)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, y)
            row:SetPoint("TOPRIGHT", 0, y)
            y = y - 30
            local key = BossKey(bossID, ownDiff)
            local flag = char.doneBosses[key]
            local doneManual = flag == true
            local evValue = BossSimEV(bossID, simKey, ownDiff, diff)
            -- the confirmed pool works with no sim at all: it counts what
            -- this boss's coin can still give (once-per-difficulty rule)
            local pool = poolStore[diff] and poolStore[diff][bossID]
            local poolTotal, poolLeft = 0, 0
            if pool then
                for itemID in pairs(pool) do
                    poolTotal = poolTotal + 1
                    if not IsOwnedItem(itemID, ownDiff) then poolLeft = poolLeft + 1 end
                end
            end
            local doneAuto = false
            if flag == nil and not evValue and simStore[simKey] then
                local gains = simStore[simKey].gains[bossID]
                if gains and next(gains) then
                    local anyLeft = false
                    for itemID in pairs(gains) do
                        if not IsOwnedItem(itemID, ownDiff) then anyLeft = true break end
                    end
                    doneAuto = not anyLeft
                end
            end
            if flag == nil and poolTotal > 0 and poolLeft == 0 then
                doneAuto = true   -- pool exhausted = the coin has nothing left
            end
            local done = doneManual or doneAuto
            local planned = IsPlanned(week, bossID, ownDiff)
            local selected = pg.selectedEnc == bossID
            row.state = { enc = bossID, diff = ownDiff, week = week, name = bossName,
                          planned = planned, done = done, autoWould = doneAuto,
                          mplus = mplusMode }
            local img
            if mplusMode then
                img = select(6, EJ_GetInstanceInfo(bossID))   -- the dungeon's tile image
            else
                img = select(5, EJ_GetCreatureInfo(1, bossID))
            end
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
            row.rolled:SetShown(GetRollRecord(week, bossID, ownDiff) ~= nil)
            if evValue then
                row.ev:SetText(FormatGainNumber(evValue, simKey))
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
                local ev = simStore[simKey]
                local gains = ev and ev.gains[bossID]
                local cache = poolStore[diff] and poolStore[diff][bossID]
                local list, remaining = {}, 0
                if cache and next(cache) then
                    for itemID, v in pairs(cache) do
                        list[#list + 1] = { itemID = itemID, gain = gains and gains[itemID] or nil,
                                            link = (type(v) == "string") and v or nil }
                        if not IsOwnedItem(itemID, ownDiff) then remaining = remaining + 1 end
                    end
                elseif gains and next(gains) then
                    for itemID, g in pairs(gains) do
                        if not IsTokenItem(itemID) then
                            list[#list + 1] = { itemID = itemID, gain = g }
                            if not IsOwnedItem(itemID, ownDiff) then remaining = remaining + 1 end
                        end
                    end
                end
                -- the boss's set token rolls too (Arc's correction): shown
                -- as the PIECE it becomes for this spec, never the token
                -- (in the no-cache branch a piece-keyed sim entry already
                -- listed itself as a plain row)
                if not mplusMode then
                    local hadCache = cache and next(cache) ~= nil
                    local piece, tGain, tOwned, _src, inGains = GetBossTokenOutcome(bossID, simKey, ownDiff)
                    -- never duplicate: skip when the piece is already a pool
                    -- row (or a plain gains row in the no-cache branch)
                    if piece and ((hadCache and not cache[piece]) or (not hadCache and not inGains)) then
                        list[#list + 1] = { itemID = piece, tokenOutcome = true, gain = tGain }
                        if not tOwned then remaining = remaining + 1 end
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
                        local owned, source = IsOwnedItem(entry.itemID, ownDiff)
                        local cvPiece = ev and ev.cv and ev.cv[entry.itemID]
                        local caGain = cvPiece and ev.ca and ev.ca[entry.itemID] or nil
                        it.state = { itemID = entry.itemID, diff = ownDiff, owned = owned,
                                     source = source, link = entry.link,
                                     simLv = ev and ev.lv and ev.lv[entry.itemID],
                                     simConv = cvPiece,
                                     simAsTxt = caGain and FormatGainNumber(caGain, simKey) or nil }
                        it.icon:SetTexture(C_Item.GetItemIconByID(entry.itemID) or 134400)
                        it.check:SetShown(owned)
                        it.ghost:Hide()
                        it.rank:Hide()
                        it.name:SetText(OverviewItemName(pg, entry.itemID)
                            .. (cvPiece and "  |cff8ca0b8(Catalyst)|r" or ""))
                        if owned then
                            it.share:SetText("")
                            it.gain:SetText("")
                        else
                            it.share:SetText(remaining > 0 and ("~%.0f%%"):format(100 / remaining) or "")
                            if entry.gain then
                                it.gain:SetText(FormatGainNumber(entry.gain, simKey))
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
                    it.rank:Hide()
                    it.name:SetText(mplusMode
                        and "|cff8ca0b8Confirming this dungeon's pool from the game's journal data - a few seconds...|r"
                        or "|cff8ca0b8Confirming this boss's pool from the game's journal data - a few seconds...|r")
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
                    it.rank:Hide()
                    it.name:SetText("|cff8ca0b8Sim-priced list - confirming the full pool from the game's journal data...|r")
                    it.share:SetText("")
                    it.gain:SetText("")
                    it:Show()
                end
            end
        end
    end
    if bestIdx and pg.rows[bestIdx] then pg.rows[bestIdx].best:Show() end
    for k = shown + 1, #pg.rows do pg.rows[k]:Hide() end
    for k = itemsShown + 1, #pg.itemRows do pg.itemRows[k]:Hide() end
    pg.listContent:SetHeight(math.max(1, -y + 4))
    pg.listScroll:UpdateScroll()
    if shown == 0 then
        -- the journal's data engine has not streamed this list yet (right
        -- after login, or the Adventure Guide is parked elsewhere). Kick it
        -- awake when the real journal is closed, and KEEP retrying while
        -- the page is up. Kick EVEN when inst is unknown: discovering the
        -- instance NEEDS the tier data awake, so gating the kick (or the
        -- retry) on inst was a circular dead-end - the page sat on
        -- "Loading the raid list..." forever on a cold character.
        local ejBusy = EncounterJournal and EncounterJournal:IsShown()
        if not ejBusy and not mplusMode
            and EJ_SelectTier and EJ_GetNumTiers then
            EJ_SelectTier(EJ_GetNumTiers())
            if inst and EJ_SelectInstance then EJ_SelectInstance(inst) end
        end
        pg._loadRetries = (pg._loadRetries or 0) + 1
        local delay = ejBusy and 2 or (pg._loadRetries > 6 and 3 or 0.8)
        C_Timer.After(delay, function()
            if pg:IsShown() then OverviewRefresh(pg) end
        end)
        pg.hint:SetText(ejBusy
            and "Waiting for the Adventure Guide to free up the journal data..."
            or (mplusMode and "Loading the dungeon list..." or "Loading the raid list..."))
    else
        pg._loadRetries = nil
        pg.hint:SetText(shown > 0
            and (mplusMode
                and "Click a dungeon for its pool; click an item to mark it gained. Coin: click plans, right-click checks off. One pool per dungeon."
                or "Click a boss for its gear; click an item to mark it gained. Coin: click plans, right-click checks off. Per difficulty.")
            or "No raid found yet - open the Adventure Guide once, or import a sim.")
    end
end

-- ── Drops Overview: RAW drop pricing, no coin math ──────────────────────────
-- Expected value of ONE random drop for a whole DUNGEON: the end-of-run
-- sim has no per-dungeon identity, so intersect its pooled gains with the
-- dungeon's confirmed item set - positive gains averaged over every
-- un-collected item, the same math as a boss's roll EV. (Raid rows use
-- BossSimEV directly on the drops bucket.)
local function DropsDungeonEV(instID, ownDiff)
    local ev = simStore.mplus
    local g = ev and ev.gains[-1]
    local pool = poolStore.mplusBonus and poolStore.mplusBonus[instID]
    if not (g and pool) then return nil end
    local sum, remaining = 0, 0
    for itemID in pairs(pool) do
        if not IsOwnedItem(itemID, ownDiff) then
            remaining = remaining + 1
            local gain = g[itemID]
            if gain and gain > 0 then sum = sum + gain end
        end
    end
    if remaining > 0 and sum > 0 then return sum / remaining, remaining end
    return nil
end

-- Same boss/dungeon list look as the Bonus Roll Overview, but the number on
-- a row is its BEST raw drop gain, the expand ranks every item by gain, and
-- there are no coins or shares - planning stays a bonus roll thing.
local function DropsRefresh(pg)
    if not char then return end
    PrimePoolCache()
    local diff = char.settings.dropsDiff or 15
    local mplusMode = diff == "mplus"
    local ownDiff = mplusMode and MPLUS_DIFF or diff
    -- slot filter: expands every boss, keeps only that slot's items
    local slotKey = SlotFilter.Current()
    local slotOn = slotKey ~= "all"
    pg.rolls:SetText("")
    if pg.pctCb then pg.pctCb:SetOn(char.settings.evPercent) end
    local haveSim = simStore[diff] ~= nil
    if pg.simNotice then
        pg.simNotice:SetShown(not haveSim)
        if not haveSim then
            pg.simNotice.fs:SetText(("|T%d:14|t |cff3fc9f2Sim your character|r to price this page - no %s sim for %s yet. Click to import one."):format(
                CoinIconTexture(), mplusMode and "Mythic+ runs" or DifficultyName(diff), CurrentSpecName()))
        end
        pg.listScroll:SetPoint("TOPLEFT", 0, haveSim and -34 or -62)
    end
    pg.listContent:SetWidth(math.max(200, pg.listScroll:GetWidth() or 0))
    local inst = (not mplusMode) and GetCurrentRaidInstanceID() or nil
    local shown, itemsShown = 0, 0
    local bestIdx, bestEV
    local y = 0
    local entries
    if mplusMode then
        entries = GetSeasonDungeonList()
    elseif inst and EJ_GetEncounterInfoByIndex then
        local bosses = {}
        local i = 1
        while true do
            local nm, _, id = EJ_GetEncounterInfoByIndex(i, inst)
            if not nm or not id then break end
            bosses[#bosses + 1] = { id = id, name = nm }
            i = i + 1
        end
        if #bosses > 0 then
            db.bossList = db.bossList or {}
            db.bossList[inst] = bosses
        elseif db.bossList and db.bossList[inst] then
            bosses = db.bossList[inst]
        end
        entries = bosses
    end
    -- TOP 5 UPGRADES across the whole selection, straight from the sim:
    -- "these are my best possible drops here", ranked, un-collected only
    local topMap = {}
    do
        local ev = simStore[diff]
        if ev then
            if mplusMode then
                for itemID, g in pairs(ev.gains[-1] or {}) do
                    if g >= 0.5 and not IsOwnedItem(itemID, ownDiff) then
                        local cur = topMap[itemID]
                        if not cur or g > cur.gain then topMap[itemID] = { gain = g } end
                    end
                end
            else
                for enc, gains in pairs(ev.gains) do
                    for itemID, g in pairs(gains) do
                        if g >= 0.5 and not IsOwnedItem(itemID, ownDiff) then
                            local cur = topMap[itemID]
                            if not cur or g > cur.gain then topMap[itemID] = { gain = g, enc = enc } end
                        end
                    end
                end
            end
        end
    end
    local top = {}
    for itemID, e in pairs(topMap) do
        top[#top + 1] = { itemID = itemID, gain = e.gain, enc = e.enc }
    end
    table.sort(top, function(a, b) return a.gain > b.gain end)
    -- rank map: the gold 1-5 these items wear EVERYWHERE they appear in
    -- this view (the Top 5 list and inside their boss's expanded gear)
    local rankOf = {}
    for i = 1, math.min(5, #top) do rankOf[top[i].itemID] = i end
    local topShut = char.settings.dropsTopShut == true
    if entries and #top > 0 then
        shown = shown + 1
        local hdr = pg.rows[shown] or CreateOverviewRow(pg, shown)
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT", 0, y)
        hdr:SetPoint("TOPRIGHT", 0, y)
        y = y - 30
        hdr.state = { topHeader = true }
        hdr.portrait:Hide()
        AT.Skin(hdr, AT.COL.panel, AT.COL.line)
        hdr.coin:Hide()
        hdr.rolled:Hide()
        -- no portrait here: the title takes its slot (no dead gap)
        hdr.name:ClearAllPoints()
        hdr.name:SetPoint("LEFT", 10, 0)
        hdr.name:SetPoint("RIGHT", hdr, "RIGHT", -160, 0)
        hdr.name:SetText("Top 5 upgrades")
        hdr.name:SetTextColor(AT.COL.arc[1], AT.COL.arc[2], AT.COL.arc[3], 1)
        hdr.ev:SetText("")
        hdr.evBtn:Hide()
        hdr.simHint:Hide()
        hdr.best:Hide()
        -- the theme's collapse arrow, pinned right: down = open, right = shut
        if not hdr.colArrow then
            hdr.colArrow = hdr:CreateTexture(nil, "OVERLAY")
            hdr.colArrow:SetSize(11, 11)
            hdr.colArrow:SetPoint("RIGHT", -10, 0)
        end
        hdr.colArrow:SetAtlas(topShut and "Options_ListExpand_Right"
            or "Options_ListExpand_Right_Expanded")
        hdr.colArrow:SetVertexColor(AT.COL.arc[1], AT.COL.arc[2], AT.COL.arc[3], 1)
        hdr.colArrow:Show()
        hdr:Show()
        if not topShut then
            for i = 1, math.min(5, #top) do
                local e = top[i]
                itemsShown = itemsShown + 1
                local it = pg.itemRows[itemsShown] or CreateOverviewItemRow(pg, itemsShown)
                it:ClearAllPoints()
                it:SetPoint("TOPLEFT", 24, y)
                it:SetPoint("TOPRIGHT", 0, y)
                y = y - 26
                local link
                if e.enc then
                    local v = poolStore[diff] and poolStore[diff][e.enc] and poolStore[diff][e.enc][e.itemID]
                    if type(v) == "string" then link = v end
                end
                local tev = simStore[diff]
                local tCv = tev and tev.cv and tev.cv[e.itemID]
                local tCa = tCv and tev.ca and tev.ca[e.itemID] or nil
                it.state = { itemID = e.itemID, diff = ownDiff, owned = false, link = link,
                             simLv = tev and tev.lv and tev.lv[e.itemID],
                             simConv = tCv,
                             simAsTxt = tCa and FormatGainNumber(tCa, diff) or nil }
                it.icon:SetTexture(C_Item.GetItemIconByID(e.itemID) or 134400)
                it.check:Hide()
                it.ghost:Hide()
                local nm = OverviewItemName(pg, e.itemID)
                if e.enc then
                    -- negative encounters are non-boss sources (-97 =
                    -- catalyst conversions in the Droptimizer encoding)
                    nm = nm .. ("  |cff8ca0b8%s|r"):format(
                        e.enc > 0 and EncounterName(e.enc) or "Catalyst")
                end
                it.name:SetText(nm)
                it.share:SetText("")
                it.rank:SetText(tostring(i))
                it.rank:Show()
                it.gain:SetText(FormatGainNumber(e.gain, diff))
                it.gain:SetTextColor(0.3, 0.87, 0.3, 1)
                it:Show()
            end
        end
    end
    if entries then
        for _, boss in ipairs(entries) do
            local bossName, bossID = boss.name, boss.id
            shown = shown + 1
            local row = pg.rows[shown] or CreateOverviewRow(pg, shown)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, y)
            row:SetPoint("TOPRIGHT", 0, y)
            y = y - 30
            local selected = pg.selectedEnc == bossID
            -- the row's number is the EXPECTED value of one random drop
            -- here (positive un-collected gains averaged over the pool)
            local best
            if mplusMode then
                best = DropsDungeonEV(bossID, ownDiff)
            else
                best = BossSimEV(bossID, diff, ownDiff, diff)
            end
            row.state = { enc = bossID, diff = ownDiff, week = 0, name = bossName,
                          drops = true }
            local img
            if mplusMode then
                img = select(6, EJ_GetInstanceInfo(bossID))
            else
                img = select(5, EJ_GetCreatureInfo(1, bossID))
            end
            row.portrait:SetTexture(img or "Interface\\EncounterJournal\\UI-EJ-BOSS-Default")
            row.portrait:Show()   -- the Top 5 header hides it on this pooled row
            if row.colArrow then row.colArrow:Hide() end
            row.name:ClearAllPoints()   -- header pulls the title left; restore
            row.name:SetPoint("LEFT", 32, 0)
            row.name:SetPoint("RIGHT", row, "RIGHT", -160, 0)
            AT.Skin(row, selected and AT.COL.panel or AT.COL.box, selected and AT.COL.arcDeep or AT.COL.line)
            row.coin:Hide()
            row.rolled:Hide()
            row.name:SetText(bossName)
            row.name:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3], 1)
            if best then
                row.ev:SetText(FormatGainNumber(best, diff))
                row.evBtn:Show()
                row.simHint:Hide()
            else
                row.ev:SetText("")
                row.evBtn:Hide()
                row.simHint:Show()
            end
            row.best:Hide()
            if best and (not bestEV or best > bestEV) then
                bestEV, bestIdx = best, shown
            end
            row:Show()
            if selected or slotOn then
                local ev = simStore[diff]
                local gains, cache
                if mplusMode then
                    gains = ev and ev.gains[-1]
                    cache = poolStore.mplusBonus and poolStore.mplusBonus[bossID]
                else
                    gains = ev and ev.gains[bossID]
                    cache = poolStore[diff] and poolStore[diff][bossID]
                end
                local list = {}
                if cache and next(cache) then
                    for itemID, v in pairs(cache) do
                        list[#list + 1] = { itemID = itemID, gain = gains and gains[itemID] or nil,
                                            link = (type(v) == "string") and v or nil }
                    end
                    -- tier token conversion pieces: simmed at this boss but
                    -- never in the journal pool (the boss drops the slotless
                    -- token). Raid only - the M+ gains table is dungeon-wide.
                    if gains and not mplusMode then
                        for itemID, g in pairs(gains) do
                            if cache[itemID] == nil then
                                -- old imports credited conversions to the
                                -- sim's TOKEN id: show those as the piece
                                -- they become (Arc's model)
                                local show = itemID
                                if IsTokenItem(itemID) and not OMNI_TOKENS[itemID] then
                                    show = TokenPieceFor(itemID) or itemID
                                end
                                list[#list + 1] = { itemID = show, gain = g, fromToken = true }
                            end
                        end
                    end
                elseif gains and next(gains) and not mplusMode then
                    for itemID, g in pairs(gains) do
                        list[#list + 1] = { itemID = itemID, gain = g }
                    end
                end
                -- slot filter: keep only matching items; a real list with
                -- nothing in the slot drops the boss row entirely (an empty
                -- list keeps its "confirming..." placeholder below)
                local dropBoss = false
                if slotOn and #list > 0 then
                    local kept = {}
                    for _, entry in ipairs(list) do
                        if SlotFilter.Matches(entry.itemID, slotKey) then kept[#kept + 1] = entry end
                    end
                    list = kept
                    dropBoss = #list == 0
                end
                if dropBoss then
                    row:Hide()
                    if bestIdx == shown then bestIdx, bestEV = nil, nil end
                    shown = shown - 1
                    y = y + 30
                elseif #list > 0 then
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
                        local owned, source = IsOwnedItem(entry.itemID, ownDiff)
                        local cvPiece = ev and ev.cv and ev.cv[entry.itemID]
                        local caGain = cvPiece and ev.ca and ev.ca[entry.itemID] or nil
                        it.state = { itemID = entry.itemID, diff = ownDiff, owned = owned,
                                     source = source, link = entry.link,
                                     simLv = ev and ev.lv and ev.lv[entry.itemID],
                                     simConv = cvPiece,
                                     simAsTxt = caGain and FormatGainNumber(caGain, diff) or nil }
                        it.icon:SetTexture(C_Item.GetItemIconByID(entry.itemID) or 134400)
                        it.check:SetShown(owned)
                        it.ghost:Hide()
                        it.name:SetText(OverviewItemName(pg, entry.itemID)
                            .. (cvPiece and "  |cff8ca0b8(Catalyst)|r" or ""))
                        it.share:SetText("")
                        -- a Top 5 item wears its gold rank here too
                        local r = (not owned) and rankOf[entry.itemID] or nil
                        if r then
                            it.rank:SetText(tostring(r))
                            it.rank:Show()
                        else
                            it.rank:Hide()
                        end
                        if owned then
                            it.gain:SetText("")
                        elseif entry.gain then
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
                    it.rank:Hide()
                    it.name:SetText(mplusMode
                        and "|cff8ca0b8Confirming this dungeon's pool from the game's journal data - a few seconds...|r"
                        or "|cff8ca0b8Confirming this boss's pool from the game's journal data - a few seconds...|r")
                    it.share:SetText("")
                    it.gain:SetText("")
                    it:Show()
                end
            end
        end
    end
    if bestIdx and pg.rows[bestIdx] then pg.rows[bestIdx].best:Show() end
    for k = shown + 1, #pg.rows do pg.rows[k]:Hide() end
    for k = itemsShown + 1, #pg.itemRows do pg.itemRows[k]:Hide() end
    pg.listContent:SetHeight(math.max(1, -y + 4))
    pg.listScroll:UpdateScroll()
    if shown == 0 then
        -- kick even when inst is unknown - see the note in OverviewRefresh
        local ejBusy = EncounterJournal and EncounterJournal:IsShown()
        if not ejBusy and not mplusMode
            and EJ_SelectTier and EJ_GetNumTiers then
            EJ_SelectTier(EJ_GetNumTiers())
            if inst and EJ_SelectInstance then EJ_SelectInstance(inst) end
        end
        pg._loadRetries = (pg._loadRetries or 0) + 1
        local delay = ejBusy and 2 or (pg._loadRetries > 6 and 3 or 0.8)
        C_Timer.After(delay, function()
            if pg:IsShown() then DropsRefresh(pg) end
        end)
        pg.hint:SetText(ejBusy
            and "Waiting for the Adventure Guide to free up the journal data..."
            or (mplusMode and "Loading the dungeon list..." or "Loading the raid list..."))
    else
        pg._loadRetries = nil
        pg.hint:SetText(shown > 0
            and "Click a row to see every drop ranked by DPS gain. Click an item to check it off as owned."
            or "No raid found yet - open the Adventure Guide once, or import a sim.")
    end
end

local function PageRefresh(pg)
    if pg.mode == "drops" then DropsRefresh(pg) else OverviewRefresh(pg) end
end

local function BuildOverviewPage(parent, mode)
    local pg = CreateFrame("Frame", nil, parent)
    pg:Hide()
    pg.mode = mode   -- nil = Bonus Roll Overview, "drops" = Drops Overview
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
        function() return (mode == "drops") and DROPS_DIFFS or OVERVIEW_DIFFS end,
        function()
            if mode == "drops" then return char.settings.dropsDiff or 15 end
            return char.settings.ovDiff or 15
        end,
        function(v)
            if mode == "drops" then char.settings.dropsDiff = v
            else char.settings.ovDiff = v end
            PageRefresh(pg)
        end)
    dd:SetPoint("TOPLEFT", 0, -4)
    -- Drops page only: the slot filter beside the difficulty
    local slotDD
    if mode == "drops" then
        slotDD = AT.MakeDropdown(win, pg, 110,
            function() return SlotFilter.items end,
            function() return SlotFilter.Current() end,
            function(v)
                char.settings.dropsSlot = (v ~= "all") and v or nil
                PageRefresh(pg)
            end)
        slotDD:SetPoint("LEFT", dd, "RIGHT", 8, 0)
    end
    -- "Show EV as percent": a real labeled toggle (the bare %/# chip read
    -- as noise) driving the ONE shared setting with the strip and Sims tab
    local pctCb = AT.MakeCheckbox(pg)
    pctCb:SetPoint("LEFT", slotDD or dd, "RIGHT", 12, 0)
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
        PageRefresh(pg)
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
    notice:SetScript("OnClick", function()
        AT.CloseDropdown()
        if win and win.SelectTab then win.SelectTab("Sim Import") end
    end)
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
    -- compact scan button (a labeled one does not fit the top bar): same
    -- checks as the journal's Scan gear, driven from the stored pools
    local scanBtn = CreateFrame("Button", nil, pg, "BackdropTemplate")
    scanBtn:SetSize(22, 22)
    scanBtn:SetPoint("RIGHT", journalBtn, "LEFT", -8, 0)
    AT.Skin(scanBtn, AT.COL.btn, AT.COL.steel)
    local scanTex = scanBtn:CreateTexture(nil, "ARTWORK")
    scanTex:SetAtlas("common-search-magnifyingglass")
    scanTex:SetSize(14, 14)
    scanTex:SetPoint("CENTER")
    scanTex:SetVertexColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    scanBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(AT.COL.arc[1], AT.COL.arc[2], AT.COL.arc[3], 1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Scan gear for looted items", 0.2, 0.8, 1)
        GameTooltip:AddLine("Checks equipped gear, bags, and your transmog collection against everything on this page, and checks off what you already own.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    scanBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(AT.COL.steel[1], AT.COL.steel[2], AT.COL.steel[3], 1)
        GameTooltip:Hide()
    end)
    scanBtn:SetScript("OnClick", function() AT.CloseDropdown(); OverviewScan(pg) end)
    pg.rolls = pg:CreateFontString(nil, "OVERLAY")
    pg.rolls:SetFont(STANDARD_TEXT_FONT, 12, "")
    pg.rolls:SetPoint("RIGHT", scanBtn, "LEFT", -10, 0)
    pg.rolls:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    pg.hint = pg:CreateFontString(nil, "OVERLAY")
    pg.hint:SetFont(STANDARD_TEXT_FONT, 10, "")
    pg.hint:SetPoint("BOTTOMLEFT", 4, 4)
    pg.hint:SetPoint("BOTTOMRIGHT", -4, 4)
    pg.hint:SetJustifyH("LEFT")
    pg.hint:SetTextColor(AT.COL.dim[1], AT.COL.dim[2], AT.COL.dim[3])
    function pg:Refresh()
        PageRefresh(self)
        C_Timer.After(0, function()
            if self:IsShown() then PageRefresh(self) end
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

-- ── "Show me how" import walkthrough ────────────────────────────────────────
-- Shipped screenshots (media\howto_sims_*.png) stepping through the Raw
-- Files > data.csv shortcut. PNG paths need the extension spelled out
-- (extensionless SetTexture only resolves .blp/.tga).
local HOWTO_STEPS = {
    { tex = "Interface\\AddOns\\ArcLootPlanner\\media\\howto_sims_1.png", w = 1024, h = 490,
      text = "1. On your Raidbots report page, find the |cff3fc9f2Raw Files|r row at the bottom right, under Simulation Details. Click the three dots |cff3fc9f2...|r next to it (not the Raw Files label), then pick |cff3fc9f2data.csv|r. (Step 2's address on the Sim Import tab opens the exact same page - use whichever you prefer.)" },
    { tex = "Interface\\AddOns\\ArcLootPlanner\\media\\howto_sims_2.png", w = 1024, h = 557,
      text = "2. On the page that opens, select everything (|cff3fc9f2Ctrl+A|r) and copy it (|cff3fc9f2Ctrl+C|r). It is a small page - the copy is instant." },
    { tex = "Interface\\AddOns\\ArcLootPlanner\\media\\howto_sims_3.png", w = 1024, h = 946,
      text = "3. Back in game: pick the spec the sim is for, click into the paste box, paste (|cff3fc9f2Ctrl+V|r), then press |cff3fc9f2Import pasted text|r. The status line confirms how many item gains were stored." },
}

local howtoWin, howtoStep
local function ShowHowTo()
    if not howtoWin then
        local IMG_W = 620
        local hw = AT.CreateWindow("ArcLootPlannerHowTo", {
            title = "|cff3fc9f2Arc|r|cffd5e2f2 Loot Planner|r - importing a sim",
            w = IMG_W + 24, h = 490, minW = IMG_W + 24, minH = 490, resizable = false,
        })
        -- guide always floats over the window that opened it (twin parity:
        -- the ArcUI options frame lives at FULLSCREEN_DIALOG)
        hw:SetFrameStrata("FULLSCREEN_DIALOG")
        local img = hw:CreateTexture(nil, "ARTWORK")
        img:SetPoint("TOP", 0, -40)
        local imgBorder = CreateFrame("Frame", nil, hw, "BackdropTemplate")
        AT.Skin(imgBorder, { 0, 0, 0, 0 }, AT.COL.line2)
        imgBorder:SetPoint("TOPLEFT", img, -1, 1)
        imgBorder:SetPoint("BOTTOMRIGHT", img, 1, -1)
        local caption = hw:CreateFontString(nil, "OVERLAY")
        caption:SetFont(STANDARD_TEXT_FONT, 12, "")
        caption:SetPoint("BOTTOMLEFT", 14, 42)
        caption:SetPoint("BOTTOMRIGHT", -14, 42)
        caption:SetJustifyH("LEFT")
        caption:SetSpacing(3)
        caption:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
        local prev = AT.MakeSmallButton(hw, "< Back", 80)
        prev:SetPoint("BOTTOMLEFT", 12, 10)
        local nxt = AT.MakeSmallButton(hw, "Next >", 80)
        nxt:SetPoint("BOTTOMRIGHT", -12, 10)
        local counter = hw:CreateFontString(nil, "OVERLAY")
        counter:SetFont(STANDARD_TEXT_FONT, 11, "")
        counter:SetPoint("BOTTOM", 0, 16)
        counter:SetTextColor(AT.COL.dim[1], AT.COL.dim[2], AT.COL.dim[3])
        local function SetStep(i)
            howtoStep = i
            local s = HOWTO_STEPS[i]
            img:SetTexture(s.tex)
            img:ClearAllPoints()
            img:SetPoint("TOP", 0, -40)
            local iw, ih = IMG_W, math.floor(IMG_W * s.h / s.w + 0.5)
            if ih > 460 then
                -- tall shots (the in-game step) shrink to keep the window on screen
                iw = math.floor(IMG_W * 460 / ih + 0.5)
                ih = 460
            end
            img:SetSize(iw, ih)
            local topUsed = 40 + ih
            -- caption hugs the image and the window shrinks to fit the step -
            -- no dead band between screenshot and text
            caption:ClearAllPoints()
            caption:SetPoint("TOPLEFT", 14, -(topUsed + 12))
            caption:SetPoint("TOPRIGHT", -14, -(topUsed + 12))
            caption:SetText(s.text)
            local ch = math.max(20, math.ceil(caption:GetStringHeight()))
            hw:SetHeight(topUsed + 12 + ch + 48)
            counter:SetText(("Step %d of %d"):format(i, #HOWTO_STEPS))
            prev:SetShown(i > 1)
            nxt:SetShown(i < #HOWTO_STEPS)
        end
        prev:SetScript("OnClick", function() SetStep(math.max(1, (howtoStep or 1) - 1)) end)
        nxt:SetScript("OnClick", function() SetStep(math.min(#HOWTO_STEPS, (howtoStep or 1) + 1)) end)
        hw.SetStep = SetStep
        howtoWin = hw
    end
    howtoWin.SetStep(1)
    howtoWin:Show()
    howtoWin:Raise()
end

local function EnsureWindow()
    if win then return win end
    win = AT.CreateWindow("ArcLootPlannerWindow", {
        title = "|cff3fc9f2Arc|r|cffd5e2f2 Loot Planner|r",
        version = C_AddOns.GetAddOnMetadata(ADDON, "Version"),
        -- six chip tabs need the width (Bonus Roll Overview + Drops Overview)
        w = 640, h = 590, minW = 620, minH = 500,
    })

    local pages = {}

    -- Overview + History are hand-built; the rest use the row engine
    pages["Bonus Roll Overview"] = BuildOverviewPage(win)
    pages["Drops Overview"] = BuildOverviewPage(win, "drops")
    pages.History = BuildHistoryPage(win)

    local prot = AT.NewPage(win)
    pages.Protection = prot
    AT.Section(prot, "Bonus Roll Protection")
    AT.RowToggle(prot, "Enable bonus roll protection",
        function() return char.settings.protection end,
        function(v) char.settings.protection = v; UpdateCovers() end,
        nil,
        "Planned bosses roll freely. Every other boss's roll button gets a lock; one click unlocks it. Never rolls or passes for you.")
    AT.RowToggle(prot, "Guard Pass on your planned bosses",
        function() return char.settings.passGuard end,
        function(v) char.settings.passGuard = v; UpdateCovers() end,
        function() return char.settings.protection end,
        "On planned bosses the PASS button gets the lock instead, so a misclick cannot throw away your saved roll.")
    AT.RowToggle(prot, "New week plan reminder",
        function() return char.settings.planReminder end,
        function(v) char.settings.planReminder = v end,
        nil,
        "New raid week, no plan: a small popup reminds you to pick bosses. Planning any boss dismisses it.")
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
    pages.Overlays = jour
    AT.Section(jour, "Adventure Guide Markers")
    AT.RowToggle(jour, "Adventure Guide overlays (master)",
        function() return char.settings.ejOverlay end,
        function(v) char.settings.ejOverlay = v; RefreshEJ() end,
        nil,
        "Everything Arc Loot Planner adds to the Adventure Guide: plan coins, EV numbers, drop shares, and the owned check marks on loot icons. Off = the guide is untouched.")
    AT.RowToggle(jour, "Bonus Roll Sim",
        function() return char.settings.showShares ~= false end,
        function(v) char.settings.showShares = v; RefreshEJ() end,
        function() return char.settings.ejOverlay end,
        "Everything COIN: the coin line on each item (bonus roll EV plus ~% drop share), the plan coins on bosses, dungeon titles and dungeon tiles, and each boss's per-coin EV.")
    AT.RowToggle(jour, "Drop Sim",
        function() return char.settings.showGains ~= false end,
        function(v) char.settings.showGains = v; RefreshEJ() end,
        function() return char.settings.ejOverlay end,
        "The LOOT BAG line on each item: its DPS value if it drops for you, priced by your drops sim. Nothing bonus roll related.")
    AT.RowToggle(jour, "Show on raid pages",
        function() return char.settings.showOnRaids end,
        function(v) char.settings.showOnRaids = v; RefreshEJ(); RefreshEJStrip() end,
        function() return char.settings.ejOverlay end,
        "The overlays above (and the info bar) on the guide's raid pages.")
    AT.RowToggle(jour, "Show on dungeon pages",
        function() return char.settings.showOnDungeons end,
        function(v) char.settings.showOnDungeons = v; RefreshEJ(); RefreshEJStrip() end,
        function() return char.settings.ejOverlay end,
        "The overlays above on dungeon (Mythic+) journal pages, with the coin working per DUNGEON. Off by default.")
    RowButtonPair(jour,
        "Scan gear for looted items", EstimateLootedScan,
        "Open Adventure Guide", OpenJournalToCurrentRaid)
    AT.Section(jour, "Adventure Guide Info Bar")
    AT.RowToggle(jour, "Journal info bar",
        function() return char.settings.showStrip end,
        function(v) char.settings.showStrip = v; RefreshEJ() end,
        nil,
        "The Arc Loot Planner bar inside the Adventure Guide: rolls available, planned bosses, the roll counter, and the Scan gear button.")
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
    AT.Section(jour, "Loot Roll Window")
    AT.RowToggle(jour, "Sim value on loot rolls",
        function() return char.settings.lootRollSim ~= false end,
        function(v) char.settings.lootRollSim = v end,
        nil,
        "The loot-bag drop value on need/greed roll windows, priced by your drops sim for the instance you are in. Type /alp lootroll for a test window.")
    AT.Section(jour, "Item Tooltips")
    AT.RowToggle(jour, "Bonus roll win notes",
        function() return char.settings.tooltips end,
        function(v) char.settings.tooltips = v end,
        nil,
        "Adds a line to any item's tooltip when you won that item from a recorded bonus roll.")
    AT.Section(jour, "Minimap")
    AT.RowToggle(jour, "Minimap button",
        function() return char.settings.minimap end,
        function(v)
            char.settings.minimap = v
            if ApplyMinimapButton then ApplyMinimapButton() end
        end,
        nil,
        "The Arc Loot Planner chest button on the minimap. Click it to open this window; drag it around the rim to move it.")

    local sims = AT.NewPage(win)
    pages["Sim Import"] = sims
    AT.Section(sims, "Import a Raidbots Droptimizer")
    AT.RowButton(sims, "Show me how (screenshots)", ShowHowTo, nil, 210)
    StatusRow(sims, function()
        return ("Sims are |cffffd100per spec|r. Importing stores for: |cff3fc9f2%s|r"):format(
            SpecLabel(SimTargetSpec()))
    end)
    -- sims are per spec: pick which of THIS character's specs the paste is
    -- for, so all specs can be imported without swapping between them.
    -- (Cross-character import exists in the backend - SimBucketFor takes any
    -- charKey - but the picker is deliberately not shown for now.)
    AT.RowDropdown(sims, win, "For spec",
        function() return SimTargetSpec() end,
        function(v) simTarget.specID = v end,
        function()
            local items = {}
            local classID = select(3, UnitClass("player"))
            local n = classID and C_SpecializationInfo.GetNumSpecializationsForClassID(classID) or 0
            for i = 1, n do
                local id, name = GetSpecializationInfoForClassID(classID, i)
                if id then items[#items + 1] = { value = id, text = name } end
            end
            return items
        end,
        nil,
        function() if sims.Refresh then sims:Refresh() end end)
    -- the 3-step wizard lives IN the tab now (matches the ArcUI twin):
    -- link in, derived data.csv address out, paste below, Import
    AT.RowInput(sims, "1. Report link",
        function() return linkInput end,
        function(v)
            linkInput = v or ""
            if sims.Refresh then sims:Refresh() end   -- re-derive step 2 now
        end,
        nil,
        "Run a Raidbots Droptimizer for the spec you are on, then paste the report link here. Healers: a QE Live Upgrade Finder report link works too.",
        nil,
        true)   -- live: step 2 must populate the moment the link is pasted
    AT.RowInput(sims, "2. Open THIS address",
        function()
            -- healers: a QE Live Upgrade Finder report converts too
            local qe = linkInput:match("upgradereport/(%w+)")
            if qe then
                return "https://questionablyepic.com/api/getUpgradeReport.php?reportID=" .. qe
            end
            local id = linkInput:match("simbot/report/(%w+)") or linkInput:match("/reports/(%w+)")
            return id and ("https://www.raidbots.com/reports/" .. id .. "/data.csv") or ""
        end,
        function() end,
        nil,
        "Click in, select all (Ctrl+A), copy (Ctrl+C), open it in your browser, then copy that page's full text. Shortcut: the Raw Files ... menu on the report page itself opens the same data.csv - press Show me how for pictures.")
    local pasteRow = AT.AddRow(sims, 118)
    local pasteLabel = pasteRow:CreateFontString(nil, "OVERLAY")
    pasteLabel:SetFont(STANDARD_TEXT_FONT, 11, "")
    pasteLabel:SetPoint("TOPLEFT", 10, -4)
    pasteLabel:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    pasteLabel:SetText("3. Paste the page's FULL text below, then press Import:")
    local pasteFrame = CreateFrame("Frame", nil, pasteRow, "BackdropTemplate")
    pasteFrame:SetPoint("TOPLEFT", 10, -20)
    pasteFrame:SetPoint("BOTTOMRIGHT", -10, 6)
    AT.Skin(pasteFrame, AT.COL.well)
    local eb = CreateFrame("EditBox")
    eb:SetMultiLine(true)
    eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(430)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local pasteScroll = AT.MakeScroll(pasteFrame, eb)
    pasteScroll:SetPoint("TOPLEFT", 4, -4)
    pasteScroll:SetPoint("BOTTOMRIGHT", -10, 4)
    eb:SetScript("OnTextChanged", function() pasteScroll:UpdateScroll() end)
    pasteFrame:EnableMouse(true)
    pasteFrame:SetScript("OnMouseUp", function() eb:SetFocus() end)
    pasteEB = eb
    RowButtonPair(sims,
        "Import pasted text", function()
            local targetKey, targetSpec = SimTargetKey(), SimTargetSpec()
            if not targetSpec then
                simStatusMsg = "|cffff6060Pick a spec to import for first.|r"
                if RefreshWindow then RefreshWindow() end
                return
            end
            local bucket = SimBucketFor(targetKey, targetSpec)
            local tName = targetKey:match("^(.-)%s*%-") or targetKey
            local tClass = (targetKey == CharKey()) and select(3, UnitClass("player"))
                or (db.chars[targetKey] and db.chars[targetKey].classID) or nil
            local diffs, items, impErr, usedSpec = ApplySimImport(
                pasteEB and pasteEB:GetText() or "", bucket, targetSpec, tName, tClass,
                function(s) return SimBucketFor(targetKey, s) end)
            if diffs then
                local finalSpec = usedSpec or targetSpec
                simStatusMsg = ("|cff4cde4cImported %d item gains (%d difficulty set%s) for %s%s.|r"):format(
                    items, diffs, diffs == 1 and "" or "s", SpecLabel(finalSpec),
                    (usedSpec and usedSpec ~= targetSpec) and " (the sim said so)" or "")
                pasteEB:SetText("")
                if targetKey == CharKey() and finalSpec == CurrentSpecID() then
                    WipeLootPool()
                    RefreshEJ()
                end
            else
                local raw = pasteEB and pasteEB:GetText() or ""
                if impErr then
                    simStatusMsg = "|cffff6060" .. impErr .. "|r"
                elseif raw:find("^%s*[%[{]") then
                    simStatusMsg = "|cffff6060That is the data.json - not needed, and far too big. Open the data.csv instead (press Show me how).|r"
                else
                    simStatusMsg = "|cffff6060Could not read that. Paste the FULL text of the data.csv page.|r"
                end
            end
            if RefreshWindow then RefreshWindow() end
        end,
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
    AT.RowButton(sims, "Clear the selected spec's sims", function()
        local targetKey, targetSpec = SimTargetKey(), SimTargetSpec()
        if not targetSpec then return end
        wipe(SimBucketFor(targetKey, targetSpec))
        simStatusMsg = ("|cffffd100Cleared imported sims for %s.|r"):format(SpecLabel(targetSpec))
        WipeLootPool()
        RefreshEJ()
        RefreshEJStrip()
        if RefreshWindow then RefreshWindow() end
    end, nil, 210)
    AT.RowToggle(sims, "Show EV as percent",
        function() return char.settings.evPercent end,
        function(v) char.settings.evPercent = v; RefreshEJ() end,
        nil,
        "Raidbots' Relative DPS view: gains and roll EVs show as a percent of your simmed DPS instead of raw numbers.")
    -- collapsible + self-cleaning: one row per difficulty that HAS a sim,
    -- every empty one folded into a single dim line - nobody needs six
    -- "no sim imported" rows for content they ignore (Arc's call). Starts
    -- shut on first sight; the user's open/shut choice sticks after that.
    char.settings.secCollapsed = char.settings.secCollapsed or {}
    if char.settings.simDataSeeded == nil then
        char.settings.simDataSeeded = true
        char.settings.secCollapsed["Imported Data"] = true
    end
    AT.Section(sims, "Imported Data", { collapsible = true, store = char.settings })
    StatusRow(sims, function()
        return ("For |cff3fc9f2%s|r:"):format(CurrentSpecName())
    end)
    local DIFF_LABEL = {
        [17] = "Raid Finder drops",
        [14] = "Raid Normal drops",
        [15] = "Raid Heroic drops",
        [16] = "Raid Mythic drops",
        vault17 = "Raid Finder bonus rolls",
        vault14 = "Raid Normal bonus rolls",
        vault15 = "Raid Heroic bonus rolls",
        vault16 = "Raid Mythic bonus rolls",
        mplus = "Mythic+ run drops",
        mplusBonus = "Mythic+ bonus rolls",
    }
    local DIFF_ROWS = { 17, 14, 15, 16,
        "vault17", "vault14", "vault15", "vault16", "mplus", "mplusBonus" }
    for _, d in ipairs(DIFF_ROWS) do
        StatusRow(sims, function()
            local ev = simStore[d]
            if not ev then return "" end
            local n = 0
            for _, encGains in pairs(ev.gains) do
                for _ in pairs(encGains) do n = n + 1 end
            end
            return ("%s: |cffffd100%d|r item gains, imported %s"):format(
                DIFF_LABEL[d] or DifficultyName(d), n, date("%m-%d %H:%M", ev.t or 0))
        end, nil, function() return simStore[d] ~= nil end)
    end
    StatusRow(sims, function()
        local missing
        for _, d in ipairs(DIFF_ROWS) do
            if not simStore[d] then
                local nm = DIFF_LABEL[d] or DifficultyName(d)
                missing = missing and (missing .. ", " .. nm) or nm
            end
        end
        return missing and ("|cff8ca0b8No sims for: %s|r"):format(missing) or ""
    end, nil, function()
        for _, d in ipairs(DIFF_ROWS) do
            if not simStore[d] then return true end
        end
        return false
    end)

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
    AT.AddTabs(win, { "Bonus Roll Overview", "Drops Overview", "Protection", "Overlays", "Sim Import", "History" }, pages)
    AT.AddDiscordFooter(win, "ArcLootPlannerDiscordCopy")
    win.SelectTab("Bonus Roll Overview")
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
    w.SelectTab(w._activeTab or "Bonus Roll Overview")
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
    mmBtn = CreateFrame("Button", "ArcLootPlannerMinimapButton", Minimap)
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
    -- the chest logo (glow-keyed); the ring is round, so mask the corners
    -- off with the portrait alpha circle
    icon:SetTexture(ROLL_BADGE_ICON)
    -- dead-center on the background disc (a TOPLEFT offset sat 1.5px left)
    icon:SetPoint("CENTER", bg, "CENTER", 0, 0)
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
        GameTooltip:AddLine("|cff3fc9f2Arc|r|cffd5e2f2 Loot Planner|r")
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
    mmBtn.icon:SetTexture(ROLL_BADGE_ICON)
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
    planPopup = CreateFrame("Frame", "ArcLootPlannerPlanReminder", UIParent, "BackdropTemplate")
    planPopup:SetSize(400, 104)
    planPopup:SetPoint("TOP", 0, -160)
    planPopup:SetFrameStrata("DIALOG")
    planPopup:EnableMouse(true)
    AT.Skin(planPopup, AT.COL.bg, AT.COL.arcDeep)
    local title = planPopup:CreateFontString(nil, "OVERLAY")
    title:SetFont(STANDARD_TEXT_FONT, 12, "")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("|cff3fc9f2Arc|r|cffd5e2f2 Loot Planner|r")
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
        w.SelectTab("Bonus Roll Overview")
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
        planPopup.body:SetText("A bonus roll is up but nothing is planned this week, so bonus roll protection is not covering anything. Pick your bosses when you get a moment.")
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
        C_Timer.After(8, PrimePoolCache)
        C_Timer.After(10, function()
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
StaticPopupDialogs["ARCLOOTPLANNER_WIPE"] = {
    text = "Arc Loot Planner: erase ALL saved data (roll history, plans, owned marks, sims, pools - every character) and reload for a fresh-install state?",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        ArcLootPlannerDB = nil   -- nil survives the reload's save = clean slate
        C_UI.Reload()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

SLASH_ARCLOOTPLANNER1 = "/arclootplanner"
SLASH_ARCLOOTPLANNER2 = "/alp"
SLASH_ARCLOOTPLANNER3 = "/abr"           -- legacy alias (pre-rename)
SLASH_ARCLOOTPLANNER4 = "/arcbonusroll"  -- legacy alias (pre-rename)
SlashCmdList["ARCLOOTPLANNER"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "wipe" then
        StaticPopup_Show("ARCLOOTPLANNER_WIPE")
        return
    end
    if msg == "mock" then
        ShowMock()
        return
    end
    if msg == "lootroll force" then
        lootRollForce = not lootRollForce
        Print(lootRollForce
            and "loot roll FORCE test ON: real roll windows show a fake +1,234 when no sim value exists. Resets on reload."
            or "loot roll force test off.")
        return
    end
    if msg == "lootroll" then
        ToggleMockLootRoll()
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
        local w = EnsureWindow()
        if not w:IsShown() then w:Show() end
        w.SelectTab("Sim Import")
        C_Timer.After(0, RefreshWindow)
        return
    end
    ToggleWindow()
end
