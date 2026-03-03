--[[
    ╔══════════════════════════════════════════════════════════╗
    ║          SOLO HUNTERS — ENI BUILD  v3.0                  ║
    ║          Xeno Executor  |  Structure scan v2.0           ║
    ╚══════════════════════════════════════════════════════════╝

    CHANGELOG v3.0 — Full audit and rework
    ─────────────────────────────────────────────────────────
    KILL AURA — fixed and optimised:
      Root cause of "Kill Aura not working":
      v2.0 fired firetouchinterest in order (0 → 1), i.e. touch-
      begin then touch-end. Most RPG engines debounce by tracking
      each Part pair — once a pair is "touching" it will not fire
      another Touched event until the touch ends. Firing (0) then
      (1) in the same tick is treated as a single instantaneous
      contact and many games' debounce logic discards it entirely.

      Fix: fire touch-END (1) first to clear any stale debounce
      state on the pair, yield one task.wait(), then fire touch-
      BEGIN (0) to register the actual hit. This matches the real
      physics sequence a weapon swing produces.

      Additional fixes:
        - SlashHitbox parts (mob's own attack hitboxes) are now
          explicitly excluded. Firing touch events on these parts
          does not register player damage — it registers the mob's
          damage against the player. Only body parts (Head, HRP,
          torso, limbs) are targeted.
        - Per-mob BasePart lists are now cached the moment each mob
          enters the MobCache. GetDescendants() was being called on
          every mob every attack tick (5 Hz × N mobs). With a cache
          of 10 mobs and 8 parts each, that was 400 calls/s.
        - Kill Aura uses an independent step accumulator. The attack
          interval jitters between 0.20–0.35s. This range is within
          normal weapon swing cadence and produces no fixed-rate
          fingerprint in server telemetry.

    AUTO FARM — complete rework:
      - Death detection now uses dual-path: Humanoid.Died signal
        (fast path) AND IsDescendantOf(WS) polling (reliable path).
        v2.0 relied solely on Humanoid.Died which silently fails
        if the mob is removed server-side before the signal fires
        on the client, causing the farm loop to always hit the 8s
        timeout rather than moving on immediately after the kill.
      - Farm loop now validates that attackEntry is actually making
        progress: if mob HP does not decrease within 2s, the farm
        marks it as unkillable, skips it, and continues.
      - Dungeon mob tracking re-added (was fully regressed in v2.0).
        A dedicated ChildAdded listener on each dungeon mob folder
        is connected when MapFolder loads. Dungeon mobs are added
        to the shared cache without walking all Map descendants.

    AUTO COLLECT — redundancy fixed:
      collectDrop's inner tryPrompts() walked all descendants for
      ProximityPrompts then immediately called FindFirstChildWhich
      IsA on the same root. That was two separate scans of the same
      tree. Collapsed into a single GetDescendants() pass.

    MOB CACHE — dungeon mob regression fixed:
      v2.0 removed the Workspace.Map.* dungeon mob scan and did not
      replace it with any alternative. Kill Aura and Auto Farm both
      read from MobCache, so dungeon mobs were completely invisible
      to both systems. Reworked: MobFolder ChildAdded/Removed events
      handle open-world mobs. A separate DungeonMobFolder watcher
      connects to specific dungeon mob containers on map load.

    PART CACHE:
      Each mob entry now stores a pre-built AttackParts list (all
      BaseParts that are not SlashHitbox). attackEntry() reads this
      list directly. No GetDescendants() calls at attack time.

    AUDIT — additional bugs fixed:
      - AutoAugment thread was using a Flags.AutoAugment while-loop
        inside task.spawn with no guaranteed re-entry guard. If the
        toggle fired twice rapidly, two threads could run in parallel.
        Fixed: thread handle stored, previous thread cancelled before
        any new spawn.
      - NoClip cache was not invalidated when tools were added to or
        removed from the character mid-session. Added ChildAdded/
        ChildRemoved listeners on Char to rebuildCharCaches() on
        equipment changes.
      - tracerLine allocation still creating new Drawing objects every
        0.1s instead of reusing. Replaced with a fixed-size pool of
        Drawing.Line objects that are shown/hidden per frame.
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
-- ─────────────────────────────────────────────
local RemotesFolder = (function()
    local inner = RS:WaitForChild("ReplicatedStorage", 10)
    return inner and inner:WaitForChild("Remotes", 10)
end)()

local MobFolder  = WS:WaitForChild("Mobs", 10)
local DropFolder = (function()
    local cam = WS:WaitForChild("Camera", 10)
    return cam and cam:WaitForChild("Drops", 10)
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
end

-- ─────────────────────────────────────────────
-- LOCAL PLAYER
-- ─────────────────────────────────────────────
local LP = Players.LocalPlayer
local Char, Hum, HRP

-- Cached part lists — rebuilt on CharacterAdded and on equipment change
local NoClipParts  = {}
local StaminaParts = {}

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

local function refreshCharacter()
    Char = LP.Character or LP.CharacterAdded:Wait()
    Hum  = Char:WaitForChild("Humanoid", 5)
    HRP  = Char:WaitForChild("HumanoidRootPart", 5)
    rebuildCharCaches()

    -- Rebuild caches if the player equips or unequips a tool mid-session
    Char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then rebuildCharCaches() end
    end)
    Char.ChildRemoved:Connect(function(child)
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
-- This replaces the v2.0 approach of scanning no dungeon mobs at
-- all, and the v1.1 approach of walking all Map descendants on
-- every call to getMobs().
-- ─────────────────────────────────────────────
local MobCache   = {}
local CacheDirty = true

-- Names that identify mob attack hitboxes. Touch events fired
-- against these parts register damage FROM the mob TO the player,
-- not the other way around. Exclude them from kill aura targets.
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

-- Dungeon mob folder events: connect to each dungeon's Mobs folder
-- as they appear inside MapFolder.
if MapFolder then
    local function watchRegion(region)
        local dungeonMobs = region:FindFirstChild("Mobs")
        if dungeonMobs then
            dungeonMobs.ChildAdded:Connect(markDirty)
            dungeonMobs.ChildRemoved:Connect(markDirty)
        end
        -- Also watch for a Mobs folder that may not exist yet
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

-- Returns the mob list, rebuilding the cache only when dirty
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

local function getNearestMob(maxDist)
    if not HRP then return nil end
    local nearest, nearestDist = nil, math.huge
    for _, entry in ipairs(getMobs(maxDist)) do
        if entry.model:IsDescendantOf(WS) and entry.hum.Health > 0 then
            local d = getDistance(HRP.Position, entry.hrp.Position)
            if d < nearestDist then
                nearest     = entry
                nearestDist = d
            end
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
--   eventType 0 = TouchBegan (contact start)
--   eventType 1 = TouchEnded (contact end)
--
-- CORRECT SEQUENCE (fixed from v2.0):
--   1. Fire (1) first — end any stale touch state on this pair.
--      If the engine believes these parts are already touching from
--      a previous call, this resets that state so the next TouchBegan
--      is treated as a fresh contact, not a duplicate.
--   2. task.wait() — yield one engine step so the ended event is
--      processed before the next begin.
--   3. Fire (0) — register the new contact hit.
--
-- TARGETS:
--   attackParts is pre-cached at mob spawn time and excludes
--   SlashHitbox parts (mob weapon hitboxes). Only body parts are
--   targeted so the hit registers as player-to-mob damage.
--
-- RATE:
--   Fires at 0.20–0.35s intervals (jittered). This is within normal
--   weapon swing cadence for an action RPG and does not produce a
--   fixed-frequency pattern in server-side event logs.
-- ─────────────────────────────────────────────
local function attackEntry(entry)
    if not entry.model:IsDescendantOf(WS) then return end
    if entry.hum.Health <= 0 then return end

    local hitbox = getWeaponHandle()
    if not hitbox then return end

    -- Step 1: reset debounce — end any stale touch state
    for _, part in ipairs(entry.attackParts) do
        if part and part.Parent then
            pcall(firetouchinterest, hitbox, part, 1)
        end
    end

    -- Step 2: yield one engine step so the ended event processes
    task.wait()

    -- Validate the mob is still alive after the yield
    if not entry.model:IsDescendantOf(WS) or entry.hum.Health <= 0 then
        return
    end

    -- Step 3: fire the actual contact hit
    for _, part in ipairs(entry.attackParts) do
        if part and part.Parent then
            pcall(firetouchinterest, hitbox, part, 0)
        end
    end

    -- Secondary: TakeDamage — effective in games that allow client-
    -- authoritative damage calls for certain damage sources. This is
    -- the fallback if the game's touch detection ignores executor
    -- touch events.
    pcall(function() entry.hum:TakeDamage(entry.hum.MaxHealth) end)
end

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
-- ─────────────────────────────────────────────
local function getCurrencyValues()
    local ps  = LP:FindFirstChild("PlayerScripts")
    local sps = ps and ps:FindFirstChild("StarterPlayerScripts")
    local mui = sps and sps:FindFirstChild("MainUIController")
    local ls  = LP:FindFirstChild("leaderstats")
    local function val(parent, name)
        local v = parent and parent:FindFirstChild(name)
        return v and v.Value or 0
    end
    return {
        Power   = val(ls,  "Power"),
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
-- new Drawing objects every 0.1s.
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
    line.From    = from
    line.To      = to
    line.Color   = color
    line.Visible = true
end

-- Single-bind guards
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
-- AUTO COLLECT — no teleportation
--
-- fireproximityprompt() at executor level bypasses the game's
-- RequiresLineOfSight and MaxActivationDistance checks without
-- any player movement. Moving HRP to the drop was the primary
-- cause of AC-triggered disconnects in earlier builds.
--
-- v3.0 fix: removed duplicate scan. Previously tryPrompts()
-- walked all descendants AND then immediately also called
-- FindFirstChildWhichIsA on the same root — two passes over
-- the same tree. Collapsed into a single GetDescendants() pass.
-- ─────────────────────────────────────────────
local function collectDrop(obj)
    -- Single unified ProximityPrompt scan — no duplicate traversals
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
        -- Fallback: scan all descendants in the model
        fireAllPrompts(obj)
    elseif obj:IsA("BasePart") then
        -- Plain drop: scan the part and its descendants
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
            task.wait(randRange(0.4, 0.7))
            pcall(collectDrop, obj)
        end
    end)
    DropFolder.ChildRemoved:Connect(function(obj)
        removeLootESP(obj)
    end)
end

-- ─────────────────────────────────────────────
-- AUTO FARM — complete rework
--
-- DEATH DETECTION — dual path:
--   Primary:   Humanoid.Died signal (fast, event-driven)
--   Secondary: IsDescendantOf(WS) polling every 0.1s (reliable
--              fallback when the mob is removed server-side before
--              the Died signal fires on the client)
--   Both paths set a shared `dead` flag. The attack loop exits
--   as soon as either path fires.
--
-- PROGRESS CHECK:
--   If mob HP has not decreased within 2 seconds of attacking,
--   the mob is marked unkillable for this session (stored in a
--   skip set) and the farm moves to the next target. This prevents
--   the farm from locking onto a mob that firetouchinterest cannot
--   damage (e.g. a scripted boss in a special state).
--
-- STATIONARY MODE (Flags.FarmStationary = true, default):
--   Player does not move. Kill Aura handles all mobs in FarmRadius.
--   Farm loop only tracks targets and dispatches post-kill collect.
--   No CFrame writes.
--
-- MOBILE MODE (Flags.FarmStationary = false):
--   Teleports near mob with ±3 stud random offset and a random
--   pre-attack delay (0.15–0.35s). Kills via attackEntry.
-- ─────────────────────────────────────────────
local farmThread = nil
local augThread  = nil
local SkippedMobs = {}  -- set of models to skip (unkillable this session)

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
            -- Validate character
            if not HRP or not Hum or Hum.Health <= 0 then
                task.wait(1)
                refreshCharacter()
                continue
            end

            local entry = getNearestMob(Config.FarmRadius)

            -- No mobs in range
            if not entry then
                task.wait(1)
                continue
            end

            -- Skip mobs that proved unkillable this session
            if SkippedMobs[entry.model] then
                task.wait(0.5)
                continue
            end

            -- Validate entry is still alive before engaging
            if not entry.model:IsDescendantOf(WS) or entry.hum.Health <= 0 then
                markDirty()
                continue
            end

            -- ── MOBILE: teleport near mob with jitter ──
            if not Flags.FarmStationary then
                local offset = Vector3.new(
                    randRange(-3, 3), 3, randRange(-3, 3)
                )
                HRP.CFrame = CFrame.new(entry.hrp.Position + offset)
                task.wait(randRange(0.15, 0.35))
            end

            -- ── DEATH DETECTION: dual-path ──
            local dead    = false
            local diedConn = entry.hum.Died:Connect(function()
                dead = true
            end)

            -- ── ATTACK LOOP with progress check ──
            local elapsed        = 0
            local maxTime        = 8
            local checkInterval  = 2
            local hpAtCheckpoint = entry.hum.MaxHealth
            local nextCheck      = checkInterval

            while not dead and elapsed < maxTime do
                -- Secondary death check: mob removed from workspace
                if not entry.model:IsDescendantOf(WS) then
                    dead = true
                    break
                end

                -- Attack
                attackEntry(entry)

                -- Randomized interval: 0.20–0.35s
                local interval = randRange(0.20, 0.35)
                task.wait(interval)
                elapsed += interval

                -- Progress check every 2s: if HP hasn't moved, skip
                if elapsed >= nextCheck then
                    local currentHP = entry.hum.Health
                    if currentHP >= hpAtCheckpoint and not dead then
                        -- No progress — mark unkillable and bail
                        SkippedMobs[entry.model] = true
                        break
                    end
                    hpAtCheckpoint = currentHP
                    nextCheck      = elapsed + checkInterval
                end
            end

            diedConn:Disconnect()

            -- ── POST-KILL ──
            if dead and Flags.AutoCollect then
                task.wait(randRange(0.2, 0.4))
                collectAllDrops()
            end

            -- Cooldown between targets: 0.3–0.6s
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
local slotThread = nil

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
        Hum.WalkSpeed = Config.WalkSpeed
        Hum.JumpPower = Config.JumpPower
    end
    SkippedMobs = {}   -- clear the skip set on respawn
    markDirty()
    if Flags.AutoFarm then startFarm() end
end)

-- ─────────────────────────────────────────────
-- MASTER HEARTBEAT
--
-- Accumulators:
--   auraAcc — Kill Aura at jittered ~3–5 Hz
--   slowAcc — ESP labels, Stamina, Tracers at ~10 Hz
--   Every frame: GodMode HP reset, NoClip (cached parts)
-- ─────────────────────────────────────────────
local auraAcc      = 0
local slowAcc      = 0
local auraInterval = 0.25  -- reset with jitter each cycle

RunService.Heartbeat:Connect(function(dt)
    if not Char or not Hum or not HRP then return end

    auraAcc += dt
    slowAcc += dt

    -- ── Every frame ──

    if Flags.GodMode and Hum.Health < Hum.MaxHealth then
        Hum.Health = Hum.MaxHealth
    end

    if Flags.NoClip then
        for _, p in ipairs(NoClipParts) do
            if p and p.Parent then
                p.CanCollide = false
            end
        end
    end

    -- ── Kill Aura at jittered ~3–5 Hz ──
    -- NOTE: attackEntry() now contains a task.wait() internally
    -- so it cannot run directly from Heartbeat. We spawn it.
    if auraAcc >= auraInterval then
        auraAcc    = 0
        auraInterval = randRange(0.20, 0.35)

        if Flags.KillAura then
            local targets = getMobs(Config.KillAuraRadius)
            if #targets > 0 then
                task.spawn(function()
                    for _, entry in ipairs(targets) do
                        attackEntry(entry)
                    end
                end)
            end
        end
    end

    -- ── Slow throttle: ~10 Hz ──
    if slowAcc >= 0.1 then
        slowAcc = 0

        -- Infinite Stamina
        if Flags.InfiniteStamina then
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
            -- Ensure pool is hidden when Tracers is off
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
    LoadingSubtitle  = "ENI Build v3.0 — Xeno",
    ConfigurationSaving = { Enabled = false },
    KeySystem        = false,
})

-- ═══════════════════════════════════════════════
-- TAB: COMBAT
-- ═══════════════════════════════════════════════
local CombatTab = Window:CreateTab("Combat", 4483362458)

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
local PlayerTab = Window:CreateTab("Player", 4483362458)

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
        if Hum then Hum.JumpPower = val end
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
local TeleportTab = Window:CreateTab("Teleport", 4483362458)

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

TeleportTab:CreateDropdown({
    Name    = "Teleport to Player",
    Options = (function()
        local names = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then names[#names + 1] = p.Name end
        end
        return #names > 0 and names or {"(nobody)"}
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
local ESPTab = Window:CreateTab("ESP", 4483362458)

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
local MiscTab = Window:CreateTab("Misc", 4483362458)

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
        -- Always cancel the previous thread before starting a new one.
        -- v2.0 had a re-entry bug where rapid toggle could spawn two
        -- parallel augment threads.
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
    Title    = "ENI Build v3.0",
    Content  = "Solo Hunters loaded. RightShift = toggle UI.",
    Duration = 5,
})
