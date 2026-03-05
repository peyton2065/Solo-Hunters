--[[
    ╔══════════════════════════════════════════════════════════╗
    ║          SOLO HUNTERS — ENI BUILD  v7.0                  ║
    ║          Xeno Executor  |  Senior Engineering Remed.     ║
    ╚══════════════════════════════════════════════════════════╝

    Based on analysis of community scripts:
      6FootScripts, NS Hub (OhhMyGehlee), Hina Hub (Threeeps),
      mazino45 (Aeonic Hub), WynossWare, ApelHub

    ARCHITECTURE: Dungeon State Machine
    ─────────────────────────────────────────────────────────
    States:
      LOBBY    → scan portals, pick best, move to it, enter
      ENTERING → wait for dungeon to load
      FIGHTING → kill all mobs, auto skills running passively
      COLLECTING → open chests, pick up drops
      LEAVING  → fire leave remote / teleport out
      QUESTING → turn in, accept new, sell, buy, restock

    ═══════════════════════════════════════════════════════════
    CHANGELOG v6.5 → v7.0  (Senior Engineering Remediation Pass)
    ═══════════════════════════════════════════════════════════

    ── INITIALIZATION ARCHITECTURE ──────────────────────────

    ARCH-1 [CRITICAL] Thread proliferation on Rayfield CDN retry.
      killAuraThread and autoSkillsThread were spawned at module
      scope before Rayfield loaded. On CDN failure + retry the
      guard cleared while orphaned while-true loops ran for the
      entire session with no surviving handle to cancel them.
      Each retry compounded: N retries = 2N orphaned threads.
      Fix: both threads MOVED to after Rayfield window creation.
      All handles stored in getgenv().ENI_THREAD_REGISTRY for
      cross-execution access. At the very top of each execution,
      any handles from a prior run are cancelled before any new
      threads are spawned.

    ARCH-2 [HIGH] Rejoin button only cancelled killAuraThread and
      autoSkillsThread. afkThread, slotThread, and augThread were
      left running through TeleportAsync — firing remotes during
      teleport and leaving coroutines alive in the new place.
      Fix: unified cancelAllThreads() iterates the full registry.
      Rejoin, the load-guard cleanup, and the re-exec path all
      call it before proceeding.

    ARCH-3 [HIGH] CharacterAdded double-refresh race condition.
      refreshChar() contained a blocking LP.CharacterAdded:Wait()
      fallback. Both the farm loop's guard path and the top-level
      CharacterAdded:Connect handler activated for the same event,
      producing two concurrent coroutines writing Hum/HRP and two
      startAutoFarm() calls. The farm loop from path 1 was then
      cancelled mid-execution (potentially mid-teleport or mid-
      killAllDungeonMobs) by path 2's startAutoFarm cancel logic.
      Fix: refreshChar() is now strictly synchronous — reads
      LP.Character and returns false if nil, no Wait(). The
      CharacterAdded:Connect handler is the single authoritative
      restart point. Farm loop guard yields on task.wait() only.

    ARCH-4 [HIGH] MapFolder/CirclesFolder captured with synchronous
      FindFirstChild at module scope. If the Map folder loads after
      injection (streaming-enabled games, deferred workspace pop-
      ulation), both references are nil and AutoFarm silently finds
      zero portals indefinitely. Fix: FindFirstChild first; if nil,
      a background task.spawn resolves via WaitForChild(60s) and
      updates the module-level locals when ready.

    ── PROXIMITYPROMPT RESOLUTION ───────────────────────────

    PP-1 [CRITICAL] Three systems silently disabled by Lua
      truthiness misunderstanding.
      Old pattern: (pp.ActionText or pp.ObjectText or pp.Name)
      ActionText defaults to "Use" / key-label in Roblox — a
      non-empty string, therefore always truthy. ObjectText
      (where devs write "Sell", "Chest", "Reward", "Buy") was
      never evaluated. Keyword matching ran against the wrong
      property in 100% of cases.
      Affected: AutoSell, AutoBuy, AutoCollect — all broken.
      Fix: getPromptText() helper builds a single composite
      string: ObjectText + ActionText + Name (ObjectText first,
      since it is the semantically rich property). All three
      systems now call getPromptText().

    ── STATE MANAGEMENT ─────────────────────────────────────

    STATE-1 [HIGH] doAutoEquipBest() scan missed currently
      equipped tool. Best-item search only covered Backpack.
      If the equipped tool had the highest power it was not
      found; the function equipped an inferior backpack item
      and cycled the best tool through Backpack every call.
      Fix: scan both Backpack and Char:GetChildren(). Track
      currentTool. Skip the swap entirely when best == current.

    STATE-2 [HIGH] doRedeemCodes() blocking InvokeServer with
      no timeout. A hung server handler (rate-limit, network
      partition, server-side error) stalled the entire LOBBY
      state indefinitely; codesRedeemedThisSession never set.
      Fix: each InvokeServer runs in its own spawned coroutine
      with a 5-second task.delay hard timeout per code.

    STATE-3 [MEDIUM] inferStartState() relied on CirclesFolder
      being empty when inside a dungeon. In a shared-workspace
      architecture where portals persist in MapFolder.Circles
      regardless of player position, this check always failed,
      returning LOBBY instead of LEAVING for cleared dungeons.
      Fix: secondary signal — if HRP position is not near any
      known lobby landmark, and no portals score above the floor,
      treat as inside dungeon.

    ── CONDITIONAL LOGIC ────────────────────────────────────

    LOGIC-1 [MEDIUM] doAutoBuy() BUY_KEYWORDS contained "item" —
      a substring match hitting "UpgradeItem", "DisenchantItem",
      "ItemShop", "ItemDetails", etc. Removed.

    LOGIC-2 [MEDIUM] getToolPower() now checks GearScore, Tier,
      Rank, Score, Strength, Attack as additional value names,
      and also checks Roblox Instance Attributes before falling
      back to name-digit parsing. Name-parse emits a warn().

    LOGIC-3 [LOW] attackEntry() TakeDamage call removed.
      Client-side Humanoid:TakeDamage() on server-owned NPCs is
      filtered by Roblox's replication system — a silent no-op.
      Retaining it created a false impression of a secondary
      attack pathway and wasted one pcall allocation per attack.

    LOGIC-4 [LOW] SELL_KEYWORDS "npc" substring removed.
      Matched any prompt from any NPC model in the lobby
      (quest givers, augment vendors, slot machine operators).
]]

-- ════════════════════════════════════════════════════════════
-- SECTION 0: THREAD REGISTRY + PRE-EXECUTION CLEANUP
-- Must run before everything else, including the load guard.
-- Cancels any threads from a previous execution (e.g. after
-- a Rayfield CDN failure that cleared the guard and allowed
-- re-execution). ARCH-1 / ARCH-2.
-- ════════════════════════════════════════════════════════════
if getgenv then
    local reg = getgenv().ENI_THREAD_REGISTRY
    if reg then
        for _, handle in pairs(reg) do
            if handle then pcall(task.cancel, handle) end
        end
        getgenv().ENI_THREAD_REGISTRY = {}
    end
end

-- Thread registry interface (module-level API)
local function getThreadRegistry()
    if not getgenv then return {} end
    if not getgenv().ENI_THREAD_REGISTRY then
        getgenv().ENI_THREAD_REGISTRY = {}
    end
    return getgenv().ENI_THREAD_REGISTRY
end

local function registerThread(name, handle)
    getThreadRegistry()[name] = handle
end

local function cancelAllThreads()
    -- Cancels every registered thread and clears the registry.
    -- Called by Rejoin, load-guard cleanup, and re-exec path.
    local reg = getThreadRegistry()
    for name, handle in pairs(reg) do
        if handle then pcall(task.cancel, handle) end
        reg[name] = nil
    end
end

-- ════════════════════════════════════════════════════════════
-- SECTION 1: DOUBLE-LOAD GUARD
-- FIX S2 (retained): guard is set immediately to block rapid
-- concurrent re-executions, but CLEARED before any early-exit
-- return so a failed load allows retry. Confirmed permanent
-- only after Rayfield window is created.
-- ARCH-1: guard is only set here for concurrent blocking.
-- After a CDN failure + retry the prior threads were already
-- cancelled in SECTION 0 above.
-- ════════════════════════════════════════════════════════════
if getgenv and getgenv().ENI_SOLO_LOADED then
    print("[ENI] Already loaded — re-execution blocked. Use Rejoin button or rejoin manually.")
    return
end
if getgenv then getgenv().ENI_SOLO_LOADED = true end

local function clearLoadGuard()
    if getgenv then getgenv().ENI_SOLO_LOADED = nil end
end

-- ════════════════════════════════════════════════════════════
-- SECTION 2: SERVICES
-- ════════════════════════════════════════════════════════════
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TeleportService  = game:GetService("TeleportService")
local WS               = game:GetService("Workspace")
local RS               = game:GetService("ReplicatedStorage")
local UIS              = UserInputService

-- ════════════════════════════════════════════════════════════
-- SECTION 3: PATHS
-- Verified against Structure.txt v2.0
--
-- RS (service)
--   └─ ReplicatedStorage [Folder]
--         ├─ Remotes [Folder]
--         └─ Controllers [Folder]
--               └─ MainUIController [ModuleScript]
--                     ├─ Gold [IntValue]  ├─ Gems [IntValue]
--                     ├─ Raidium [IntValue] ├─ Souls2026 [IntValue]
--                     └─ Power [IntValue]
--
-- ARCH-4: MapFolder uses FindFirstChild first; if nil a background
-- task resolves it via WaitForChild(60) without blocking init.
-- ════════════════════════════════════════════════════════════
local RS_inner      = RS:WaitForChild("ReplicatedStorage", 10)
local RemotesFolder = RS_inner and RS_inner:WaitForChild("Remotes", 10)
local MobFolder     = WS:WaitForChild("Mobs", 10)

-- Map paths: attempt synchronous first, defer async if absent
local MapFolder     = WS:FindFirstChild("Map")
local CirclesFolder = MapFolder and MapFolder:FindFirstChild("Circles")
local LobbyFolder   = MapFolder and MapFolder:FindFirstChild("Lobby")

if not MapFolder then
    warn("[ENI] WS.Map not found at injection time — deferring resolution (60s window).")
    task.spawn(function()
        MapFolder = WS:WaitForChild("Map", 60)
        if MapFolder then
            CirclesFolder = MapFolder:FindFirstChild("Circles")
            LobbyFolder   = MapFolder:FindFirstChild("Lobby")
            if not CirclesFolder then
                warn("[ENI] WS.Map.Circles not found — portal scanning disabled.")
            end
            if not LobbyFolder then
                warn("[ENI] WS.Map.Lobby not found — sell/buy/quest teleport disabled.")
            end
        else
            warn("[ENI] WS.Map not found after 60s — AutoFarm portal features disabled.")
        end
    end)
