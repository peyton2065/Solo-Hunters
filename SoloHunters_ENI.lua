--[[
    ╔══════════════════════════════════════════════════════════╗
    ║          SOLO HUNTERS — ENI BUILD  v8.0                  ║
    ║          Xeno Executor  |  v8 Engineering Pass           ║
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
    CHANGELOG v7.0 → v8.0  (v8 Engineering Diagnostic Pass)
    ═══════════════════════════════════════════════════════════

    ── HOOK-1 [CRITICAL] Guard/Registry Ordering Inversion ──
      v7.0 ran Section 0 (cancel ALL threads in ENI_THREAD_
      REGISTRY) unconditionally BEFORE the load guard check.
      Any accidental re-execution while the script was running
      destroyed all active threads — killAuraThread, dungeonThread,
      slotThread, afkThread, augThread — then printed "already
      loaded" and returned. The fix killed the thing it was
      protecting.

      Two execution cases must now be explicitly discriminated:

      Case A — Duplicate execution (guard is SET):
        ENI_SOLO_LOADED is true → threads are alive and healthy.
        Return immediately. Do NOT touch the registry. Do NOT
        cancel anything.

      Case B — Retry after failure (guard is CLEAR):
        ENI_SOLO_LOADED is nil → prior execution failed (e.g.
        Rayfield CDN down) and guard was cleared. Prior threads
        may be orphaned. Cancel them, reset registry, proceed.

      Fix: guard check is now FIRST. Registry cleanup is ONLY
      reached in Case B. A single accidental re-execution during
      a live farm session is now harmless.

    ── HOOK-2 [HIGH] refreshChar() Race Condition Survives v7 ──
      refreshChar() was documented as "strictly synchronous" but
      called Char:WaitForChild("Humanoid",5) and WaitForChild
      ("HumanoidRootPart",5) internally — each yields the calling
      coroutine for up to 5 seconds. Total possible blocking: 10s.
      If the character died during this window, CharacterAdded
      fired and entered a concurrent second invocation of
      refreshChar(), producing two concurrent writes to Hum/HRP.
      Fix: added isRefreshing mutex flag to prevent concurrent
      entry. If a second caller enters while isRefreshing is true,
      it exits immediately. The CharacterAdded handler is still
      the single authoritative restart point.

    ── HOOK-3 [HIGH] MapFolder Mob Listeners on Deferred Load ──
      The mob cache event listeners for MapFolder's dungeon region
      subfolders (the watchReg pattern) only ran at module scope
      inside `if MapFolder then`. When MapFolder was nil at
      injection (deferred load case), that block was skipped. The
      ARCH-4 deferred resolution task set MapFolder but never
      called the listener setup. Dungeon-specific mobs in MapFolder
      sub-regions were invisible to the cache in streaming games.
      Fix: extracted setupMapListeners() as a standalone function
      called from BOTH module scope (immediate path) AND from the
      deferred resolution callback. A dirty() call is appended to
      the deferred path to trigger an immediate rebuild.

    ── HOOK-4 [MEDIUM] ENI_MOB_ESP_BOUND Not Cleared on Retry ──
      Section 0's retry cleanup only cleared ENI_THREAD_REGISTRY.
      ENI_MOB_ESP_BOUND was left set, so a re-execution after
      failure saw MobESPBound = true, skipped registering the new
      ChildAdded listener, and the prior execution's orphaned
      listener wrote to the dead MobESPObjs table. New mobs
      received no labels in a fresh execution.
      Fix: the retry-path cleanup (Case B) now clears all ENI_
      namespaced getgenv keys that represent connection state.

    ── STATE-1 [CRITICAL] getToolPower() pcall Return Misuse ──
      The Instance Attributes branch used:
        local av = pcall(function() return tool:GetAttribute(attr) end)
        if type(av) == "number" then return av end
      pcall() returns (status_bool, value, ...). av captured only
      the boolean status. type(av) == "number" was always false.
      The Attributes path was a dead branch — all tools fell
      through to the name-digit parse heuristic regardless of
      whether a recognized attribute existed. LOGIC-2 from the
      v7 pass was documented as fixed but was not functional.
      Fix: local ok, av = pcall(...) with ok and prepended to
      the type guard. Validated against all four priority paths.

    ── STATE-2 [HIGH] doAutoQuest() Blocking InvokeServer ──
      doRedeemCodes() had its blocking InvokeServer calls wrapped
      with per-call timeout logic in v7. doAutoQuest() uses the
      identical call pattern (three bare InvokeServer yields
      inside pcall, no timeout) but was not audited in the same
      pass. In the QUESTING state the farm loop calls doAutoQuest()
      synchronously. A hung TurnInQuest:InvokeServer() would
      freeze the farm loop indefinitely, and unlike the codes
      function there is no once-per-session guard limiting
      exposure — QUESTING runs after every single dungeon.
      Fix: each of the three InvokeServer calls in doAutoQuest()
      is now wrapped with the same task.spawn + task.delay(3)
      timeout pattern used in doRedeemCodes().

    ── STATE-3 [MEDIUM] inferStartState() Overly Aggressive ──
      The secondary dungeon-detection branch returned "LEAVING"
      on the first child of MapFolder that was not named exactly
      "Lobby" or "Circles". Any utility folder, terrain object,
      or ambient script container would satisfy this condition.
      In practice, MapFolder almost certainly contains more than
      two children. The check had no confirmation that the player
      was actually inside a dungeon — only that MapFolder had
      non-lobby contents, which is always true.
      Fix: replaced the per-child loop-return with a positive
      confirmation: we only conclude LEAVING if (a) the player
      is not near the lobby AND (b) a dungeon region contains
      the player (position inside any non-Lobby, non-Circles
      Model child of MapFolder, checked via BoundingBox). Falls
      through to LOBBY if positive confirmation cannot be made.

    ── STATE-4 [MEDIUM] inferStartState() O(N) Traversal ──
      The lobby position check called LobbyFolder:GetDescendants()
      on every startAutoFarm() call (including every respawn).
      In a complex lobby with thousands of instances this blocks
      the calling coroutine for a measurable duration.
      Fix: lobbyCandidateParts is cached on first call and reused.
      Additionally the check now finds the closest BasePart rather
      than breaking on first-match, improving accuracy.

    ── LOGIC-1 [HIGH] cancelAllThreads() Table Mutation ──
      The function set reg[name] = nil inside a pairs() iteration
      over reg. Mutating the iterated table while iterating relies
      on Lua/Luau implementation-specific behavior for "current
      key" removal — technically safe today but not guaranteed.
      Fix: collect all keys into a temporary array first, then
      iterate the array to cancel and nil the registry entries.

    ── LOGIC-2 [MEDIUM] inferStartState() First-Match Break ──
      The lobby proximity check broke on the first BasePart within
      300 studs, in GetDescendants() tree order (not distance
      order). A decorative part near the dungeon entrance could
      produce a false nearLobby = true. Fix: minimum-distance
      evaluation across all cached lobby BaseParts.

    ── LOGIC-3 [LOW] DropFolder Callbacks Flag Re-check ──
      task.wait() yields inside DropFolder ChildAdded callbacks.
      If AutoCollect or LootESP was toggled off during the yield,
      the actions (fireproximityprompt, addLootESP) executed
      anyway against the stale flag state at callback entry.
      Fix: flags re-checked after every task.wait() resumes.
]]

