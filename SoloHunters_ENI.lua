--[[
    ╔══════════════════════════════════════════════════════════╗
    ║          SOLO HUNTERS — ENI BUILD                        ║
    ║          Built for Xeno Executor                         ║
    ║          Structure-accurate as of scan v2.0              ║
    ╚══════════════════════════════════════════════════════════╝

    CHANGELOG:
    [v1.0] - Initial release
    - Kill Aura targeting Workspace.Mobs
    - Auto Farm state machine with mob-removal death detection
    - Auto Collect via ProximityPrompt trigger on Camera.Drops
    - God Mode via __namecall hook + Heartbeat HP reset
    - Confirmed Remote hooks: BossAltarSpawnBoss, SpinSlotMachine,
      GiveSlotMachinePrize, ChooseAugment, SendAugment,
      StartChallenge, FullDungeonRemote
    - Live currency reader: Gold, Gems, Souls2026, Raidium from MainUIController
    - Dungeon teleport: WolfCave, DoubleDungeon, Subway, Jungle
    - Quest NPC + Daily Quest board teleport from Workspace.Map.Lobby
    - Mob ESP augmenting existing HealthGui + distance label
    - Loot ESP on Camera.Drops (Epic=gold, Part=white)
    - Player ESP, Chams (BoxHandleAdornment), Drawing Tracers
    - No Clip, WalkSpeed, JumpPower, Infinite Stamina
    - Auto Augment, Auto Slot Machine, Start Challenge, Full Dungeon
    - FPS Unlocker (setfpscap), Rejoin, RightShift UI toggle
    - One master Heartbeat loop, CharacterAdded re-init, ESP AncestryChanged cleanup
]]

-- ─────────────────────────────────────────────
-- EXECUTOR CHECK
-- ─────────────────────────────────────────────
if not (hookmetamethod and getrawmetatable and setfpscap) then
    warn("[ENI] Unsupported executor. Xeno required.")
    return
end

-- ─────────────────────────────────────────────
-- SERVICES
-- ─────────────────────────────────────────────
local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService   = game:GetService("TweenService")
local TeleportService = game:GetService("TeleportService")
local WS             = game:GetService("Workspace")

-- ─────────────────────────────────────────────
-- CONFIRMED PATHS (from Structure.txt)
-- ─────────────────────────────────────────────
local RS             = game:GetService("ReplicatedStorage")
local RemotesFolder  = RS:WaitForChild("ReplicatedStorage", 10) and
                       RS:WaitForChild("ReplicatedStorage"):WaitForChild("Remotes", 10)
local MobFolder      = WS:WaitForChild("Mobs", 10)
local DropFolder     = WS:WaitForChild("Camera", 10) and
                       WS:WaitForChild("Camera"):WaitForChild("Drops", 10)
local MapFolder      = WS:FindFirstChild("Map")
local LobbyFolder    = MapFolder and MapFolder:FindFirstChild("Lobby")

-- ─────────────────────────────────────────────
-- REMOTES (confirmed names from Structure.txt)
-- ─────────────────────────────────────────────
local Remotes = {}
if RemotesFolder then
    local names = {
        "BossAltarSpawnBoss",
        "FullDungeonRemote",
        "SpinSlotMachine",
        "GiveSlotMachinePrize",
        "StartChallenge",
        "SendAugment",
        "ChooseAugment",
        "SacrificeWeapon",
        "BodyMover",
        "MouseReplication",
    }
    for _, name in ipairs(names) do
        local r = RemotesFolder:FindFirstChild(name)
        if r then Remotes[name] = r end
    end
end

-- ─────────────────────────────────────────────
-- LOCAL PLAYER REFS
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
-- FLAGS — one table, one loop
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
    KillAuraRadius  = 50,
    WalkSpeed       = 16,
    JumpPower       = 50,
    ESPMaxDist      = 300,
    SlotMachineDelay = 2,
}

-- ─────────────────────────────────────────────
-- WAYPOINTS
-- ─────────────────────────────────────────────
local Waypoints  = {}
local SafeSpot   = nil

