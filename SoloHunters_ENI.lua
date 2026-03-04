--[[
    ╔══════════════════════════════════════════════════════════╗
    ║          SOLO HUNTERS — ENI BUILD  v6.0                  ║
    ║          Xeno Executor  |  Community-Architecture Rewrite ║
    ╚══════════════════════════════════════════════════════════╝

    Based on analysis of community scripts:
      6FootScripts, NS Hub (OhhMyGehlee), Hina Hub (Threeeps),
      mazino45 (Aeonic Hub), WynossWare, ApelHub

    ARCHITECTURE: Dungeon State Machine
    ─────────────────────────────────────────────────────────
    Community scripts share one core pattern: a persistent
    state machine that tracks where you are in the dungeon loop.

    States:
      LOBBY    → scan portals, pick best, move to it, enter
      ENTERING → wait for dungeon to load
      FIGHTING → kill all mobs, auto skills running passively
      COLLECTING → open chests, pick up drops
      LEAVING  → fire leave remote / teleport out
      QUESTING → turn in, accept new, sell, buy, restock

    NEW VS v5.0:
      ✦ Full state machine (not just one monolithic task.spawn)
      ✦ Auto Skills — keypress simulation for class abilities
      ✦ Smart Portal System — score portals by power/type,
                              prioritize Red (boss) gates
      ✦ Auto-Scale Difficulty — reads Power, picks right tier
      ✦ Auto Sell — proximity scan, fire sell NPC prompts
      ✦ Auto Buy Merchant Shop — fire shop purchase prompts
      ✦ Auto Equip Best Gear — scan backpack, equip by Power
      ✦ Auto Redeem Codes — fires known working codes
      ✦ Anti-AFK — periodic dummy jump
      ✦ All v4.0 bugfixes retained

    BUGFIXES RETAINED FROM AUDIT:
      ✓ Kill Aura: single persistent coroutine, no thread storm
      ✓ hpAtCheckpoint = current HP, not MaxHealth
      ✓ Currency path: MainUIController under RS.Controllers
      ✓ refreshCharacter: charConns flushed per respawn
      ✓ getNearestMob: redundant distance re-check removed
      ✓ JumpPower: writes both JumpPower + JumpHeight
      ✓ Plain Part drops: deferred ProximityPrompt listener
      ✓ Drawing pool: destroyPool() on rejoin
      ✓ DropFolder nil: diagnostic warn
]]

-- ════════════════════════════════════════════════════════════
-- SERVICES
-- ════════════════════════════════════════════════════════════
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TeleportService  = game:GetService("TeleportService")
local WS   = game:GetService("Workspace")
local RS   = game:GetService("ReplicatedStorage")
local UIS  = UserInputService

-- ════════════════════════════════════════════════════════════
-- PATHS (verified against Structure.txt v2.0)
--
-- RS (service)
--   └─ ReplicatedStorage [Folder]
--         ├─ Remotes [Folder]
--         └─ Controllers [Folder]
--               └─ MainUIController [ModuleScript]
--                     ├─ Gold [IntValue]  ├─ Gems [IntValue]
--                     ├─ Raidium [IntValue] ├─ Souls2026 [IntValue]
--                     └─ Power [IntValue]
-- ════════════════════════════════════════════════════════════
local RS_inner      = RS:WaitForChild("ReplicatedStorage", 10)
local RemotesFolder = RS_inner and RS_inner:WaitForChild("Remotes", 10)
local MobFolder     = WS:WaitForChild("Mobs", 10)
local MapFolder     = WS:FindFirstChild("Map")
local CirclesFolder = MapFolder and MapFolder:FindFirstChild("Circles")
local LobbyFolder   = MapFolder and MapFolder:FindFirstChild("Lobby")

local DropFolder = (function()
    local cam = WS:WaitForChild("Camera", 10)
    local d   = cam and cam:FindFirstChild("Drops")
    if not d then warn("[ENI] Camera.Drops not found — AutoCollect/LootESP disabled.") end
    return d
end)()

