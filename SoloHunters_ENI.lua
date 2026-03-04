--[[
    ╔══════════════════════════════════════════════════════════╗
    ║          SOLO HUNTERS — ENI BUILD  v4.0                  ║
    ║          Xeno Executor  |  Structure scan v2.0           ║
    ╚══════════════════════════════════════════════════════════╝

    CHANGELOG v4.0 — Full audit pass against Structure.txt scan
    ─────────────────────────────────────────────────────────
    BUG FIX — Kill Aura unbounded thread storm (🔴 CRITICAL):
      v3.0 spawned a new task.spawn() every aura tick from the
      Heartbeat callback. Because attackEntry() yields internally
      (task.wait), each spawn lived ~0.25s × N-mobs seconds.
      At 4 Hz with 10 mobs this created ~40 overlapping tasks
      after 10 seconds, producing an exponential remote-fire
      spike detectable server-side.

      Fix: Kill Aura is now driven by a single persistent coroutine
      (auraThread) that paces itself with randRange(0.20, 0.35).
      It is started once at script init, runs perpetually, and
      only does work when Flags.KillAura is true. No Heartbeat
      involvement; no concurrent spawning.

    BUG FIX — hpAtCheckpoint wrong initial value (🔴 CRITICAL):
      Was: hpAtCheckpoint = entry.hum.MaxHealth
      Now: hpAtCheckpoint = entry.hum.Health
      Effect: if a mob spawned pre-damaged (e.g. 500/1000 HP),
      the progress check at 2s found currentHP < MaxHealth and
      incorrectly concluded damage was dealt. Pre-damaged mobs
      were never marked unkillable even if firetouchinterest
      wasn't working.

    BUG FIX — getCurrencyValues wrong path (🟡):
      Structure confirms MainUIController is a ModuleScript at:
        RS (service) → ReplicatedStorage (Folder)
             → Controllers (Folder) → MainUIController
      Its IntValue children: Gold, Gems, Raidium, Souls2026, Power.
      v3.0 was looking in LP.PlayerScripts.StarterPlayerScripts,
      which doesn't contain MainUIController. All currency values
      always returned 0. Fixed to the confirmed path.

    BUG FIX — InfiniteStamina silently non-functional (🟡):
      Structure confirms NO Stamina/Energy IntValue or NumberValue
      exists anywhere on the character model. The StaminaParts
      table always built empty; the feature was a no-op.
      New approach: multi-path attempt each tick —
        1. Char:SetAttribute("Stamina"/"Energy"/"Dash") = max
        2. StaminaParts value scan (kept as cheap fallback)
      Path 1 covers games using Roblox Attributes for stamina.

    BUG FIX — refreshCharacter stacks duplicate listeners (🟡):
      Each call to refreshCharacter() connected new ChildAdded/
      ChildRemoved handlers on the new character without
      disconnecting the previous character's handlers. After 5
      deaths, 5 simultaneous handlers fired on equipment changes.
      Fix: charConnections table stores all per-character RBX
      connections; each refreshCharacter() disconnects them all
      before reconnecting on the new character.

    BUG FIX — getNearestMob double-filters by distance (🟡):
      getMobs(maxDist) already guarantees every returned entry is
      within maxDist. The inner getDistance check in getNearestMob
      was pure redundancy. Removed; the loop now only tracks the
      nearest entry without re-filtering.

    BUG FIX — Player teleport dropdown static at load (🟡):
      The dropdown was built from Players:GetPlayers() at load
      time via an IIFE. Players who joined after script load were
      missing. Added "Teleport to Nearest Player" dynamic button
      alongside the existing dropdown as a reliable alternative.

    BUG FIX — JumpPower ignores UseJumpPower flag (🟡):
      If the Humanoid uses JumpHeight mode (UseJumpPower = false),
      writing JumpPower has zero effect. Now writes both JumpPower
      and JumpHeight so whichever mode is active takes effect.

    POLISH — Distinct tab icons per tab (🟢):
      All five tabs previously used the same asset ID 4483362458.
      Now each tab uses a semantically appropriate Lucide icon
      string: sword / user / map / eye / settings.

    POLISH — GodMode Heartbeat HP reset removed (🟢):
      The Hum.Health = Hum.MaxHealth write every frame was
      redundant: the namecall hook already blocks TakeDamage
      before health changes. The frame-late write caused visible
      HP-bar flicker. Removed.

    POLISH — Drawing pool cleanup on script stop (🟢):
      Added destroyDrawingPool() to properly hide and remove all
      pre-allocated Drawing.Line objects. Called from the Rejoin
      button and exposed for manual cleanup.

    POLISH — DropFolder nil diagnostic warn (🟢):
      If Camera.Drops is not found, a warn() is now emitted so the
      failure is visible in the executor console rather than silent.

    POLISH — Plain Part drops get deferred ProximityPrompt listener (🟢):
      Structure confirms plain Part drops inside Camera.Drops have
      no ProximityPrompt at spawn time. The game adds it dynamically.
      The DropFolder.ChildAdded handler now also connects a
      ChildAdded watcher on bare Part drops to fire the prompt the
      moment it appears.
]]

-- ─────────────────────────────────────────────
-- SERVICES
-- ─────────────────────────────────────────────
local Players         = game:GetService("Players")
local RunService      = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local WS              = game:GetService("Workspace")
local RS              = game:GetService("ReplicatedStorage")

-- ─────────────────────────────────────────────
-- CONFIRMED PATHS (from Structure.txt scan)
--
-- Remotes live at:
--   RS (service) → RS:FindFirstChild("ReplicatedStorage")
--                → :FindFirstChild("Remotes")
--
-- Currency values live at:
--   RS (service) → RS:FindFirstChild("ReplicatedStorage")
--                → :FindFirstChild("Controllers")
--                → :FindFirstChild("MainUIController")
--                    ├─ Gold      [IntValue]
--                    ├─ Gems      [IntValue]
--                    ├─ Raidium   [IntValue]
--                    ├─ Souls2026 [IntValue]
--                    └─ Power     [IntValue]
-- ─────────────────────────────────────────────
local RS_inner = RS:WaitForChild("ReplicatedStorage", 10)

local RemotesFolder = RS_inner and RS_inner:WaitForChild("Remotes", 10)

local MobFolder  = WS:WaitForChild("Mobs", 10)

-- Drops are parented to Camera (local-only, no replication)
local DropFolder = (function()
    local cam = WS:WaitForChild("Camera", 10)
    local drops = cam and cam:WaitForChild("Drops", 10)
    if not drops then
        warn("[ENI] WARNING: Camera.Drops not found — AutoCollect and LootESP are disabled.")
    end
    return drops
end)()

local MapFolder   = WS:FindFirstChild("Map")
local LobbyFolder = MapFolder and MapFolder:FindFirstChild("Lobby")

