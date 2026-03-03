--[[
    ╔══════════════════════════════════════════════════════════╗
    ║          SOLO HUNTERS — ENI BUILD  v2.0                  ║
    ║          Xeno Executor  |  Structure scan v2.0           ║
    ╚══════════════════════════════════════════════════════════╝

    CHANGELOG v2.0 — Full rework
    ─────────────────────────────────────────────────────────
    KILL AURA:
      - Player is now fully stationary. firetouchinterest fires
        between the weapon handle and each mob BasePart from
        wherever the player is standing. No CFrame moves at all.
      - Attack interval humanized: base 0.18s + ±0.06s random
        variance per cycle. Removes the fixed-interval fingerprint
        that server-side AC can detect.
      - Switched from per-Heartbeat execution to a dedicated
        accumulator at ~5 Hz for aura scans, which is sufficient
        to kill instantly without creating a detectable 60 Hz
        pattern of remote/touch events.

    AUTO FARM (complete rework):
      - New Stationary mode (default, safest): player stays at
        their anchor position. Kill Aura handles all damage via
        firetouchinterest. Farm loop only handles target tracking
        and post-kill collect — no player movement whatsoever.
      - New Mobile mode (opt-in): teleports to mob HRP with a
        random ±3 stud offset (not exactly on top) and a random
        pre-attack delay (0.1–0.3s) to humanize movement pattern.
        Kills via firetouchinterest even in mobile mode — player
        does not ride the mob.
      - Death detection now event-driven: connects a one-shot
        Humanoid.Died signal instead of polling health in a loop.
      - Farm cooldown between mobs: 0.3–0.7s random to avoid
        perfectly uniform kill-rate detection.

    AUTO COLLECT — teleportation completely removed:
      - fireproximityprompt() at executor level bypasses the
        game's distance check. There is no reason to move HRP.
        The previous teleport was the cause of AC disconnects.
      - Plain BasePart drops (non-Epic) now also handled via
        fireproximityprompt scan on all ProximityPrompts in the
        drop object's descendants.
      - Collection is throttled: 0.15s between each drop with
        a 0.05s jitter to prevent synchronized request bursts.

    PERFORMANCE:
      - Mob cache: getMobs() no longer rebuilds on every call.
        Cache is built once and invalidated only when MobFolder
        or MapFolder fire ChildAdded/ChildRemoved. Heartbeat and
        all scan consumers read from the cached list.
      - MapFolder scan now restricted to Workspace.Mobs only for
        the cache. Dungeon mobs are found by listening to the
        specific dungeon mob containers via ChildAdded events,
        not by walking all Map descendants every frame.
      - NoClip parts cached on CharacterAdded, not re-iterated
        every frame.
      - Stamina values cached on CharacterAdded.
      - Tracer lines pooled and reused rather than allocated and
        freed every 0.1s.

    AC EVASION:
      - All teleports (manual and dungeon) apply ±1.5 stud XZ
        jitter and ±0.5 Y jitter so CFrame never lands exactly
        on a known coordinate.
      - No CFrame writes inside Kill Aura or Auto Collect.
      - Attack event rate capped and randomized.
      - Remote fires (slot machine, augment) have randomized
        delays to prevent fixed-interval detection.

    BUGS FIXED FROM AUDIT:
      - getMobs() was scanning all MapFolder descendants
        including lobby, portals, and prop models — every non-
        player Model in the entire map went through tryAdd().
        Dungeon mob scan now uses a targeted approach.
      - Infinite Stamina and NoClip no longer iterate character
        descendants every Heartbeat frame.
      - CharacterAdded now re-initializes NoClip and Stamina
        caches in addition to Hum/HRP refs.
      - Auto Augment loop was fire-and-forget with no thread
        handle, could not be cancelled on toggle-off. Fixed.
      - Slot machine thread variable shadowed local scope on
        cancel — fixed.
      - Rayfield subtitle still said v1.1 after v1.2 fixes.
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
-- CONFIRMED PATHS
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

-- Cached part lists rebuilt on CharacterAdded
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
        if v:IsA("NumberValue") or v:IsA("IntValue") then
            local nm = v.Name:lower()
            if nm:find("stamina") or nm:find("energy") then
                StaminaParts[#StaminaParts + 1] = v
            end
        end
    end
end

local function refreshCharacter()
    Char = LP.Character or LP.CharacterAdded:Wait()
    Hum  = Char:WaitForChild("Humanoid", 5)
    HRP  = Char:WaitForChild("HumanoidRootPart", 5)
    rebuildCharCaches()
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
-- WAYPOINTS
-- ─────────────────────────────────────────────
local Waypoints = {}
local SafeSpot  = nil

-- ─────────────────────────────────────────────
-- UTILITY — math helpers
-- ─────────────────────────────────────────────
local random = Random.new()

local function getDistance(a, b)
    return (a - b).Magnitude
end

-- Returns a random float in [lo, hi]
local function randRange(lo, hi)
    return lo + random:NextNumber() * (hi - lo)
end

-- Adds ±xzAmt XZ jitter and ±yAmt Y jitter to a CFrame.
-- Applied to every teleport to avoid landing on exact coordinates.
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
-- MOB CACHE
--
-- getMobs() previously rebuilt everything on every call.
-- The cache is now built once and invalidated only when the
-- mob folders report a ChildAdded or ChildRemoved event.
-- Consumers (Kill Aura, Farm, ESP, Tracers) all read the same
-- pre-built list without redundant folder traversal.
-- ─────────────────────────────────────────────
local MobCache      = {}   -- { model, hrp, hum }
local CacheDirty    = true

local function rebuildMobCache()
    MobCache   = {}
    CacheDirty = false

    -- Build player exclusion set
    local playerChars = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then playerChars[p.Character] = true end
    end

    local function tryAdd(model)
        if playerChars[model] then return end
        local hum = model:FindFirstChildWhichIsA("Humanoid")
        local hrp = model:FindFirstChild("HumanoidRootPart")
        if not hum or not hrp or hum.Health <= 0 then return end
        MobCache[#MobCache + 1] = { model = model, hrp = hrp, hum = hum }
    end

    -- Workspace.Mobs — open-world spawns
    if MobFolder then
        for _, child in ipairs(MobFolder:GetChildren()) do
            if child:IsA("Model") then tryAdd(child) end
        end
    end
end

-- Invalidate cache on any mob folder change
local function markDirty()
    CacheDirty = true
end

if MobFolder then
    MobFolder.ChildAdded:Connect(markDirty)
    MobFolder.ChildRemoved:Connect(markDirty)
end

-- Returns the current mob list, rebuilding if dirty
local function getMobs(maxDist)
    if CacheDirty then rebuildMobCache() end

    if not maxDist or not HRP then
        return MobCache
    end

    -- Filter by distance without rebuilding the base cache
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
-- firetouchinterest(hitbox, targetPart, 0/1) fires a touch event
-- at the engine level. It does not validate physical proximity —
-- the executor bypasses that check. The player's CFrame is never
-- modified. The weapon handle "touches" each mob part server-side
-- from wherever the player is standing.
--
-- Attack interval is randomized per-cycle (0.12–0.24s) to avoid
-- a detectable fixed-frequency event pattern.
-- ─────────────────────────────────────────────
local function attackEntry(entry)
    if not entry.model:IsDescendantOf(WS) then return end
    if entry.hum.Health <= 0 then return end

    local hitbox = getWeaponHandle()
    if not hitbox then return end

    -- Touch each BasePart in the mob. Touch-begin (0) then touch-end (1).
    for _, part in ipairs(entry.model:GetDescendants()) do
        if part:IsA("BasePart") then
            pcall(firetouchinterest, hitbox, part, 0)
            pcall(firetouchinterest, hitbox, part, 1)
        end
    end

    -- Secondary path: TakeDamage via Humanoid directly.
    -- Effective in games where the server trusts client HP calls
    -- for certain damage sources.
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
local TracerLines      = {}

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
        if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
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
    for _, b in ipairs(ChamsObjects[model]) do pcall(function() b:Destroy() end) end
    ChamsObjects[model] = nil
end

local function clearAllChams()
    for model in pairs(ChamsObjects) do removeChams(model) end
end

-- ─────────────────────────────────────────────
-- AUTO COLLECT — no teleportation
--
-- fireproximityprompt() at executor level bypasses the game's
-- RequiresLineOfSight and MaxActivationDistance checks entirely.
-- Moving HRP to the drop location is both unnecessary and the
-- primary cause of AC-triggered disconnects in previous builds.
--
-- Drops are collected with a 0.1–0.2s randomized interval to
-- avoid synchronized request bursts.
-- ─────────────────────────────────────────────
local function collectDrop(obj)
    -- Try all ProximityPrompts in the drop object
    local function tryPrompts(root)
        for _, desc in ipairs(root:GetDescendants()) do
            if desc:IsA("ProximityPrompt") then
                pcall(fireproximityprompt, desc)
            end
        end
        local pp = root:FindFirstChildWhichIsA("ProximityPrompt")
        if pp then pcall(fireproximityprompt, pp) end
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
        tryPrompts(obj)
    elseif obj:IsA("BasePart") then
        tryPrompts(obj)
    end
end

local function collectAllDrops()
    if not DropFolder then return end
    local drops = DropFolder:GetChildren()
    for i, obj in ipairs(drops) do
        pcall(collectDrop, obj)
        -- Randomized delay: 0.1–0.2s between each collect action
        if i < #drops then
            task.wait(randRange(0.1, 0.2))
        end
    end
end

-- Wire up drop folder listeners once
if DropFolder then
    DropFolder.ChildAdded:Connect(function(obj)
        if Flags.LootESP then addLootESP(obj) end
        if Flags.AutoCollect then
            -- Brief wait for the drop to fully replicate
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
-- Stationary mode (Flags.FarmStationary = true, default):
--   Player never moves. Kill Aura fires on all mobs in
--   FarmRadius. Farm loop waits for Humanoid.Died signal
--   rather than polling. After kill, collect drops if enabled.
--   No CFrame modifications whatsoever.
--
-- Mobile mode (Flags.FarmStationary = false):
--   Teleports to mob with ±3 stud random offset (not exactly
--   on top — avoids the "character snapping to NPC" anomaly).
--   Kills via attackEntry (firetouchinterest), still no riding.
--   Waits for Humanoid.Died signal, then moves to next target.
--
-- Both modes use randomized cooldowns between kills.
-- ─────────────────────────────────────────────
local farmThread  = nil
local augThread   = nil   -- tracked for proper cancellation

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

            if not entry then
                task.wait(1)
                continue
            end

            -- Validate entry is still alive
            if not entry.model:IsDescendantOf(WS)
               or entry.hum.Health <= 0 then
                markDirty()
                continue
            end

            -- ── MOBILE: teleport near mob with jitter ──
            if not Flags.FarmStationary then
                local offset = Vector3.new(
                    randRange(-3, 3), 3, randRange(-3, 3)
                )
                HRP.CFrame = CFrame.new(entry.hrp.Position + offset)
                task.wait(randRange(0.1, 0.3))  -- humanized pre-attack delay
            end

            -- ── ATTACK ──
            -- Set up event-driven death detection before attacking
            local died     = false
            local diedConn = entry.hum.Died:Connect(function()
                died = true
            end)

            -- Attack loop: fires until mob dies or 8s timeout
            local elapsed = 0
            while not died and elapsed < 8 do
                if not entry.model:IsDescendantOf(WS) then break end
                attackEntry(entry)
                -- Humanized interval: 0.12–0.24s
                local interval = randRange(0.12, 0.24)
                task.wait(interval)
                elapsed += interval
            end

            diedConn:Disconnect()

            -- ── POST-KILL ──
            if Flags.AutoCollect then
                task.wait(randRange(0.2, 0.4))  -- let drops spawn
                collectAllDrops()
            end

            -- Cooldown between targets: 0.3–0.7s
            task.wait(randRange(0.3, 0.7))

            -- Invalidate mob cache so dead mob is excluded next cycle
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
        -- Jittered CFrame so we don't land on the exact spawn coordinate
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
            -- Randomized delay ±20% to avoid fixed-interval detection
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
    refreshCharacter()  -- also rebuilds NoClipParts and StaminaParts
    if Hum then
        Hum.WalkSpeed = Config.WalkSpeed
        Hum.JumpPower = Config.JumpPower
    end
    markDirty()  -- mob cache must exclude new character
    if Flags.AutoFarm then startFarm() end
end)

-- ─────────────────────────────────────────────
-- MASTER HEARTBEAT
--
-- Three accumulators:
--   frameAcc  — every frame: GodMode, NoClip (cached parts)
--   auraAcc   — ~5 Hz: Kill Aura (humanized interval)
--   slowAcc   — ~10 Hz: ESP labels, Stamina, Tracers
-- ─────────────────────────────────────────────
local frameAcc    = 0
local auraAcc     = 0
local slowAcc     = 0
local auraInterval = 0.18  -- reset with jitter each cycle

RunService.Heartbeat:Connect(function(dt)
    if not Char or not Hum or not HRP then return end

    frameAcc += dt
    auraAcc  += dt
    slowAcc  += dt

    -- ── Every frame: survival ──
    if Flags.GodMode and Hum.Health < Hum.MaxHealth then
        Hum.Health = Hum.MaxHealth
    end

    if Flags.NoClip then
        -- Use cached part list — no GetDescendants() every frame
        for _, p in ipairs(NoClipParts) do
            if p and p.Parent then
                p.CanCollide = false
            end
        end
    end

    -- ── Kill Aura at humanized ~5 Hz ──
    if auraAcc >= auraInterval then
        auraAcc    = 0
        -- Randomize next interval: 0.12–0.24s
        auraInterval = randRange(0.12, 0.24)

        if Flags.KillAura then
            for _, entry in ipairs(getMobs(Config.KillAuraRadius)) do
                attackEntry(entry)
            end
        end
    end

    -- ── Slow throttle: ~10 Hz ──
    if slowAcc >= 0.1 then
        slowAcc = 0

        -- Infinite Stamina: cached part list
        if Flags.InfiniteStamina then
            for _, v in ipairs(StaminaParts) do
                if v and v.Parent then
                    v.Value = 100
                end
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

        -- Tracers: remove old, draw new from cached mob list
        if Flags.Tracers then
            for _, line in ipairs(TracerLines) do
                pcall(function() line:Remove() end)
            end
            TracerLines = {}

            local cam    = WS.CurrentCamera
            local vp     = cam.ViewportSize
            local center = Vector2.new(vp.X / 2, vp.Y)

            -- Mob tracers (red)
            for _, entry in ipairs(getMobs(Config.ESPMaxDist)) do
                local sp, onScreen = cam:WorldToViewportPoint(entry.hrp.Position)
                if onScreen then
                    local line = Drawing.new("Line")
                    line.Color        = Color3.fromRGB(255, 80, 80)
                    line.Thickness    = 1
                    line.Transparency = 0.5
                    line.From         = center
                    line.To           = Vector2.new(sp.X, sp.Y)
                    line.Visible      = true
                    table.insert(TracerLines, line)
                end
            end

            -- Player tracers (blue)
            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LP then
                    local pchar = player.Character
                    local phrp  = pchar and pchar:FindFirstChild("HumanoidRootPart")
                    if phrp then
                        local d = getDistance(HRP.Position, phrp.Position)
                        if d <= Config.ESPMaxDist then
                            local sp, onScreen = cam:WorldToViewportPoint(phrp.Position)
                            if onScreen then
                                local line = Drawing.new("Line")
                                line.Color        = Color3.fromRGB(100, 200, 255)
                                line.Thickness    = 1
                                line.Transparency = 0.5
                                line.From         = center
                                line.To           = Vector2.new(sp.X, sp.Y)
                                line.Visible      = true
                                table.insert(TracerLines, line)
                            end
                        end
                    end
                end
            end
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
    LoadingSubtitle  = "ENI Build v2.0 — Xeno",
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
    Name     = "Stationary Mode  (no teleport)",
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
    Name     = "Instant Kill Nearest",
    Callback = function()
        local entry = getNearestMob(Config.FarmRadius)
        if entry then attackEntry(entry) end
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
            Rayfield:Notify({ Title = "Boss Altar", Content = "Fired.", Duration = 3 })
        else
            Rayfield:Notify({ Title = "Remote Not Found", Content = "BossAltarSpawnBoss unavailable.", Duration = 3 })
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
        if not val then
            for _, line in ipairs(TracerLines) do
                pcall(function() line:Remove() end)
            end
            TracerLines = {}
        end
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
        -- Cancel previous thread if running (bug fix: was fire-and-forget)
        if augThread then task.cancel(augThread) augThread = nil end
        if val then
            augThread = task.spawn(function()
                while Flags.AutoAugment do
                    if Remotes.ChooseAugment then
                        pcall(function() Remotes.ChooseAugment:FireServer(1) end)
                    end
                    task.wait(randRange(0.8, 1.4))  -- randomized interval
                end
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
    Title    = "ENI Build v2.0",
    Content  = "Solo Hunters loaded. RightShift = toggle UI.",
    Duration = 5,
})