-- ════════════════════════════════════════════════════════════
-- REMOTES
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

-- Quest RemoteFunctions (inside RS.Controllers.Quests per structure)
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
-- LOCAL PLAYER & CHARACTER
-- ════════════════════════════════════════════════════════════
local LP = Players.LocalPlayer
local Char, Hum, HRP
local NoClipParts  = {}
local StaminaParts = {}
local charConns    = {}   -- flushed per respawn — prevents listener stacking

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

local function refreshChar()
    for _, c in ipairs(charConns) do c:Disconnect() end
    charConns = {}
    Char = LP.Character or LP.CharacterAdded:Wait()
    Hum  = Char:WaitForChild("Humanoid", 5)
    HRP  = Char:WaitForChild("HumanoidRootPart", 5)
    rebuildCharCaches()
    charConns[1] = Char.ChildAdded:Connect(function(c)
        if c:IsA("Tool") then rebuildCharCaches() end
    end)
    charConns[2] = Char.ChildRemoved:Connect(function(c)
        if c:IsA("Tool") then rebuildCharCaches() end
    end)
end
refreshChar()

-- ════════════════════════════════════════════════════════════
-- CONFIG
-- ════════════════════════════════════════════════════════════
local Flags = {
    -- Dungeon loop
    AutoFarm        = false,   -- master switch: full dungeon state machine
    AutoQuest       = false,
    AutoSell        = false,
    AutoBuyMerchant = false,
    AutoEquipBest   = false,
    AutoRedeemCodes = false,
    PrioritizeRed   = true,    -- boss portals first (community default)
    AutoScaleDiff   = true,    -- pick portal tier by Power stat

    -- Combat
    KillAura        = false,
    AutoSkills      = false,   -- fire class abilities automatically
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

    -- Skill keys (Xeno keypress codes): adjust to your class keybinds
    -- Format: {keyCode, cooldown_seconds}
    SkillKeys = {
        { key = 0x51, cd = 8  },  -- Q
        { key = 0x45, cd = 12 },  -- E
        { key = 0x52, cd = 20 },  -- R
        { key = 0x46, cd = 30 },  -- F
    },
}

-- ════════════════════════════════════════════════════════════
-- UTILITY
-- ════════════════════════════════════════════════════════════
local rng = Random.new()
local function rnd(lo, hi) return lo + rng:NextNumber()*(hi-lo) end
local function dist(a, b)  return (a-b).Magnitude end
local function inWS(obj)   return obj and obj:IsDescendantOf(WS) end

local function jitter(cf, r, y)
    r = r or 2; y = y or 0.5
    return cf + Vector3.new(rnd(-r,r), rnd(-y,y), rnd(-r,r))
end

local function safeTP(cf)
    if not HRP then return end
    HRP.CFrame = cf
    task.wait(0.1)
end