-- ════════════════════════════════════════════════════════════
-- SECTION 0: GUARD CHECK + CONDITIONAL REGISTRY CLEANUP
--
-- HOOK-1: The guard check MUST run first — before any thread
-- cancellation. Two cases:
--
-- Case A: ENI_SOLO_LOADED is SET → script is running live.
--   Threads are healthy. Return immediately, touch nothing.
--
-- Case B: ENI_SOLO_LOADED is CLEAR → no running instance.
--   May have orphaned threads from a failed prior attempt.
--   Cancel them now, reset registry, proceed with full init.
-- ════════════════════════════════════════════════════════════

-- Case A: Live instance guard — exit before touching anything
if getgenv and getgenv().ENI_SOLO_LOADED then
    print("[ENI] Already loaded — re-execution blocked. Use Rejoin or rejoin manually.")
    return
end

-- Case B: Clean up any orphaned threads from prior failed load
-- (Only reached when no live instance exists)
if getgenv then
    -- HOOK-4: clear all ENI_ connection-state keys on retry
    local function clearENIState()
        getgenv().ENI_THREAD_REGISTRY  = {}
        getgenv().ENI_MOB_ESP_BOUND    = false
    end

    local reg = getgenv().ENI_THREAD_REGISTRY
    if reg then
        -- LOGIC-1: collect keys first, then cancel — safe iteration
        local keys = {}
        for k in pairs(reg) do keys[#keys + 1] = k end
        for _, k in ipairs(keys) do
            if reg[k] then pcall(task.cancel, reg[k]) end
        end
    end
    clearENIState()
end

-- ════════════════════════════════════════════════════════════
-- SECTION 1: LOAD GUARD
-- Set immediately to block concurrent re-executions.
-- Cleared on failure so the user can retry.
-- Permanently confirmed after Rayfield window creation.
-- ════════════════════════════════════════════════════════════
if getgenv then getgenv().ENI_SOLO_LOADED = true end

local function clearLoadGuard()
    if getgenv then getgenv().ENI_SOLO_LOADED = nil end
end

-- ════════════════════════════════════════════════════════════
-- SECTION 2: THREAD REGISTRY API
-- ════════════════════════════════════════════════════════════
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
    -- LOGIC-1: collect keys before iterating to avoid undefined
    -- behavior from mutating the pairs() iterated table mid-loop.
    local reg  = getThreadRegistry()
    local keys = {}
    for k in pairs(reg) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do
        if reg[k] then pcall(task.cancel, reg[k]) end
        reg[k] = nil
    end
end

-- ════════════════════════════════════════════════════════════
-- SECTION 3: SERVICES
-- ════════════════════════════════════════════════════════════
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TeleportService  = game:GetService("TeleportService")
local WS               = game:GetService("Workspace")
local RS               = game:GetService("ReplicatedStorage")

-- ════════════════════════════════════════════════════════════
-- SECTION 4: PATHS
--
-- RS (service)
--   └─ ReplicatedStorage [Folder]
--         ├─ Remotes [Folder]
--         └─ Controllers [Folder]
--               └─ MainUIController [ModuleScript]
--                     ├─ Gold, Gems, Raidium, Souls2026, Power
--
-- ARCH-4 (retained): MapFolder deferred if absent at injection.
-- HOOK-3: deferred path now calls setupMapListeners() after
-- resolution so dungeon sub-region mob listeners are registered.
-- ════════════════════════════════════════════════════════════
local RS_inner      = RS:WaitForChild("ReplicatedStorage", 10)
local RemotesFolder = RS_inner and RS_inner:WaitForChild("Remotes", 10)
local MobFolder     = WS:WaitForChild("Mobs", 10)

local MapFolder     = WS:FindFirstChild("Map")
local CirclesFolder = MapFolder and MapFolder:FindFirstChild("Circles")
local LobbyFolder   = MapFolder and MapFolder:FindFirstChild("Lobby")

-- Forward-declare so the deferred task can call it after resolution
local setupMapListeners  -- defined in Section 9
local lobbyBaseParts     -- STATE-4: cached for inferStartState()

if not MapFolder then
    warn("[ENI] WS.Map not found at injection — deferring resolution (60s).")
    task.spawn(function()
        MapFolder = WS:WaitForChild("Map", 60)
        if MapFolder then
            CirclesFolder = MapFolder:FindFirstChild("Circles")
            LobbyFolder   = MapFolder:FindFirstChild("Lobby")
            lobbyBaseParts = nil   -- invalidate cache so it rebuilds
            if not CirclesFolder then
                warn("[ENI] WS.Map.Circles not found — portal scanning disabled.")
            end
            if not LobbyFolder then
                warn("[ENI] WS.Map.Lobby not found — sell/buy/quest teleport disabled.")
            end
            -- HOOK-3: register mob cache listeners now that MapFolder exists
            if setupMapListeners then
                setupMapListeners()
                -- dirty() not yet defined here; CacheDirty is a local below.
                -- We set the flag directly — it's initialized true, so this
                -- is effectively a no-op, but it documents intent.
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
-- SECTION 5: REMOTES
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
-- SECTION 6: LOCAL PLAYER & CHARACTER
--
-- HOOK-2: refreshChar() is strictly synchronous in intent but
-- calls WaitForChild internally which yields. Added isRefreshing
-- mutex to prevent concurrent entry. If CharacterAdded fires
-- while a prior refreshChar() is blocked inside WaitForChild,
-- the second call exits immediately. The CharacterAdded handler
-- (SECTION 22) is the single authoritative restart point.
-- ════════════════════════════════════════════════════════════
local LP            = Players.LocalPlayer
local Char, Hum, HRP
local NoClipParts   = {}
local StaminaParts  = {}
local charConns     = {}
local isRefreshing  = false   -- HOOK-2: mutex flag

local function rebuildCharCaches()
    NoClipParts  = {}
    StaminaParts = {}
    if not Char then return end
    for _, v in ipairs(Char:GetDescendants()) do
        if v:IsA("BasePart") then
            NoClipParts[#NoClipParts + 1] = v
        end
        local nm = v.Name:lower()
        if (v:IsA("NumberValue") or v:IsA("IntValue"))
           and (nm:find("stamina") or nm:find("energy")) then
            StaminaParts[#StaminaParts + 1] = v
        end
    end
end

local function refreshChar()
    -- HOOK-2: mutex prevents concurrent entry
    if isRefreshing then return false end
    isRefreshing = true

    for _, c in ipairs(charConns) do c:Disconnect() end
    charConns = {}

    Char = LP.Character
    if not Char then
        isRefreshing = false
        return false
    end

    Hum = Char:WaitForChild("Humanoid", 5)
    HRP = Char:WaitForChild("HumanoidRootPart", 5)

    if not Hum or not HRP then
        warn("[ENI] refreshChar: Humanoid or HRP did not load within 5s — suspended until respawn.")
        isRefreshing = false
        return false
    end

    rebuildCharCaches()
    lobbyBaseParts = nil   -- STATE-4: invalidate lobby cache on respawn

    charConns[1] = Char.ChildAdded:Connect(function(c)
        if c:IsA("Tool") then rebuildCharCaches() end
    end)
    charConns[2] = Char.ChildRemoved:Connect(function(c)
        if c:IsA("Tool") then rebuildCharCaches() end
    end)

    isRefreshing = false
    return true
end

task.spawn(refreshChar)

-- ════════════════════════════════════════════════════════════
-- SECTION 7: FLAGS & CONFIG
-- ════════════════════════════════════════════════════════════
local Flags = {
    AutoFarm        = false,
    AutoQuest       = false,
    AutoSell        = false,
    AutoBuyMerchant = false,
    AutoEquipBest   = false,
    AutoRedeemCodes = false,
    PrioritizeRed   = true,
    AutoScaleDiff   = true,

    KillAura        = false,
    AutoSkills      = false,
    AutoCollect     = false,

    GodMode         = false,
    InfiniteStamina = false,
    NoClip          = false,
    AntiAFK         = false,
    SpeedHack       = false,

    MobESP          = false,
    PlayerESP       = false,
    LootESP         = false,
    Chams           = false,
    Tracers         = false,

    AutoSlotMachine = false,
    AutoAugment     = false,
}

local Config = {
    KillAuraRadius = 80,
    WalkSpeed      = 16,
    JumpPower      = 50,
    ESPMaxDist     = 500,
    SlotDelay      = 2,
    TracerPoolSize = 200,

    SkillKeys = {
        { key = 0x51, cd = 8  },  -- Q
        { key = 0x45, cd = 12 },  -- E
        { key = 0x52, cd = 20 },  -- R
        { key = 0x46, cd = 30 },  -- F
    },
}

-- ════════════════════════════════════════════════════════════
-- SECTION 8: UTILITY
-- ════════════════════════════════════════════════════════════
local rng = Random.new()
local function rnd(lo, hi)  return lo + rng:NextNumber() * (hi - lo) end
local function dist(a, b)   return (a - b).Magnitude end
local function inWS(obj)    return obj and obj:IsDescendantOf(WS) end

local function jitter(cf, r, y)
    r = r or 2; y = y or 0.5
    return cf + Vector3.new(rnd(-r, r), rnd(-y, y), rnd(-r, r))
end

-- PP-1 (retained): composite ProximityPrompt text
-- ObjectText holds the descriptive label (Sell, Chest, Buy…)
-- ActionText holds the key label ("E", "Use")
-- Name is least informative — checked last
local function getPromptText(pp)
    local parts = {}
    if pp.ObjectText and pp.ObjectText ~= "" then
        parts[#parts + 1] = pp.ObjectText:lower()
    end
    if pp.ActionText and pp.ActionText ~= "" then
        parts[#parts + 1] = pp.ActionText:lower()
    end
    if pp.Name and pp.Name ~= "" then
        parts[#parts + 1] = pp.Name:lower()
    end
    return table.concat(parts, " ")
end

-- ════════════════════════════════════════════════════════════
-- SECTION 9: MOB CACHE  (event-driven registry)
-- ════════════════════════════════════════════════════════════
local HITBOX     = {SlashHitbox=true,AttackHitbox=true,DamageHitbox=true,WeaponHitbox=true}
local MobCache   = {}
local CacheDirty = true

local function dirty() CacheDirty = true end

local function buildParts(model)
    local t = {}
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") and not HITBOX[d.Name] then t[#t + 1] = d end
    end
    return t
end

local function rebuildCache()
    MobCache = {}; CacheDirty = false
    local pchars = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then pchars[p.Character] = true end
    end
    local function addModel(m)
        if pchars[m] then return end
        local hum = m:FindFirstChildWhichIsA("Humanoid")
        local hrp = m:FindFirstChild("HumanoidRootPart")
        if not hum or not hrp or hum.Health <= 0 then return end
        MobCache[#MobCache + 1] = {model=m, hrp=hrp, hum=hum, parts=buildParts(m)}
    end
    if MobFolder then
        for _, c in ipairs(MobFolder:GetChildren()) do
            if c:IsA("Model") then addModel(c) end
        end
    end
    if MapFolder then
        for _, reg in ipairs(MapFolder:GetChildren()) do
            local dm = reg:FindFirstChild("Mobs")
            if dm then
                for _, c in ipairs(dm:GetChildren()) do
                    if c:IsA("Model") then addModel(c) end
                end
            end
        end
    end
end

-- HOOK-3: standalone function called from BOTH the module-scope
-- immediate path AND the deferred MapFolder resolution callback.
setupMapListeners = function()
    if not MapFolder then return end
    local function watchReg(reg)
        local dm = reg:FindFirstChild("Mobs")
        if dm then
            dm.ChildAdded:Connect(dirty)
            dm.ChildRemoved:Connect(dirty)
        end
        reg.ChildAdded:Connect(function(c)
            if c.Name == "Mobs" then
                c.ChildAdded:Connect(dirty)
                c.ChildRemoved:Connect(dirty)
                dirty()
            end
        end)
    end
    for _, r in ipairs(MapFolder:GetChildren()) do watchReg(r) end
    MapFolder.ChildAdded:Connect(function(r) watchReg(r); dirty() end)
    MapFolder.ChildRemoved:Connect(dirty)
    dirty()  -- force rebuild now that listeners are registered
end

if MobFolder then
    MobFolder.ChildAdded:Connect(dirty)
    MobFolder.ChildRemoved:Connect(dirty)
end

-- Immediate path: register MapFolder listeners if available now
if MapFolder then
    setupMapListeners()
end
-- Deferred path: the task.spawn in Section 4 calls setupMapListeners()
-- after WaitForChild resolves, so listeners are guaranteed even in
-- streaming-enabled games.

local function getMobs(maxD)
    if CacheDirty then rebuildCache() end
    if not maxD or not HRP then return MobCache end
    local out = {}
    for _, e in ipairs(MobCache) do
        if inWS(e.model) and e.hum.Health > 0
           and dist(HRP.Position, e.hrp.Position) <= maxD then
            out[#out + 1] = e
        end
    end
    return out
end

local function getNearestMob(maxD)
    if not HRP then return nil end
    local near, nearD = nil, math.huge
    for _, e in ipairs(getMobs(maxD)) do
        local d = dist(HRP.Position, e.hrp.Position)
        if d < nearD then near = e; nearD = d end
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
-- SECTION 11: ATTACK
-- firetouchinterest begin → yield → firetouchinterest end
-- TakeDamage removed (v7 LOGIC-3): client-side, server-filtered.
-- ════════════════════════════════════════════════════════════
local function attackEntry(e)
    if not inWS(e.model) or e.hum.Health <= 0 then return end
    local h = getHandle(); if not h then return end
    for _, p in ipairs(e.parts) do
        if p and p.Parent then pcall(firetouchinterest, h, p, 1) end
    end
    task.wait()
    if not inWS(e.model) or e.hum.Health <= 0 then return end
    for _, p in ipairs(e.parts) do
        if p and p.Parent then pcall(firetouchinterest, h, p, 0) end
    end
end

-- ════════════════════════════════════════════════════════════
-- SECTION 12: GOD MODE
-- Layer 1: Heartbeat health floor (Section 23)
-- Layer 2: __namecall hook (below) — client-side interception
-- Layer 3: Rayfield notify on toggle
-- ════════════════════════════════════════════════════════════
local namecallHook
local godHookActive = false

if hookmetamethod and getrawmetatable then
    pcall(function()
        local mt = getrawmetatable(game)
        setreadonly(mt, false)

        namecallHook = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            if Flags.GodMode and Hum and Hum.Parent
               and self == Hum
               and (method == "TakeDamage" or method == "BreakJoints" or method == "Kill") then
                return
            end
            return namecallHook(self, ...)
        end)

        pcall(function() setreadonly(mt, true) end)
    end)

    if namecallHook then
        godHookActive = true
    else
        warn("[ENI] GodMode: namecall hook failed — TakeDamage interception inactive. " ..
             "Heartbeat health floor remains active.")
    end
end

-- ════════════════════════════════════════════════════════════
-- SECTION 13: CURRENCY
-- ════════════════════════════════════════════════════════════
local function getCurrencies()
    local ctrl   = RS_inner and RS_inner:FindFirstChild("Controllers")
    local mui    = ctrl and ctrl:FindFirstChild("MainUIController")
    local ls     = LP:FindFirstChild("leaderstats")
    local function v(p, n)
        local x = p and p:FindFirstChild(n); return x and x.Value or 0
    end
    local muiPower = v(mui, "Power")
    return {
        Power   = muiPower > 0 and muiPower or v(ls, "Power"),
        Gold    = v(mui, "Gold"),
        Gems    = v(mui, "Gems"),
        Souls   = v(mui, "Souls2026"),
        Raidium = v(mui, "Raidium"),
    }
end

local function getPlayerPower()
    return getCurrencies().Power
end

-- ════════════════════════════════════════════════════════════
-- SECTION 14: PORTAL SCANNER & SCORER
-- ════════════════════════════════════════════════════════════
local PORTAL_POWER_TAGS = {
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
    if req and (req:IsA("IntValue") or req:IsA("NumberValue")) then
        return req.Value
    end
    local nameLower = circle.Name:lower()
    for _, entry in ipairs(PORTAL_POWER_TAGS) do
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

    if req == 0 then
        score = 50
    elseif Flags.AutoScaleDiff then
        if playerPower < req * 0.8 then
            score = -9999
        else
            local diff = playerPower - req
            score = 100 - math.min(diff / math.max(req, 1) * 50, 80)
        end
        if isRed and Flags.PrioritizeRed then score = score + 500 end
    else
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
            local score = scorePortal(circle, playerPower)
            if score > bestScore then
                best      = circle
                bestScore = score
            end
        end
    end

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

    if not entered and R.FullDungeonRemote then
        pcall(function() R.FullDungeonRemote:FireServer() end)
        entered = true
    end

    return entered
end

-- ════════════════════════════════════════════════════════════
-- SECTION 15: COLLECT
-- PP-1 (retained): isCollectPrompt() uses getPromptText()
-- LOGIC-3: flags re-checked after every task.wait() resumes
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

local COLLECT_KEYWORDS = {"chest","reward","loot","pickup","claim","prize"}

local function isCollectPrompt(pp)
    local txt = getPromptText(pp)
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

-- Forward declarations for ESP functions used in DropFolder listener
local addLootESP, removeLootESP

if DropFolder then
    DropFolder.ChildAdded:Connect(function(obj)
        -- LOGIC-3: check LootESP flag at callback entry AND after yield
        if Flags.LootESP then
            pcall(function() addLootESP(obj) end)
        end
        if not Flags.AutoCollect then return end

        if obj:IsA("BasePart") then
            local pp = obj:FindFirstChildWhichIsA("ProximityPrompt")
            if pp then
                task.wait(rnd(0.3, 0.6))
                -- LOGIC-3: re-check after yield
                if Flags.AutoCollect then
                    pcall(fireproximityprompt, pp)
                end
            else
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
                        task.wait(rnd(0.1, 0.25))
                        -- LOGIC-3: re-check after yield
                        if Flags.AutoCollect then
                            pcall(fireproximityprompt, c)
                        end
                    end
                end)
            end
        else
            task.wait(rnd(0.3, 0.6))
            -- LOGIC-3: re-check after yield
            if Flags.AutoCollect then
                pcall(collectDrop, obj)
            end
        end
    end)
    DropFolder.ChildRemoved:Connect(function(obj)
        pcall(function() removeLootESP(obj) end)
    end)
end

-- ════════════════════════════════════════════════════════════
-- SECTION 16: AUTO SELL
-- PP-1 (retained): composite text via getPromptText()
-- "npc" removed (v7 LOGIC-4): too broad
-- ════════════════════════════════════════════════════════════
local SELL_KEYWORDS = {"sell","merchant","shop","store","vendor"}

local function findSellPrompts()
    local prompts = {}
    if not LobbyFolder then return prompts end
    for _, desc in ipairs(LobbyFolder:GetDescendants()) do
        if desc:IsA("ProximityPrompt") then
            local txt = getPromptText(desc)
            for _, kw in ipairs(SELL_KEYWORDS) do
                if txt:find(kw) then prompts[#prompts + 1] = desc; break end
            end
        end
    end
    return prompts
end

local function doAutoSell()
    local prompts = findSellPrompts()
    for _, pp in ipairs(prompts) do
        if HRP then
            local targetPart = (pp.Parent and pp.Parent:IsA("BasePart") and pp.Parent)
                            or (pp.Parent and pp.Parent:IsA("Model")
                                and pp.Parent:FindFirstChildWhichIsA("BasePart"))
            if targetPart then
                HRP.CFrame = CFrame.new(targetPart.Position + Vector3.new(0, 5, 0))
                task.wait(0.3)
            end
        end
        pcall(fireproximityprompt, pp)
        task.wait(rnd(0.3, 0.6))
    end
end

-- ════════════════════════════════════════════════════════════
-- SECTION 17: AUTO BUY MERCHANT SHOP
-- PP-1 (retained): composite text via getPromptText()
-- "item" removed (v7 LOGIC-1): substring too broad
-- ════════════════════════════════════════════════════════════
local BUY_KEYWORDS = {"buy","purchase","trade"}

local function doAutoBuy()
    if not LobbyFolder then return end
    for _, desc in ipairs(LobbyFolder:GetDescendants()) do
        if desc:IsA("ProximityPrompt") then
            local txt = getPromptText(desc)
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
-- SECTION 18: AUTO EQUIP BEST GEAR
--
-- STATE-1 (v7, retained): scans both Backpack and Char.
-- STATE-1 (v7, retained): skips swap when best == current.
--
-- STATE-1 (v8): getToolPower() Attributes path fixed.
-- Previous code: local av = pcall(...)
-- pcall returns (bool, value). av captured only the bool.
-- type(av) == "number" was always false — dead branch.
-- Fix: local ok, av = pcall(...) with ok guard on type check.
-- ════════════════════════════════════════════════════════════
local TOOL_POWER_ATTRS = {
    "Power","Level","Stats","GearScore","Tier",
    "Rank","Score","Strength","Attack",
}

local function getToolPower(tool)
    -- Priority 1: recognized child value instances
    for _, attr in ipairs(TOOL_POWER_ATTRS) do
        local v = tool:FindFirstChild(attr)
        if v and (v:IsA("IntValue") or v:IsA("NumberValue")) then
            return v.Value
        end
    end
    -- Priority 2: Roblox Instance Attributes
    -- STATE-1: fixed pcall capture — ok, av not just av
    for _, attr in ipairs(TOOL_POWER_ATTRS) do
        local ok, av = pcall(function() return tool:GetAttribute(attr) end)
        if ok and type(av) == "number" then return av end
    end
    -- Priority 3: name-digit heuristic (last resort)
    local n = tool.Name:match("%d+")
    if n then
        warn("[ENI] getToolPower: name-parse fallback for '" .. tool.Name ..
             "' — add a recognized value child or Attribute to eliminate this warn.")
        return tonumber(n)
    end
    return 0
end

local function doAutoEquipBest()
    local backpack = LP:FindFirstChild("Backpack")
    if not backpack or not Char then return end

    local best, bestPow = nil, -1
    local currentTool   = nil

    for _, tool in ipairs(backpack:GetChildren()) do
        if tool:IsA("Tool") then
            local pw = getToolPower(tool)
            if pw > bestPow then best = tool; bestPow = pw end
        end
    end

    for _, item in ipairs(Char:GetChildren()) do
        if item:IsA("Tool") then
            currentTool = item
            local pw = getToolPower(item)
            if pw > bestPow then best = item; bestPow = pw end
        end
    end

    if not best then return end
    if best == currentTool then return end   -- already equipped

    if currentTool then
        pcall(function() currentTool.Parent = backpack end)
        task.wait(0.05)
    end
    pcall(function() best.Parent = Char end)
end

-- ════════════════════════════════════════════════════════════
-- SECTION 19: AUTO QUEST
--
-- STATE-2: doAutoQuest() had the identical blocking InvokeServer
-- pattern that was fixed in doRedeemCodes() but was not audited
-- in the v7 pass. Three bare InvokeServer calls inside pcall,
-- no timeout. In QUESTING state the farm loop calls this
-- synchronously after every dungeon — one network partition
-- freezes the loop permanently.
-- Fix: each call wrapped with task.spawn + task.delay(3) timeout,
-- identical pattern to the doRedeemCodes() fix.
-- ════════════════════════════════════════════════════════════

-- Shared timeout-bounded InvokeServer helper
local function timedInvoke(rf, timeout, ...)
    if not rf then return end
    local args    = {...}
    local done    = false
    local timedOut = false

    local callThread = task.spawn(function()
        pcall(function() rf:InvokeServer(table.unpack(args)) end)
        done = true
    end)

    local timeoutHandle = task.delay(timeout, function()
        if not done then
            timedOut = true
            pcall(task.cancel, callThread)
        end
    end)

    local elapsed = 0
    while not done and not timedOut and elapsed < timeout + 0.5 do
        local dt = task.wait(0.1)
        elapsed  = elapsed + dt
    end

    if done and not timedOut then
        pcall(task.cancel, timeoutHandle)
    end
end

local function doAutoQuest()
    -- STATE-2: 3-second timeout per call
    timedInvoke(QF.TurnInQuest,    3)
    task.wait(rnd(0.4, 0.7))
    timedInvoke(QF.RequestQuest,   3)
    task.wait(rnd(0.4, 0.7))
    timedInvoke(QF.MarkGiverViewed, 3)
end

-- ════════════════════════════════════════════════════════════
-- SECTION 20: AUTO REDEEM CODES
-- STATE-2 (v7, retained): 5-second timeout per code.
-- Uses the shared timedInvoke helper added for Section 19.
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
        timedInvoke(rf, 5, code)
        task.wait(rnd(0.3, 0.6))
    end

    codesRedeemedThisSession = true
end

-- ════════════════════════════════════════════════════════════
-- SECTION 21: DUNGEON STATE MACHINE
-- ════════════════════════════════════════════════════════════
local DungeonState   = "LOBBY"
local dungeonThread  = nil
local DungeonTimeout = 120

local function isDungeonMob(model)
    return not MobFolder or not model:IsDescendantOf(MobFolder)
end

local function hasDungeonMobs()
    for _, e in ipairs(getMobs()) do
        if isDungeonMob(e.model) then return true end
    end
    return false
end

local function waitForDungeonLoad(timeoutSec)
    local elapsed = 0
    while elapsed < timeoutSec do
        dirty()
        if hasDungeonMobs() then return true end
        local actual = task.wait(0.5)
        elapsed = elapsed + actual
    end
    return false
end

local function killAllDungeonMobs()
    local elapsed = 0
    while elapsed < DungeonTimeout do
        dirty()
        local dungeonMobs = {}
        for _, e in ipairs(getMobs()) do
            if isDungeonMob(e.model) then
                dungeonMobs[#dungeonMobs + 1] = e
            end
        end
        if #dungeonMobs == 0 then break end
        for _, e in ipairs(dungeonMobs) do
            if inWS(e.model) and e.hum.Health > 0 then
                attackEntry(e)
            end
        end
        dirty()
        local actual = task.wait(rnd(0.15, 0.28))
        elapsed = elapsed + actual
    end
end

local function returnToLobby()
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
            HRP.CFrame = CFrame.new(spawn.Position + Vector3.new(0, 6, 0))
            return
        end
    end
    HRP.CFrame = CFrame.new(Vector3.new(0, 100, 0))
end

-- ─────────────────────────────────────────────────────────────
-- STATE-4: Cached lobby BaseParts list for proximity detection.
-- Rebuilt lazily and on every respawn (refreshChar clears it).
-- LOGIC-2: finds minimum-distance BasePart, not first-match.
-- ─────────────────────────────────────────────────────────────
local function getLobbyBaseParts()
    if lobbyBaseParts then return lobbyBaseParts end
    lobbyBaseParts = {}
    if not LobbyFolder then return lobbyBaseParts end
    for _, p in ipairs(LobbyFolder:GetDescendants()) do
        if p:IsA("BasePart") then
            lobbyBaseParts[#lobbyBaseParts + 1] = p
        end
    end
    return lobbyBaseParts
end

-- ─────────────────────────────────────────────────────────────
-- STATE-3: Improved dungeon detection — replaces the
-- `child.Name ~= "Lobby" and child.Name ~= "Circles"` loop
-- which returned LEAVING on the first non-lobby child (utility
-- folders, terrain, scripts all triggered it).
-- Now requires positive confirmation: player position inside
-- a non-lobby, non-circles MapFolder region BoundingBox.
-- ─────────────────────────────────────────────────────────────
local function isInsideDungeonRegion()
    if not HRP or not MapFolder then return false end
    local playerPos = HRP.Position
    for _, child in ipairs(MapFolder:GetChildren()) do
        if child.Name ~= "Lobby" and child.Name ~= "Circles" and child:IsA("Model") then
            -- Check each BasePart of the region for containment
            for _, part in ipairs(child:GetDescendants()) do
                if part:IsA("BasePart") then
                    -- Convert player position to the part's local space
                    local localPos = part.CFrame:PointToObjectSpace(playerPos)
                    local halfSize = part.Size * 0.5
                    -- Slightly generous bounds (1.5x) to handle edge detection
                    if math.abs(localPos.X) <= halfSize.X * 1.5
                    and math.abs(localPos.Y) <= halfSize.Y * 1.5
                    and math.abs(localPos.Z) <= halfSize.Z * 1.5 then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function inferStartState()
    dirty()

    -- Signal 1: live dungeon mobs → mid-fight
    for _, e in ipairs(getMobs()) do
        if isDungeonMob(e.model) then return "FIGHTING" end
    end

    -- Signal 2: CirclesFolder empty with player present → cleared dungeon
    if CirclesFolder then
        local hasPortals = false
        for _, c in ipairs(CirclesFolder:GetChildren()) do
            if c:IsA("Model") then hasPortals = true; break end
        end
        if not hasPortals and HRP then return "LEAVING" end
    end

    -- Signal 3: position-based dungeon detection
    -- LOGIC-2: minimum-distance evaluation over all lobby parts (not first-match)
    if HRP and LobbyFolder and MapFolder then
        local LOBBY_THRESHOLD = 300
        local parts   = getLobbyBaseParts()
        local nearest = math.huge
        -- STATE-4: iterate cached list, find minimum distance
        for _, part in ipairs(parts) do
            local d = dist(HRP.Position, part.Position)
            if d < nearest then nearest = d end
        end

        local nearLobby = nearest < LOBBY_THRESHOLD

        -- STATE-3: only return LEAVING if player is positively inside
        -- a dungeon region BoundingBox — not just "MapFolder has other folders"
        if not nearLobby and isInsideDungeonRegion() then
            return "LEAVING"
        end
    end

    return "LOBBY"
end

local function startAutoFarm()
    if dungeonThread then
        pcall(task.cancel, dungeonThread)
        dungeonThread = nil
    end

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

            if not HRP or not Hum or Hum.Health <= 0 then
                task.wait(1); continue
            end

            -- ── LOBBY ─────────────────────────────────────────
            if DungeonState == "LOBBY" then

                if Flags.AutoSell        then doAutoSell();        task.wait(rnd(0.5, 1.0)) end
                if Flags.AutoBuyMerchant then doAutoBuy();         task.wait(rnd(0.3, 0.6)) end
                if Flags.AutoEquipBest   then doAutoEquipBest() end
                if Flags.AutoRedeemCodes then doRedeemCodes(false) end

                local portal = getBestPortal()
                if not portal then task.wait(2); continue end

                enterPortal(portal)
                DungeonState = "ENTERING"
                task.wait(rnd(2.5, 4.5))

            -- ── ENTERING ──────────────────────────────────────
            elseif DungeonState == "ENTERING" then

                local loaded = waitForDungeonLoad(15)
                DungeonState = loaded and "FIGHTING" or "LEAVING"

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
                DungeonState = Flags.AutoQuest and "QUESTING" or "LOBBY"

            -- ── QUESTING ──────────────────────────────────────
            elseif DungeonState == "QUESTING" then

                if HRP and LobbyFolder then
                    local qg   = LobbyFolder:FindFirstChild("QuestGiver")
                    local base = qg and qg:FindFirstChildWhichIsA("BasePart")
                    if base then
                        HRP.CFrame = CFrame.new(base.Position + Vector3.new(0, 5, 0))
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
-- SECTION 22: MISC AUTOMATIONS
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
                pcall(function() Hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
            end
        end
    end)
    registerThread("afkThread", afkThread)
end

-- ════════════════════════════════════════════════════════════
-- SECTION 23: ESP
-- ════════════════════════════════════════════════════════════
local MobESPObjs  = {}
local PlrESPObjs  = {}
local LootESPObjs = {}
local ChamsObjs   = {}

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

local TRACER_RED  = Color3.fromRGB(255,  80,  80)
local TRACER_BLUE = Color3.fromRGB(100, 200, 255)

local function clearTr()
    for i = 1, activeTr do if TrPool[i] then TrPool[i].Visible = false end end
    activeTr = 0
end

local function drawTr(from, to, col)
    activeTr += 1
    if activeTr > POOL_SIZE then return end
    local l = TrPool[activeTr]
    l.From = from; l.To = to; l.Color = col; l.Visible = true
end

local function destroyPool()
    for i = 1, POOL_SIZE do
        if TrPool[i] then pcall(function() TrPool[i]:Remove() end); TrPool[i] = nil end
    end
    activeTr  = 0
    drawingOk = false
end

local function makeBB(parent, text, col, w)
    local bb = Instance.new("BillboardGui")
    bb.AlwaysOnTop = true; bb.Size = UDim2.new(0, w or 80, 0, 30)
    bb.StudsOffset = Vector3.new(0, 3.5, 0); bb.Parent = parent
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1; lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.Text = text; lbl.TextColor3 = col
    lbl.TextStrokeTransparency = 0; lbl.TextScaled = true
    lbl.Font = Enum.Font.GothamBold; lbl.Parent = bb
    return bb, lbl
end

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

-- HOOK-4: initialise from getgenv after ENI_MOB_ESP_BOUND was
-- properly cleared by the retry-path in Section 0.
local MobESPBound = (getgenv and getgenv().ENI_MOB_ESP_BOUND) or false

local function addMobESP(model)
    if MobESPObjs[model] then return end
    local hrp = model:FindFirstChild("HumanoidRootPart")
    local hum = model:FindFirstChildWhichIsA("Humanoid")
    if not hrp or not hum then return end
    local bb, lbl = makeBB(hrp, model.Name, Color3.fromRGB(255, 80, 80), 110)
    local dl = Instance.new("TextLabel")
    dl.BackgroundTransparency = 1; dl.Size = UDim2.new(1, 0, 0.4, 0)
    dl.Position = UDim2.new(0, 0, 1, 0)
    dl.TextColor3 = Color3.fromRGB(255, 200, 200)
    dl.TextStrokeTransparency = 0; dl.TextScaled = true
    dl.Font = Enum.Font.Gotham; dl.Text = ""; dl.Parent = bb
    MobESPObjs[model] = {bb=bb, lbl=lbl, dl=dl, conn=nil}
    MobESPObjs[model].conn = model.AncestryChanged:Connect(function()
        if not model:IsDescendantOf(game) then cleanESP(MobESPObjs, model) end
    end)
end
local function removeMobESP(model) cleanESP(MobESPObjs, model) end

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

local addPlayerESP
addPlayerESP = function(p)
    if PlrESPObjs[p] or p == LP then return end
    local char = p.Character; if not char then return end
    local hrp  = char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
    local bb, lbl = makeBB(hrp, p.Name, Color3.fromRGB(100, 200, 255), 100)
    local dl = Instance.new("TextLabel")
    dl.BackgroundTransparency = 1; dl.Size = UDim2.new(1, 0, 0.4, 0)
    dl.Position = UDim2.new(0, 0, 1, 0)
    dl.TextColor3 = Color3.fromRGB(180, 230, 255)
    dl.TextStrokeTransparency = 0; dl.TextScaled = true
    dl.Font = Enum.Font.Gotham; dl.Text = ""; dl.Parent = bb
    PlrESPObjs[p] = {bb=bb, lbl=lbl, dl=dl}
end
local function removePlayerESP(p) cleanESP(PlrESPObjs, p) end

addLootESP = function(obj)
    if LootESPObjs[obj] then return end
    local part = obj
    if obj:IsA("Model") then
        part = obj:FindFirstChild("Center") or obj:FindFirstChildWhichIsA("BasePart")
    end
    if not part or not part:IsA("BasePart") then return end
    local isEpic = obj:IsA("Model")
    local col    = isEpic and Color3.fromRGB(255, 215, 0) or Color3.fromRGB(220, 220, 220)
    local sel    = Instance.new("SelectionBox")
    sel.Color3 = col; sel.LineThickness = 0.06; sel.SurfaceTransparency = 0.7
    sel.SurfaceColor3 = col; sel.Adornee = part; sel.Parent = part
    local bb = makeBB(part, isEpic and "★ EPIC" or "Drop", col, 80)
    LootESPObjs[obj] = {sel=sel, bb=bb, conn=nil}
    LootESPObjs[obj].conn = obj.AncestryChanged:Connect(function()
        if not obj:IsDescendantOf(game) and LootESPObjs[obj] then
            pcall(function() LootESPObjs[obj].sel:Destroy() end)
            pcall(function() LootESPObjs[obj].bb:Destroy()  end)
            LootESPObjs[obj] = nil
        end
    end)
end

removeLootESP = function(obj)
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
            b.AlwaysOnTop = true; b.ZIndex = 5
            b.Color3 = Color3.fromRGB(255, 60, 60); b.Transparency = 0.5
            b.Size = p.Size; b.Adornee = p; b.Parent = p
            ChamsObjs[model][#ChamsObjs[model] + 1] = b
        end
    end
    ChamsObjs[model].conn = model.AncestryChanged:Connect(function()
        if not model:IsDescendantOf(game) and ChamsObjs[model] then
            for _, b in pairs(ChamsObjs[model]) do
                if typeof(b) == "Instance"            then pcall(function() b:Destroy()    end) end
                if typeof(b) == "RBXScriptConnection" then pcall(function() b:Disconnect() end) end
            end
            ChamsObjs[model] = nil
        end
    end)
end
local function removeChams(model)
    if not ChamsObjs[model] then return end
    for _, b in pairs(ChamsObjs[model]) do
        if typeof(b) == "Instance"            then pcall(function() b:Destroy()    end) end
        if typeof(b) == "RBXScriptConnection" then pcall(function() b:Disconnect() end) end
    end
    ChamsObjs[model] = nil
end
local function clearChams()
    for m in pairs(ChamsObjs) do removeChams(m) end
end

-- ════════════════════════════════════════════════════════════
-- SECTION 24: HEARTBEAT
-- NoClip, SpeedHack, GodMode health floor, ESP updates, Tracers
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

    -- Layer 1 God Mode: health floor
    if Flags.GodMode and Hum and Hum.Parent
       and Hum.Health > 0 and Hum.Health < Hum.MaxHealth then
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
                    o.dl.Text    = d .. "st | HP:" .. math.floor(hum.Health) ..
                                   "/" .. math.floor(hum.MaxHealth)
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
                o.dl.Text    = d .. " studs"
                o.bb.Enabled = d <= Config.ESPMaxDist
            end
        end
    end

    if Flags.Tracers then
        clearTr()
        local cam = WS.CurrentCamera
        local vp  = cam.ViewportSize
        local ctr = Vector2.new(vp.X / 2, vp.Y)
        for _, e in ipairs(getMobs(Config.ESPMaxDist)) do
            local sp, on = cam:WorldToViewportPoint(e.hrp.Position)
            if on then drawTr(ctr, Vector2.new(sp.X, sp.Y), TRACER_RED) end
        end
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP and p.Character then
                local phr = p.Character:FindFirstChild("HumanoidRootPart")
                if phr and dist(HRP.Position, phr.Position) <= Config.ESPMaxDist then
                    local sp, on = cam:WorldToViewportPoint(phr.Position)
                    if on then drawTr(ctr, Vector2.new(sp.X, sp.Y), TRACER_BLUE) end
                end
            end
        end
    else
        if activeTr > 0 then clearTr() end
    end
end)

-- ════════════════════════════════════════════════════════════
-- SECTION 25: CHARACTER RESPAWN
-- ARCH-3 (retained): single authoritative restart point.
-- HOOK-2: isRefreshing mutex in refreshChar() prevents double-
-- write if the CharacterAdded event fires while a prior
-- refreshChar() is still blocked inside WaitForChild.
-- ════════════════════════════════════════════════════════════
LP.CharacterAdded:Connect(function()
    task.wait(0.5)

    local ok = refreshChar()
    if not ok then
        warn("[ENI] CharacterAdded: refreshChar() failed — suspended until next respawn.")
        return
    end

    if Hum then
        Hum.WalkSpeed = Config.WalkSpeed
        Hum.JumpPower = Config.JumpPower
        pcall(function() Hum.JumpHeight = Config.JumpPower * 0.36 end)
    end

    dirty()

    if Flags.AutoFarm then
        if dungeonThread then
            pcall(task.cancel, dungeonThread)
            dungeonThread = nil
        end
        startAutoFarm()
    end
end)

-- ════════════════════════════════════════════════════════════
-- SECTION 26: RAYFIELD
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
    clearLoadGuard()
    warn("[ENI] Rayfield failed — all endpoints exhausted. Re-execution is unlocked.")
    return
end

-- Permanent guard confirmed — Rayfield loaded successfully
if getgenv then getgenv().ENI_SOLO_LOADED = true end

local W = Rayfield:CreateWindow({
    Name            = "Solo Hunters — ENI Build",
    LoadingTitle    = "Solo Hunters",
    LoadingSubtitle = "ENI Build v8.0",
    ConfigurationSaving = { Enabled = false },
    KeySystem = false,
})

-- ════════════════════════════════════════════════════════════
-- SECTION 27: KILL AURA & AUTO SKILLS
-- ARCH-1 (retained): spawned AFTER Rayfield window creation.
-- Handles stored in getgenv() registry for cross-execution cancel.
-- ════════════════════════════════════════════════════════════
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
-- TAB: FARM
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
        if v and not Flags.AutoFarm then task.spawn(doAutoQuest) end
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

FarmTab:CreateButton({ Name = "Do Auto Quest Now",           Callback = function() task.spawn(doAutoQuest)          end })
FarmTab:CreateButton({ Name = "Do Auto Sell Now",            Callback = function() task.spawn(doAutoSell)           end })
FarmTab:CreateButton({ Name = "Collect All Drops Now",       Callback = function() task.spawn(collectAll)           end })
FarmTab:CreateButton({ Name = "Collect Dungeon Rewards Now", Callback = function() task.spawn(collectDungeonRewards) end })

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
                    Content = portal.Name .. " | Req: " .. req .. " | Boss: " .. tostring(isRed),
                    Duration = 4,
                })
                enterPortal(portal)
            else
                Rayfield:Notify({ Title="Portal", Content="No portals found or all out of reach.", Duration=3 })
            end
        end)
    end,
})

FarmTab:CreateButton({ Name = "Return to Lobby", Callback = function() task.spawn(returnToLobby) end })

FarmTab:CreateSection("Codes")

FarmTab:CreateToggle({
    Name = "Auto Redeem Codes",
    Default = false,
    Callback = function(v) Flags.AutoRedeemCodes = v end,
})

FarmTab:CreateButton({
    Name = "Redeem Codes Now",
    Callback = function()
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
    Range = {16, 500}, Increment = 1, Suffix = "",
    CurrentValue = 16, Flag = "WalkSpeed",
    Callback = function(v)
        Config.WalkSpeed = v
        if Hum then Hum.WalkSpeed = v end
    end,
})

PlrTab:CreateSlider({
    Name = "Jump Power",
    Range = {7, 300}, Increment = 1, Suffix = "",
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
        if v then
            local hookStatus = godHookActive and "active" or "inactive (see console)"
            Rayfield:Notify({
                Title   = "God Mode ON",
                Content = "Health floor: ON  |  Hook: " .. hookStatus,
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
        if v then
            startAntiAFK()
        else
            if afkThread then
                pcall(task.cancel, afkThread)
                afkThread = nil
                registerThread("afkThread", nil)
            end
        end
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
        if e and HRP then HRP.CFrame = jitter(CFrame.new(e.hrp.Position + Vector3.new(0, 5, 0))) end
    end,
})

TpTab:CreateButton({ Name = "Return to Lobby", Callback = function() task.spawn(returnToLobby) end })

TpTab:CreateButton({
    Name = "Quest Giver (Lobby)",
    Callback = function()
        if not HRP or not LobbyFolder then return end
        local qg   = LobbyFolder:FindFirstChild("QuestGiver")
        local base = qg and qg:FindFirstChildWhichIsA("BasePart")
        if base then HRP.CFrame = jitter(base.CFrame + Vector3.new(0, 5, 0)) end
    end,
})

TpTab:CreateButton({
    Name = "Daily Quest Board",
    Callback = function()
        if not HRP or not LobbyFolder then return end
        local dq = LobbyFolder:FindFirstChild("Daily Quest")
        local qp = dq and dq:FindFirstChild("QuestsPart")
        if qp then HRP.CFrame = jitter(qp.CFrame + Vector3.new(0, 5, 0)) end
    end,
})

TpTab:CreateSection("Players")

TpTab:CreateButton({
    Name = "Teleport to Nearest Player",
    Callback = function()
        if not HRP then return end
        local near, nearD = nil, math.huge
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP and p.Character then
                local phr = p.Character:FindFirstChild("HumanoidRootPart")
                if phr then
                    local d = dist(HRP.Position, phr.Position)
                    if d < nearD then near = phr; nearD = d end
                end
            end
        end
        if near then
            HRP.CFrame = jitter(near.CFrame + Vector3.new(0, 5, 0))
        else
            Rayfield:Notify({ Title="TP", Content="No other players found.", Duration=3 })
        end
    end,
})

TpTab:CreateDropdown({
    Name = "Teleport to Player (load-time)",
    Options = (function()
        local t = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then t[#t + 1] = p.Name end
        end
        return #t > 0 and t or {"(nobody)"}
    end)(),
    Default = "...",
    Callback = function(v)
        local t = Players:FindFirstChild(v)
        if t and t.Character then
            local thr = t.Character:FindFirstChild("HumanoidRootPart")
            if thr and HRP then HRP.CFrame = jitter(thr.CFrame + Vector3.new(0, 5, 0)) end
        end
    end,
})

TpTab:CreateSection("Waypoints")

local SafeSpot = nil
local Waypoints = {}

TpTab:CreateButton({
    Name = "Save Safe Spot",
    Callback = function()
        if HRP then SafeSpot = HRP.CFrame; Rayfield:Notify({ Title="Safe Spot", Content="Saved.", Duration=2 }) end
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
        local name = "WP" .. tostring(#Waypoints + 1)
        Waypoints[#Waypoints + 1] = {name=name, cf=HRP.CFrame}
        Rayfield:Notify({ Title="Waypoint", Content=name .. " saved.", Duration=2 })
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
                bindPlayerLifetime(p); addPlayerESP(p)
            end
            if not PlrESPBound then
                PlrESPBound = true
                Players.PlayerAdded:Connect(function(p)
                    bindPlayerLifetime(p)
                    if Flags.PlayerESP then task.wait(0.5); addPlayerESP(p) end
                end)
                Players.PlayerRemoving:Connect(function(p)
                    removePlayerESP(p); unbindPlayerLifetime(p)
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
    Range = {50, 2000}, Increment = 50, Suffix = " studs",
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
        if v then
            startAugment()
        else
            if augThread then
                pcall(task.cancel, augThread)
                augThread = nil
                registerThread("augThread", nil)
            end
        end
    end,
})

MiscTab:CreateToggle({
    Name = "Auto Slot Machine",
    Default = false,
    Callback = function(v)
        Flags.AutoSlotMachine = v
        if v then
            startSlot()
        else
            if slotThread then
                pcall(task.cancel, slotThread)
                slotThread = nil
                registerThread("slotThread", nil)
            end
        end
    end,
})

MiscTab:CreateSlider({
    Name = "Slot Delay",
    Range = {1, 10}, Increment = 0.5, Suffix = "s",
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
            Rayfield:Notify({ Title="FPS", Content="Cap removed.", Duration=3 })
        else
            Rayfield:Notify({ Title="FPS", Content="setfpscap not available on this executor.", Duration=4 })
        end
    end,
})

MiscTab:CreateButton({
    Name = "Rejoin",
    Callback = function()
        destroyPool()
        cancelAllThreads()
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
    Title   = "ENI Build v8.0",
    Content = "Solo Hunters loaded  |  RightShift = toggle UI",
    Duration = 5,
})