end

local DropFolder = (function()
    local cam = WS:WaitForChild("Camera", 10)
    local d   = cam and cam:FindFirstChild("Drops")
    if not d then warn("[ENI] Camera.Drops not found — AutoCollect/LootESP disabled.") end
    return d
end)()

-- ════════════════════════════════════════════════════════════
-- SECTION 4: REMOTES
-- ════════════════════════════════════════════════════════════
local R = {}
if RemotesFolder then
    for _, n in ipairs({
        "BossAltarSpawnBoss","FullDungeonRemote","SpinSlotMachine",
        "GiveSlotMachinePrize","StartChallenge","SendAugment",
        "ChooseAugment","SacrificeWeapon","BodyMover","MouseReplication",
    }) do
        local o = RemotesFolder:FindFirstChild(n)
        if o then R[n] = o end
    end
else
    warn("[ENI] RemotesFolder not found — server remotes disabled.")
end

-- Quest RemoteFunctions (RS.Controllers.Quests)
local QF = {}
local function loadQuestRemotes()
    local ctrl = RS_inner and RS_inner:FindFirstChild("Controllers")
    local qr   = ctrl and ctrl:FindFirstChild("Quests")
    if not qr then return end
    for _, n in ipairs({
        "RequestQuest","GetActiveQuests","SurrenderQuest",
        "TurnInQuest","MarkGiverViewed","ResetGiverViewed",
    }) do
        local o = qr:FindFirstChild(n)
        if o then QF[n] = o end
    end
end
loadQuestRemotes()

-- ════════════════════════════════════════════════════════════
-- SECTION 5: LOCAL PLAYER & CHARACTER
--
-- ARCH-3: refreshChar() is now STRICTLY SYNCHRONOUS.
-- It reads LP.Character and returns false if nil — no internal
-- CharacterAdded:Wait() call. The blocking fallback was the
-- root cause of the double-refresh race condition where both
-- the farm loop guard and the CharacterAdded handler entered
-- the function concurrently, producing two writes to Hum/HRP
-- and two startAutoFarm() calls for the same respawn event.
-- The CharacterAdded:Connect handler (SECTION 13) is the
-- single authoritative restart point for all systems.
-- ════════════════════════════════════════════════════════════
local LP           = Players.LocalPlayer
local Char, Hum, HRP
local NoClipParts  = {}
local StaminaParts = {}
local charConns    = {}