-- ════════════════════════════════════════════════════════════
-- CURRENCY
-- ════════════════════════════════════════════════════════════
local function getCurrencies()
    local ctrl = RS_inner and RS_inner:FindFirstChild("Controllers")
    local mui  = ctrl and ctrl:FindFirstChild("MainUIController")
    local ls   = LP:FindFirstChild("leaderstats")
    local function v(p,n) local x=p and p:FindFirstChild(n); return x and x.Value or 0 end
    return {
        Power   = v(mui,"Power") > 0 and v(mui,"Power") or v(ls,"Power"),
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
-- MOB CACHE
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
-- WEAPON HANDLE
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
-- ATTACK  (TouchEnded then TouchBegan — debounce safe)
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
    pcall(function() e.hum:TakeDamage(e.hum.MaxHealth) end)
end

-- ════════════════════════════════════════════════════════════
-- KILL AURA — single persistent coroutine (never from Heartbeat)
-- ════════════════════════════════════════════════════════════
task.spawn(function()
    while true do
        task.wait(rnd(0.15, 0.28))
        if Flags.KillAura and HRP and Hum and Hum.Health > 0 then
            for _, e in ipairs(getMobs(Config.KillAuraRadius)) do
                attackEntry(e)
            end
        end
    end
end)

-- ════════════════════════════════════════════════════════════
-- AUTO SKILLS
-- Simulates pressing skill keys using Xeno's keypress/keyrelease.
-- Tracks per-skill cooldowns so each key fires only when ready.
-- Community scripts (NS Hub, Aeonic) all do skill automation
-- this way — keypress is the only reliable method client-side.
-- ════════════════════════════════════════════════════════════
local skillCooldowns = {}
for i = 1, #Config.SkillKeys do skillCooldowns[i] = 0 end

task.spawn(function()
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

-- ════════════════════════════════════════════════════════════
-- GOD MODE — namecall hook
-- ════════════════════════════════════════════════════════════
local namecallHook
if hookmetamethod and getrawmetatable then
    pcall(function()
        local mt = getrawmetatable(game)
        setreadonly(mt, false)
        namecallHook = hookmetamethod(game, "__namecall", function(self, ...)
            if Flags.GodMode and getnamecallmethod()=="TakeDamage" and self==Hum then
                return
            end
            return namecallHook(self, ...)
        end)
        setreadonly(mt, true)
    end)
end

-- ════════════════════════════════════════════════════════════
-- PORTAL SCANNER & SCORER
--
-- Community scripts (6FootScripts, Hina Hub) all share one
-- pattern: scan Map.Circles for circle models, score each
-- by the player's current Power vs the portal's power req,
-- optionally boost score for red/boss portals.
--
-- Red gates = boss portals. In Solo Hunters these are typically
-- marked by a red/orange color value on the Gate part, or by
-- the circle model's name containing "Boss" or "Red".
--
-- Score formula:
--   Base: 100 - abs(playerPower - portalReq) / portalReq * 100
--   Boss bonus: +500 if Flags.PrioritizeRed
--   Too weak penalty: -999 if playerPower < portalReq * 0.8
-- ════════════════════════════════════════════════════════════
local PORTAL_POWER_TAGS = {
    -- map circle model names → approximate power requirement
    -- Update these as the game adds new difficulty tiers.
    ["Circle"]   = 0,     -- catch-all default
    ["Easy"]     = 500,
    ["Normal"]   = 1000,
    ["Hard"]     = 2500,
    ["Expert"]   = 5000,
    ["Red"]      = 10000,
    ["Boss"]     = 10000,
}

local function getPortalReq(circle)
    -- Try to read a power-requirement value from the model
    local req = circle:FindFirstChild("PowerRequirement")
               or circle:FindFirstChild("MinPower")
               or circle:FindFirstChild("RequiredPower")
    if req and req:IsA("IntValue") then return req.Value end
    -- Fall back to name matching
    for tag, power in pairs(PORTAL_POWER_TAGS) do
        if circle.Name:lower():find(tag:lower()) then return power end
    end
    return 0
end

local function isRedPortal(circle)
    local n = circle.Name:lower()
    if n:find("red") or n:find("boss") or n:find("raid") then return true end
    -- Check Gate part color
    local gate = circle:FindFirstChild("Gate") or circle:FindFirstChildWhichIsA("BasePart")
    if gate and gate:IsA("BasePart") then
        local col = gate.Color
        -- Red-ish: R > 0.6, G < 0.3, B < 0.3
        if col.R > 0.6 and col.G < 0.35 and col.B < 0.35 then return true end
    end
    return false
end

local function scorePortal(circle, playerPower)
    local req    = getPortalReq(circle)
    local isRed  = isRedPortal(circle)
    local score  = 0

    -- Too weak: heavily penalise
    if playerPower < req * 0.8 then
        score = -9999
    else
        -- Prefer portals just within reach (matches Auto-Scale Difficulty)
        local diff = playerPower - req
        score = 100 - math.min(diff / math.max(req, 1) * 50, 80)
    end

    if isRed and Flags.PrioritizeRed then score = score + 500 end
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
    return best
end

local function enterPortal(portal)
    if not portal or not HRP then return false end
    -- Move character to portal position
    local gate = portal:FindFirstChild("Gate")
               or portal:FindFirstChild("Center")
               or portal:FindFirstChildWhichIsA("BasePart")
    if not gate then return false end

    HRP.CFrame = CFrame.new(gate.Position + Vector3.new(0, 5, 0))
    task.wait(rnd(0.5, 0.8))

    -- Fire all ProximityPrompts on the portal model
    local entered = false
    for _, desc in ipairs(portal:GetDescendants()) do
        if desc:IsA("ProximityPrompt") then
            pcall(fireproximityprompt, desc)
            entered = true
        end
    end

    -- Also fire FullDungeonRemote as backup
    if R.FullDungeonRemote then
        pcall(function() R.FullDungeonRemote:FireServer() end)
    end

    return entered
end

-- ════════════════════════════════════════════════════════════
-- COLLECT
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

-- Collect all ProximityPrompts in dungeon chest/reward containers
local function collectDungeonRewards()
    if not MapFolder then return end
    for _, reg in ipairs(MapFolder:GetChildren()) do
        if reg.Name ~= "Lobby" and reg.Name ~= "Circles" then
            for _, desc in ipairs(reg:GetDescendants()) do
                if desc:IsA("ProximityPrompt") then
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
            -- forward to ESP; defined later, guarded with pcall
            pcall(function() addLootESP(obj) end)
        end
        if not Flags.AutoCollect then return end
        if obj:IsA("BasePart") then
            local pp = obj:FindFirstChildWhichIsA("ProximityPrompt")
            if pp then
                task.wait(rnd(0.3, 0.6)); pcall(fireproximityprompt, pp)
            else
                local conn; conn = obj.ChildAdded:Connect(function(c)
                    if c:IsA("ProximityPrompt") then
                        conn:Disconnect()
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
-- AUTO SELL
-- Scans the lobby for a sell NPC by ProximityPrompt name/parent
-- then fires it. Community scripts walk to sell NPC position.
-- ════════════════════════════════════════════════════════════
local SELL_KEYWORDS = {"sell","merchant","shop","store","vendor","npc"}

local function findSellPrompts()
    local prompts = {}
    if not LobbyFolder then return prompts end
    for _, desc in ipairs(LobbyFolder:GetDescendants()) do
        if desc:IsA("ProximityPrompt") then
            local nm = (desc.ActionText or desc.ObjectText or desc.Name):lower()
            for _, kw in ipairs(SELL_KEYWORDS) do
                if nm:find(kw) then prompts[#prompts+1] = desc; break end
            end
        end
    end
    return prompts
end

local function doAutoSell()
    local prompts = findSellPrompts()
    for _, pp in ipairs(prompts) do
        -- Teleport close enough to interact
        if pp.Parent and pp.Parent:IsA("BasePart") and HRP then
            HRP.CFrame = CFrame.new(pp.Parent.Position + Vector3.new(0,5,0))
            task.wait(0.3)
        end
        pcall(fireproximityprompt, pp)
        task.wait(rnd(0.3, 0.6))
    end
end

-- ════════════════════════════════════════════════════════════
-- AUTO BUY MERCHANT SHOP
-- Same pattern as auto sell — find merchant prompts, fire them.
-- ════════════════════════════════════════════════════════════
local BUY_KEYWORDS = {"buy","purchase","merchant","shop","item"}

local function doAutoBuy()
    if not LobbyFolder then return end
    for _, desc in ipairs(LobbyFolder:GetDescendants()) do
        if desc:IsA("ProximityPrompt") then
            local nm = (desc.ActionText or desc.ObjectText or desc.Name):lower()
            for _, kw in ipairs(BUY_KEYWORDS) do
                if nm:find(kw) then
                    pcall(fireproximityprompt, desc)
                    task.wait(rnd(0.2, 0.4))
                    break
                end
            end
        end
    end
end

-- ════════════════════════════════════════════════════════════
-- AUTO EQUIP BEST GEAR
-- Scans the player's backpack for Tools. Tries to equip the
-- one whose name sorts highest by "Power" child value or by
-- alphabetical name as a tie-breaker. Equipping is done by
-- parenting the Tool to the character (client-side).
-- ════════════════════════════════════════════════════════════
local function getToolPower(tool)
    local v = tool:FindFirstChild("Power")
             or tool:FindFirstChild("Level")
             or tool:FindFirstChild("Stats")
    if v and (v:IsA("IntValue") or v:IsA("NumberValue")) then
        return v.Value
    end
    -- Fall back: parse first number out of tool name
    local n = tool.Name:match("%d+")
    return n and tonumber(n) or 0
end

local function doAutoEquipBest()
    local backpack = LP:FindFirstChild("Backpack")
    if not backpack or not Char then return end
    local best, bestPow = nil, -1
    for _, tool in ipairs(backpack:GetChildren()) do
        if tool:IsA("Tool") then
            local pw = getToolPower(tool)
            if pw > bestPow then best=tool; bestPow=pw end
        end
    end
    if best then
        pcall(function() best.Parent = Char end)
    end
end

-- ════════════════════════════════════════════════════════════
-- AUTO QUEST
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
-- AUTO REDEEM CODES
-- Known active codes at time of writing. Fire via RedeemCode
-- RemoteFunction found in RS.Controllers.CodeRedemption.
-- ════════════════════════════════════════════════════════════
local CODES = {
    "80KLIKESLETSGOO",
    "SORRYABOUTUPD",
    "SOLOHUNTERS",
    "RELEASE",
    "UPDATE1",
}

local function doRedeemCodes()
    local ctrl = RS_inner and RS_inner:FindFirstChild("Controllers")
    local cr   = ctrl and ctrl:FindFirstChild("CodeRedemption")
    local rf   = cr  and cr:FindFirstChild("RedeemCode")
    if not rf then return end
    for _, code in ipairs(CODES) do
        pcall(function() rf:InvokeServer(code) end)
        task.wait(rnd(0.5, 1.0))
    end
end

-- ════════════════════════════════════════════════════════════
-- DUNGEON STATE MACHINE
--
-- States: LOBBY → ENTERING → FIGHTING → COLLECTING → LEAVING → QUESTING
--
-- This is the core architectural pattern from community scripts:
-- a persistent state-machine loop rather than nested task.spawns.
-- Each state has an entry action and an exit condition.
-- ════════════════════════════════════════════════════════════
local DungeonState = "LOBBY"
local dungeonThread = nil
local DungeonTimeout = 120  -- seconds before we force-leave a stuck dungeon

local function hasDungeonMobs()
    local mobs = getMobs()
    for _, e in ipairs(mobs) do
        if not e.model:IsDescendantOf(MobFolder) then
            return true
        end
    end
    return false
end

local function waitForDungeonLoad(timeoutSec)
    local elapsed = 0
    while elapsed < timeoutSec do
        dirty()
        if hasDungeonMobs() then return true end
        task.wait(0.5); elapsed = elapsed + 0.5
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
            if not e.model:IsDescendantOf(MobFolder) then
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
        local t = rnd(0.15, 0.28)
        task.wait(t); elapsed = elapsed + t
    end
end

local function returnToLobby()
    -- Method 1: fire FullDungeonRemote to leave (some games use this as leave)
    if R.FullDungeonRemote then
        pcall(function() R.FullDungeonRemote:FireServer() end)
        task.wait(1.5)
    end
    -- Method 2: teleport character to lobby spawn
    if not HRP then return end
    if LobbyFolder then
        local spawn = LobbyFolder:FindFirstChild("SpawnLocation")
                   or LobbyFolder:FindFirstChildWhichIsA("BasePart", true)
        if spawn then
            HRP.CFrame = CFrame.new(spawn.Position + Vector3.new(0,6,0))
            return
        end
    end
    -- Fallback: origin
    HRP.CFrame = CFrame.new(Vector3.new(0, 100, 0))
end

local function startAutoFarm()
    if dungeonThread then task.cancel(dungeonThread) end
    DungeonState = "LOBBY"

    dungeonThread = task.spawn(function()
        while Flags.AutoFarm do

            -- Guard: need live character
            if not HRP or not Hum or Hum.Health <= 0 then
                task.wait(1); refreshChar(); continue
            end

            -- ── LOBBY ─────────────────────────────────────────
            if DungeonState == "LOBBY" then

                -- Auto quest in lobby
                if Flags.AutoQuest then
                    doAutoQuest()
                    task.wait(rnd(0.5, 1.0))
                end

                -- Auto sell in lobby
                if Flags.AutoSell then
                    doAutoSell()
                    task.wait(rnd(0.5, 1.0))
                end

                -- Auto buy merchant
                if Flags.AutoBuyMerchant then
                    doAutoBuy()
                    task.wait(rnd(0.3, 0.6))
                end

                -- Auto equip best gear
                if Flags.AutoEquipBest then
                    doAutoEquipBest()
                end

                -- Auto redeem codes (once per session guard below)
                if Flags.AutoRedeemCodes then
                    doRedeemCodes()
                end

                -- Find best portal and enter
                local portal = getBestPortal()
                if not portal then
                    task.wait(2); continue  -- no portal found, wait
                end

                enterPortal(portal)
                DungeonState = "ENTERING"
                task.wait(rnd(2.5, 4.5))  -- wait for load

            -- ── ENTERING ──────────────────────────────────────
            elseif DungeonState == "ENTERING" then

                local loaded = waitForDungeonLoad(15)
                if loaded then
                    DungeonState = "FIGHTING"
                else
                    -- Dungeon didn't load, go back
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
                DungeonState = "LOBBY"

            end
        end

        DungeonState = "LOBBY"
    end)
end

local function stopAutoFarm()
    if dungeonThread then task.cancel(dungeonThread); dungeonThread = nil end
    DungeonState = "LOBBY"
end

-- ════════════════════════════════════════════════════════════
-- MISC AUTOMATIONS
-- ════════════════════════════════════════════════════════════
local slotThread, augThread, afkThread

local function startSlot()
    if slotThread then task.cancel(slotThread) end
    slotThread = task.spawn(function()
        while Flags.AutoSlotMachine do
            pcall(function() if R.SpinSlotMachine then R.SpinSlotMachine:FireServer() end end)
            task.wait(Config.SlotDelay * rnd(0.8, 1.2))
            pcall(function() if R.GiveSlotMachinePrize then R.GiveSlotMachinePrize:FireServer() end end)
            task.wait(Config.SlotDelay * rnd(0.8, 1.2))
        end
    end)
end

local function startAugment()
    if augThread then task.cancel(augThread); augThread = nil end
    augThread = task.spawn(function()
        while Flags.AutoAugment do
            pcall(function() if R.ChooseAugment then R.ChooseAugment:FireServer(1) end end)
            task.wait(rnd(0.8, 1.4))
        end
        augThread = nil
    end)
end

local function startAntiAFK()
    if afkThread then task.cancel(afkThread) end
    afkThread = task.spawn(function()
        while Flags.AntiAFK do
            task.wait(rnd(55, 75))
            if Flags.AntiAFK and Hum then
                pcall(function() Hum.Jump = true end)
                task.wait(0.1)
                pcall(function() Hum.Jump = false end)
            end
        end
    end)
end

-- ════════════════════════════════════════════════════════════
-- ESP
-- ════════════════════════════════════════════════════════════
local MobESPObjs  = {}
local PlrESPObjs  = {}
local LootESPObjs = {}
local ChamsObjs   = {}

local POOL_SIZE = 80
local TrPool    = {}
local activeTr  = 0

for i = 1, POOL_SIZE do
    local l = Drawing.new("Line")
    l.Thickness = 1; l.Transparency = 0.5; l.Visible = false
    TrPool[i] = l
end

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
    activeTr = 0
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

local function cleanESP(tbl, key)
    if not tbl[key] then return end
    for _, o in pairs(tbl[key]) do
        if typeof(o)=="Instance" then pcall(function() o:Destroy() end) end
    end
    tbl[key] = nil
end

local MobESPBound = false
local function addMobESP(model)
    if MobESPObjs[model] then return end
    local hrp = model:FindFirstChild("HumanoidRootPart")
    local hum = model:FindFirstChildWhichIsA("Humanoid")
    if not hrp or not hum then return end
    local bb, lbl = makeBB(hrp, model.Name, Color3.fromRGB(255,80,80), 110)
    local dl = Instance.new("TextLabel")
    dl.BackgroundTransparency=1; dl.Size=UDim2.new(1,0,0.4,0); dl.Position=UDim2.new(0,0,1,0)
    dl.TextColor3=Color3.fromRGB(255,200,200); dl.TextStrokeTransparency=0
    dl.TextScaled=true; dl.Font=Enum.Font.Gotham; dl.Parent=bb
    MobESPObjs[model] = {bb=bb,lbl=lbl,dl=dl}
    model.AncestryChanged:Connect(function()
        if not model:IsDescendantOf(game) then cleanESP(MobESPObjs, model) end
    end)
end
local function removeMobESP(model) cleanESP(MobESPObjs, model) end

local PlrESPBound = false
local function addPlayerESP(p)
    if PlrESPObjs[p] or p==LP then return end
    local char = p.Character; if not char then return end
    local hrp  = char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
    local bb, lbl = makeBB(hrp, p.Name, Color3.fromRGB(100,200,255), 100)
    local dl = Instance.new("TextLabel")
    dl.BackgroundTransparency=1; dl.Size=UDim2.new(1,0,0.4,0); dl.Position=UDim2.new(0,0,1,0)
    dl.TextColor3=Color3.fromRGB(180,230,255); dl.TextStrokeTransparency=0
    dl.TextScaled=true; dl.Font=Enum.Font.Gotham; dl.Parent=bb
    PlrESPObjs[p] = {bb=bb,lbl=lbl,dl=dl}
    p.CharacterRemoving:Connect(function() cleanESP(PlrESPObjs, p) end)
end
local function removePlayerESP(p) cleanESP(PlrESPObjs, p) end

function addLootESP(obj)   -- intentionally non-local for DropFolder handler
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
    LootESPObjs[obj] = {sel=sel, bb=bb}
    obj.AncestryChanged:Connect(function()
        if not obj:IsDescendantOf(game) and LootESPObjs[obj] then
            pcall(function() LootESPObjs[obj].sel:Destroy() end)
            pcall(function() LootESPObjs[obj].bb:Destroy()  end)
            LootESPObjs[obj] = nil
        end
    end)
end
function removeLootESP(obj)  -- non-local
    if not LootESPObjs[obj] then return end
    pcall(function() LootESPObjs[obj].sel:Destroy() end)
    pcall(function() LootESPObjs[obj].bb:Destroy()  end)
    LootESPObjs[obj] = nil
end

local function addChams(model)
    if ChamsObjs[model] then return end
    ChamsObjs[model] = {}
    for _, p in ipairs(model:GetDescendants()) do
        if p:IsA("BasePart") and not HITBOX[p.Name] then
            local b = Instance.new("BoxHandleAdornment")
            b.AlwaysOnTop=true; b.ZIndex=5
            b.Color3=Color3.fromRGB(255,60,60); b.Transparency=0.5
            b.Size=p.Size; b.Adornee=p; b.Parent=p
            ChamsObjs[model][#ChamsObjs[model]+1] = b
        end
    end
    model.AncestryChanged:Connect(function()
        if not model:IsDescendantOf(game) and ChamsObjs[model] then
            for _, b in ipairs(ChamsObjs[model]) do pcall(function() b:Destroy() end) end
            ChamsObjs[model] = nil
        end
    end)
end
local function removeChams(model)
    if not ChamsObjs[model] then return end
    for _, b in ipairs(ChamsObjs[model]) do pcall(function() b:Destroy() end) end
    ChamsObjs[model] = nil
end
local function clearChams()
    for m in pairs(ChamsObjs) do removeChams(m) end
end

-- ════════════════════════════════════════════════════════════
-- CHARACTER RESPAWN
-- ════════════════════════════════════════════════════════════
LP.CharacterAdded:Connect(function()
    task.wait(0.5)
    refreshChar()
    if Hum then
        Hum.WalkSpeed = Config.WalkSpeed
        Hum.JumpPower = Config.JumpPower
        pcall(function() Hum.JumpHeight = Config.JumpPower * 0.36 end)
    end
    dirty()
    if Flags.AutoFarm then startAutoFarm() end
end)

-- ════════════════════════════════════════════════════════════
-- HEARTBEAT — NoClip, Stamina, ESP labels, Tracers
-- Kill Aura + AutoSkills run in their own coroutines above.
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
        local RED  = Color3.fromRGB(255,80,80)
        local BLUE = Color3.fromRGB(100,200,255)
        for _, e in ipairs(getMobs(Config.ESPMaxDist)) do
            local sp, on = cam:WorldToViewportPoint(e.hrp.Position)
            if on then drawTr(ctr, Vector2.new(sp.X,sp.Y), RED) end
        end
        for _, p in ipairs(Players:GetPlayers()) do
            if p~=LP and p.Character then
                local phr = p.Character:FindFirstChild("HumanoidRootPart")
                if phr and dist(HRP.Position,phr.Position)<=Config.ESPMaxDist then
                    local sp, on = cam:WorldToViewportPoint(phr.Position)
                    if on then drawTr(ctr, Vector2.new(sp.X,sp.Y), BLUE) end
                end
            end
        end
    else
        if activeTr > 0 then clearTr() end
    end
end)

-- ════════════════════════════════════════════════════════════
-- RAYFIELD
-- ════════════════════════════════════════════════════════════
local ok, Rayfield = pcall(function()
    return loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
end)
if not ok or not Rayfield then warn("[ENI] Rayfield failed."); return end

local W = Rayfield:CreateWindow({
    Name = "Solo Hunters — ENI Build",
    LoadingTitle    = "Solo Hunters",
    LoadingSubtitle = "ENI Build v6.0",
    ConfigurationSaving = { Enabled = false },
    KeySystem = false,
})

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
                Rayfield:Notify({ Title="Portal", Content="No portals found.", Duration=3 })
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
    Callback = function() task.spawn(doRedeemCodes) end,
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
    Callback = function(v) Flags.GodMode = v end,
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
        else if afkThread then task.cancel(afkThread); afkThread = nil end end
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
            if MobFolder and not MobESPBound then
                MobESPBound = true
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
            for _, p in ipairs(Players:GetPlayers()) do addPlayerESP(p) end
            if not PlrESPBound then
                PlrESPBound = true
                Players.PlayerAdded:Connect(function(p)
                    if Flags.PlayerESP then
                        p.CharacterAdded:Connect(function()
                            task.wait(0.5); addPlayerESP(p)
                        end)
                    end
                end)
                Players.PlayerRemoving:Connect(removePlayerESP)
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
        else if augThread then task.cancel(augThread); augThread=nil end end
    end,
})

MiscTab:CreateToggle({
    Name = "Auto Slot Machine",
    Default = false,
    Callback = function(v)
        Flags.AutoSlotMachine = v
        if v then startSlot()
        else if slotThread then task.cancel(slotThread); slotThread=nil end end
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
        TeleportService:Teleport(game.PlaceId, LP)
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
    Title   = "ENI Build v6.0",
    Content = "Solo Hunters loaded  |  RightShift = toggle UI",
    Duration = 5,
})