-- ─────────────────────────────────────────────
-- REMOTES
-- ─────────────────────────────────────────────
local Remotes = {}
if RemotesFolder then
    for _, name in ipairs({
        "BossAltarSpawnBoss", "FullDungeonRemote",
        "SpinSlotMachine",    "GiveSlotMachinePrize",
        "StartChallenge",     "SendAugment",
        "ChooseAugment",      "SacrificeWeapon",
        "BodyMover",          "MouseReplication",
    }) do
        local r = RemotesFolder:FindFirstChild(name)
        if r then Remotes[name] = r end
    end
else
    warn("[ENI] WARNING: RemotesFolder not found — all remote-based features disabled.")
end

-- ─────────────────────────────────────────────
-- LOCAL PLAYER
-- ─────────────────────────────────────────────
local LP = Players.LocalPlayer
local Char, Hum, HRP

-- Cached part lists — rebuilt on CharacterAdded and on equipment change
local NoClipParts  = {}
local StaminaParts = {}

-- Per-character RBX connection handles — disconnected on each refresh
-- to prevent listener accumulation across deaths.
local charConnections = {}

local function rebuildCharCaches()
    NoClipParts  = {}
    StaminaParts = {}
    if not Char then return end
    for _, v in ipairs(Char:GetDescendants()) do
        if v:IsA("BasePart") then
            NoClipParts[#NoClipParts + 1] = v
        end
        -- Scan for value objects with stamina-like names (fallback path).
        -- NOTE: Structure scan found no such objects on this character;
        -- this scan is a cheap no-op but costs nothing to keep.
        local nm = v.Name:lower()
        if (v:IsA("NumberValue") or v:IsA("IntValue"))
           and (nm:find("stamina") or nm:find("energy")) then
            StaminaParts[#StaminaParts + 1] = v
        end
    end
end

local function refreshCharacter()
    -- Disconnect ALL previous per-character listeners before binding new ones.
    -- v3.0 omitted this step, causing N handlers to accumulate after N deaths.
    for _, conn in ipairs(charConnections) do
        conn:Disconnect()
    end
    charConnections = {}

    Char = LP.Character or LP.CharacterAdded:Wait()
    Hum  = Char:WaitForChild("Humanoid", 5)
    HRP  = Char:WaitForChild("HumanoidRootPart", 5)
    rebuildCharCaches()

    -- Rebuild caches when the player equips or unequips a tool mid-session
    charConnections[#charConnections + 1] = Char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then rebuildCharCaches() end
    end)
    charConnections[#charConnections + 1] = Char.ChildRemoved:Connect(function(child)
        if child:IsA("Tool") then rebuildCharCaches() end
    end)
end
refreshCharacter()

-- ─────────────────────────────────────────────
-- FLAGS
-- ─────────────────────────────────────────────
local Flags = {
    GodMode         = false,
    InfiniteStamina = false,
    KillAura        = false,
    AutoFarm        = false,
    FarmStationary  = true,   -- true = player stays put; false = mobile
    AutoCollect     = false,
    NoClip          = false,
    MobESP          = false,
    PlayerESP       = false,
    LootESP         = false,
    Chams           = false,
    Tracers         = false,
    AutoSlotMachine = false,
    AutoAugment     = false,
}

local Config = {
    KillAuraRadius   = 50,
    FarmRadius       = 500,
    WalkSpeed        = 16,
    JumpPower        = 50,
    ESPMaxDist       = 300,
    SlotMachineDelay = 2,
}

-- ─────────────────────────────────────────────
-- UTILITY
-- ─────────────────────────────────────────────
local random = Random.new()

local function getDistance(a, b)
    return (a - b).Magnitude
end

local function randRange(lo, hi)
    return lo + random:NextNumber() * (hi - lo)
end

local function jitterCFrame(cf, xzAmt, yAmt)
    xzAmt = xzAmt or 1.5
    yAmt  = yAmt  or 0.5
    return cf + Vector3.new(
        randRange(-xzAmt, xzAmt),
        randRange(-yAmt,  yAmt),
        randRange(-xzAmt, xzAmt)
    )
end

-- ─────────────────────────────────────────────
-- WAYPOINTS
-- ─────────────────────────────────────────────
local Waypoints = {}
local SafeSpot  = nil

-- ─────────────────────────────────────────────
-- MOB CACHE
--
-- Each entry: { model, hrp, hum, attackParts }
--   attackParts = pre-built list of BaseParts to target with
--   firetouchinterest, excluding SlashHitbox (mob weapon parts).
--
-- Open-world mobs (Workspace.Mobs): managed by ChildAdded/Removed
-- on MobFolder.
--
-- Dungeon mobs (Workspace.Map.*): managed by ChildAdded/Removed
-- on each dungeon's mob container discovered at load time.
--
-- NOTE: Structure scan showed Map only contains Lobby and Circles at
-- scan time. Dungeon Mobs folders appear dynamically when a dungeon
-- loads. The watchRegion() listener handles this correctly.
-- ─────────────────────────────────────────────
local MobCache   = {}
local CacheDirty = true

-- Part names that are mob attack hitboxes. Firing touch events on
-- these registers damage FROM the mob TO the player, not the reverse.
local EXCLUDED_PART_NAMES = {
    SlashHitbox  = true,
    AttackHitbox = true,
    DamageHitbox = true,
    WeaponHitbox = true,
}

local function buildAttackParts(model)
    local parts = {}
    for _, desc in ipairs(model:GetDescendants()) do
        if desc:IsA("BasePart") and not EXCLUDED_PART_NAMES[desc.Name] then
            parts[#parts + 1] = desc
        end
    end
    return parts
end

local function rebuildMobCache()
    MobCache   = {}
    CacheDirty = false

    local playerChars = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then playerChars[p.Character] = true end
    end

    local function tryAdd(model)
        if playerChars[model] then return end
        local hum = model:FindFirstChildWhichIsA("Humanoid")
        local hrp = model:FindFirstChild("HumanoidRootPart")
        if not hum or not hrp or hum.Health <= 0 then return end
        MobCache[#MobCache + 1] = {
            model       = model,
            hrp         = hrp,
            hum         = hum,
            attackParts = buildAttackParts(model),
        }
    end

    -- Open-world spawns
    if MobFolder then
        for _, child in ipairs(MobFolder:GetChildren()) do
            if child:IsA("Model") then tryAdd(child) end
        end
    end

    -- Dungeon mobs: scan the Mobs sub-folder of each dungeon region
    -- that is currently loaded inside Workspace.Map.
    if MapFolder then
        for _, region in ipairs(MapFolder:GetChildren()) do
            local dungeonMobs = region:FindFirstChild("Mobs")
            if dungeonMobs then
                for _, child in ipairs(dungeonMobs:GetChildren()) do
                    if child:IsA("Model") then tryAdd(child) end
                end
            end
        end
    end
end

local function markDirty()
    CacheDirty = true
end

-- Open-world mob folder events
if MobFolder then
    MobFolder.ChildAdded:Connect(markDirty)
    MobFolder.ChildRemoved:Connect(markDirty)
end

-- Dungeon mob folder events
if MapFolder then
    local function watchRegion(region)
        local dungeonMobs = region:FindFirstChild("Mobs")
        if dungeonMobs then
            dungeonMobs.ChildAdded:Connect(markDirty)
            dungeonMobs.ChildRemoved:Connect(markDirty)
        end
        -- Watch for a Mobs folder that may not exist at scan time
        region.ChildAdded:Connect(function(child)
            if child.Name == "Mobs" then
                child.ChildAdded:Connect(markDirty)
                child.ChildRemoved:Connect(markDirty)
                markDirty()
            end
        end)
    end

    for _, region in ipairs(MapFolder:GetChildren()) do
        watchRegion(region)
    end
    MapFolder.ChildAdded:Connect(function(region)
        watchRegion(region)
        markDirty()
    end)
    MapFolder.ChildRemoved:Connect(markDirty)
end

-- Returns the mob list, rebuilding the cache only when dirty.
local function getMobs(maxDist)
    if CacheDirty then rebuildMobCache() end

    if not maxDist or not HRP then
        return MobCache
    end

    local filtered = {}
    for _, entry in ipairs(MobCache) do
        if entry.model:IsDescendantOf(WS)
           and entry.hum.Health > 0
           and getDistance(HRP.Position, entry.hrp.Position) <= maxDist then
            filtered[#filtered + 1] = entry
        end
    end
    return filtered
end

-- Returns the nearest mob within maxDist.
-- FIX: removed redundant inner distance/health re-check — getMobs(maxDist)
-- already guarantees every returned entry satisfies both conditions.
local function getNearestMob(maxDist)
    if not HRP then return nil end
    local nearest, nearestDist = nil, math.huge
    for _, entry in ipairs(getMobs(maxDist)) do
        local d = getDistance(HRP.Position, entry.hrp.Position)
        if d < nearestDist then
            nearest     = entry
            nearestDist = d
        end
    end
    return nearest, nearestDist
end

-- ─────────────────────────────────────────────
-- WEAPON HANDLE
-- ─────────────────────────────────────────────
local function getWeaponHandle()
    if not Char then return HRP end
    for _, item in ipairs(Char:GetChildren()) do
        if item:IsA("Tool") then
            local h = item:FindFirstChild("Handle")
                   or item:FindFirstChildWhichIsA("BasePart")
            if h then return h end
        end
    end
    return HRP
end

-- ─────────────────────────────────────────────
-- KILL AURA — stationary, no player movement
--
-- TECHNIQUE: firetouchinterest(source, target, eventType)
--   eventType 1 = TouchEnded  (fired FIRST — clears stale state)
--   eventType 0 = TouchBegan  (fired AFTER yield — registers hit)
--
-- THREAD MODEL (fixed from v3.0):
--   A single persistent coroutine (auraThread) runs forever and
--   paces itself with randRange(0.20, 0.35). It only does work
--   when Flags.KillAura is true. This replaces the v3.0 pattern
--   of spawning a new task every aura tick from Heartbeat, which
--   created an unbounded pile of overlapping coroutines.
-- ─────────────────────────────────────────────
local function attackEntry(entry)
    if not entry.model:IsDescendantOf(WS) then return end
    if entry.hum.Health <= 0 then return end

    local hitbox = getWeaponHandle()
    if not hitbox then return end

    -- Step 1: reset debounce — end any stale touch state on this pair
    for _, part in ipairs(entry.attackParts) do
        if part and part.Parent then
            pcall(firetouchinterest, hitbox, part, 1)
        end
    end

    -- Step 2: yield one engine step so the ended event processes
    task.wait()

    -- Re-validate after yield
    if not entry.model:IsDescendantOf(WS) or entry.hum.Health <= 0 then
        return
    end

    -- Step 3: fire the actual contact hit
    for _, part in ipairs(entry.attackParts) do
        if part and part.Parent then
            pcall(firetouchinterest, hitbox, part, 0)
        end
    end

    -- Secondary: TakeDamage fallback for games that allow client-
    -- authoritative damage for certain damage sources.
    pcall(function() entry.hum:TakeDamage(entry.hum.MaxHealth) end)
end

-- Single persistent Kill Aura coroutine — started once at init.
-- Paces itself with jittered 0.20–0.35s waits. Only acts when
-- Flags.KillAura is true; otherwise just burns through waits cheaply.
local auraThread = task.spawn(function()
    while true do
        local interval = randRange(0.20, 0.35)
        task.wait(interval)

        if Flags.KillAura and Char and Hum and HRP and Hum.Health > 0 then
            local targets = getMobs(Config.KillAuraRadius)
            for _, entry in ipairs(targets) do
                attackEntry(entry)
            end
        end
    end
end)

-- ─────────────────────────────────────────────
-- GOD MODE — __namecall hook (guarded)
-- ─────────────────────────────────────────────
local namecallHook
if hookmetamethod and getrawmetatable then
    pcall(function()
        local mt = getrawmetatable(game)
        setreadonly(mt, false)
        namecallHook = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            if Flags.GodMode and method == "TakeDamage" and self == Hum then
                return
            end
            return namecallHook(self, ...)
        end)
        setreadonly(mt, true)
    end)
end

-- ─────────────────────────────────────────────
-- CURRENCY READER
--
-- Confirmed path from Structure.txt scan:
--   RS (service)
--     └─ ReplicatedStorage [Folder]  (RS_inner)
--           └─ Controllers [Folder]
--                 └─ MainUIController [ModuleScript]
--                       ├─ Gold      [IntValue]
--                       ├─ Gems      [IntValue]
--                       ├─ Raidium   [IntValue]
--                       ├─ Souls2026 [IntValue]
--                       └─ Power     [IntValue]
--
-- leaderstats also carries Power [IntValue] as a redundant source.
-- ─────────────────────────────────────────────
local function getCurrencyValues()
    local controllers = RS_inner and RS_inner:FindFirstChild("Controllers")
    local mui         = controllers and controllers:FindFirstChild("MainUIController")
    local ls          = LP:FindFirstChild("leaderstats")

    local function val(parent, name)
        local v = parent and parent:FindFirstChild(name)
        return v and v.Value or 0
    end

    return {
        -- Power is present in both sources; prefer MainUIController for
        -- consistency with the other currencies, fall back to leaderstats.
        Power   = val(mui, "Power") > 0 and val(mui, "Power") or val(ls, "Power"),
        Gold    = val(mui, "Gold"),
        Gems    = val(mui, "Gems"),
        Souls   = val(mui, "Souls2026"),
        Raidium = val(mui, "Raidium"),
    }
end

-- ─────────────────────────────────────────────
-- ESP HELPERS
-- ─────────────────────────────────────────────
local MobESPObjects    = {}
local PlayerESPObjects = {}
local LootESPObjects   = {}

-- Tracer line pool: pre-allocate and reuse instead of allocating
-- new Drawing objects every tick.
local TRACER_POOL_SIZE = 60
local TracerPool = {}
for i = 1, TRACER_POOL_SIZE do
    local line = Drawing.new("Line")
    line.Thickness    = 1
    line.Transparency = 0.5
    line.Visible      = false
    TracerPool[i] = line
end
local activeTracerCount = 0

-- Destroy all pre-allocated Drawing objects. Call before rejoin or
-- on manual cleanup to prevent Drawing leaks on re-execution.
local function destroyDrawingPool()
    for i = 1, TRACER_POOL_SIZE do
        if TracerPool[i] then
            pcall(function() TracerPool[i]:Remove() end)
            TracerPool[i] = nil
        end
    end
    activeTracerCount = 0
end

local function clearTracers()
    for i = 1, activeTracerCount do
        if TracerPool[i] then TracerPool[i].Visible = false end
    end
    activeTracerCount = 0
end

local function drawTracer(from, to, color)
    activeTracerCount += 1
    if activeTracerCount > TRACER_POOL_SIZE then return end
    local line = TracerPool[activeTracerCount]
    if not line then return end
    line.From    = from
    line.To      = to
    line.Color   = color
    line.Visible = true
end

-- Single-bind guards for ESP listeners
local MobESPConnected    = false
local PlayerESPConnected = false

local function makeBillboard(parent, text, color, width)
    local bb = Instance.new("BillboardGui")
    bb.AlwaysOnTop = true
    bb.Size        = UDim2.new(0, width or 80, 0, 30)
    bb.StudsOffset = Vector3.new(0, 3, 0)
    bb.Parent      = parent

    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Size       = UDim2.new(1, 0, 1, 0)
    lbl.Text       = text
    lbl.TextColor3 = color
    lbl.TextStrokeTransparency = 0
    lbl.TextScaled = true
    lbl.Font       = Enum.Font.GothamBold
    lbl.Parent     = bb

    return bb, lbl
end

local function cleanESP(tbl, key)
    if not tbl[key] then return end
    for _, obj in pairs(tbl[key]) do
        if typeof(obj) == "Instance" then
            pcall(function() obj:Destroy() end)
        end
    end
    tbl[key] = nil
end

-- MOB ESP
local function addMobESP(model)
    if MobESPObjects[model] then return end
    local hrp = model:FindFirstChild("HumanoidRootPart")
    local hum = model:FindFirstChildWhichIsA("Humanoid")
    if not hrp or not hum then return end

    local bb, lbl = makeBillboard(hrp, model.Name, Color3.fromRGB(255, 80, 80), 100)

    local distLbl = Instance.new("TextLabel")
    distLbl.BackgroundTransparency = 1
    distLbl.Size       = UDim2.new(1, 0, 0.4, 0)
    distLbl.Position   = UDim2.new(0, 0, 1, 0)
    distLbl.TextColor3 = Color3.fromRGB(255, 200, 200)
    distLbl.TextStrokeTransparency = 0
    distLbl.TextScaled = true
    distLbl.Font       = Enum.Font.Gotham
    distLbl.Parent     = bb

    MobESPObjects[model] = { bb = bb, lbl = lbl, distLbl = distLbl }

    model.AncestryChanged:Connect(function()
        if not model:IsDescendantOf(game) then
            cleanESP(MobESPObjects, model)
        end
    end)
end

local function removeMobESP(model) cleanESP(MobESPObjects, model) end

-- PLAYER ESP
local function addPlayerESP(player)
    if PlayerESPObjects[player] or player == LP then return end
    local char = player.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local bb, lbl = makeBillboard(hrp, player.Name, Color3.fromRGB(100, 200, 255), 100)

    local distLbl = Instance.new("TextLabel")
    distLbl.BackgroundTransparency = 1
    distLbl.Size       = UDim2.new(1, 0, 0.4, 0)
    distLbl.Position   = UDim2.new(0, 0, 1, 0)
    distLbl.TextColor3 = Color3.fromRGB(180, 230, 255)
    distLbl.TextStrokeTransparency = 0
    distLbl.TextScaled = true
    distLbl.Font       = Enum.Font.Gotham
    distLbl.Parent     = bb

    PlayerESPObjects[player] = { bb = bb, lbl = lbl, distLbl = distLbl }

    player.CharacterRemoving:Connect(function()
        cleanESP(PlayerESPObjects, player)
    end)
end

local function removePlayerESP(player) cleanESP(PlayerESPObjects, player) end

-- LOOT ESP
local function addLootESP(obj)
    if LootESPObjects[obj] then return end

    local part = obj
    if obj:IsA("Model") then
        part = obj:FindFirstChild("Center") or obj:FindFirstChildWhichIsA("BasePart")
    end
    if not part or not part:IsA("BasePart") then return end

    local isEpic = obj:IsA("Model")
    local color  = isEpic and Color3.fromRGB(255, 215, 0) or Color3.fromRGB(220, 220, 220)

    local sel = Instance.new("SelectionBox")
    sel.Color3              = color
    sel.LineThickness       = 0.06
    sel.SurfaceTransparency = 0.7
    sel.SurfaceColor3       = color
    sel.Adornee             = part
    sel.Parent              = part

    local bb = makeBillboard(part, isEpic and "★ EPIC" or "Drop", color, 80)

    LootESPObjects[obj] = { sel = sel, bb = bb }

    obj.AncestryChanged:Connect(function()
        if not obj:IsDescendantOf(game) and LootESPObjects[obj] then
            pcall(function() LootESPObjects[obj].sel:Destroy() end)
            pcall(function() LootESPObjects[obj].bb:Destroy() end)
            LootESPObjects[obj] = nil
        end
    end)
end

local function removeLootESP(obj)
    if not LootESPObjects[obj] then return end
    pcall(function() LootESPObjects[obj].sel:Destroy() end)
    pcall(function() LootESPObjects[obj].bb:Destroy() end)
    LootESPObjects[obj] = nil
end

-- CHAMS
local ChamsObjects = {}

local function addChams(model)
    if ChamsObjects[model] then return end
    ChamsObjects[model] = {}
    for _, part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") and not EXCLUDED_PART_NAMES[part.Name] then
            local box = Instance.new("BoxHandleAdornment")
            box.AlwaysOnTop  = true
            box.ZIndex       = 5
            box.Color3       = Color3.fromRGB(255, 60, 60)
            box.Transparency = 0.5
            box.Size         = part.Size
            box.Adornee      = part
            box.Parent       = part
            table.insert(ChamsObjects[model], box)
        end
    end
    model.AncestryChanged:Connect(function()
        if not model:IsDescendantOf(game) and ChamsObjects[model] then
            for _, b in ipairs(ChamsObjects[model]) do
                pcall(function() b:Destroy() end)
            end
            ChamsObjects[model] = nil
        end
    end)
end

local function removeChams(model)
    if not ChamsObjects[model] then return end
    for _, b in ipairs(ChamsObjects[model]) do
        pcall(function() b:Destroy() end)
    end
    ChamsObjects[model] = nil
end

local function clearAllChams()
    for model in pairs(ChamsObjects) do removeChams(model) end
end

-- ─────────────────────────────────────────────
-- AUTO COLLECT
--
-- fireproximityprompt() at executor level bypasses RequiresLineOfSight
-- and MaxActivationDistance without any player movement.
--
-- PLAIN PART DROPS: Structure scan shows bare Part drops in Camera.Drops
-- have no ProximityPrompt at spawn time — the game adds it dynamically.
-- The DropFolder.ChildAdded handler below attaches a ChildAdded watcher
-- on plain Parts so the prompt is fired the moment it appears.
-- ─────────────────────────────────────────────
local function collectDrop(obj)
    local function fireAllPrompts(root)
        for _, desc in ipairs(root:GetDescendants()) do
            if desc:IsA("ProximityPrompt") then
                pcall(fireproximityprompt, desc)
            end
        end
    end

    if obj:IsA("Model") then
        -- Epic drop: Center.ProximityPrompt is the primary trigger
        local center = obj:FindFirstChild("Center")
        if center then
            local pp = center:FindFirstChildWhichIsA("ProximityPrompt")
            if pp then
                pcall(fireproximityprompt, pp)
                return
            end
        end
        fireAllPrompts(obj)
    elseif obj:IsA("BasePart") then
        local pp = obj:FindFirstChildWhichIsA("ProximityPrompt")
        if pp then
            pcall(fireproximityprompt, pp)
        end
    end
end

local function collectAllDrops()
    if not DropFolder then return end
    local drops = DropFolder:GetChildren()
    for i, obj in ipairs(drops) do
        pcall(collectDrop, obj)
        if i < #drops then
            task.wait(randRange(0.1, 0.2))
        end
    end
end

if DropFolder then
    DropFolder.ChildAdded:Connect(function(obj)
        if Flags.LootESP then addLootESP(obj) end

        if Flags.AutoCollect then
            if obj:IsA("BasePart") then
                -- Plain Part: ProximityPrompt may not exist yet — watch for it.
                local pp = obj:FindFirstChildWhichIsA("ProximityPrompt")
                if pp then
                    task.wait(randRange(0.4, 0.7))
                    pcall(fireproximityprompt, pp)
                else
                    -- Connect a one-shot ChildAdded to catch the delayed spawn
                    local conn
                    conn = obj.ChildAdded:Connect(function(child)
                        if child:IsA("ProximityPrompt") then
                            conn:Disconnect()
                            task.wait(randRange(0.1, 0.3))
                            pcall(fireproximityprompt, child)
                        end
                    end)
                end
            else
                task.wait(randRange(0.4, 0.7))
                pcall(collectDrop, obj)
            end
        end
    end)

    DropFolder.ChildRemoved:Connect(function(obj)
        removeLootESP(obj)
    end)
end

-- ─────────────────────────────────────────────
-- AUTO FARM
--
-- DEATH DETECTION — dual path:
--   Primary:   Humanoid.Died signal (fast, event-driven)
--   Secondary: IsDescendantOf(WS) polling in attack loop (reliable
--              fallback when mob is removed before signal fires)
--
-- PROGRESS CHECK:
--   If mob HP has not decreased within 2 seconds, mark unkillable
--   and move to next target.
--   FIX: hpAtCheckpoint now initialises to entry.hum.Health (not
--   MaxHealth). v3.0 used MaxHealth, which caused the check to
--   pass for any pre-damaged mob even with zero DPS dealt.
-- ─────────────────────────────────────────────
local farmThread  = nil
local augThread   = nil
local slotThread  = nil
local SkippedMobs = {}  -- models to skip this session (unkillable)

local function stopFarm()
    if farmThread then
        task.cancel(farmThread)
        farmThread = nil
    end
end

local function startFarm()
    stopFarm()
    farmThread = task.spawn(function()
        while Flags.AutoFarm do
            if not HRP or not Hum or Hum.Health <= 0 then
                task.wait(1)
                refreshCharacter()
                continue
            end

            local entry = getNearestMob(Config.FarmRadius)

            if not entry then
                task.wait(1)
                continue
            end

            if SkippedMobs[entry.model] then
                task.wait(0.5)
                continue
            end

            if not entry.model:IsDescendantOf(WS) or entry.hum.Health <= 0 then
                markDirty()
                continue
            end

            -- Mobile: teleport near mob with jitter
            if not Flags.FarmStationary then
                local offset = Vector3.new(randRange(-3, 3), 3, randRange(-3, 3))
                HRP.CFrame = CFrame.new(entry.hrp.Position + offset)
                task.wait(randRange(0.15, 0.35))
            end

            -- Death detection: primary (event-driven)
            local dead     = false
            local diedConn = entry.hum.Died:Connect(function()
                dead = true
            end)

            -- Attack loop with progress check
            local elapsed        = 0
            local maxTime        = 8
            local checkInterval  = 2
            -- FIX: was MaxHealth — caused pre-damaged mobs to bypass unkillable detection
            local hpAtCheckpoint = entry.hum.Health
            local nextCheck      = checkInterval

            while not dead and elapsed < maxTime do
                -- Death detection: secondary (mob removed from workspace)
                if not entry.model:IsDescendantOf(WS) then
                    dead = true
                    break
                end

                attackEntry(entry)

                local interval = randRange(0.20, 0.35)
                task.wait(interval)
                elapsed += interval

                -- Progress check: if HP hasn't dropped in checkInterval seconds, skip mob
                if elapsed >= nextCheck then
                    local currentHP = entry.hum.Health
                    if currentHP >= hpAtCheckpoint and not dead then
                        SkippedMobs[entry.model] = true
                        break
                    end
                    hpAtCheckpoint = currentHP
                    nextCheck      = elapsed + checkInterval
                end
            end

            diedConn:Disconnect()

            -- Post-kill collect
            if dead and Flags.AutoCollect then
                task.wait(randRange(0.2, 0.4))
                collectAllDrops()
            end

            task.wait(randRange(0.3, 0.6))
            markDirty()
        end
    end)
end

-- ─────────────────────────────────────────────
-- DUNGEON TELEPORTS
-- ─────────────────────────────────────────────
local function teleportToDungeon(name)
    if not MapFolder or not HRP then return end
    local dungeon   = MapFolder:FindFirstChild(name, true)
    local spawnPart = dungeon and dungeon:FindFirstChild("PlayerSpawnInDungeon", true)
    if spawnPart then
        HRP.CFrame = jitterCFrame(spawnPart.CFrame + Vector3.new(0, 5, 0))
    end
end

-- ─────────────────────────────────────────────
-- SLOT MACHINE
-- ─────────────────────────────────────────────
local function startSlotMachine()
    if slotThread then task.cancel(slotThread) end
    slotThread = task.spawn(function()
        while Flags.AutoSlotMachine do
            if Remotes.SpinSlotMachine then
                pcall(function() Remotes.SpinSlotMachine:FireServer() end)
            end
            task.wait(Config.SlotMachineDelay * randRange(0.8, 1.2))
            if Remotes.GiveSlotMachinePrize then
                pcall(function() Remotes.GiveSlotMachinePrize:FireServer() end)
            end
            task.wait(Config.SlotMachineDelay * randRange(0.8, 1.2))
        end
    end)
end

-- ─────────────────────────────────────────────
-- CHARACTER RESPAWN
-- ─────────────────────────────────────────────
LP.CharacterAdded:Connect(function()
    task.wait(0.5)
    refreshCharacter()
    if Hum then
        Hum.WalkSpeed  = Config.WalkSpeed
        Hum.JumpPower  = Config.JumpPower
        -- Write JumpHeight too — covers games where UseJumpPower = false
        pcall(function() Hum.JumpHeight = Config.JumpPower * 0.36 end)
    end
    SkippedMobs = {}
    markDirty()
    if Flags.AutoFarm then startFarm() end
end)

-- ─────────────────────────────────────────────
-- MASTER HEARTBEAT
--
-- Accumulators:
--   slowAcc — ESP labels, Stamina, Tracers at ~10 Hz
--   Every frame: NoClip (cached parts)
--
-- NOTE: Kill Aura is NO LONGER driven from Heartbeat.
-- It runs in its own persistent coroutine (auraThread) above.
-- GodMode HP-reset-every-frame has also been removed — the
-- namecall hook handles damage interception before health changes.
-- ─────────────────────────────────────────────
local slowAcc = 0

RunService.Heartbeat:Connect(function(dt)
    if not Char or not Hum or not HRP then return end

    slowAcc += dt

    -- ── Every frame ──

    if Flags.NoClip then
        for _, p in ipairs(NoClipParts) do
            if p and p.Parent then
                p.CanCollide = false
            end
        end
    end

    -- ── Slow throttle: ~10 Hz ──
    if slowAcc >= 0.1 then
        slowAcc = 0

        -- Infinite Stamina
        -- FIX: Structure scan shows NO Stamina IntValue/NumberValue on the character.
        -- Primary approach: SetAttribute (covers attribute-based stamina systems).
        -- Secondary: value-object scan (kept as cheap fallback; no-op if table empty).
        if Flags.InfiniteStamina then
            pcall(function() Char:SetAttribute("Stamina", 100) end)
            pcall(function() Char:SetAttribute("Energy", 100)  end)
            pcall(function() Char:SetAttribute("Dash", 100)    end)
            for _, v in ipairs(StaminaParts) do
                if v and v.Parent then v.Value = 100 end
            end
        end

        -- Mob ESP label updates
        if Flags.MobESP then
            for model, objs in pairs(MobESPObjects) do
                if model:IsDescendantOf(WS) then
                    local hrp = model:FindFirstChild("HumanoidRootPart")
                    local hum = model:FindFirstChildWhichIsA("Humanoid")
                    if hrp and hum then
                        local dist = math.floor(getDistance(HRP.Position, hrp.Position))
                        objs.distLbl.Text = dist .. " studs | HP: "
                            .. math.floor(hum.Health) .. "/" .. math.floor(hum.MaxHealth)
                        objs.bb.Enabled = dist <= Config.ESPMaxDist
                    end
                end
            end
        end

        -- Player ESP label updates
        if Flags.PlayerESP then
            for player, objs in pairs(PlayerESPObjects) do
                local pchar = player.Character
                local phrp  = pchar and pchar:FindFirstChild("HumanoidRootPart")
                if phrp then
                    local dist = math.floor(getDistance(HRP.Position, phrp.Position))
                    objs.distLbl.Text = dist .. " studs"
                    objs.bb.Enabled   = dist <= Config.ESPMaxDist
                end
            end
        end

        -- Tracers — pooled, no allocation per frame
        if Flags.Tracers then
            clearTracers()

            local cam    = WS.CurrentCamera
            local vp     = cam.ViewportSize
            local center = Vector2.new(vp.X / 2, vp.Y)
            local RED    = Color3.fromRGB(255, 80, 80)
            local BLUE   = Color3.fromRGB(100, 200, 255)

            for _, entry in ipairs(getMobs(Config.ESPMaxDist)) do
                local sp, onScreen = cam:WorldToViewportPoint(entry.hrp.Position)
                if onScreen then
                    drawTracer(center, Vector2.new(sp.X, sp.Y), RED)
                end
            end

            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LP then
                    local pchar = player.Character
                    local phrp  = pchar and pchar:FindFirstChild("HumanoidRootPart")
                    if phrp then
                        local d = getDistance(HRP.Position, phrp.Position)
                        if d <= Config.ESPMaxDist then
                            local sp, onScreen = cam:WorldToViewportPoint(phrp.Position)
                            if onScreen then
                                drawTracer(center, Vector2.new(sp.X, sp.Y), BLUE)
                            end
                        end
                    end
                end
            end
        else
            if activeTracerCount > 0 then clearTracers() end
        end
    end
end)

-- ─────────────────────────────────────────────
-- RAYFIELD LOAD
-- ─────────────────────────────────────────────
local RayfieldLoaded, Rayfield = pcall(function()
    return loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
end)

if not RayfieldLoaded or not Rayfield then
    warn("[ENI] Rayfield failed to load.")
    return
end

local Window = Rayfield:CreateWindow({
    Name             = "Solo Hunters  |  ENI Build",
    LoadingTitle     = "Solo Hunters",
    LoadingSubtitle  = "ENI Build v4.0 — Xeno",
    ConfigurationSaving = { Enabled = false },
    KeySystem        = false,
})

-- ═══════════════════════════════════════════════
-- TAB: COMBAT
-- Icon: "sword" — distinct per-tab icons replacing shared ID
-- ═══════════════════════════════════════════════
local CombatTab = Window:CreateTab("Combat", "sword")

CombatTab:CreateSection("Auto Farm")

CombatTab:CreateToggle({
    Name     = "Auto Farm",
    Default  = false,
    Callback = function(val)
        Flags.AutoFarm = val
        if val then startFarm() else stopFarm() end
    end,
})

CombatTab:CreateToggle({
    Name     = "Stationary Mode  (safe / no teleport)",
    Default  = true,
    Callback = function(val)
        Flags.FarmStationary = val
    end,
})

CombatTab:CreateSlider({
    Name         = "Farm Radius",
    Range        = {50, 2000},
    Increment    = 50,
    Suffix       = " studs",
    CurrentValue = 500,
    Flag         = "FarmRadius",
    Callback     = function(val)
        Config.FarmRadius = val
    end,
})

CombatTab:CreateButton({
    Name     = "Clear Skip List",
    Callback = function()
        SkippedMobs = {}
        Rayfield:Notify({ Title = "Farm", Content = "Skip list cleared.", Duration = 2 })
    end,
})

CombatTab:CreateSection("Kill Aura")

CombatTab:CreateToggle({
    Name     = "Kill Aura",
    Default  = false,
    Callback = function(val)
        Flags.KillAura = val
    end,
})

CombatTab:CreateSlider({
    Name         = "Kill Aura Radius",
    Range        = {10, 500},
    Increment    = 5,
    Suffix       = " studs",
    CurrentValue = 50,
    Flag         = "KillAuraRadius",
    Callback     = function(val)
        Config.KillAuraRadius = val
    end,
})

CombatTab:CreateButton({
    Name     = "Instant Kill Nearest Mob",
    Callback = function()
        local entry = getNearestMob(Config.FarmRadius)
        if entry then
            task.spawn(attackEntry, entry)
        end
    end,
})

CombatTab:CreateSection("Loot")

CombatTab:CreateToggle({
    Name     = "Auto Collect Drops",
    Default  = false,
    Callback = function(val)
        Flags.AutoCollect = val
        if val then task.spawn(collectAllDrops) end
    end,
})

CombatTab:CreateButton({
    Name     = "Collect All Now",
    Callback = function()
        task.spawn(collectAllDrops)
    end,
})

CombatTab:CreateSection("Boss")

CombatTab:CreateButton({
    Name     = "Fire Boss Altar Remote",
    Callback = function()
        if Remotes.BossAltarSpawnBoss then
            pcall(function() Remotes.BossAltarSpawnBoss:FireServer() end)
            Rayfield:Notify({ Title = "Boss Altar", Content = "BossAltarSpawnBoss fired.", Duration = 3 })
        else
            Rayfield:Notify({ Title = "Not Found", Content = "BossAltarSpawnBoss unavailable.", Duration = 3 })
        end
    end,
})

-- ═══════════════════════════════════════════════
-- TAB: PLAYER
-- ═══════════════════════════════════════════════
local PlayerTab = Window:CreateTab("Player", "user")

PlayerTab:CreateSection("Live Stats")

PlayerTab:CreateButton({
    Name     = "Refresh Currency Display",
    Callback = function()
        local c = getCurrencyValues()
        Rayfield:Notify({
            Title    = "Your Stats",
            Content  = string.format(
                "Power: %d | Gold: %d | Gems: %d\nSouls: %d | Raidium: %d",
                c.Power, c.Gold, c.Gems, c.Souls, c.Raidium
            ),
            Duration = 8,
        })
    end,
})

PlayerTab:CreateSection("Movement")

PlayerTab:CreateSlider({
    Name         = "Walk Speed",
    Range        = {16, 500},
    Increment    = 1,
    Suffix       = "",
    CurrentValue = 16,
    Flag         = "WalkSpeed",
    Callback     = function(val)
        Config.WalkSpeed = val
        if Hum then Hum.WalkSpeed = val end
    end,
})

PlayerTab:CreateSlider({
    Name         = "Jump Power",
    Range        = {7, 300},
    Increment    = 1,
    Suffix       = "",
    CurrentValue = 50,
    Flag         = "JumpPower",
    Callback     = function(val)
        Config.JumpPower = val
        if Hum then
            -- Write both properties; whichever the game's UseJumpPower flag
            -- selects will take effect. Avoids silent no-op on UseJumpPower=false.
            Hum.JumpPower = val
            pcall(function() Hum.JumpHeight = val * 0.36 end)
        end
    end,
})

PlayerTab:CreateToggle({
    Name     = "No Clip",
    Default  = false,
    Callback = function(val) Flags.NoClip = val end,
})

PlayerTab:CreateSection("Survival")

PlayerTab:CreateToggle({
    Name     = "God Mode",
    Default  = false,
    Callback = function(val) Flags.GodMode = val end,
})

PlayerTab:CreateToggle({
    Name     = "Infinite Stamina",
    Default  = false,
    Callback = function(val) Flags.InfiniteStamina = val end,
})

-- ═══════════════════════════════════════════════
-- TAB: TELEPORT
-- ═══════════════════════════════════════════════
local TeleportTab = Window:CreateTab("Teleport", "map")

TeleportTab:CreateSection("World")

TeleportTab:CreateButton({
    Name     = "Nearest Mob",
    Callback = function()
        local entry = getNearestMob(Config.FarmRadius)
        if entry and HRP then
            HRP.CFrame = jitterCFrame(CFrame.new(entry.hrp.Position + Vector3.new(0, 5, 0)))
        end
    end,
})

TeleportTab:CreateButton({
    Name     = "Quest Giver (Lobby)",
    Callback = function()
        if not HRP or not LobbyFolder then return end
        local qg   = LobbyFolder:FindFirstChild("QuestGiver")
        local base = qg and qg:FindFirstChildWhichIsA("BasePart")
        if base then HRP.CFrame = jitterCFrame(base.CFrame + Vector3.new(0, 5, 0)) end
    end,
})

TeleportTab:CreateButton({
    Name     = "Daily Quest Board (Lobby)",
    Callback = function()
        if not HRP or not LobbyFolder then return end
        local dq = LobbyFolder:FindFirstChild("Daily Quest")
        local qp = dq and dq:FindFirstChild("QuestsPart")
        if qp then HRP.CFrame = jitterCFrame(qp.CFrame + Vector3.new(0, 5, 0)) end
    end,
})

TeleportTab:CreateSection("Dungeons")

TeleportTab:CreateDropdown({
    Name     = "Teleport to Dungeon",
    Options  = {"WolfCave", "DoubleDungeon", "Subway", "Jungle"},
    Default  = "WolfCave",
    Callback = function(val) teleportToDungeon(val) end,
})

TeleportTab:CreateSection("Players")

-- FIX: Added dynamic "Teleport to Nearest Player" button as the reliable
-- alternative to the static dropdown. The dropdown is still present for
-- players who were online at load time; the button always works.
TeleportTab:CreateButton({
    Name     = "Teleport to Nearest Player",
    Callback = function()
        if not HRP then return end
        local nearest, nearestDist = nil, math.huge
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP and p.Character then
                local pHRP = p.Character:FindFirstChild("HumanoidRootPart")
                if pHRP then
                    local d = getDistance(HRP.Position, pHRP.Position)
                    if d < nearestDist then
                        nearest     = pHRP
                        nearestDist = d
                    end
                end
            end
        end
        if nearest then
            HRP.CFrame = jitterCFrame(nearest.CFrame + Vector3.new(0, 5, 0))
        else
            Rayfield:Notify({ Title = "Teleport", Content = "No other players found.", Duration = 3 })
        end
    end,
})

TeleportTab:CreateDropdown({
    Name    = "Teleport to Player (load-time list)",
    Options = (function()
        local names = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then names[#names + 1] = p.Name end
        end
        return #names > 0 and names or {"(nobody online)"}
    end)(),
    Default  = "...",
    Callback = function(val)
        local target = Players:FindFirstChild(val)
        if target and target.Character then
            local tHRP = target.Character:FindFirstChild("HumanoidRootPart")
            if tHRP and HRP then
                HRP.CFrame = jitterCFrame(tHRP.CFrame + Vector3.new(0, 5, 0))
            end
        end
    end,
})

TeleportTab:CreateSection("Waypoints")

TeleportTab:CreateButton({
    Name     = "Save Safe Spot",
    Callback = function()
        if HRP then
            SafeSpot = HRP.CFrame
            Rayfield:Notify({ Title = "Safe Spot", Content = "Position saved.", Duration = 2 })
        end
    end,
})

TeleportTab:CreateButton({
    Name     = "Return to Safe Spot",
    Callback = function()
        if SafeSpot and HRP then HRP.CFrame = SafeSpot end
    end,
})

TeleportTab:CreateButton({
    Name     = "Save Waypoint",
    Callback = function()
        if not HRP then return end
        local name = "WP" .. (#Waypoints + 1)
        Waypoints[#Waypoints + 1] = { name = name, cf = HRP.CFrame }
        Rayfield:Notify({ Title = "Waypoint", Content = name .. " saved.", Duration = 2 })
    end,
})

TeleportTab:CreateButton({
    Name     = "Go to Last Waypoint",
    Callback = function()
        if #Waypoints > 0 and HRP then
            HRP.CFrame = Waypoints[#Waypoints].cf
        end
    end,
})

-- ═══════════════════════════════════════════════
-- TAB: ESP
-- ═══════════════════════════════════════════════
local ESPTab = Window:CreateTab("ESP", "eye")

ESPTab:CreateToggle({
    Name     = "Mob ESP",
    Default  = false,
    Callback = function(val)
        Flags.MobESP = val
        if val then
            for _, entry in ipairs(getMobs()) do addMobESP(entry.model) end
            if MobFolder and not MobESPConnected then
                MobESPConnected = true
                MobFolder.ChildAdded:Connect(function(model)
                    if Flags.MobESP and model:IsA("Model") then
                        task.wait(0.1)
                        addMobESP(model)
                    end
                end)
            end
        else
            for model in pairs(MobESPObjects) do removeMobESP(model) end
        end
    end,
})

ESPTab:CreateToggle({
    Name     = "Player ESP",
    Default  = false,
    Callback = function(val)
        Flags.PlayerESP = val
        if val then
            for _, p in ipairs(Players:GetPlayers()) do addPlayerESP(p) end
            if not PlayerESPConnected then
                PlayerESPConnected = true
                Players.PlayerAdded:Connect(function(p)
                    if Flags.PlayerESP then
                        p.CharacterAdded:Connect(function()
                            task.wait(0.5)
                            addPlayerESP(p)
                        end)
                    end
                end)
                Players.PlayerRemoving:Connect(function(p)
                    removePlayerESP(p)
                end)
            end
        else
            for p in pairs(PlayerESPObjects) do removePlayerESP(p) end
        end
    end,
})

ESPTab:CreateToggle({
    Name     = "Loot ESP",
    Default  = false,
    Callback = function(val)
        Flags.LootESP = val
        if val then
            if DropFolder then
                for _, obj in ipairs(DropFolder:GetChildren()) do addLootESP(obj) end
            end
        else
            for obj in pairs(LootESPObjects) do removeLootESP(obj) end
        end
    end,
})

ESPTab:CreateToggle({
    Name     = "Chams",
    Default  = false,
    Callback = function(val)
        Flags.Chams = val
        if val then
            for _, entry in ipairs(getMobs()) do addChams(entry.model) end
        else
            clearAllChams()
        end
    end,
})

ESPTab:CreateToggle({
    Name     = "Tracers",
    Default  = false,
    Callback = function(val)
        Flags.Tracers = val
        if not val then clearTracers() end
    end,
})

ESPTab:CreateSlider({
    Name         = "Max ESP Distance",
    Range        = {50, 1000},
    Increment    = 10,
    Suffix       = " studs",
    CurrentValue = 300,
    Flag         = "ESPMaxDist",
    Callback     = function(val) Config.ESPMaxDist = val end,
})

-- ═══════════════════════════════════════════════
-- TAB: MISC
-- ═══════════════════════════════════════════════
local MiscTab = Window:CreateTab("Misc", "settings")

MiscTab:CreateSection("Remotes")

MiscTab:CreateToggle({
    Name     = "Auto Slot Machine",
    Default  = false,
    Callback = function(val)
        Flags.AutoSlotMachine = val
        if val then
            startSlotMachine()
        else
            if slotThread then task.cancel(slotThread) slotThread = nil end
        end
    end,
})

MiscTab:CreateSlider({
    Name         = "Slot Machine Delay",
    Range        = {1, 10},
    Increment    = 0.5,
    Suffix       = "s",
    CurrentValue = 2,
    Flag         = "SlotDelay",
    Callback     = function(val) Config.SlotMachineDelay = val end,
})

MiscTab:CreateToggle({
    Name     = "Auto Augment",
    Default  = false,
    Callback = function(val)
        Flags.AutoAugment = val
        -- Cancel previous thread before starting a new one —
        -- prevents parallel augment threads from rapid toggling.
        if augThread then task.cancel(augThread) augThread = nil end
        if val then
            augThread = task.spawn(function()
                while Flags.AutoAugment do
                    if Remotes.ChooseAugment then
                        pcall(function() Remotes.ChooseAugment:FireServer(1) end)
                    end
                    task.wait(randRange(0.8, 1.4))
                end
                augThread = nil
            end)
        end
    end,
})

MiscTab:CreateButton({
    Name     = "Start Challenge",
    Callback = function()
        if Remotes.StartChallenge then
            pcall(function() Remotes.StartChallenge:FireServer() end)
            Rayfield:Notify({ Title = "Challenge", Content = "StartChallenge fired.", Duration = 3 })
        end
    end,
})

MiscTab:CreateButton({
    Name     = "Full Dungeon Remote",
    Callback = function()
        if Remotes.FullDungeonRemote then
            pcall(function() Remotes.FullDungeonRemote:FireServer() end)
            Rayfield:Notify({ Title = "Dungeon", Content = "FullDungeonRemote fired.", Duration = 3 })
        end
    end,
})

MiscTab:CreateSection("Utility")

MiscTab:CreateButton({
    Name     = "FPS Unlocker",
    Callback = function()
        local fn = setfpscap
                or (getfenv and getfenv(0).setfpscap)
                or (syn and syn.setfpscap)
        if fn then
            pcall(fn, 0)
            Rayfield:Notify({ Title = "FPS Unlocker", Content = "FPS cap removed.", Duration = 3 })
        else
            Rayfield:Notify({ Title = "FPS Unlocker", Content = "setfpscap not available.", Duration = 4 })
        end
    end,
})

MiscTab:CreateButton({
    Name     = "Rejoin",
    Callback = function()
        -- Clean up Drawing pool before teleporting to avoid leaked objects
        destroyDrawingPool()
        TeleportService:Teleport(game.PlaceId, LP)
    end,
})

MiscTab:CreateKeybind({
    Name           = "Toggle UI",
    CurrentKeybind = "RightShift",
    HoldToInteract = false,
    Callback       = function() Rayfield:ToggleUI() end,
})

-- ─────────────────────────────────────────────
-- READY
-- ─────────────────────────────────────────────
Rayfield:Notify({
    Title    = "ENI Build v4.0",
    Content  = "Solo Hunters loaded. RightShift = toggle UI.",
    Duration = 5,
})