local function rebuildCharCaches()
    NoClipParts  = {}
    StaminaParts = {}
    if not Char then return end
    for _, v in ipairs(Char:GetDescendants()) do
        if v:IsA("BasePart") then NoClipParts[#NoClipParts+1] = v end
        local nm = v.Name:lower()
        if (v:IsA("NumberValue") or v:IsA("IntValue"))
           and (nm:find("stamina") or nm:find("energy")) then
            StaminaParts[#StaminaParts+1] = v
        end
    end
end

-- ARCH-3: Synchronous only. Returns true on success, false if
-- LP.Character is nil or WaitForChild times out. No Wait() call.
local function refreshChar()
    for _, c in ipairs(charConns) do c:Disconnect() end
    charConns = {}

    Char = LP.Character
    if not Char then
        -- Character not loaded yet — CharacterAdded will call us
        return false
    end

    Hum = Char:WaitForChild("Humanoid", 5)
    HRP = Char:WaitForChild("HumanoidRootPart", 5)

    -- FIX H4: diagnostic warn if WaitForChild timed out
    if not Hum or not HRP then
        warn("[ENI] refreshChar: Humanoid or HRP did not load within 5s — features suspended until next respawn.")
        return false
    end

    rebuildCharCaches()

    charConns[1] = Char.ChildAdded:Connect(function(c)
        if c:IsA("Tool") then rebuildCharCaches() end
    end)
    charConns[2] = Char.ChildRemoved:Connect(function(c)
        if c:IsA("Tool") then rebuildCharCaches() end
    end)

    return true
end

-- Initial character setup (non-blocking; refreshChar() returns
-- false gracefully if character not yet present)
task.spawn(refreshChar)

-- ════════════════════════════════════════════════════════════
-- SECTION 6: FLAGS & CONFIG
-- ════════════════════════════════════════════════════════════
local Flags = {
    -- Dungeon loop
    AutoFarm        = false,
    AutoQuest       = false,
    AutoSell        = false,
    AutoBuyMerchant = false,
    AutoEquipBest   = false,
    AutoRedeemCodes = false,
    PrioritizeRed   = true,
    AutoScaleDiff   = true,

    -- Combat
    KillAura        = false,
    AutoSkills      = false,
    AutoCollect     = false,

    -- Player
    GodMode         = false,
    InfiniteStamina = false,
    NoClip          = false,
    AntiAFK         = false,
    SpeedHack       = false,

    -- ESP
    MobESP          = false,
    PlayerESP       = false,
    LootESP         = false,
    Chams           = false,
    Tracers         = false,

    -- Misc
    AutoSlotMachine = false,
    AutoAugment     = false,
}

local Config = {
    KillAuraRadius   = 80,
    WalkSpeed        = 16,
    JumpPower        = 50,
    ESPMaxDist       = 500,
    SlotDelay        = 2,
    TracerPoolSize   = 200,

    -- Skill keys (Xeno keypress codes): adjust to your class
    -- Format: {keyCode, cooldown_seconds}
    SkillKeys = {
        { key = 0x51, cd = 8  },  -- Q
        { key = 0x45, cd = 12 },  -- E
        { key = 0x52, cd = 20 },  -- R
        { key = 0x46, cd = 30 },  -- F
    },
}

-- ════════════════════════════════════════════════════════════
-- SECTION 7: UTILITY
-- ════════════════════════════════════════════════════════════
local rng = Random.new()
local function rnd(lo, hi) return lo + rng:NextNumber()*(hi-lo) end
local function dist(a, b)  return (a-b).Magnitude end
local function inWS(obj)   return obj and obj:IsDescendantOf(WS) end

local function jitter(cf, r, y)
    r = r or 2; y = y or 0.5
    return cf + Vector3.new(rnd(-r,r), rnd(-y,y), rnd(-r,r))
end

-- PP-1: ProximityPrompt composite text helper.
-- ObjectText contains the descriptive label (Sell, Chest, etc).
-- ActionText contains the interaction key label ("E", "Use").
-- Name is the instance name — least informative, checked last.
-- All three properties are joined so keyword matching is
-- exhaustive regardless of which property the dev used.
local function getPromptText(pp)
    local parts = {}
    -- ObjectText is semantically richest — check first
    if pp.ObjectText and pp.ObjectText ~= "" then
        parts[#parts+1] = pp.ObjectText:lower()
    end
    if pp.ActionText and pp.ActionText ~= "" then
        parts[#parts+1] = pp.ActionText:lower()
    end
    if pp.Name and pp.Name ~= "" then
        parts[#parts+1] = pp.Name:lower()
    end
    return table.concat(parts, " ")
end

-- ════════════════════════════════════════════════════════════
-- SECTION 8: CURRENCY
-- ════════════════════════════════════════════════════════════
local function getCurrencies()
    local ctrl    = RS_inner and RS_inner:FindFirstChild("Controllers")
    local mui     = ctrl and ctrl:FindFirstChild("MainUIController")
    local ls      = LP:FindFirstChild("leaderstats")
    local function v(p,n) local x=p and p:FindFirstChild(n); return x and x.Value or 0 end
    -- FIX J (retained): cache Power once to avoid two FindFirstChild traversals
    local muiPower = v(mui, "Power")
    return {
        Power   = muiPower > 0 and muiPower or v(ls, "Power"),
        Gold    = v(mui,"Gold"),
        Gems    = v(mui,"Gems"),
        Souls   = v(mui,"Souls2026"),
        Raidium = v(mui,"Raidium"),
    }
end

local function getPlayerPower()
    return getCurrencies().Power
end

-- ════════════════════════════════════════════════════════════
-- SECTION 9: MOB CACHE (event-driven registry)
-- ════════════════════════════════════════════════════════════
local HITBOX   = {SlashHitbox=true,AttackHitbox=true,DamageHitbox=true,WeaponHitbox=true}
local MobCache = {}
local CacheDirty = true

local function buildParts(model)
    local t = {}
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") and not HITBOX[d.Name] then t[#t+1]=d end
    end
    return t
end

local function rebuildCache()
    MobCache = {}; CacheDirty = false
    local pchars = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then pchars[p.Character]=true end
    end
    local function add(m)
        if pchars[m] then return end
        local hum = m:FindFirstChildWhichIsA("Humanoid")
        local hrp = m:FindFirstChild("HumanoidRootPart")
        if not hum or not hrp or hum.Health<=0 then return end
        MobCache[#MobCache+1] = {model=m,hrp=hrp,hum=hum,parts=buildParts(m)}
    end
    if MobFolder then
        for _, c in ipairs(MobFolder:GetChildren()) do
            if c:IsA("Model") then add(c) end
        end
    end
    if MapFolder then
        for _, reg in ipairs(MapFolder:GetChildren()) do
            local dm = reg:FindFirstChild("Mobs")
            if dm then
                for _, c in ipairs(dm:GetChildren()) do
                    if c:IsA("Model") then add(c) end
                end
            end
        end
    end
end

local function dirty() CacheDirty = true end

if MobFolder then
    MobFolder.ChildAdded:Connect(dirty)
    MobFolder.ChildRemoved:Connect(dirty)
end

if MapFolder then
    local function watchReg(reg)
        local dm = reg:FindFirstChild("Mobs")
        if dm then
            dm.ChildAdded:Connect(dirty); dm.ChildRemoved:Connect(dirty)
        end
        reg.ChildAdded:Connect(function(c)
            if c.Name == "Mobs" then
                c.ChildAdded:Connect(dirty); c.ChildRemoved:Connect(dirty); dirty()
            end
        end)
    end
    for _, r in ipairs(MapFolder:GetChildren()) do watchReg(r) end
    MapFolder.ChildAdded:Connect(function(r) watchReg(r); dirty() end)
    MapFolder.ChildRemoved:Connect(dirty)
end

local function getMobs(maxD)
    if CacheDirty then rebuildCache() end
    if not maxD or not HRP then return MobCache end
    local out = {}
    for _, e in ipairs(MobCache) do
        if inWS(e.model) and e.hum.Health>0
           and dist(HRP.Position, e.hrp.Position) <= maxD then
            out[#out+1] = e
        end
    end
    return out
end

local function getNearestMob(maxD)
    if not HRP then return nil end
    local near, nearD = nil, math.huge
    for _, e in ipairs(getMobs(maxD)) do
        local d = dist(HRP.Position, e.hrp.Position)
        if d < nearD then near=e; nearD=d end
    end
    return near, nearD
end

-- ════════════════════════════════════════════════════════════
-- SECTION 10: WEAPON HANDLE
-- ════════════════════════════════════════════════════════════
local function getHandle()
    if not Char then return HRP end
    for _, item in ipairs(Char:GetChildren()) do
        if item:IsA("Tool") then
            return item:FindFirstChild("Handle")
                or item:FindFirstChildWhichIsA("BasePart")
                or HRP
        end
    end
    return HRP
end

-- ════════════════════════════════════════════════════════════
-- SECTION 11: ATTACK  (TouchEnded then TouchBegan — debounce)
--
-- LOGIC-3: Removed the trailing TakeDamage call.
-- Humanoid:TakeDamage() from the client on a server-owned NPC
-- is filtered by Roblox's property replication security model —
-- the write never reaches the server Humanoid. It was consuming
-- a pcall allocation on every attack tick while doing nothing.
-- The firetouchinterest calls are the actual attack mechanism.
-- ════════════════════════════════════════════════════════════
local function attackEntry(e)
    if not inWS(e.model) or e.hum.Health<=0 then return end
    local h = getHandle(); if not h then return end
    for _, p in ipairs(e.parts) do
        if p and p.Parent then pcall(firetouchinterest, h, p, 1) end
    end
    task.wait()
    if not inWS(e.model) or e.hum.Health<=0 then return end
    for _, p in ipairs(e.parts) do
        if p and p.Parent then pcall(firetouchinterest, h, p, 0) end
    end
    -- TakeDamage removed (LOGIC-3): client-side call on server-owned
    -- Humanoid is a silent no-op filtered by replication security.
end

-- ════════════════════════════════════════════════════════════
-- SECTION 12: GOD MODE — three-layer implementation
--
-- Layer 1 (Primary): Heartbeat health floor — see SECTION 15.
--   Restores Health to MaxHealth every ~100ms. Catches all
--   damage pathways including server-replicated property writes.
--
-- Layer 2 (Secondary): __namecall hook — intercepts client-side
--   TakeDamage, BreakJoints, Kill on the local Humanoid.
--   Silent against server-side damage; Layer 1 is the workhorse.
--
-- Layer 3 (UX): Rayfield:Notify on toggle reports active layers.
-- ════════════════════════════════════════════════════════════
local namecallHook
local godHookActive = false

if hookmetamethod and getrawmetatable then
    pcall(function()
        local mt = getrawmetatable(game)
        setreadonly(mt, false)

        namecallHook = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            -- FIX 13 / FIX 15 (retained)
            if Flags.GodMode and Hum and Hum.Parent
               and self == Hum
               and (method == "TakeDamage" or method == "BreakJoints" or method == "Kill") then
                return
            end
            return namecallHook(self, ...)
        end)

        -- FIX 14: re-lock in its own pcall (retained)
        pcall(function() setreadonly(mt, true) end)
    end)

    if namecallHook then
        godHookActive = true
    else
        warn("[ENI] GodMode: namecall hook failed to install — " ..
             "TakeDamage/BreakJoints/Kill interception inactive. " ..
             "Heartbeat health floor remains active.")
    end
end

-- ════════════════════════════════════════════════════════════
-- SECTION 13: PORTAL SCANNER & SCORER
-- ════════════════════════════════════════════════════════════
-- FIX L (retained): ordered priority tag list
local PORTAL_POWER_TAGS_ORDERED = {
    { tag = "boss",   power = 10000 },
    { tag = "red",    power = 10000 },
    { tag = "raid",   power = 10000 },
    { tag = "expert", power = 5000  },
    { tag = "hard",   power = 2500  },
    { tag = "normal", power = 1000  },
    { tag = "easy",   power = 500   },
    { tag = "circle", power = 0     },
}

local function getPortalReq(circle)
    local req = circle:FindFirstChild("PowerRequirement")
               or circle:FindFirstChild("MinPower")
               or circle:FindFirstChild("RequiredPower")
    -- FIX L1 (retained): accept NumberValue, not just IntValue
    if req and (req:IsA("IntValue") or req:IsA("NumberValue")) then
        return req.Value
    end
    local nameLower = circle.Name:lower()
    for _, entry in ipairs(PORTAL_POWER_TAGS_ORDERED) do
        if nameLower:find(entry.tag) then return entry.power end
    end
    return 0
end

local function isRedPortal(circle)
    local n = circle.Name:lower()
    if n:find("red") or n:find("boss") or n:find("raid") then return true end
    local gate = circle:FindFirstChild("Gate") or circle:FindFirstChildWhichIsA("BasePart")
    if gate and gate:IsA("BasePart") then
        local col = gate.Color
        if col.R > 0.6 and col.G < 0.35 and col.B < 0.35 then return true end
    end
    return false
end

local function scorePortal(circle, playerPower)
    local req   = getPortalReq(circle)
    local isRed = isRedPortal(circle)
    local score = 0

    -- FIX 9 / FIX L2 (retained): catch-all portals skip power
    -- check and do NOT receive the PrioritizeRed boss bonus
    if req == 0 then
        score = 50

    elseif Flags.AutoScaleDiff then
        -- FIX 1 (retained): power-scaling only when flag is on
        if playerPower < req * 0.8 then
            score = -9999
        else
            local diff = playerPower - req
            score = 100 - math.min(diff / math.max(req, 1) * 50, 80)
        end
        if isRed and Flags.PrioritizeRed then score = score + 500 end
    else
        -- AutoScaleDiff off: flat score, power ignored
        score = 75
        if isRed and Flags.PrioritizeRed then score = score + 500 end
    end

    return score, req, isRed
end

local function getBestPortal()
    if not CirclesFolder then return nil end
    local playerPower = getPlayerPower()
    local best, bestScore = nil, -math.huge

    for _, circle in ipairs(CirclesFolder:GetChildren()) do
        if circle:IsA("Model") then
            -- Note: scorePortal returns (score, req, isRed).
            -- We capture only score here intentionally.
            local score = scorePortal(circle, playerPower)
            if score > bestScore then
                best      = circle
                bestScore = score
            end
        end
    end

    -- FIX 3 (retained): return nil when all portals are out of reach
    if bestScore < -500 then return nil end
    return best
end

local function enterPortal(portal)
    if not portal or not HRP then return false end
    local gate = portal:FindFirstChild("Gate")
               or portal:FindFirstChild("Center")
               or portal:FindFirstChildWhichIsA("BasePart")
    if not gate then return false end

    HRP.CFrame = CFrame.new(gate.Position + Vector3.new(0, 5, 0))
    task.wait(rnd(0.5, 0.8))

    local entered = false
    for _, desc in ipairs(portal:GetDescendants()) do
        if desc:IsA("ProximityPrompt") then
            pcall(fireproximityprompt, desc)
            entered = true
        end
    end

    -- FIX C (retained): only fire FullDungeonRemote as fallback
    if not entered and R.FullDungeonRemote then
        pcall(function() R.FullDungeonRemote:FireServer() end)
        entered = true
    end

    return entered
end

-- ════════════════════════════════════════════════════════════
-- SECTION 14: COLLECT
-- PP-1: isCollectPrompt() now uses getPromptText() helper
-- ════════════════════════════════════════════════════════════
local function collectDrop(obj)
    if obj:IsA("Model") then
        local center = obj:FindFirstChild("Center")
        local pp = center and center:FindFirstChildWhichIsA("ProximityPrompt")
        if pp then pcall(fireproximityprompt, pp); return end
        for _, d in ipairs(obj:GetDescendants()) do
            if d:IsA("ProximityPrompt") then pcall(fireproximityprompt, d) end
        end
    elseif obj:IsA("BasePart") then
        local pp = obj:FindFirstChildWhichIsA("ProximityPrompt")
        if pp then pcall(fireproximityprompt, pp) end
    end
end

local function collectAll()
    if not DropFolder then return end
    for _, obj in ipairs(DropFolder:GetChildren()) do
        pcall(collectDrop, obj)
        task.wait(rnd(0.04, 0.10))
    end
end

-- FIX L3 (retained) + PP-1: getPromptText() ensures ObjectText
-- is checked, which is where the game dev puts "Chest", "Reward",
-- "Loot", etc. Previous code using ActionText or never reached
-- ObjectText, silently matching zero prompts.
local COLLECT_KEYWORDS = {"chest","reward","loot","pickup","claim","prize"}
local function isCollectPrompt(pp)
    local txt = getPromptText(pp)  -- PP-1: composite text search
    for _, kw in ipairs(COLLECT_KEYWORDS) do
        if txt:find(kw) then return true end
    end
    return false
end

local function collectDungeonRewards()
    if not MapFolder then return end
    for _, reg in ipairs(MapFolder:GetChildren()) do
        if reg.Name ~= "Lobby" and reg.Name ~= "Circles" then
            for _, desc in ipairs(reg:GetDescendants()) do
                if desc:IsA("ProximityPrompt") and isCollectPrompt(desc) then
                    pcall(fireproximityprompt, desc)
                end
            end
        end
    end
    collectAll()
end

if DropFolder then
    DropFolder.ChildAdded:Connect(function(obj)
        if Flags.LootESP then
            pcall(function() addLootESP(obj) end)
        end
        if not Flags.AutoCollect then return end
        if obj:IsA("BasePart") then
            local pp = obj:FindFirstChildWhichIsA("ProximityPrompt")
            if pp then
                task.wait(rnd(0.3, 0.6)); pcall(fireproximityprompt, pp)
            else
                -- FIX D (retained): paired AncestryChanged cleanup
                local conn, cleanConn
                cleanConn = obj.AncestryChanged:Connect(function()
                    if not obj:IsDescendantOf(game) then
                        if conn then conn:Disconnect() end
                        cleanConn:Disconnect()
                    end
                end)
                conn = obj.ChildAdded:Connect(function(c)
                    if c:IsA("ProximityPrompt") then
                        conn:Disconnect()
                        cleanConn:Disconnect()
                        task.wait(rnd(0.1, 0.25)); pcall(fireproximityprompt, c)
                    end
                end)
            end
        else
            task.wait(rnd(0.3, 0.6)); pcall(collectDrop, obj)
        end
    end)
    DropFolder.ChildRemoved:Connect(function(obj)
        pcall(function() removeLootESP(obj) end)
    end)
end

-- ════════════════════════════════════════════════════════════
-- SECTION 15: AUTO SELL
-- PP-1: findSellPrompts() now uses getPromptText() helper.
-- LOGIC-4: Removed "npc" from SELL_KEYWORDS — too broad,
-- matched every NPC model in the lobby (quest givers, augment
-- vendors, slot operators). Only descriptive sell terms kept.
-- ════════════════════════════════════════════════════════════
local SELL_KEYWORDS = {"sell","merchant","shop","store","vendor"}
-- "npc" removed (LOGIC-4): substring matched all lobby NPCs

local function findSellPrompts()
    local prompts = {}
    if not LobbyFolder then return prompts end
    for _, desc in ipairs(LobbyFolder:GetDescendants()) do
        if desc:IsA("ProximityPrompt") then
            local txt = getPromptText(desc)  -- PP-1: composite text
            for _, kw in ipairs(SELL_KEYWORDS) do
                if txt:find(kw) then prompts[#prompts+1] = desc; break end
            end
        end
    end
    return prompts
end

local function doAutoSell()
    local prompts = findSellPrompts()
    for _, pp in ipairs(prompts) do
        -- FIX L4 (retained): resolve BasePart from either
        -- direct-parent or Model-parent layout
        if HRP then
            local targetPart = (pp.Parent and pp.Parent:IsA("BasePart") and pp.Parent)
                            or (pp.Parent and pp.Parent:IsA("Model")
                                and pp.Parent:FindFirstChildWhichIsA("BasePart"))
            if targetPart then
                HRP.CFrame = CFrame.new(targetPart.Position + Vector3.new(0,5,0))
                task.wait(0.3)
            end
        end
        pcall(fireproximityprompt, pp)
        task.wait(rnd(0.3, 0.6))
    end
end

-- ════════════════════════════════════════════════════════════
-- SECTION 16: AUTO BUY MERCHANT SHOP
-- PP-1: doAutoBuy() now uses getPromptText() helper.
-- FIX 5 (retained): "merchant" and "shop" removed to prevent
-- double-fires with SELL_KEYWORDS.
-- LOGIC-1: Removed "item" — too broad as a substring match.
-- "item" matched "UpgradeItem", "DisenchantItem", "ItemShop",
-- etc., firing unintended shop interactions. After PP-1 fix
-- enables ObjectText matching, this becomes an active hazard.
-- ════════════════════════════════════════════════════════════
local BUY_KEYWORDS = {"buy","purchase","trade"}
-- "item" removed (LOGIC-1): substring too broad post-PP-1 fix

local function doAutoBuy()
    if not LobbyFolder then return end
    for _, desc in ipairs(LobbyFolder:GetDescendants()) do
        if desc:IsA("ProximityPrompt") then
            local txt = getPromptText(desc)  -- PP-1: composite text
            for _, kw in ipairs(BUY_KEYWORDS) do
                if txt:find(kw) then
                    pcall(fireproximityprompt, desc)
                    task.wait(rnd(0.2, 0.4))
                    break
                end
            end
        end
    end
end

-- ════════════════════════════════════════════════════════════
-- SECTION 17: AUTO EQUIP BEST GEAR
--
-- STATE-1: Previous version scanned only Backpack, missing the
-- currently equipped tool. If the equipped tool had the highest
-- power it was not found — the function selected an inferior
-- backpack item, moved the best tool to Backpack on unequip,
-- then equipped the inferior item. This cycled the best gear
-- in/out of the character slot on every single call.
-- Fix: scan both Backpack and Char:GetChildren(). Track which
-- tool is currently equipped. Skip the swap if best == current.
--
-- LOGIC-2: getToolPower() extended to check additional common
-- attribute names and Roblox Instance Attributes.
-- ════════════════════════════════════════════════════════════

-- LOGIC-2: Extended attribute name list for tool power lookup
local TOOL_POWER_ATTRS = {
    "Power","Level","Stats","GearScore","Tier",
    "Rank","Score","Strength","Attack",
}

local function getToolPower(tool)
    -- Check known child value names
    for _, attr in ipairs(TOOL_POWER_ATTRS) do
        local v = tool:FindFirstChild(attr)
        if v and (v:IsA("IntValue") or v:IsA("NumberValue")) then
            return v.Value
        end
    end
    -- Check Roblox Instance Attributes (newer game pattern)
    for _, attr in ipairs(TOOL_POWER_ATTRS) do
        local av = pcall(function() return tool:GetAttribute(attr) end)
        if type(av) == "number" then return av end
    end
    -- Last resort: parse first digit sequence from tool name
    local n = tool.Name:match("%d+")
    if n then
        warn("[ENI] getToolPower: name-parse fallback for '" .. tool.Name ..
             "' — add a recognized value child to eliminate this warn.")
        return tonumber(n)
    end
    return 0
end

local function doAutoEquipBest()
    local backpack = LP:FindFirstChild("Backpack")
    if not backpack or not Char then return end

    local best, bestPow = nil, -1
    local currentTool   = nil   -- STATE-1: track what's equipped

    -- STATE-1: scan Backpack
    for _, tool in ipairs(backpack:GetChildren()) do
        if tool:IsA("Tool") then
            local pw = getToolPower(tool)
            if pw > bestPow then best = tool; bestPow = pw end
        end
    end

    -- STATE-1: scan currently equipped tool in character
    for _, item in ipairs(Char:GetChildren()) do
        if item:IsA("Tool") then
            currentTool = item
            local pw = getToolPower(item)
            if pw > bestPow then best = item; bestPow = pw end
        end
    end

    if not best then return end

    -- STATE-1: skip swap if best is already equipped
    if best == currentTool then return end

    -- Unequip current tool first (FIX G retained)
    if currentTool then
        pcall(function() currentTool.Parent = backpack end)
        task.wait(0.05)
    end

    pcall(function() best.Parent = Char end)
end

-- ════════════════════════════════════════════════════════════
-- SECTION 18: AUTO QUEST
-- ════════════════════════════════════════════════════════════
local function doAutoQuest()
    pcall(function()
        if QF.TurnInQuest    then QF.TurnInQuest:InvokeServer()    end
    end)
    task.wait(rnd(0.4, 0.7))
    pcall(function()
        if QF.RequestQuest   then QF.RequestQuest:InvokeServer()   end
    end)
    task.wait(rnd(0.4, 0.7))
    pcall(function()
        if QF.MarkGiverViewed then QF.MarkGiverViewed:InvokeServer() end
    end)
end

-- ════════════════════════════════════════════════════════════
-- SECTION 19: AUTO REDEEM CODES
--
-- STATE-2: Previous InvokeServer had no timeout. A hung server
-- handler stalled the entire LOBBY state indefinitely, and
-- codesRedeemedThisSession was never set if the call never
-- returned, causing repeated attempts on every LOBBY iteration.
-- Fix: each code fires in its own task.spawn coroutine. A
-- task.delay sets a 5-second hard timeout per code. The main
-- loop waits on a per-code done signal with bounded wait time.
-- ════════════════════════════════════════════════════════════
local CODES = {
    "80KLIKESLETSGOO",
    "SORRYABOUTUPD",
    "SOLOHUNTERS",
    "RELEASE",
    "UPDATE1",
}

local codesRedeemedThisSession = false

local function doRedeemCodes(forceRetry)
    if codesRedeemedThisSession and not forceRetry then return end
    local ctrl = RS_inner and RS_inner:FindFirstChild("Controllers")
    local cr   = ctrl and ctrl:FindFirstChild("CodeRedemption")
    local rf   = cr  and cr:FindFirstChild("RedeemCode")
    if not rf then return end

    for _, code in ipairs(CODES) do
        -- STATE-2: spawn the InvokeServer in its own coroutine
        -- and enforce a hard 5-second timeout per code
        local done    = false
        local timeout = false

        local codeThread = task.spawn(function()
            pcall(function() rf:InvokeServer(code) end)
            done = true
        end)

        -- Timeout sentinel: cancel the coroutine if it hasn't
        -- finished within 5 seconds
        local timeoutHandle = task.delay(5, function()
            if not done then
                timeout = true
                pcall(task.cancel, codeThread)
            end
        end)

        -- Wait for done or timeout (poll at 100ms granularity)
        local elapsed = 0
        while not done and not timeout and elapsed < 5.5 do
            local dt = task.wait(0.1)
            elapsed  = elapsed + dt
        end

        -- Clean up the timeout task if it didn't fire
        if done and not timeout then
            pcall(task.cancel, timeoutHandle)
        end

        task.wait(rnd(0.3, 0.6))
    end

    codesRedeemedThisSession = true
end

-- ════════════════════════════════════════════════════════════
-- SECTION 20: DUNGEON STATE MACHINE
-- ════════════════════════════════════════════════════════════
local DungeonState  = "LOBBY"
local dungeonThread = nil
local DungeonTimeout = 120

-- FIX A (retained): nil-safe dungeon mob predicate
local function isDungeonMob(model)
    return not MobFolder or not model:IsDescendantOf(MobFolder)
end

local function hasDungeonMobs()
    local mobs = getMobs()
    for _, e in ipairs(mobs) do
        if isDungeonMob(e.model) then return true end
    end
    return false
end

local function waitForDungeonLoad(timeoutSec)
    local elapsed = 0
    while elapsed < timeoutSec do
        dirty()
        if hasDungeonMobs() then return true end
        -- FIX B (retained): actual delta from task.wait()
        local actual = task.wait(0.5)
        elapsed = elapsed + actual
    end
    return false
end

local function killAllDungeonMobs()
    local timeout = DungeonTimeout
    local elapsed = 0
    while elapsed < timeout do
        dirty()
        local dungeonMobs = {}
        for _, e in ipairs(getMobs()) do
            if isDungeonMob(e.model) then
                dungeonMobs[#dungeonMobs+1] = e
            end
        end
        if #dungeonMobs == 0 then break end
        for _, e in ipairs(dungeonMobs) do
            if inWS(e.model) and e.hum.Health > 0 then
                attackEntry(e)
            end
        end
        dirty()
        -- FIX 6 (retained): actual delta
        local actual = task.wait(rnd(0.15, 0.28))
        elapsed = elapsed + actual
    end
end

local function returnToLobby()
    -- FIX S4 (retained): HRP guard at function entry
    if not HRP then
        if R.FullDungeonRemote then
            pcall(function() R.FullDungeonRemote:FireServer() end)
        end
        return
    end
    if R.FullDungeonRemote then
        pcall(function() R.FullDungeonRemote:FireServer() end)
        task.wait(1.5)
    end
    if LobbyFolder then
        local spawn = LobbyFolder:FindFirstChild("SpawnLocation")
                   or LobbyFolder:FindFirstChildWhichIsA("BasePart", true)
        if spawn then
            HRP.CFrame = CFrame.new(spawn.Position + Vector3.new(0,6,0))
            return
        end
    end
    HRP.CFrame = CFrame.new(Vector3.new(0, 100, 0))
end

-- STATE-3: inferStartState() improved dungeon detection.
-- Previous version relied solely on CirclesFolder being empty,
-- which fails in shared-workspace games where portals persist
-- in MapFolder.Circles regardless of player position.
-- Additional signal: if the player is not near any lobby
-- landmark (spawn, quest giver) and dungeon regions exist,
-- treat as inside a cleared dungeon (LEAVING).
local function inferStartState()
    dirty()
    -- Check for live dungeon mobs — if found, mid-fight
    for _, e in ipairs(getMobs()) do
        if isDungeonMob(e.model) then
            return "FIGHTING"
        end
    end

    -- Check CirclesFolder (original logic)
    if CirclesFolder then
        local hasPortals = false
        for _, c in ipairs(CirclesFolder:GetChildren()) do
            if c:IsA("Model") then hasPortals = true; break end
        end

        if not hasPortals and HRP then
            return "LEAVING"
        end
    end

    -- STATE-3: secondary position-based signal.
    -- If HRP exists and the player is not near any known lobby
    -- BasePart within a reasonable threshold, and MapFolder has
    -- non-lobby, non-circles children (dungeon regions), the
    -- player is likely inside a cleared dungeon.
    if HRP and LobbyFolder and MapFolder then
        local nearLobby = false
        local LOBBY_THRESHOLD = 300  -- studs
        for _, part in ipairs(LobbyFolder:GetDescendants()) do
            if part:IsA("BasePart") then
                if dist(HRP.Position, part.Position) < LOBBY_THRESHOLD then
                    nearLobby = true
                    break
                end
            end
        end

        if not nearLobby then
            -- Check if dungeon regions exist
            for _, child in ipairs(MapFolder:GetChildren()) do
                if child.Name ~= "Lobby" and child.Name ~= "Circles" then
                    return "LEAVING"
                end
            end
        end
    end

    return "LOBBY"
end

local function startAutoFarm()
    if dungeonThread then pcall(task.cancel, dungeonThread); dungeonThread = nil end

    -- FIX S3 (retained): resume from correct state
    DungeonState = inferStartState()
    if DungeonState ~= "LOBBY" then
        pcall(function()
            Rayfield:Notify({
                Title   = "Auto Farm",
                Content = "Detected active dungeon — resuming from " .. DungeonState,
                Duration = 4,
            })
        end)
    end

    dungeonThread = task.spawn(function()
        while Flags.AutoFarm do

            -- ARCH-3: farm loop guard no longer calls refreshChar().
            -- CharacterAdded is the authoritative restart point.
            -- Guard simply waits and continues when char is absent.
            if not HRP or not Hum or Hum.Health <= 0 then
                task.wait(1)
                continue
            end

            -- ── LOBBY ─────────────────────────────────────────
            if DungeonState == "LOBBY" then

                if Flags.AutoSell then
                    doAutoSell()
                    task.wait(rnd(0.5, 1.0))
                end

                if Flags.AutoBuyMerchant then
                    doAutoBuy()
                    task.wait(rnd(0.3, 0.6))
                end

                if Flags.AutoEquipBest then
                    doAutoEquipBest()
                end

                -- FIX 2 (retained): once-per-session guard
                if Flags.AutoRedeemCodes then
                    doRedeemCodes(false)
                end

                local portal = getBestPortal()
                if not portal then
                    task.wait(2); continue
                end

                enterPortal(portal)
                DungeonState = "ENTERING"
                task.wait(rnd(2.5, 4.5))

            -- ── ENTERING ──────────────────────────────────────
            elseif DungeonState == "ENTERING" then

                local loaded = waitForDungeonLoad(15)
                if loaded then
                    DungeonState = "FIGHTING"
                else
                    DungeonState = "LEAVING"
                end

            -- ── FIGHTING ──────────────────────────────────────
            elseif DungeonState == "FIGHTING" then

                killAllDungeonMobs()
                DungeonState = "COLLECTING"

            -- ── COLLECTING ────────────────────────────────────
            elseif DungeonState == "COLLECTING" then

                collectDungeonRewards()
                task.wait(rnd(0.5, 1.0))
                DungeonState = "LEAVING"

            -- ── LEAVING ───────────────────────────────────────
            elseif DungeonState == "LEAVING" then

                returnToLobby()
                dirty()
                task.wait(rnd(1.5, 3.0))
                -- FIX 4 (retained): QUESTING state
                DungeonState = Flags.AutoQuest and "QUESTING" or "LOBBY"

            -- ── QUESTING ──────────────────────────────────────
            -- FIX 4 (retained): proper QUESTING state branch
            elseif DungeonState == "QUESTING" then

                if HRP and LobbyFolder then
                    local qg   = LobbyFolder:FindFirstChild("QuestGiver")
                    local base = qg and qg:FindFirstChildWhichIsA("BasePart")
                    if base then
                        HRP.CFrame = CFrame.new(base.Position + Vector3.new(0,5,0))
                        task.wait(rnd(0.4, 0.7))
                    end
                end

                doAutoQuest()
                task.wait(rnd(0.5, 1.0))
                DungeonState = "LOBBY"

            end
        end

        DungeonState = "LOBBY"
    end)

    -- ARCH-1: register farm thread handle
    registerThread("dungeonThread", dungeonThread)
end

local function stopAutoFarm()
    if dungeonThread then
        pcall(task.cancel, dungeonThread)
        registerThread("dungeonThread", nil)
        dungeonThread = nil
    end
    DungeonState = "LOBBY"
end

-- ════════════════════════════════════════════════════════════
-- SECTION 21: MISC AUTOMATIONS
-- ARCH-2: all thread handles registered for unified cancellation
-- ════════════════════════════════════════════════════════════
local slotThread, augThread, afkThread

local function startSlot()
    if slotThread then pcall(task.cancel, slotThread) end
    slotThread = task.spawn(function()
        while Flags.AutoSlotMachine do
            pcall(function() if R.SpinSlotMachine then R.SpinSlotMachine:FireServer() end end)
            task.wait(Config.SlotDelay * rnd(0.8, 1.2))
            pcall(function() if R.GiveSlotMachinePrize then R.GiveSlotMachinePrize:FireServer() end end)
            task.wait(Config.SlotDelay * rnd(0.8, 1.2))
        end
    end)
    registerThread("slotThread", slotThread)
end

local function startAugment()
    if augThread then pcall(task.cancel, augThread); augThread = nil end
    augThread = task.spawn(function()
        while Flags.AutoAugment do
            pcall(function() if R.ChooseAugment then R.ChooseAugment:FireServer(1) end end)
            task.wait(rnd(0.8, 1.4))
        end
        augThread = nil
    end)
    registerThread("augThread", augThread)
end

local function startAntiAFK()
    if afkThread then pcall(task.cancel, afkThread) end
    afkThread = task.spawn(function()
        while Flags.AntiAFK do
            task.wait(rnd(55, 75))
            if Flags.AntiAFK and Hum and Hum.Parent then
                -- FIX M (retained): ChangeState, not Humanoid.Jump
                pcall(function()
                    Hum:ChangeState(Enum.HumanoidStateType.Jumping)
                end)
            end
        end
    end)
    registerThread("afkThread", afkThread)
end

-- ════════════════════════════════════════════════════════════
-- SECTION 22: ESP
-- ════════════════════════════════════════════════════════════
local MobESPObjs  = {}
local PlrESPObjs  = {}
local LootESPObjs = {}
local ChamsObjs   = {}

-- FIX 10 / FIX 8 (retained): pool init in pcall, size config-driven
local POOL_SIZE = Config.TracerPoolSize
local TrPool    = {}
local activeTr  = 0
local drawingOk = false

pcall(function()
    for i = 1, POOL_SIZE do
        local l = Drawing.new("Line")
        l.Thickness = 1; l.Transparency = 0.5; l.Visible = false
        TrPool[i] = l
    end
    drawingOk = true
end)

if not drawingOk then
    warn("[ENI] Drawing API unavailable — Tracers disabled.")
    Flags.Tracers = false
end

-- FIX N (retained): tracer color constants at module level
local TRACER_RED  = Color3.fromRGB(255, 80,  80)
local TRACER_BLUE = Color3.fromRGB(100, 200, 255)

local function clearTr()
    for i = 1, activeTr do if TrPool[i] then TrPool[i].Visible = false end end
    activeTr = 0
end

local function drawTr(from, to, col)
    activeTr += 1
    if activeTr > POOL_SIZE then return end
    local l = TrPool[activeTr]
    l.From=from; l.To=to; l.Color=col; l.Visible=true
end

local function destroyPool()
    for i = 1, POOL_SIZE do
        if TrPool[i] then pcall(function() TrPool[i]:Remove() end); TrPool[i]=nil end
    end
    activeTr  = 0
    drawingOk = false  -- FIX P (retained): prevent drawTr() indexing nil pool
end

local function makeBB(parent, text, col, w)
    local bb = Instance.new("BillboardGui")
    bb.AlwaysOnTop=true; bb.Size=UDim2.new(0,w or 80,0,30)
    bb.StudsOffset=Vector3.new(0,3.5,0); bb.Parent=parent
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency=1; lbl.Size=UDim2.new(1,0,1,0)
    lbl.Text=text; lbl.TextColor3=col
    lbl.TextStrokeTransparency=0; lbl.TextScaled=true
    lbl.Font=Enum.Font.GothamBold; lbl.Parent=bb
    return bb, lbl
end

-- FIX E (retained): cleanESP disconnects stored connections
local function cleanESP(tbl, key)
    if not tbl[key] then return end
    for _, o in pairs(tbl[key]) do
        if typeof(o) == "RBXScriptConnection" then
            pcall(function() o:Disconnect() end)
        elseif typeof(o) == "Instance" then
            pcall(function() o:Destroy() end)
        end
    end
    tbl[key] = nil
end

-- FIX H4 (HOOK-4 remediation): MobESPBound is set here but
-- the flag is stored in getgenv() so a re-execution after
-- guard-clear sees the correct state rather than re-registering
-- a second ChildAdded connection on top of the orphaned first.
local MobESPBound = (getgenv and getgenv().ENI_MOB_ESP_BOUND) or false

local function addMobESP(model)
    if MobESPObjs[model] then return end
    local hrp = model:FindFirstChild("HumanoidRootPart")
    local hum = model:FindFirstChildWhichIsA("Humanoid")
    if not hrp or not hum then return end
    local bb, lbl = makeBB(hrp, model.Name, Color3.fromRGB(255,80,80), 110)
    local dl = Instance.new("TextLabel")
    dl.BackgroundTransparency=1; dl.Size=UDim2.new(1,0,0.4,0); dl.Position=UDim2.new(0,0,1,0)
    dl.TextColor3=Color3.fromRGB(255,200,200); dl.TextStrokeTransparency=0
    dl.TextScaled=true; dl.Font=Enum.Font.Gotham
    dl.Text = ""  -- FIX 7 (retained): no blank flash
    dl.Parent=bb
    -- FIX E (retained): store AncestryChanged connection for leak-free cleanup
    MobESPObjs[model] = {bb=bb, lbl=lbl, dl=dl, conn=nil}
    MobESPObjs[model].conn = model.AncestryChanged:Connect(function()
        if not model:IsDescendantOf(game) then cleanESP(MobESPObjs, model) end
    end)
end
local function removeMobESP(model) cleanESP(MobESPObjs, model) end

-- FIX H1 (retained): per-player lifetime connection registry
-- Connections are initialized once per player, never per respawn
local PlrESPBound = false
local playerLifetimeConns = {}

local function bindPlayerLifetime(p)
    if playerLifetimeConns[p] then return end
    playerLifetimeConns[p] = {}
    playerLifetimeConns[p][1] = p.CharacterAdded:Connect(function()
        task.wait(0.5)
        if Flags.PlayerESP then addPlayerESP(p) end
    end)
    playerLifetimeConns[p][2] = p.CharacterRemoving:Connect(function()
        cleanESP(PlrESPObjs, p)
    end)
end

local function unbindPlayerLifetime(p)
    if not playerLifetimeConns[p] then return end
    for _, c in ipairs(playerLifetimeConns[p]) do
        pcall(function() c:Disconnect() end)
    end
    playerLifetimeConns[p] = nil
end

-- addPlayerESP forward declaration (defined just below)
local addPlayerESP

addPlayerESP = function(p)
    if PlrESPObjs[p] or p==LP then return end
    local char = p.Character; if not char then return end
    local hrp  = char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
    local bb, lbl = makeBB(hrp, p.Name, Color3.fromRGB(100,200,255), 100)
    local dl = Instance.new("TextLabel")
    dl.BackgroundTransparency=1; dl.Size=UDim2.new(1,0,0.4,0); dl.Position=UDim2.new(0,0,1,0)
    dl.TextColor3=Color3.fromRGB(180,230,255); dl.TextStrokeTransparency=0
    dl.TextScaled=true; dl.Font=Enum.Font.Gotham
    dl.Text = ""  -- FIX 7 (retained)
    dl.Parent=bb
    PlrESPObjs[p] = {bb=bb, lbl=lbl, dl=dl}
    -- FIX H1 (retained): lifecycle connections not bound here
end
local function removePlayerESP(p) cleanESP(PlrESPObjs, p) end

function addLootESP(obj)
    if LootESPObjs[obj] then return end
    local part = obj
    if obj:IsA("Model") then
        part = obj:FindFirstChild("Center") or obj:FindFirstChildWhichIsA("BasePart")
    end
    if not part or not part:IsA("BasePart") then return end
    local isEpic = obj:IsA("Model")
    local col    = isEpic and Color3.fromRGB(255,215,0) or Color3.fromRGB(220,220,220)
    local sel    = Instance.new("SelectionBox")
    sel.Color3=col; sel.LineThickness=0.06; sel.SurfaceTransparency=0.7
    sel.SurfaceColor3=col; sel.Adornee=part; sel.Parent=part
    local bb = makeBB(part, isEpic and "★ EPIC" or "Drop", col, 80)
    -- FIX H2 (retained): store AncestryChanged connection
    LootESPObjs[obj] = {sel=sel, bb=bb, conn=nil}
    LootESPObjs[obj].conn = obj.AncestryChanged:Connect(function()
        if not obj:IsDescendantOf(game) and LootESPObjs[obj] then
            pcall(function() LootESPObjs[obj].sel:Destroy() end)
            pcall(function() LootESPObjs[obj].bb:Destroy()  end)
            LootESPObjs[obj] = nil
        end
    end)
end

function removeLootESP(obj)
    if not LootESPObjs[obj] then return end
    if LootESPObjs[obj].conn then
        pcall(function() LootESPObjs[obj].conn:Disconnect() end)
    end
    pcall(function() LootESPObjs[obj].sel:Destroy() end)
    pcall(function() LootESPObjs[obj].bb:Destroy()  end)
    LootESPObjs[obj] = nil
end

local function addChams(model)
    if ChamsObjs[model] then return end
    ChamsObjs[model] = {conn=nil}
    for _, p in ipairs(model:GetDescendants()) do
        if p:IsA("BasePart") and not HITBOX[p.Name] then
            local b = Instance.new("BoxHandleAdornment")
            b.AlwaysOnTop=true; b.ZIndex=5
            b.Color3=Color3.fromRGB(255,60,60); b.Transparency=0.5
            b.Size=p.Size; b.Adornee=p; b.Parent=p
            ChamsObjs[model][#ChamsObjs[model]+1] = b
        end
    end
    -- FIX E (retained): store AncestryChanged connection
    ChamsObjs[model].conn = model.AncestryChanged:Connect(function()
        if not model:IsDescendantOf(game) and ChamsObjs[model] then
            for _, b in pairs(ChamsObjs[model]) do
                if typeof(b) == "Instance"           then pcall(function() b:Destroy() end) end
                if typeof(b) == "RBXScriptConnection" then pcall(function() b:Disconnect() end) end
            end
            ChamsObjs[model] = nil
        end
    end)
end
local function removeChams(model)
    if not ChamsObjs[model] then return end
    for _, b in pairs(ChamsObjs[model]) do
        if typeof(b) == "Instance"           then pcall(function() b:Destroy() end) end
        if typeof(b) == "RBXScriptConnection" then pcall(function() b:Disconnect() end) end
    end
    ChamsObjs[model] = nil
end
local function clearChams()
    for m in pairs(ChamsObjs) do removeChams(m) end
end

-- ════════════════════════════════════════════════════════════
-- SECTION 23: CHARACTER RESPAWN
--
-- ARCH-3: This is the SINGLE AUTHORITATIVE restart point for
-- all character-dependent systems. refreshChar() is called
-- here and only here during normal runtime (not from the farm
-- loop guard, not from within refreshChar() itself).
-- The explicit task.cancel before startAutoFarm() is now
-- intentional and documented, not incidental.
-- ════════════════════════════════════════════════════════════
LP.CharacterAdded:Connect(function()
    task.wait(0.5)

    local ok = refreshChar()
    if not ok then
        warn("[ENI] CharacterAdded: refreshChar() failed — character may not have loaded.")
        return
    end

    if Hum then
        Hum.WalkSpeed = Config.WalkSpeed
        Hum.JumpPower = Config.JumpPower
        pcall(function() Hum.JumpHeight = Config.JumpPower * 0.36 end)
    end

    dirty()

    -- ARCH-3: explicitly cancel previous dungeonThread before
    -- calling startAutoFarm(), which would cancel it anyway —
    -- this makes the intent clear and prevents any ambiguity
    -- about which path triggers the cancel.
    if Flags.AutoFarm then
        if dungeonThread then
            pcall(task.cancel, dungeonThread)
            dungeonThread = nil
        end
        startAutoFarm()
    end
end)

-- ════════════════════════════════════════════════════════════
-- SECTION 24: HEARTBEAT — NoClip, Stamina, GodMode, ESP, Tracers
-- Kill Aura + AutoSkills run in their own coroutines (SECTION 26,
-- spawned after Rayfield window creation per ARCH-1).
-- ════════════════════════════════════════════════════════════
local slowAcc = 0

RunService.Heartbeat:Connect(function(dt)
    if not Char or not Hum or not HRP then return end
    slowAcc += dt

    if Flags.NoClip then
        for _, p in ipairs(NoClipParts) do
            if p and p.Parent then p.CanCollide = false end
        end
    end

    if Flags.SpeedHack and Hum then
        Hum.WalkSpeed = Config.WalkSpeed
    end

    if slowAcc < 0.1 then return end
    slowAcc = 0

    -- FIX 12 Layer 1 (retained): Heartbeat health floor
    -- FIX 15 (retained): guard Hum.Parent for stale upvalue
    if Flags.GodMode and Hum and Hum.Parent and Hum.Health > 0
       and Hum.Health < Hum.MaxHealth then
        Hum.Health = Hum.MaxHealth
    end

    if Flags.InfiniteStamina then
        pcall(function() Char:SetAttribute("Stamina", 100) end)
        pcall(function() Char:SetAttribute("Energy",  100) end)
        pcall(function() Char:SetAttribute("Dash",    100) end)
        for _, v in ipairs(StaminaParts) do
            if v and v.Parent then v.Value = 100 end
        end
    end

    if Flags.MobESP then
        for model, o in pairs(MobESPObjs) do
            if inWS(model) then
                local hrp = model:FindFirstChild("HumanoidRootPart")
                local hum = model:FindFirstChildWhichIsA("Humanoid")
                if hrp and hum then
                    local d = math.floor(dist(HRP.Position, hrp.Position))
                    o.dl.Text  = d.."st | HP:"..math.floor(hum.Health).."/"..math.floor(hum.MaxHealth)
                    o.bb.Enabled = d <= Config.ESPMaxDist
                end
            end
        end
    end

    if Flags.PlayerESP then
        for p, o in pairs(PlrESPObjs) do
            local pc  = p.Character
            local phr = pc and pc:FindFirstChild("HumanoidRootPart")
            if phr then
                local d = math.floor(dist(HRP.Position, phr.Position))
                o.dl.Text    = d.." studs"
                o.bb.Enabled = d <= Config.ESPMaxDist
            end
        end
    end

    if Flags.Tracers then
        clearTr()
        local cam = WS.CurrentCamera
        local vp  = cam.ViewportSize
        local ctr = Vector2.new(vp.X/2, vp.Y)
        for _, e in ipairs(getMobs(Config.ESPMaxDist)) do
            local sp, on = cam:WorldToViewportPoint(e.hrp.Position)
            if on then drawTr(ctr, Vector2.new(sp.X,sp.Y), TRACER_RED) end
        end
        for _, p in ipairs(Players:GetPlayers()) do
            if p~=LP and p.Character then
                local phr = p.Character:FindFirstChild("HumanoidRootPart")
                if phr and dist(HRP.Position,phr.Position)<=Config.ESPMaxDist then
                    local sp, on = cam:WorldToViewportPoint(phr.Position)
                    if on then drawTr(ctr, Vector2.new(sp.X,sp.Y), TRACER_BLUE) end
                end
            end
        end
    else
        if activeTr > 0 then clearTr() end
    end
end)

-- ════════════════════════════════════════════════════════════
-- SECTION 25: RAYFIELD
-- FIX H (retained): fallback CDN
-- FIX S2 (retained): guard confirmed permanent only here
-- ════════════════════════════════════════════════════════════
local ok, Rayfield = pcall(function()
    return loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
end)
if not ok or not Rayfield then
    warn("[ENI] Primary Rayfield URL failed — trying GitHub fallback...")
    ok, Rayfield = pcall(function()
        return loadstring(game:HttpGet(
            "https://raw.githubusercontent.com/shlexware/Rayfield/main/source"
        ))()
    end)
end
if not ok or not Rayfield then
    -- Clear guard so the user can retry (ARCH-1: threads already
    -- cancelled at top of script; no orphan accumulation)
    clearLoadGuard()
    warn("[ENI] Rayfield failed — all endpoints exhausted. Re-execution is unlocked.")
    return
end

-- FIX S2 (retained): permanent guard set here, after success
if getgenv then getgenv().ENI_SOLO_LOADED = true end

local W = Rayfield:CreateWindow({
    Name            = "Solo Hunters — ENI Build",
    LoadingTitle    = "Solo Hunters",
    LoadingSubtitle = "ENI Build v7.0",
    ConfigurationSaving = { Enabled = false },
    KeySystem = false,
})

-- ════════════════════════════════════════════════════════════
-- SECTION 26: KILL AURA & AUTO SKILLS
--
-- ARCH-1: These threads are initialized HERE, after the Rayfield
-- window is created, not at module scope. In v6.5 they spawned
-- before Rayfield loaded. On CDN failure the guard cleared and
-- re-execution spawned new threads while the originals remained
-- alive with no surviving handle. Orphan count = 2 per retry.
--
-- Both handles are stored in getgenv().ENI_THREAD_REGISTRY via
-- registerThread(). The next execution (SECTION 0) will cancel
-- them before spawning replacements. Handle locals are also kept
-- for the Rejoin button and cancelAllThreads().
-- ════════════════════════════════════════════════════════════

-- Declare locals so Heartbeat and Rejoin can reference them
local killAuraThread   = nil
local autoSkillsThread = nil

killAuraThread = task.spawn(function()
    while true do
        task.wait(rnd(0.15, 0.28))
        if Flags.KillAura and HRP and Hum and Hum.Health > 0 then
            for _, e in ipairs(getMobs(Config.KillAuraRadius)) do
                attackEntry(e)
            end
        end
    end
end)
registerThread("killAuraThread", killAuraThread)

local skillCooldowns = {}
for i = 1, #Config.SkillKeys do skillCooldowns[i] = 0 end

autoSkillsThread = task.spawn(function()
    while true do
        task.wait(0.25)
        if Flags.AutoSkills and HRP and Hum and Hum.Health > 0 then
            local now = tick()
            for i, sk in ipairs(Config.SkillKeys) do
                if now >= skillCooldowns[i] then
                    pcall(function()
                        if keypress   then keypress(sk.key)   end
                        task.wait(0.05)
                        if keyrelease then keyrelease(sk.key) end
                    end)
                    skillCooldowns[i] = now + sk.cd
                end
            end
        end
    end
end)
registerThread("autoSkillsThread", autoSkillsThread)

-- ════════════════════════════════════════════════════════════
-- TAB: AUTO FARM
-- ════════════════════════════════════════════════════════════
local FarmTab = W:CreateTab("Farm", "sword")

FarmTab:CreateSection("Dungeon Loop")

FarmTab:CreateToggle({
    Name = "Auto Farm  (Full Loop)",
    Default = false,
    Callback = function(v)
        Flags.AutoFarm = v
        if v then startAutoFarm() else stopAutoFarm() end
    end,
})

FarmTab:CreateLabel("State: checks current dungeon loop state")

FarmTab:CreateButton({
    Name = "Status: What State Are We In?",
    Callback = function()
        Rayfield:Notify({ Title="State", Content="Current: "..DungeonState, Duration=4 })
    end,
})

FarmTab:CreateToggle({
    Name = "Prioritize Red Gates (Boss)",
    Default = true,
    Callback = function(v) Flags.PrioritizeRed = v end,
})

FarmTab:CreateToggle({
    Name = "Auto-Scale Difficulty",
    Default = true,
    Callback = function(v) Flags.AutoScaleDiff = v end,
})

FarmTab:CreateSection("Dungeon Actions")

FarmTab:CreateToggle({
    Name = "Auto Quest",
    Default = false,
    Callback = function(v)
        Flags.AutoQuest = v
        if v and not Flags.AutoFarm then
            task.spawn(doAutoQuest)
        end
    end,
})

FarmTab:CreateToggle({
    Name = "Auto Sell",
    Default = false,
    Callback = function(v)
        Flags.AutoSell = v
        if v and not Flags.AutoFarm then task.spawn(doAutoSell) end
    end,
})

FarmTab:CreateToggle({
    Name = "Auto Buy Merchant Shop",
    Default = false,
    Callback = function(v)
        Flags.AutoBuyMerchant = v
        if v and not Flags.AutoFarm then task.spawn(doAutoBuy) end
    end,
})

FarmTab:CreateToggle({
    Name = "Auto Equip Best Gear",
    Default = false,
    Callback = function(v)
        Flags.AutoEquipBest = v
        if v then doAutoEquipBest() end
    end,
})

FarmTab:CreateButton({
    Name = "Do Auto Quest Now",
    Callback = function() task.spawn(doAutoQuest) end,
})

FarmTab:CreateButton({
    Name = "Do Auto Sell Now",
    Callback = function() task.spawn(doAutoSell) end,
})

FarmTab:CreateButton({
    Name = "Collect All Drops Now",
    Callback = function() task.spawn(collectAll) end,
})

FarmTab:CreateButton({
    Name = "Collect Dungeon Rewards Now",
    Callback = function() task.spawn(collectDungeonRewards) end,
})

FarmTab:CreateSection("Portal")

FarmTab:CreateButton({
    Name = "Enter Best Portal Now",
    Callback = function()
        task.spawn(function()
            local portal = getBestPortal()
            if portal then
                local score, req, isRed = scorePortal(portal, getPlayerPower())
                Rayfield:Notify({
                    Title   = "Portal Selected",
                    Content = portal.Name.." | Req: "..req.." | Boss: "..tostring(isRed),
                    Duration = 4,
                })
                enterPortal(portal)
            else
                Rayfield:Notify({ Title="Portal", Content="No portals found or all out of reach.", Duration=3 })
            end
        end)
    end,
})

FarmTab:CreateButton({
    Name = "Return to Lobby",
    Callback = function() task.spawn(returnToLobby) end,
})

FarmTab:CreateSection("Codes")

FarmTab:CreateToggle({
    Name = "Auto Redeem Codes",
    Default = false,
    Callback = function(v) Flags.AutoRedeemCodes = v end,
})

FarmTab:CreateButton({
    Name = "Redeem Codes Now",
    Callback = function()
        -- FIX 2 (retained): manual reset bypasses session guard
        codesRedeemedThisSession = false
        task.spawn(function() doRedeemCodes(true) end)
    end,
})

FarmTab:CreateToggle({
    Name = "Auto Collect Drops",
    Default = false,
    Callback = function(v)
        Flags.AutoCollect = v
        if v then task.spawn(collectAll) end
    end,
})

-- ════════════════════════════════════════════════════════════
-- TAB: COMBAT
-- ════════════════════════════════════════════════════════════
local CombTab = W:CreateTab("Combat", "zap")

CombTab:CreateSection("Kill Aura")

CombTab:CreateToggle({
    Name = "Kill Aura",
    Default = false,
    Callback = function(v) Flags.KillAura = v end,
})

CombTab:CreateSlider({
    Name = "Kill Aura Radius",
    Range = {10, 600}, Increment = 10, Suffix = " studs",
    CurrentValue = 80, Flag = "AuraRadius",
    Callback = function(v) Config.KillAuraRadius = v end,
})

CombTab:CreateButton({
    Name = "Kill Nearest Mob",
    Callback = function()
        local e = getNearestMob(1000)
        if e then task.spawn(attackEntry, e) end
    end,
})

CombTab:CreateButton({
    Name = "Kill All In Aura Range",
    Callback = function()
        task.spawn(function()
            for _, e in ipairs(getMobs(Config.KillAuraRadius)) do attackEntry(e) end
        end)
    end,
})

CombTab:CreateSection("Auto Skills")

CombTab:CreateToggle({
    Name = "Auto Skills  (keypress Q E R F)",
    Default = false,
    Callback = function(v) Flags.AutoSkills = v end,
})

CombTab:CreateSection("Remotes")

CombTab:CreateButton({
    Name = "Boss Altar Remote",
    Callback = function()
        if R.BossAltarSpawnBoss then
            pcall(function() R.BossAltarSpawnBoss:FireServer() end)
            Rayfield:Notify({ Title="Boss", Content="BossAltarSpawnBoss fired.", Duration=3 })
        end
    end,
})

CombTab:CreateButton({
    Name = "Start Challenge",
    Callback = function()
        if R.StartChallenge then
            pcall(function() R.StartChallenge:FireServer() end)
            Rayfield:Notify({ Title="Challenge", Content="StartChallenge fired.", Duration=3 })
        end
    end,
})

CombTab:CreateButton({
    Name = "FullDungeonRemote",
    Callback = function()
        if R.FullDungeonRemote then
            pcall(function() R.FullDungeonRemote:FireServer() end)
            Rayfield:Notify({ Title="Dungeon", Content="FullDungeonRemote fired.", Duration=3 })
        end
    end,
})

-- ════════════════════════════════════════════════════════════
-- TAB: PLAYER
-- ════════════════════════════════════════════════════════════
local PlrTab = W:CreateTab("Player", "user")

PlrTab:CreateSection("Stats")

PlrTab:CreateButton({
    Name = "Show Currencies",
    Callback = function()
        local c = getCurrencies()
        Rayfield:Notify({
            Title   = "Currencies",
            Content = ("Power:%d | Gold:%d | Gems:%d\nSouls:%d | Raidium:%d")
                      :format(c.Power, c.Gold, c.Gems, c.Souls, c.Raidium),
            Duration = 8,
        })
    end,
})

PlrTab:CreateSection("Movement")

PlrTab:CreateToggle({
    Name = "Speed Hack",
    Default = false,
    Callback = function(v) Flags.SpeedHack = v end,
})

PlrTab:CreateSlider({
    Name = "Walk Speed",
    Range = {16,500}, Increment = 1, Suffix = "",
    CurrentValue = 16, Flag = "WalkSpeed",
    Callback = function(v)
        Config.WalkSpeed = v
        if Hum then Hum.WalkSpeed = v end
    end,
})

PlrTab:CreateSlider({
    Name = "Jump Power",
    Range = {7,300}, Increment = 1, Suffix = "",
    CurrentValue = 50, Flag = "JumpPower",
    Callback = function(v)
        Config.JumpPower = v
        if Hum then
            Hum.JumpPower = v
            pcall(function() Hum.JumpHeight = v * 0.36 end)
        end
    end,
})

PlrTab:CreateToggle({
    Name = "No Clip",
    Default = false,
    Callback = function(v) Flags.NoClip = v end,
})

PlrTab:CreateSection("Survival")

PlrTab:CreateToggle({
    Name = "God Mode",
    Default = false,
    Callback = function(v)
        Flags.GodMode = v
        -- FIX 16 (retained): notify shows which layers are active
        if v then
            local hookStatus = godHookActive and "active" or "inactive (see console)"
            Rayfield:Notify({
                Title   = "God Mode ON",
                Content = "Health loop: ON  |  Hook: " .. hookStatus,
                Duration = 5,
            })
        end
    end,
})

PlrTab:CreateToggle({
    Name = "Infinite Stamina",
    Default = false,
    Callback = function(v) Flags.InfiniteStamina = v end,
})

PlrTab:CreateToggle({
    Name = "Anti-AFK",
    Default = false,
    Callback = function(v)
        Flags.AntiAFK = v
        if v then startAntiAFK()
        else if afkThread then pcall(task.cancel, afkThread); afkThread = nil; registerThread("afkThread", nil) end end
    end,
})

-- ════════════════════════════════════════════════════════════
-- TAB: TELEPORT
-- ════════════════════════════════════════════════════════════
local TpTab = W:CreateTab("Teleport", "map-pin")

TpTab:CreateSection("World")

TpTab:CreateButton({
    Name = "Nearest Mob",
    Callback = function()
        local e = getNearestMob(1000)
        if e and HRP then HRP.CFrame = jitter(CFrame.new(e.hrp.Position+Vector3.new(0,5,0))) end
    end,
})

TpTab:CreateButton({
    Name = "Return to Lobby",
    Callback = function() task.spawn(returnToLobby) end,
})

TpTab:CreateButton({
    Name = "Quest Giver (Lobby)",
    Callback = function()
        if not HRP or not LobbyFolder then return end
        local qg   = LobbyFolder:FindFirstChild("QuestGiver")
        local base = qg and qg:FindFirstChildWhichIsA("BasePart")
        if base then HRP.CFrame = jitter(base.CFrame + Vector3.new(0,5,0)) end
    end,
})

TpTab:CreateButton({
    Name = "Daily Quest Board",
    Callback = function()
        if not HRP or not LobbyFolder then return end
        local dq = LobbyFolder:FindFirstChild("Daily Quest")
        local qp = dq and dq:FindFirstChild("QuestsPart")
        if qp then HRP.CFrame = jitter(qp.CFrame + Vector3.new(0,5,0)) end
    end,
})

TpTab:CreateSection("Players")

TpTab:CreateButton({
    Name = "Teleport to Nearest Player",
    Callback = function()
        if not HRP then return end
        local near, nearD = nil, math.huge
        for _, p in ipairs(Players:GetPlayers()) do
            if p~=LP and p.Character then
                local phr = p.Character:FindFirstChild("HumanoidRootPart")
                if phr then
                    local d = dist(HRP.Position, phr.Position)
                    if d < nearD then near=phr; nearD=d end
                end
            end
        end
        if near then HRP.CFrame = jitter(near.CFrame+Vector3.new(0,5,0))
        else Rayfield:Notify({Title="TP",Content="No other players found.",Duration=3}) end
    end,
})

TpTab:CreateDropdown({
    Name = "Teleport to Player (load-time)",
    Options = (function()
        local t={}
        for _, p in ipairs(Players:GetPlayers()) do
            if p~=LP then t[#t+1]=p.Name end
        end
        return #t>0 and t or {"(nobody)"}
    end)(),
    Default = "...",
    Callback = function(v)
        local t = Players:FindFirstChild(v)
        if t and t.Character then
            local thr = t.Character:FindFirstChild("HumanoidRootPart")
            if thr and HRP then HRP.CFrame = jitter(thr.CFrame+Vector3.new(0,5,0)) end
        end
    end,
})

TpTab:CreateSection("Waypoints")

local SafeSpot = nil
local Waypoints = {}

TpTab:CreateButton({
    Name = "Save Safe Spot",
    Callback = function()
        if HRP then
            SafeSpot = HRP.CFrame
            Rayfield:Notify({Title="Safe Spot",Content="Saved.",Duration=2})
        end
    end,
})

TpTab:CreateButton({
    Name = "Return to Safe Spot",
    Callback = function() if SafeSpot and HRP then HRP.CFrame = SafeSpot end end,
})

TpTab:CreateButton({
    Name = "Save Waypoint",
    Callback = function()
        if not HRP then return end
        local name = "WP"..tostring(#Waypoints+1)
        Waypoints[#Waypoints+1] = {name=name, cf=HRP.CFrame}
        Rayfield:Notify({Title="Waypoint",Content=name.." saved.",Duration=2})
    end,
})

TpTab:CreateButton({
    Name = "Go to Last Waypoint",
    Callback = function()
        if #Waypoints > 0 and HRP then HRP.CFrame = Waypoints[#Waypoints].cf end
    end,
})

-- ════════════════════════════════════════════════════════════
-- TAB: ESP
-- ════════════════════════════════════════════════════════════
local ESPTab = W:CreateTab("ESP", "eye")

ESPTab:CreateToggle({
    Name = "Mob ESP",
    Default = false,
    Callback = function(v)
        Flags.MobESP = v
        if v then
            for _, e in ipairs(getMobs()) do addMobESP(e.model) end
            -- HOOK-4: store bound state in getgenv() so re-execution
            -- sees the existing connection and does not double-register
            if MobFolder and not MobESPBound then
                MobESPBound = true
                if getgenv then getgenv().ENI_MOB_ESP_BOUND = true end
                MobFolder.ChildAdded:Connect(function(m)
                    if Flags.MobESP and m:IsA("Model") then
                        task.wait(0.1); addMobESP(m)
                    end
                end)
            end
        else
            for m in pairs(MobESPObjs) do removeMobESP(m) end
        end
    end,
})

ESPTab:CreateToggle({
    Name = "Player ESP",
    Default = false,
    Callback = function(v)
        Flags.PlayerESP = v
        if v then
            for _, p in ipairs(Players:GetPlayers()) do
                bindPlayerLifetime(p)
                addPlayerESP(p)
            end
            if not PlrESPBound then
                PlrESPBound = true
                Players.PlayerAdded:Connect(function(p)
                    bindPlayerLifetime(p)
                    if Flags.PlayerESP then
                        task.wait(0.5); addPlayerESP(p)
                    end
                end)
                Players.PlayerRemoving:Connect(function(p)
                    removePlayerESP(p)
                    unbindPlayerLifetime(p)
                end)
            end
        else
            for p in pairs(PlrESPObjs) do removePlayerESP(p) end
        end
    end,
})

ESPTab:CreateToggle({
    Name = "Loot ESP",
    Default = false,
    Callback = function(v)
        Flags.LootESP = v
        if v and DropFolder then
            for _, o in ipairs(DropFolder:GetChildren()) do addLootESP(o) end
        else
            for o in pairs(LootESPObjs) do removeLootESP(o) end
        end
    end,
})

ESPTab:CreateToggle({
    Name = "Chams",
    Default = false,
    Callback = function(v)
        Flags.Chams = v
        if v then for _, e in ipairs(getMobs()) do addChams(e.model) end
        else clearChams() end
    end,
})

ESPTab:CreateToggle({
    Name = "Tracers",
    Default = false,
    Callback = function(v)
        Flags.Tracers = v
        if not v then clearTr() end
    end,
})

ESPTab:CreateSlider({
    Name = "Max ESP Distance",
    Range = {50,2000}, Increment = 50, Suffix = " studs",
    CurrentValue = 500, Flag = "ESPDist",
    Callback = function(v) Config.ESPMaxDist = v end,
})

-- ════════════════════════════════════════════════════════════
-- TAB: MISC
-- ════════════════════════════════════════════════════════════
local MiscTab = W:CreateTab("Misc", "settings")

MiscTab:CreateSection("Augment & Slots")

MiscTab:CreateToggle({
    Name = "Auto Augment",
    Default = false,
    Callback = function(v)
        Flags.AutoAugment = v
        if v then startAugment()
        else if augThread then pcall(task.cancel, augThread); augThread=nil; registerThread("augThread", nil) end end
    end,
})

MiscTab:CreateToggle({
    Name = "Auto Slot Machine",
    Default = false,
    Callback = function(v)
        Flags.AutoSlotMachine = v
        if v then startSlot()
        else if slotThread then pcall(task.cancel, slotThread); slotThread=nil; registerThread("slotThread", nil) end end
    end,
})

MiscTab:CreateSlider({
    Name = "Slot Delay",
    Range = {1,10}, Increment = 0.5, Suffix = "s",
    CurrentValue = 2, Flag = "SlotDelay",
    Callback = function(v) Config.SlotDelay = v end,
})

MiscTab:CreateSection("Utility")

MiscTab:CreateButton({
    Name = "FPS Unlocker",
    Callback = function()
        local fn = setfpscap or (getfenv and getfenv(0).setfpscap) or (syn and syn.setfpscap)
        if fn then
            pcall(fn, 0)
            Rayfield:Notify({Title="FPS",Content="Cap removed.",Duration=3})
        else
            Rayfield:Notify({Title="FPS",Content="setfpscap not available on this executor.",Duration=4})
        end
    end,
})

MiscTab:CreateButton({
    Name = "Rejoin",
    Callback = function()
        destroyPool()
        -- ARCH-2: cancel ALL threads via unified registry
        -- Previous version only cancelled killAuraThread and autoSkillsThread,
        -- leaving afkThread, slotThread, and augThread alive through TeleportAsync.
        cancelAllThreads()
        -- FIX I (retained): TeleportAsync, wrapped in pcall
        pcall(function()
            TeleportService:TeleportAsync(game.PlaceId, {LP})
        end)
    end,
})

MiscTab:CreateKeybind({
    Name = "Toggle UI",
    CurrentKeybind = "RightShift",
    HoldToInteract = false,
    Callback = function() Rayfield:ToggleUI() end,
})

-- ════════════════════════════════════════════════════════════
-- READY
-- ════════════════════════════════════════════════════════════
Rayfield:Notify({
    Title   = "ENI Build v7.0",
    Content = "Solo Hunters loaded  |  RightShift = toggle UI",
    Duration = 5,
})