-- ─────────────────────────────────────────────
-- ESP TRACKING TABLES
-- ─────────────────────────────────────────────
local MobESPObjects    = {}  -- [model] = {billboard, box}
local PlayerESPObjects = {}  -- [player] = {billboard, box}
local LootESPObjects   = {}  -- [part/model] = selectionbox
local TracerLines      = {}  -- [instance] = Drawing.Line

-- ─────────────────────────────────────────────
-- UTILITY FUNCTIONS
-- ─────────────────────────────────────────────
local function getDistance(a, b)
    return (a - b).Magnitude
end

local function isAlive(model)
    local h = model:FindFirstChildWhichIsA("Humanoid")
    return h and h.Health > 0
end

local function getMobs()
    local list = {}
    if not MobFolder then return list end
    for _, model in ipairs(MobFolder:GetChildren()) do
        if model:IsA("Model") and isAlive(model) then
            local hrp = model:FindFirstChild("HumanoidRootPart")
            if hrp then
                list[#list + 1] = { model = model, hrp = hrp }
            end
        end
    end
    return list
end

local function getNearestMob()
    if not HRP then return nil end
    local nearest, nearestDist = nil, math.huge
    for _, entry in ipairs(getMobs()) do
        local d = getDistance(HRP.Position, entry.hrp.Position)
        if d < nearestDist then
            nearest = entry
            nearestDist = d
        end
    end
    return nearest, nearestDist
end

local function worldToScreen(pos)
    local cam = WS.CurrentCamera
    local screenPos, onScreen = cam:WorldToViewportPoint(pos)
    return Vector2.new(screenPos.X, screenPos.Y), onScreen, screenPos.Z
end

-- ─────────────────────────────────────────────
-- GOD MODE — __namecall hook
-- ─────────────────────────────────────────────
local namecallHook
local mt = getrawmetatable(game)
setreadonly(mt, false)

namecallHook = hookmetamethod(game, "__namecall", function(self, ...)
    local method = getnamecallmethod()
    -- Block TakeDamage on our Humanoid when God Mode is on
    if Flags.GodMode and method == "TakeDamage" and self == Hum then
        return
    end
    return namecallHook(self, ...)
end)

setreadonly(mt, true)

-- ─────────────────────────────────────────────
-- CURRENCY READER
-- ─────────────────────────────────────────────
local function getCurrencyValues()
    -- MainUIController lives in PlayerScripts.StarterPlayerScripts
    local ps  = LP:FindFirstChild("PlayerScripts")
    local sps = ps and ps:FindFirstChild("StarterPlayerScripts")
    local mui = sps and sps:FindFirstChild("MainUIController")
    if not mui then return {} end
    return {
        Gold     = mui:FindFirstChild("Gold")     and mui.Gold.Value     or 0,
        Gems     = mui:FindFirstChild("Gems")     and mui.Gems.Value     or 0,
        Souls    = mui:FindFirstChild("Souls2026") and mui.Souls2026.Value or 0,
        Raidium  = mui:FindFirstChild("Raidium")  and mui.Raidium.Value  or 0,
        Power    = (LP:FindFirstChild("leaderstats") and
                    LP.leaderstats:FindFirstChild("Power") and
                    LP.leaderstats.Power.Value) or 0,
    }
end

-- ─────────────────────────────────────────────
-- ESP HELPERS
-- ─────────────────────────────────────────────
local function makeBillboard(parent, text, color, size)
    local bb = Instance.new("BillboardGui")
    bb.AlwaysOnTop   = true
    bb.Size          = UDim2.new(0, size or 80, 0, 30)
    bb.StudsOffset   = Vector3.new(0, 3, 0)
    bb.Parent        = parent

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

local function makeBox(adornee, color)
    local box = Instance.new("BoxHandleAdornment")
    box.AlwaysOnTop = true
    box.ZIndex      = 5
    box.Color3      = color
    box.Transparency = 0.4
    box.Size        = adornee.Size
    box.Adornee     = adornee
    box.Parent      = adornee
    return box
end

local function makeTracer(color)
    local line = Drawing.new("Line")
    line.Visible   = false
    line.Color     = color
    line.Thickness = 1
    line.Transparency = 0.5
    return line
end

local function cleanESP(tbl, key)
    if not tbl[key] then return end
    for _, obj in pairs(tbl[key]) do
        if typeof(obj) == "Instance" then
            pcall(function() obj:Destroy() end)
        elseif obj.Remove then
            pcall(function() obj:Remove() end)
        end
    end
    tbl[key] = nil
end

-- ─────────────────────────────────────────────
-- MOB ESP — CREATE / REMOVE
-- ─────────────────────────────────────────────
local function addMobESP(model)
    if MobESPObjects[model] then return end
    local hrp = model:FindFirstChild("HumanoidRootPart")
    local hum = model:FindFirstChildWhichIsA("Humanoid")
    if not hrp or not hum then return end

    -- Billboard above HRP
    local bb, lbl = makeBillboard(hrp, model.Name, Color3.fromRGB(255, 80, 80), 100)
    -- Distance sub-label
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

    -- Auto-clean when mob is removed
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
-- PLAYER ESP — CREATE / REMOVE
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
-- LOOT ESP — CREATE / REMOVE
-- ─────────────────────────────────────────────
local function addLootESP(obj)
    if LootESPObjects[obj] then return end

    -- Determine the actual Part to adorn
    local part = obj
    if obj:IsA("Model") then
        -- Epic model: use Center part
        local center = obj:FindFirstChild("Center")
        part = center or obj:FindFirstChildWhichIsA("BasePart")
    end
    if not part or not part:IsA("BasePart") then return end

    -- Color: Epic = gold, plain Part = white
    local isEpic = obj:IsA("Model")
    local color  = isEpic and Color3.fromRGB(255, 215, 0) or Color3.fromRGB(220, 220, 220)

    local sel = Instance.new("SelectionBox")
    sel.Color3         = color
    sel.LineThickness  = 0.06
    sel.SurfaceTransparency = 0.7
    sel.SurfaceColor3  = color
    sel.Adornee        = part
    sel.Parent         = part

    local bb, lbl = makeBillboard(part, isEpic and "⭐ EPIC" or "Drop", color, 80)

    LootESPObjects[obj] = { sel = sel, bb = bb }

    obj.AncestryChanged:Connect(function()
        if not obj:IsDescendantOf(game) then
            if LootESPObjects[obj] then
                pcall(function() LootESPObjects[obj].sel:Destroy() end)
                pcall(function() LootESPObjects[obj].bb:Destroy() end)
                LootESPObjects[obj] = nil
            end
        end
    end)
end

local function removeLootESP(obj)
    if LootESPObjects[obj] then
        pcall(function() LootESPObjects[obj].sel:Destroy() end)
        pcall(function() LootESPObjects[obj].bb:Destroy() end)
        LootESPObjects[obj] = nil
    end
end

-- ─────────────────────────────────────────────
-- CHAMS — BoxHandleAdornment on mob parts
-- ─────────────────────────────────────────────
local ChamsObjects = {}

local function addChams(model)
    if ChamsObjects[model] then return end
    ChamsObjects[model] = {}
    for _, part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
            local box = Instance.new("BoxHandleAdornment")
            box.AlwaysOnTop   = true
            box.ZIndex        = 5
            box.Color3        = Color3.fromRGB(255, 60, 60)
            box.Transparency  = 0.5
            box.Size          = part.Size
            box.Adornee       = part
            box.Parent        = part
            table.insert(ChamsObjects[model], box)
        end
    end
    model.AncestryChanged:Connect(function()
        if not model:IsDescendantOf(game) then
            if ChamsObjects[model] then
                for _, b in ipairs(ChamsObjects[model]) do
                    pcall(function() b:Destroy() end)
                end
                ChamsObjects[model] = nil
            end
        end
    end)
end

local function removeChams(model)
    if ChamsObjects[model] then
        for _, b in ipairs(ChamsObjects[model]) do
            pcall(function() b:Destroy() end)
        end
        ChamsObjects[model] = nil
    end
end

local function clearAllChams()
    for model, _ in pairs(ChamsObjects) do
        removeChams(model)
    end
end

-- ─────────────────────────────────────────────
-- AUTO COLLECT — fire ProximityPrompt on drops
-- ─────────────────────────────────────────────
local function collectDrop(obj)
    if not HRP then return end
    -- Epic model: has Center.ProximityPrompt
    if obj:IsA("Model") then
        local center = obj:FindFirstChild("Center")
        if center then
            local pp = center:FindFirstChildWhichIsA("ProximityPrompt")
            if pp then
                -- Teleport close enough, then trigger
                HRP.CFrame = CFrame.new(center.Position + Vector3.new(0, 3, 0))
                task.wait(0.05)
                fireproximityprompt(pp)
                return
            end
        end
    end
    -- Plain Part: just teleport to it
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

-- Listen for new drops
if DropFolder then
    DropFolder.ChildAdded:Connect(function(obj)
        if Flags.AutoCollect then
            task.wait(0.5) -- let it fully load
            pcall(collectDrop, obj)
        end
        if Flags.LootESP then
            addLootESP(obj)
        end
    end)
    DropFolder.ChildRemoved:Connect(function(obj)
        removeLootESP(obj)
    end)
end

-- ─────────────────────────────────────────────
-- AUTO FARM STATE MACHINE
-- ─────────────────────────────────────────────
local farmCoroutine = nil

local function stopFarm()
    if farmCoroutine then
        task.cancel(farmCoroutine)
        farmCoroutine = nil
    end
end

local function startFarm()
    stopFarm()
    farmCoroutine = task.spawn(function()
        while Flags.AutoFarm do
            if not HRP or not Hum or Hum.Health <= 0 then
                task.wait(1)
                refreshCharacter()
            end

            local entry, dist = getNearestMob()
            if entry then
                -- Teleport to mob
                HRP.CFrame = CFrame.new(entry.hrp.Position + Vector3.new(0, 3, 0))
                task.wait(0.1)

                -- Kill it
                local mobHum = entry.model:FindFirstChildWhichIsA("Humanoid")
                if mobHum and mobHum.Health > 0 then
                    mobHum.Health = 0
                end

                -- Wait for removal (death confirmation) or timeout
                local t = 0
                repeat
                    task.wait(0.1)
                    t = t + 0.1
                until not entry.model:IsDescendantOf(WS) or t > 5

                -- Collect loot
                if Flags.AutoCollect then
                    task.wait(0.3)
                    collectAllDrops()
                end
            else
                task.wait(1)
            end

            task.wait(0.2)
        end
    end)
end

-- ─────────────────────────────────────────────
-- DUNGEON TELEPORT TARGETS
-- ─────────────────────────────────────────────
local DungeonSpawns = {
    WolfCave     = function()
        local d = MapFolder and MapFolder:FindFirstChild("WolfCave", true)
        return d and d:FindFirstChild("PlayerSpawnInDungeon")
    end,
    DoubleDungeon = function()
        local d = MapFolder and MapFolder:FindFirstChild("DoubleDungeon", true)
        return d and d:FindFirstChild("PlayerSpawnInDungeon")
    end,
    Subway       = function()
        local d = MapFolder and MapFolder:FindFirstChild("Subway", true)
        return d and d:FindFirstChild("PlayerSpawnInDungeon")
    end,
    Jungle       = function()
        local d = MapFolder and MapFolder:FindFirstChild("Jungle", true)
        return d and d:FindFirstChild("PlayerSpawnInDungeon")
    end,
}

local function teleportToDungeon(name)
    local getter = DungeonSpawns[name]
    if not getter then return end
    local spawnPart = getter()
    if spawnPart and HRP then
        HRP.CFrame = spawnPart.CFrame + Vector3.new(0, 5, 0)
    else
        warn("[ENI] Dungeon spawn not found for: " .. name)
    end
end

-- ─────────────────────────────────────────────
-- SLOT MACHINE LOOP
-- ─────────────────────────────────────────────
local slotCoroutine = nil

local function startSlotMachine()
    if slotCoroutine then task.cancel(slotCoroutine) end
    slotCoroutine = task.spawn(function()
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
-- CHARACTER RE-INIT ON RESPAWN
-- ─────────────────────────────────────────────
LP.CharacterAdded:Connect(function(char)
    task.wait(0.5)
    refreshCharacter()

    -- Re-apply speed/jump
    if Hum then
        Hum.WalkSpeed = Config.WalkSpeed
        Hum.JumpPower = Config.JumpPower
    end

    -- Restart farm if it was running
    if Flags.AutoFarm then
        startFarm()
    end
end)

-- ─────────────────────────────────────────────
-- MASTER HEARTBEAT LOOP
-- ─────────────────────────────────────────────
local heartbeatAccum = 0

RunService.Heartbeat:Connect(function(dt)
    -- Guard: need valid character
    if not Char or not Hum or not HRP then return end

    heartbeatAccum = heartbeatAccum + dt

    -- God Mode: reset HP each frame
    if Flags.GodMode and Hum.Health < Hum.MaxHealth then
        Hum.Health = Hum.MaxHealth
    end

    -- Infinite Stamina: handled by watching the value if it exists
    if Flags.InfiniteStamina then
        -- Stamina isn't exposed in structure, so we scan for likely values
        for _, v in ipairs(Char:GetDescendants()) do
            if (v.Name:lower():find("stamina") or v.Name:lower():find("energy"))
               and v:IsA("NumberValue") or v:IsA("IntValue") then
                v.Value = v.Value < 50 and 100 or v.Value
            end
        end
    end

    -- No Clip
    if Flags.NoClip then
        HRP.CanCollide = false
        for _, p in ipairs(Char:GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide = false end
        end
    end

    -- Kill Aura (every frame, distance-gated)
    if Flags.KillAura then
        for _, entry in ipairs(getMobs()) do
            local d = getDistance(HRP.Position, entry.hrp.Position)
            if d <= Config.KillAuraRadius then
                local mobHum = entry.model:FindFirstChildWhichIsA("Humanoid")
                if mobHum and mobHum.Health > 0 then
                    pcall(function() mobHum.Health = 0 end)
                end
            end
        end
    end

    -- ESP distance updates and tracer draws (every ~0.1s to save perf)
    if heartbeatAccum >= 0.1 then
        heartbeatAccum = 0

        -- Mob ESP label updates
        if Flags.MobESP then
            for model, objs in pairs(MobESPObjects) do
                if model:IsDescendantOf(WS) and HRP then
                    local hrp = model:FindFirstChild("HumanoidRootPart")
                    local hum = model:FindFirstChildWhichIsA("Humanoid")
                    if hrp and hum then
                        local dist = math.floor(getDistance(HRP.Position, hrp.Position))
                        objs.distLbl.Text = dist .. " studs | HP: " ..
                            math.floor(hum.Health) .. "/" .. math.floor(hum.MaxHealth)

                        -- Hide if beyond max distance
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
                if phrp and HRP then
                    local dist = math.floor(getDistance(HRP.Position, phrp.Position))
                    objs.distLbl.Text = dist .. " studs"
                    objs.bb.Enabled   = dist <= Config.ESPMaxDist
                end
            end
        end

        -- Tracers
        if Flags.Tracers then
            local vp     = WS.CurrentCamera.ViewportSize
            local center = Vector2.new(vp.X / 2, vp.Y)

            -- Clear old lines
            for _, line in pairs(TracerLines) do
                line.Visible = false
            end
            TracerLines = {}

            -- Mob tracers
            for _, entry in ipairs(getMobs()) do
                local pos2d, onScreen = worldToScreen(entry.hrp.Position)
                if onScreen then
                    local d = getDistance(HRP.Position, entry.hrp.Position)
                    if d <= Config.ESPMaxDist then
                        local line = makeTracer(Color3.fromRGB(255, 80, 80))
                        line.From    = center
                        line.To      = pos2d
                        line.Visible = true
                        table.insert(TracerLines, line)
                    end
                end
            end

            -- Player tracers
            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LP then
                    local pchar = player.Character
                    local phrp  = pchar and pchar:FindFirstChild("HumanoidRootPart")
                    if phrp then
                        local pos2d, onScreen = worldToScreen(phrp.Position)
                        if onScreen then
                            local d = getDistance(HRP.Position, phrp.Position)
                            if d <= Config.ESPMaxDist then
                                local line = makeTracer(Color3.fromRGB(100, 200, 255))
                                line.From    = center
                                line.To      = pos2d
                                line.Visible = true
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
-- RAYFIELD UI LOAD
-- ─────────────────────────────────────────────
local RayfieldLoaded, Rayfield = pcall(function()
    return loadstring(game:HttpGet(
        "https://sirius.menu/rayfield"
    ))()
end)

if not RayfieldLoaded or not Rayfield then
    -- Fallback notification if Rayfield CDN unreachable
    warn("[ENI] Rayfield failed to load. Check your internet or executor HTTP permissions.")
    return
end

-- ─────────────────────────────────────────────
-- CREATE WINDOW
-- ─────────────────────────────────────────────
local Window = Rayfield:CreateWindow({
    Name             = "Solo Hunters  |  ENI Build",
    LoadingTitle     = "Solo Hunters",
    LoadingSubtitle  = "ENI Build — Xeno",
    ConfigurationSaving = {
        Enabled  = true,
        FileName = "SoloHunters_ENI",
    },
    KeySystem = false,
})

-- ═══════════════════════════════════════════════
-- TAB: COMBAT
-- ═══════════════════════════════════════════════
local CombatTab = Window:CreateTab("Combat", 4483362458)

CombatTab:CreateSection("Auto Systems")

CombatTab:CreateToggle({
    Name    = "Auto Farm",
    Default = false,
    Callback = function(val)
        Flags.AutoFarm = val
        if val then startFarm() else stopFarm() end
    end,
})

CombatTab:CreateToggle({
    Name    = "Kill Aura",
    Default = false,
    Callback = function(val)
        Flags.KillAura = val
    end,
})

CombatTab:CreateSlider({
    Name    = "Kill Aura Radius",
    Range   = {10, 150},
    Increment = 5,
    Suffix  = " studs",
    Default = 50,
    Callback = function(val)
        Config.KillAuraRadius = val
    end,
})

CombatTab:CreateButton({
    Name     = "Instant Kill Nearest Mob",
    Callback = function()
        local entry = getNearestMob()
        if entry then
            local h = entry.model:FindFirstChildWhichIsA("Humanoid")
            if h then pcall(function() h.Health = 0 end) end
        end
    end,
})

CombatTab:CreateSection("Loot")

CombatTab:CreateToggle({
    Name    = "Auto Collect Drops",
    Default = false,
    Callback = function(val)
        Flags.AutoCollect = val
        if val then
            task.spawn(collectAllDrops)
        end
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
            Rayfield:Notify({
                Title    = "Boss Altar",
                Content  = "BossAltarSpawnBoss fired.",
                Duration = 3,
            })
        else
            Rayfield:Notify({
                Title    = "Remote Not Found",
                Content  = "BossAltarSpawnBoss remote unavailable.",
                Duration = 3,
            })
        end
    end,
})

-- ═══════════════════════════════════════════════
-- TAB: PLAYER
-- ═══════════════════════════════════════════════
local PlayerTab = Window:CreateTab("Player", 4483362458)

PlayerTab:CreateSection("Live Stats")

-- Refresh stats button (Rayfield doesn't have live labels natively)
PlayerTab:CreateButton({
    Name     = "Refresh Currency Display",
    Callback = function()
        local c = getCurrencyValues()
        Rayfield:Notify({
            Title    = "Your Stats",
            Content  = string.format(
                "Power: %d\nGold: %d\nGems: %d\nSouls: %d\nRaidium: %d",
                c.Power or 0, c.Gold or 0, c.Gems or 0,
                c.Souls or 0, c.Raidium or 0
            ),
            Duration = 8,
        })
    end,
})

PlayerTab:CreateSection("Movement")

PlayerTab:CreateSlider({
    Name      = "Walk Speed",
    Range     = {16, 500},
    Increment = 1,
    Suffix    = "",
    Default   = 16,
    Callback  = function(val)
        Config.WalkSpeed = val
        if Hum then Hum.WalkSpeed = val end
    end,
})

PlayerTab:CreateSlider({
    Name      = "Jump Power",
    Range     = {7, 300},
    Increment = 1,
    Suffix    = "",
    Default   = 50,
    Callback  = function(val)
        Config.JumpPower = val
        if Hum then Hum.JumpPower = val end
    end,
})

PlayerTab:CreateToggle({
    Name    = "No Clip",
    Default = false,
    Callback = function(val)
        Flags.NoClip = val
    end,
})

PlayerTab:CreateSection("Survival")

PlayerTab:CreateToggle({
    Name    = "God Mode",
    Default = false,
    Callback = function(val)
        Flags.GodMode = val
    end,
})

PlayerTab:CreateToggle({
    Name    = "Infinite Stamina",
    Default = false,
    Callback = function(val)
        Flags.InfiniteStamina = val
    end,
})

-- ═══════════════════════════════════════════════
-- TAB: TELEPORT
-- ═══════════════════════════════════════════════
local TeleportTab = Window:CreateTab("Teleport", 4483362458)

TeleportTab:CreateSection("World")

TeleportTab:CreateButton({
    Name     = "Nearest Mob",
    Callback = function()
        local entry = getNearestMob()
        if entry and HRP then
            HRP.CFrame = CFrame.new(entry.hrp.Position + Vector3.new(0, 5, 0))
        end
    end,
})

TeleportTab:CreateButton({
    Name     = "Quest Giver (Lobby)",
    Callback = function()
        if not HRP or not LobbyFolder then return end
        local qg = LobbyFolder:FindFirstChild("QuestGiver")
        if qg then
            local base = qg:FindFirstChildWhichIsA("BasePart")
            if base then HRP.CFrame = base.CFrame + Vector3.new(0, 5, 0) end
        end
    end,
})

TeleportTab:CreateButton({
    Name     = "Daily Quest Board (Lobby)",
    Callback = function()
        if not HRP or not LobbyFolder then return end
        local dq = LobbyFolder:FindFirstChild("Daily Quest")
        if dq then
            local qp = dq:FindFirstChild("QuestsPart")
            if qp then HRP.CFrame = qp.CFrame + Vector3.new(0, 5, 0) end
        end
    end,
})

TeleportTab:CreateSection("Dungeons")

TeleportTab:CreateDropdown({
    Name     = "Teleport to Dungeon",
    Options  = {"WolfCave", "DoubleDungeon", "Subway", "Jungle"},
    Default  = "WolfCave",
    Callback = function(val)
        teleportToDungeon(val)
    end,
})

TeleportTab:CreateSection("Players")

local function getPlayerNames()
    local names = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            names[#names + 1] = p.Name
        end
    end
    return names
end

TeleportTab:CreateDropdown({
    Name     = "Teleport to Player",
    Options  = getPlayerNames(),
    Default  = getPlayerNames()[1] or "None",
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
            Rayfield:Notify({
                Title    = "Safe Spot Saved",
                Content  = "Position locked.",
                Duration = 2,
            })
        end
    end,
})

TeleportTab:CreateButton({
    Name     = "Return to Safe Spot",
    Callback = function()
        if SafeSpot and HRP then
            HRP.CFrame = SafeSpot
        end
    end,
})

TeleportTab:CreateButton({
    Name     = "Save Waypoint",
    Callback = function()
        if not HRP then return end
        local name = "WP" .. (#Waypoints + 1)
        Waypoints[#Waypoints + 1] = { name = name, cf = HRP.CFrame }
        Rayfield:Notify({
            Title    = "Waypoint Saved",
            Content  = name .. " saved.",
            Duration = 2,
        })
    end,
})

TeleportTab:CreateButton({
    Name     = "Go to Last Waypoint",
    Callback = function()
        if #Waypoints == 0 then return end
        if HRP then HRP.CFrame = Waypoints[#Waypoints].cf end
    end,
})

-- ═══════════════════════════════════════════════
-- TAB: ESP
-- ═══════════════════════════════════════════════
local ESPTab = Window:CreateTab("ESP", 4483362458)

ESPTab:CreateToggle({
    Name    = "Mob ESP",
    Default = false,
    Callback = function(val)
        Flags.MobESP = val
        if val then
            -- Add ESP to all current mobs
            if MobFolder then
                for _, model in ipairs(MobFolder:GetChildren()) do
                    if model:IsA("Model") then addMobESP(model) end
                end
                -- Listen for new mobs
                MobFolder.ChildAdded:Connect(function(model)
                    if Flags.MobESP and model:IsA("Model") then
                        task.wait(0.1)
                        addMobESP(model)
                    end
                end)
            end
        else
            for model, _ in pairs(MobESPObjects) do
                removeMobESP(model)
            end
        end
    end,
})

ESPTab:CreateToggle({
    Name    = "Player ESP",
    Default = false,
    Callback = function(val)
        Flags.PlayerESP = val
        if val then
            for _, p in ipairs(Players:GetPlayers()) do
                addPlayerESP(p)
            end
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
        else
            for p, _ in pairs(PlayerESPObjects) do
                removePlayerESP(p)
            end
        end
    end,
})

ESPTab:CreateToggle({
    Name    = "Loot ESP",
    Default = false,
    Callback = function(val)
        Flags.LootESP = val
        if val then
            if DropFolder then
                for _, obj in ipairs(DropFolder:GetChildren()) do
                    addLootESP(obj)
                end
            end
        else
            for obj, _ in pairs(LootESPObjects) do
                removeLootESP(obj)
            end
        end
    end,
})

ESPTab:CreateToggle({
    Name    = "Chams (Mob Highlight)",
    Default = false,
    Callback = function(val)
        Flags.Chams = val
        if val then
            if MobFolder then
                for _, model in ipairs(MobFolder:GetChildren()) do
                    if model:IsA("Model") then addChams(model) end
                end
            end
        else
            clearAllChams()
        end
    end,
})

ESPTab:CreateToggle({
    Name    = "Tracers",
    Default = false,
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
    Name      = "Max ESP Distance",
    Range     = {50, 1000},
    Increment = 10,
    Suffix    = " studs",
    Default   = 300,
    Callback  = function(val)
        Config.ESPMaxDist = val
    end,
})

-- ═══════════════════════════════════════════════
-- TAB: MISC
-- ═══════════════════════════════════════════════
local MiscTab = Window:CreateTab("Misc", 4483362458)

MiscTab:CreateSection("Remotes")

MiscTab:CreateToggle({
    Name    = "Auto Slot Machine",
    Default = false,
    Callback = function(val)
        Flags.AutoSlotMachine = val
        if val then startSlotMachine()
        else
            if slotCoroutine then
                task.cancel(slotCoroutine)
                slotCoroutine = nil
            end
        end
    end,
})

MiscTab:CreateSlider({
    Name      = "Slot Machine Delay",
    Range     = {1, 10},
    Increment = 0.5,
    Suffix    = "s",
    Default   = 2,
    Callback  = function(val)
        Config.SlotMachineDelay = val
    end,
})

MiscTab:CreateToggle({
    Name    = "Auto Augment (ChooseAugment)",
    Default = false,
    Callback = function(val)
        Flags.AutoAugment = val
        if val and Remotes.ChooseAugment then
            task.spawn(function()
                while Flags.AutoAugment do
                    pcall(function() Remotes.ChooseAugment:FireServer(1) end)
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
        setfpscap(0)
        Rayfield:Notify({ Title = "FPS Unlocker", Content = "FPS cap removed.", Duration = 3 })
    end,
})

MiscTab:CreateButton({
    Name     = "Rejoin",
    Callback = function()
        TeleportService:Teleport(game.PlaceId, LP)
    end,
})

MiscTab:CreateKeybind({
    Name         = "Toggle UI",
    CurrentKeybind = "RightShift",
    HoldToInteract = false,
    Callback     = function()
        Rayfield:ToggleUI()
    end,
})

-- ─────────────────────────────────────────────
-- INIT NOTIFY
-- ─────────────────────────────────────────────
Rayfield:Notify({
    Title    = "ENI Build Loaded",
    Content  = "Solo Hunters script ready. Toggle UI: RightShift",
    Duration = 5,
})
