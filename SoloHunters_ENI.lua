--[[
    ╔══════════════════════════════════════════════════════════╗
    ║          SOLO HUNTERS — ENI BUILD                        ║
    ║          Built for Xeno Executor                         ║
    ║          Structure-accurate as of scan v2.0              ║
    ╚══════════════════════════════════════════════════════════╝

    CHANGELOG:
    [v1.0] - Initial release
    [v1.2] - Bug fixes
      FIX: All CreateSlider calls used the unrecognized key "Default".
           Rayfield's correct parameter is "CurrentValue". The unknown
           key caused Rayfield to fire each slider callback with the
           range minimum on load, corrupting Config values before the
           user touched anything. In some Rayfield builds an unknown
           key also causes a silent error mid-tab, halting rendering of
           all subsequent elements — this is why Kill Aura disappeared
           from the GUI (it lives after the first broken slider).
           Fix: "Default" → "CurrentValue" on all six sliders, with
           unique "Flag" identifiers added to each.
      FIX: Auto Farm was calling killAuraAttack() once then sitting in
           a passive wait loop for up to 5s. Single firetouchinterest
           calls rarely kill a mob; the mob could also move during the
           idle wait. Replaced with an active 0.15s attack loop that
           re-teleports onto the mob each tick and attacks continuously
           until health reaches 0 or an 8s timeout triggers.
      FIX: ConfigurationSaving disabled — stale config was loading
           a saved KillAuraRadius of 750 that exceeded the slider
           range, causing the callback to lock Config at 750 while
           the slider handle appeared frozen at max.
      FIX: Kill Aura rewritten to use firetouchinterest against all
           mob BaseParts. Setting Humanoid.Health = 0 client-side
           does not replicate for server-owned NPCs; the mob remained
           alive server-side despite appearing dead locally.
      FIX: getMobs() expanded to scan both Workspace.Mobs (open world)
           and Workspace.Map.* sub-hierarchies (dungeon mobs). Now
           accepts an optional maxDist proximity gate so Auto Farm
           only targets mobs within Config.FarmRadius studs,
           preventing cross-gate teleportation.
      FIX: Infinite Stamina operator precedence error corrected.
           Previous: (nameCheck and IsNumberValue) or IsIntValue
           caused every IntValue in the character (including health
           values) to be overwritten unconditionally.
      FIX: Tracer Drawing objects now properly .Remove()'d each cycle.
           Previous build set them invisible and abandoned them,
           allocating fresh objects every 0.1s with no cleanup.
      FIX: MobESP ChildAdded and PlayerESP PlayerAdded/Removing
           connections now guarded by single-bind flags. Toggling
           these features repeatedly previously stacked duplicate
           listeners on the same events.
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

local MobFolder = WS:WaitForChild("Mobs", 10)

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

local function refreshCharacter()
    Char = LP.Character or LP.CharacterAdded:Wait()
    Hum  = Char:WaitForChild("Humanoid", 5)
    HRP  = Char:WaitForChild("HumanoidRootPart", 5)
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
    FarmRadius       = 500,  -- proximity gate for Auto Farm mob selection
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
-- ESP TRACKING
-- ─────────────────────────────────────────────
local MobESPObjects    = {}
local PlayerESPObjects = {}
local LootESPObjects   = {}
local TracerLines      = {}

-- Single-bind guards (prevent duplicate event connections on toggle)
local MobESPConnected    = false
local PlayerESPConnected = false

-- ─────────────────────────────────────────────
-- UTILITY
-- ─────────────────────────────────────────────
local function getDistance(a, b)
    return (a - b).Magnitude
end

--[[
    getMobs([maxDist])

    Returns all living NPC mob models found in:
      1. Workspace.Mobs           — open-world spawns
      2. Workspace.Map.*          — dungeon mobs in all sub-hierarchies

    Player characters are always excluded from results.

    maxDist (optional): if provided, only mobs within that many studs
    of HRP are included. This is the "gate lock" mechanism used by
    Auto Farm to prevent targeting mobs outside the current area.
--]]
local function getMobs(maxDist)
    local list = {}

    -- Build player character exclusion set
    local playerChars = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then playerChars[p.Character] = true end
    end

    local function tryAdd(model)
        if playerChars[model] then return end
        local hum = model:FindFirstChildWhichIsA("Humanoid")
        local hrp = model:FindFirstChild("HumanoidRootPart")
        if not hum or not hrp or hum.Health <= 0 then return end
        if maxDist and HRP then
            if getDistance(HRP.Position, hrp.Position) > maxDist then return end
        end
        list[#list + 1] = { model = model, hrp = hrp, hum = hum }
    end

    -- Source 1: Workspace.Mobs (open-world)
    if MobFolder then
        for _, child in ipairs(MobFolder:GetChildren()) do
            if child:IsA("Model") then tryAdd(child) end
        end
    end

    -- Source 2: Workspace.Map.* (dungeons)
    -- Dungeon mobs live deep inside map region hierarchies.
    -- Walking all descendants of each Map child is the only reliable
    -- way to find them without hardcoding per-dungeon paths.
    if MapFolder then
        for _, region in ipairs(MapFolder:GetChildren()) do
            for _, desc in ipairs(region:GetDescendants()) do
                if desc:IsA("Model") then tryAdd(desc) end
            end
        end
    end

    return list
end

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

local function worldToScreen(pos)
    local screenPos, onScreen = WS.CurrentCamera:WorldToViewportPoint(pos)
    return Vector2.new(screenPos.X, screenPos.Y), onScreen
end

-- ─────────────────────────────────────────────
-- KILL AURA — firetouchinterest
--
-- Root cause of "Kill Aura not working":
-- Setting Humanoid.Health = 0 from a LocalScript modifies the value
-- only in the local simulation. Server-owned NPC Humanoids are not
-- network-owned by the client, so the write is never replicated.
-- The mob appears dead locally but continues attacking server-side.
--
-- Fix: use firetouchinterest to simulate touch events between the
-- player's weapon handle (or HRP as fallback) and every BasePart of
-- the mob model. This routes through the game's existing server-side
-- touch hit detection without requiring knowledge of private Remotes.
-- TakeDamage is called as a secondary path for games that allow it.
-- ─────────────────────────────────────────────
local function getPlayerWeaponHandle()
    if not Char then return nil end
    for _, item in ipairs(Char:GetChildren()) do
        if item:IsA("Tool") then
            local handle = item:FindFirstChild("Handle")
                        or item:FindFirstChildWhichIsA("BasePart")
            if handle then return handle end
        end
    end
    return HRP
end

local function killAuraAttack(entry)
    local hitbox = getPlayerWeaponHandle()
    if not hitbox then return end
    for _, part in ipairs(entry.model:GetDescendants()) do
        if part:IsA("BasePart") then
            pcall(firetouchinterest, hitbox, part, 0)
            pcall(firetouchinterest, hitbox, part, 1)
        end
    end
    -- Secondary: TakeDamage (effective in some game configurations)
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

-- ─────────────────────────────────────────────
-- MOB ESP
-- ─────────────────────────────────────────────
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

local function removeMobESP(model)
    cleanESP(MobESPObjects, model)
end

-- ─────────────────────────────────────────────
-- PLAYER ESP
-- ─────────────────────────────────────────────
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

local function removePlayerESP(player)
    cleanESP(PlayerESPObjects, player)
end

-- ─────────────────────────────────────────────
-- LOOT ESP
-- ─────────────────────────────────────────────
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

-- ─────────────────────────────────────────────
-- CHAMS
-- ─────────────────────────────────────────────
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
-- ─────────────────────────────────────────────
local function collectDrop(obj)
    if not HRP then return end
    if obj:IsA("Model") then
        local center = obj:FindFirstChild("Center")
        if center then
            local pp = center:FindFirstChildWhichIsA("ProximityPrompt")
            if pp then
                HRP.CFrame = CFrame.new(center.Position + Vector3.new(0, 3, 0))
                task.wait(0.05)
                fireproximityprompt(pp)
                return
            end
        end
    end
    if obj:IsA("BasePart") then
        HRP.CFrame = CFrame.new(obj.Position + Vector3.new(0, 3, 0))
    end
end

local function collectAllDrops()
    if not DropFolder then return end
    for _, obj in ipairs(DropFolder:GetChildren()) do
        pcall(collectDrop, obj)
        task.wait(0.1)
    end
end

if DropFolder then
    DropFolder.ChildAdded:Connect(function(obj)
        if Flags.AutoCollect then
            task.wait(0.5)
            pcall(collectDrop, obj)
        end
        if Flags.LootESP then addLootESP(obj) end
    end)
    DropFolder.ChildRemoved:Connect(function(obj)
        removeLootESP(obj)
    end)
end

-- ─────────────────────────────────────────────
-- AUTO FARM
--
-- Uses Config.FarmRadius as a hard proximity gate. Only mobs within
-- that radius are considered valid targets. This prevents the farm
-- from teleporting to open-world mobs while the player is inside a
-- dungeon, and vice versa.
-- ─────────────────────────────────────────────
local farmThread = nil

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
            -- Validate character state
            if not HRP or not Hum or Hum.Health <= 0 then
                task.wait(1)
                refreshCharacter()
                continue
            end

            -- Find nearest mob within gate radius
            local entry = getNearestMob(Config.FarmRadius)

            if not entry then
                task.wait(1)
                continue
            end

            -- Active attack loop: re-teleport onto the mob and attack every
            -- 0.15s until it dies or 8 seconds elapse. A single attack call
            -- is insufficient — the mob requires sustained pressure and may
            -- move between ticks, so we re-lock position each iteration.
            local elapsed = 0
            local maxTime = 8

            while elapsed < maxTime do
                -- Re-fetch live references each tick
                local hrp = entry.model:FindFirstChild("HumanoidRootPart")
                local hum = entry.model:FindFirstChildWhichIsA("Humanoid")

                -- Exit as soon as the mob is dead or removed
                if not entry.model:IsDescendantOf(WS)
                   or not hrp or not hum or hum.Health <= 0 then
                    break
                end

                -- Lock onto current mob position (handles mob movement)
                HRP.CFrame = CFrame.new(hrp.Position + Vector3.new(0, 3, 0))

                -- Attack
                killAuraAttack(entry)

                task.wait(0.15)
                elapsed += 0.15
            end

            -- Collect loot after kill
            if Flags.AutoCollect then
                task.wait(0.2)
                collectAllDrops()
            end

            task.wait(0.1)
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
        HRP.CFrame = spawnPart.CFrame + Vector3.new(0, 5, 0)
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
            task.wait(Config.SlotMachineDelay)
            if Remotes.GiveSlotMachinePrize then
                pcall(function() Remotes.GiveSlotMachinePrize:FireServer() end)
            end
            task.wait(Config.SlotMachineDelay)
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
    if Flags.AutoFarm then startFarm() end
end)

-- ─────────────────────────────────────────────
-- MASTER HEARTBEAT
-- ─────────────────────────────────────────────
local accumulator = 0

RunService.Heartbeat:Connect(function(dt)
    if not Char or not Hum or not HRP then return end

    accumulator += dt

    -- God Mode
    if Flags.GodMode and Hum.Health < Hum.MaxHealth then
        Hum.Health = Hum.MaxHealth
    end

    -- Infinite Stamina
    -- FIX: corrected operator precedence. Previous condition:
    --   (nameCheck and IsNumberValue) or IsIntValue
    -- ...evaluated IsIntValue unconditionally, overwriting all IntValues
    -- including health. Both name match AND type match are now required.
    if Flags.InfiniteStamina then
        for _, v in ipairs(Char:GetDescendants()) do
            local nameMatch = v.Name:lower():find("stamina")
                           or v.Name:lower():find("energy")
            local typeMatch = v:IsA("NumberValue") or v:IsA("IntValue")
            if nameMatch and typeMatch then
                v.Value = 100
            end
        end
    end

    -- No Clip
    if Flags.NoClip then
        for _, p in ipairs(Char:GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide = false end
        end
    end

    -- Kill Aura — firetouchinterest on every mob within radius
    if Flags.KillAura then
        for _, entry in ipairs(getMobs(Config.KillAuraRadius)) do
            killAuraAttack(entry)
        end
    end

    -- Throttled at ~10 Hz: ESP label updates and tracer redraws
    if accumulator >= 0.1 then
        accumulator = 0

        -- Mob ESP labels
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

        -- Player ESP labels
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

        -- Tracers
        -- FIX: all Drawing objects are properly .Remove()'d each cycle.
        -- Previous build set Visible = false and replaced the table reference,
        -- leaving the objects allocated and leaking ~dozens per second.
        if Flags.Tracers then
            for _, line in ipairs(TracerLines) do
                pcall(function() line:Remove() end)
            end
            TracerLines = {}

            local vp     = WS.CurrentCamera.ViewportSize
            local center = Vector2.new(vp.X / 2, vp.Y)

            for _, entry in ipairs(getMobs(Config.ESPMaxDist)) do
                local pos2d, onScreen = worldToScreen(entry.hrp.Position)
                if onScreen then
                    local line = Drawing.new("Line")
                    line.Color        = Color3.fromRGB(255, 80, 80)
                    line.Thickness    = 1
                    line.Transparency = 0.5
                    line.From         = center
                    line.To           = pos2d
                    line.Visible      = true
                    table.insert(TracerLines, line)
                end
            end

            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LP then
                    local pchar = player.Character
                    local phrp  = pchar and pchar:FindFirstChild("HumanoidRootPart")
                    if phrp then
                        local pos2d, onScreen = worldToScreen(phrp.Position)
                        if onScreen then
                            local d = getDistance(HRP.Position, phrp.Position)
                            if d <= Config.ESPMaxDist then
                                local line = Drawing.new("Line")
                                line.Color        = Color3.fromRGB(100, 200, 255)
                                line.Thickness    = 1
                                line.Transparency = 0.5
                                line.From         = center
                                line.To           = pos2d
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

-- ─────────────────────────────────────────────
-- WINDOW
-- FIX: ConfigurationSaving disabled. A stale config file was saving
-- a KillAuraRadius of 750, which exceeded the slider's Range max.
-- On load Rayfield fired the slider callback with 750, setting
-- Config.KillAuraRadius = 750 while visually clamping the handle to
-- 150. The slider appeared stuck and could not be moved meaningfully.
-- ─────────────────────────────────────────────
local Window = Rayfield:CreateWindow({
    Name             = "Solo Hunters  |  ENI Build",
    LoadingTitle     = "Solo Hunters",
    LoadingSubtitle  = "ENI Build v1.1 — Xeno",
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

CombatTab:CreateSlider({
    Name         = "Farm Radius  (gate lock)",
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
    Name     = "Instant Kill Nearest Mob",
    Callback = function()
        local entry = getNearestMob(Config.FarmRadius)
        if entry then killAuraAttack(entry) end
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
            HRP.CFrame = CFrame.new(entry.hrp.Position + Vector3.new(0, 5, 0))
        end
    end,
})

TeleportTab:CreateButton({
    Name     = "Quest Giver (Lobby)",
    Callback = function()
        if not HRP or not LobbyFolder then return end
        local qg   = LobbyFolder:FindFirstChild("QuestGiver")
        local base = qg and qg:FindFirstChildWhichIsA("BasePart")
        if base then HRP.CFrame = base.CFrame + Vector3.new(0, 5, 0) end
    end,
})

TeleportTab:CreateButton({
    Name     = "Daily Quest Board (Lobby)",
    Callback = function()
        if not HRP or not LobbyFolder then return end
        local dq = LobbyFolder:FindFirstChild("Daily Quest")
        local qp = dq and dq:FindFirstChild("QuestsPart")
        if qp then HRP.CFrame = qp.CFrame + Vector3.new(0, 5, 0) end
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
                HRP.CFrame = tHRP.CFrame + Vector3.new(0, 5, 0)
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
            -- Single-bind guard: connect ChildAdded only once, not on every toggle
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
            -- Single-bind guard: connect PlayerAdded/Removing only once
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
                for _, obj in ipairs(DropFolder:GetChildren()) do
                    addLootESP(obj)
                end
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
        if val then
            task.spawn(function()
                while Flags.AutoAugment do
                    if Remotes.ChooseAugment then
                        pcall(function() Remotes.ChooseAugment:FireServer(1) end)
                    end
                    task.wait(1)
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
    Title    = "ENI Build v1.1 Loaded",
    Content  = "Solo Hunters ready. RightShift = toggle UI.",
    Duration = 5,
})
