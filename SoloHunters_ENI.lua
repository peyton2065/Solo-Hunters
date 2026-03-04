--[[
    ╔══════════════════════════════════════════════════════════╗
    ║          SOLO HUNTERS — ENI BUILD  v6.4                  ║
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

    BUGFIXES RETAINED FROM v6.0 AUDIT:
      ✓ Kill Aura: single persistent coroutine, no thread storm
      ✓ hpAtCheckpoint = current HP, not MaxHealth
      ✓ Currency path: MainUIController under RS.Controllers
      ✓ refreshCharacter: charConns flushed per respawn
      ✓ getNearestMob: redundant distance re-check removed
      ✓ JumpPower: writes both JumpPower + JumpHeight
      ✓ Plain Part drops: deferred ProximityPrompt listener
      ✓ Drawing pool: destroyPool() on rejoin
      ✓ DropFolder nil: diagnostic warn

    ═══════════════════════════════════════════════════════════
    CHANGELOG v6.0 → v6.1  (ENI audit pass)
    ═══════════════════════════════════════════════════════════

    FIX 1 — [CRITICAL] Flags.AutoScaleDiff was declared, exposed
      in UI, but never read by scorePortal(). The toggle did
      nothing. scorePortal() now wraps its power-scaling logic
      in `if Flags.AutoScaleDiff` and falls back to a flat score
      of 75 when the flag is off, making the toggle functional.

    FIX 2 — [CRITICAL] doRedeemCodes() fired every single LOBBY
      iteration when AutoRedeemCodes was enabled. The "once per
      session guard" mentioned in the comment was never written.
      Added `codesRedeemedThisSession` boolean; doRedeemCodes()
      now only executes once per script load, and "Redeem Codes
      Now" button resets the guard so manual re-fire still works.

    FIX 3 — [CRITICAL] getBestPortal() returned a portal even
      when ALL portals were heavily penalized (score = -9999),
      because bestScore initialized to -math.huge. The farm loop
      would then try to enter a portal the player cannot clear,
      looping forever. Added a score floor: returns nil when
      bestScore < -500 (all portals out of reach).

    FIX 4 — [IMPORTANT] QUESTING state was listed in the
      architecture header and the DungeonState variable but had
      no corresponding branch in the state machine. Quest actions
      were crammed into LOBBY passively. Added a proper QUESTING
      state entered after LEAVING: teleports to QuestGiver,
      calls doAutoQuest(), then advances to LOBBY.

    FIX 5 — [IMPORTANT] SELL_KEYWORDS and BUY_KEYWORDS shared
      "merchant" and "shop". When both AutoSell and AutoBuyMerchant
      were active, any matching prompt fired twice in rapid
      succession. BUY_KEYWORDS now uses exclusive terms only:
      {"buy","purchase","item","trade"}.

    FIX 6 — [IMPORTANT] killAllDungeonMobs() accumulated elapsed
      time using the *requested* wait value (t), not the *actual*
      delta returned by task.wait(). Under load, task.wait()
      overshoots; using the requested value caused DungeonTimeout
      to undercount real elapsed time, effectively making the
      timeout longer than configured. Now uses actual return value.

    FIX 7 — [MINOR] dl TextLabels in addMobESP() and
      addPlayerESP() had no initial .Text assignment. On the
      first Heartbeat tick (~16ms) they rendered blank before
      populating, causing a visible one-frame flash. Set to "".

    FIX 8 — [MINOR] Tracer pool POOL_SIZE was 80. At ESPMaxDist
      values above ~250 studs with many mobs, getMobs() returns
      more than 80 entries and drawTr() silently clips the rest.
      Increased to 200. Pool is now also config-driven via
      Config.TracerPoolSize so it can be adjusted without source
      edits.

    FIX 9 — [MINOR] scorePortal() with req==0 (catch-all portals)
      always resolved to score ≈ 20 due to the diff/math.max(req,1)
      formula clamping. Catch-all circles now short-circuit to a
      score of 50 (selectable fallback) and skip the power check.

    ═══════════════════════════════════════════════════════════
    CHANGELOG v6.1 → v6.2  (Xeno Executor hardening pass)
    ═══════════════════════════════════════════════════════════

    FIX 10 — [CRITICAL / XENO] Drawing pool initialized at the
      top level with no pcall protection. Under Xeno's execution
      model (script runs inside an overwritten CoreGui corescript),
      any unhandled top-level error surfaces as a "CoreGui.XXX"
      error message. If Drawing has a timing hiccup on injection,
      the 200-object loop would throw and kill the entire script
      before Rayfield even loads. The pool init is now wrapped in
      pcall with a graceful fallback: Drawing disabled, Tracers
      flag forced false, and a warn() so the user knows why.

    FIX 11 — [IMPORTANT / XENO] No double-load guard. Re-executing
      the script stacked a second Heartbeat listener, a second Kill
      Aura coroutine, and 200 additional Drawing objects on top of
      the existing ones. Added getgenv().ENI_LOADED guard at the
      very top: second execution returns immediately after printing
      a notice, preventing all resource duplication.

    ═══════════════════════════════════════════════════════════
    CHANGELOG v6.2 → v6.3  (God Mode remediation pass)
    ═══════════════════════════════════════════════════════════

    FIX 12 — [CRITICAL] God Mode primary mechanism was structurally
      incapable of blocking damage. The __namecall hook intercepts
      client-side Lua method invocations only. Solo Hunters applies
      damage server-side; health decrements arrive on the client as
      raw property replication, not as method calls. The hook never
      fires for server damage regardless of correctness. Fixed by
      adding a Heartbeat health floor as the primary defense layer:
      every ~100ms, if GodMode is active and Hum.Health < MaxHealth,
      Health is restored to MaxHealth. This races against incoming
      replication at 10Hz and wins consistently. The namecall hook
      is retained as a secondary layer for any client-side calls.

    FIX 13 — [CRITICAL] __namecall hook only intercepted "TakeDamage".
      Humanoid:BreakJoints() and Humanoid:Kill() are independent kill
      pathways that bypass Health entirely. Both are now caught by the
      hook when self==Hum and Flags.GodMode is true.

    FIX 14 — [IMPORTANT] Hook installation was wrapped in a single
      pcall with no error capture or post-install validation. If
      setreadonly() or hookmetamethod() threw, namecallHook remained
      nil and the hook was silently absent while the UI showed god
      mode as active. Fixed: setreadonly(mt, true) is now wrapped in
      its own separate pcall to prevent a re-lock failure from
      poisoning the assignment. namecallHook is validated after the
      pcall block; if nil, a warn() is emitted so the user knows the
      hook layer is absent (Heartbeat floor remains active regardless).

    FIX 15 — [IMPORTANT] Stale Hum upvalue during the 500ms respawn
      window. CharacterAdded fires, then task.wait(0.5) delays before
      refreshChar() updates Hum. Any god mode write during this window
      targeted the previous dead Humanoid. All god mode operations now
      guard with `Hum and Hum.Parent and Hum.Health > 0` before acting,
      which is falsy for destroyed instances and dead Humanoids alike.

    FIX 16 — [IMPORTANT] God Mode toggle callback only set the flag
      with no user feedback. Added Rayfield:Notify on enable that
      reports which protection layers are active ("Health loop: ON |
      Hook: active/inactive"), giving the user immediate visibility
      into whether full or degraded protection is running.

    ═══════════════════════════════════════════════════════════
    CHANGELOG v6.3 → v6.4  (Full audit pass — 16 issues)
    ═══════════════════════════════════════════════════════════

    FIX A — [CRITICAL] IsDescendantOf(MobFolder) called with nil.
      MobFolder is populated via WaitForChild with a 10s timeout;
      inside dungeon instances it may return nil. Both hasDungeonMobs()
      and killAllDungeonMobs() called model:IsDescendantOf(nil) which
      throws immediately. Added isDungeonMob() nil-safe predicate.

    FIX B — [CRITICAL] waitForDungeonLoad() used fixed-value time
      accumulation (elapsed + 0.5) identical to the FIX 6 bug in
      killAllDungeonMobs(). The 15s ENTERING timeout silently extended
      under scheduler load. Now uses actual delta from task.wait().

    FIX C — [CRITICAL] enterPortal() fired FullDungeonRemote
      unconditionally after ProximityPrompts, even on successful
      entry. This could trigger duplicate dungeon starts or charge
      the player twice. Remote now only fires as a fallback when
      entered == false (no prompts found).

    FIX D — [IMPORTANT] Leaked ChildAdded connection in deferred
      ProximityPrompt collector. If a plain Part drop was removed
      before a ProximityPrompt arrived, conn was never disconnected.
      Added paired AncestryChanged cleanup to guarantee disconnection.

    FIX E — [IMPORTANT] ESP AncestryChanged connections leaked on
      manual removal. removeMobESP/clearChams destroyed GUI objects
      but left the AncestryChanged connection alive on the model.
      ESP table entries now store their cleanup connection; cleanESP
      disconnects it alongside destroying instances.

    FIX F — [IMPORTANT] Player ESP not reattached on target respawn.
      addPlayerESP only bound CharacterRemoving (cleanup), not
      CharacterAdded (rebind). Players who died while ESP was active
      lost their label permanently. CharacterAdded rebind now added
      inside addPlayerESP for all already-present players.

    FIX G — [IMPORTANT] doAutoEquipBest() did not unequip the
      current tool before equipping the best one. Having two Tools
      simultaneously parented to the character is undefined behavior
      in Roblox. Current tool is now moved to Backpack first.

    FIX H — [IMPORTANT] No CDN fallback for Rayfield. If the primary
      sirius.menu URL failed, the script exited entirely with no UI.
      Added fallback to the GitHub raw source endpoint.

    FIX I — [IMPORTANT] TeleportService:Teleport() is deprecated.
      Replaced with TeleportService:TeleportAsync() wrapped in pcall.

    FIX J — [MINOR] getCurrencies() called FindFirstChild("Power")
      twice on MainUIController to evaluate the ternary. Cached into
      a local before comparison.

    FIX K — [MINOR] collectDungeonRewards() fired ALL ProximityPrompts
      in dungeon regions with no filter — doors, traps, NPC vendors,
      and exit prompts all triggered. Added collect-specific keyword
      filter: chest, reward, loot, open, collect, pick.

    FIX L — [MINOR] getPortalReq() used pairs() for PORTAL_POWER_TAGS
      name matching, making multi-match results non-deterministic.
      Replaced with an ordered priority array (specific → generic).

    FIX M — [MINOR] startAntiAFK() used deprecated Humanoid.Jump
      boolean setter. Replaced with Humanoid:ChangeState() using the
      Jumping HumanoidStateType enum.

    FIX N — [MINOR] Color3.fromRGB constants RED and BLUE allocated
      inside the Heartbeat slow-path on every tick. Hoisted to
      module-level constants, allocated once at script load.

    FIX O — [MINOR] safeTP() was defined but never called anywhere
      in the script. Removed as dead code.

    FIX P — [MINOR] destroyPool() did not reset drawingOk to false.
      If called outside the Rejoin flow, subsequent drawTr() calls
      would index a nil pool entry. drawingOk = false added.
]]

-- ════════════════════════════════════════════════════════════
-- SERVICES
-- ════════════════════════════════════════════════════════════

-- FIX 11: Double-load guard. Re-executing the script in Xeno
-- would stack a second Heartbeat listener, second Kill Aura
-- coroutine, and 200 more Drawing objects. This guard makes the
-- second execution bail out immediately and cleanly.
if getgenv and getgenv().ENI_SOLO_LOADED then
    print("[ENI] Already loaded — re-execution blocked. Rejoin or use the Rejoin button to reset.")
    return
end
if getgenv then getgenv().ENI_SOLO_LOADED = true end

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
    AutoScaleDiff   = true,    -- pick portal tier by Power stat (FIX 1)

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
    TracerPoolSize   = 200,    -- FIX 8: was hardcoded 80; now config-driven

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

-- FIX O: safeTP() was defined here but never called anywhere in the script.
-- Removed as dead code (v6.4).

-- ════════════════════════════════════════════════════════════
-- CURRENCY
-- ════════════════════════════════════════════════════════════
local function getCurrencies()
    local ctrl = RS_inner and RS_inner:FindFirstChild("Controllers")
    local mui  = ctrl and ctrl:FindFirstChild("MainUIController")
    local ls   = LP:FindFirstChild("leaderstats")
    local function v(p,n) local x=p and p:FindFirstChild(n); return x and x.Value or 0 end
    -- FIX J: cache Power once to avoid two FindFirstChild traversals per call
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
-- GOD MODE — three-layer implementation
--
-- Layer 1 (Primary): Heartbeat health floor — see Heartbeat section.
--   Restores Hum.Health to MaxHealth every ~100ms. Catches all damage
--   pathways including server-replicated property writes, which the
--   namecall hook cannot intercept. Executor-agnostic; no special APIs.
--
-- Layer 2 (Secondary): __namecall hook — intercepts client-side
--   TakeDamage, BreakJoints, and Kill calls on the local Humanoid.
--   Install-once at load time; flag-gated, not start/stop.
--   NOTE: this layer is silent against server-side damage. Layer 1
--   is the real workhorse. Layer 2 adds defense-in-depth for any
--   local invocation paths the game may use.
--
-- Layer 3 (UX): Rayfield:Notify on toggle-on reports which layers
--   are active, so the user knows immediately if hook install failed.
-- ════════════════════════════════════════════════════════════

-- FIX 14: namecallHook validated after install; setreadonly re-lock
-- is in its own pcall so a re-lock failure can't poison the assignment.
local namecallHook
local godHookActive = false

if hookmetamethod and getrawmetatable then
    pcall(function()
        local mt = getrawmetatable(game)
        setreadonly(mt, false)

        namecallHook = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            -- FIX 13: intercept TakeDamage AND BreakJoints AND Kill.
            -- FIX 15: guard self==Hum with Hum.Parent check so a stale
            -- upvalue from the respawn window never matches a live call.
            if Flags.GodMode and Hum and Hum.Parent
               and self == Hum
               and (method == "TakeDamage" or method == "BreakJoints" or method == "Kill") then
                return  -- swallow the call; Layer 1 health floor handles restoration
            end
            return namecallHook(self, ...)
        end)

        -- FIX 14: re-lock in its own pcall — a failure here must not
        -- prevent namecallHook from being assigned above.
        pcall(function() setreadonly(mt, true) end)
    end)

    -- FIX 14: post-install validation with diagnostic warn if absent.
    if namecallHook then
        godHookActive = true
    else
        warn("[ENI] GodMode: namecall hook failed to install — " ..
             "TakeDamage/BreakJoints/Kill interception inactive. " ..
             "Heartbeat health floor remains active.")
    end
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
-- Score formula (when AutoScaleDiff = true):
--   Base: 100 - abs(playerPower - portalReq) / portalReq * 50
--   Boss bonus: +500 if Flags.PrioritizeRed
--   Too weak penalty: -9999 if playerPower < portalReq * 0.8
--   Catch-all (req==0): flat 50 — always selectable fallback (FIX 9)
--
-- Score formula (when AutoScaleDiff = false):  (FIX 1)
--   All portals score a flat 75 (boss bonus still applies if
--   PrioritizeRed is on). Player power is ignored entirely.
-- ════════════════════════════════════════════════════════════
-- FIX L: ordered priority tag list for portal requirement lookup.
-- pairs() iteration is non-deterministic; a portal whose name matches
-- multiple tags (e.g. "Red Boss Circle") would return an arbitrary power
-- value. This ordered array checks specific tags first, generic last.
local PORTAL_POWER_TAGS_ORDERED = {
    { tag = "boss",   power = 10000 },
    { tag = "red",    power = 10000 },
    { tag = "raid",   power = 10000 },
    { tag = "expert", power = 5000  },
    { tag = "hard",   power = 2500  },
    { tag = "normal", power = 1000  },
    { tag = "easy",   power = 500   },
    { tag = "circle", power = 0     },  -- catch-all last
}

local function getPortalReq(circle)
    -- Try to read a power-requirement value from the model first
    local req = circle:FindFirstChild("PowerRequirement")
               or circle:FindFirstChild("MinPower")
               or circle:FindFirstChild("RequiredPower")
    if req and req:IsA("IntValue") then return req.Value end
    -- FIX L: ordered priority list — specific tags checked before generic ones
    local nameLower = circle.Name:lower()
    for _, entry in ipairs(PORTAL_POWER_TAGS_ORDERED) do
        if nameLower:find(entry.tag) then return entry.power end
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

    -- FIX 9: catch-all portals (req == 0) skip power check entirely.
    -- They score a flat 50 — always reachable fallback.
    if req == 0 then
        score = 50
    -- FIX 1: only apply power-scaling logic when AutoScaleDiff is enabled.
    elseif Flags.AutoScaleDiff then
        -- Too weak: heavily penalise
        if playerPower < req * 0.8 then
            score = -9999
        else
            -- Prefer portals just within reach
            local diff = playerPower - req
            score = 100 - math.min(diff / math.max(req, 1) * 50, 80)
        end
    else
        -- AutoScaleDiff off: ignore power entirely, flat score for all portals
        score = 75
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

    -- FIX 3: if every portal scored below the penalty floor, the player
    -- is too weak for all of them. Return nil so the farm loop waits
    -- instead of hammering an unenterable portal repeatedly.
    if bestScore < -500 then return nil end

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

    -- FIX C: only fire FullDungeonRemote as a fallback when no proximity
    -- prompts were found. Firing it alongside prompts could trigger a
    -- duplicate dungeon start or charge the player twice.
    if not entered and R.FullDungeonRemote then
        pcall(function() R.FullDungeonRemote:FireServer() end)
        entered = true
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

-- FIX K: keyword filter for dungeon reward collection.
-- Without this, every ProximityPrompt in every dungeon region fires —
-- including doors, traps, NPC vendors, and exit prompts.
local COLLECT_KEYWORDS = {"chest","reward","loot","open","collect","pick"}
local function isCollectPrompt(pp)
    local nm = (pp.ActionText or pp.ObjectText or pp.Name):lower()
    for _, kw in ipairs(COLLECT_KEYWORDS) do
        if nm:find(kw) then return true end
    end
    return false
end

-- Collect all ProximityPrompts in dungeon chest/reward containers
local function collectDungeonRewards()
    if not MapFolder then return end
    for _, reg in ipairs(MapFolder:GetChildren()) do
        if reg.Name ~= "Lobby" and reg.Name ~= "Circles" then
            for _, desc in ipairs(reg:GetDescendants()) do
                -- FIX K: only fire prompts matching collect keywords
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
            -- forward to ESP; defined later, guarded with pcall
            pcall(function() addLootESP(obj) end)
        end
        if not Flags.AutoCollect then return end
        if obj:IsA("BasePart") then
            local pp = obj:FindFirstChildWhichIsA("ProximityPrompt")
            if pp then
                task.wait(rnd(0.3, 0.6)); pcall(fireproximityprompt, pp)
            else
                -- FIX D: paired AncestryChanged connection guarantees cleanup
                -- if the part is removed before a ProximityPrompt ever arrives.
                -- Previously conn was never disconnected in that case, leaking
                -- both the connection and its closure indefinitely.
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
-- FIX 5: BUY_KEYWORDS now uses exclusive terms only ("buy",
-- "purchase", "item", "trade"). Removed "merchant" and "shop"
-- which were shared with SELL_KEYWORDS, causing double-fires
-- when both AutoSell and AutoBuyMerchant were active.
-- ════════════════════════════════════════════════════════════
local BUY_KEYWORDS = {"buy","purchase","item","trade"}

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
        -- FIX G: unequip any currently held tool before equipping the new one.
        -- Having two Tools simultaneously parented to the character is undefined
        -- behavior in Roblox and causes animation / tool-slot state corruption.
        for _, item in ipairs(Char:GetChildren()) do
            if item:IsA("Tool") then
                pcall(function() item.Parent = backpack end)
            end
        end
        task.wait(0.05)
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
--
-- FIX 2: Added codesRedeemedThisSession guard. The original
-- doRedeemCodes() was called every LOBBY iteration with no
-- guard, causing it to fire every few seconds indefinitely.
-- The flag resets only when the user presses "Redeem Codes Now"
-- manually, so deliberate re-fires are still possible.
-- ════════════════════════════════════════════════════════════
local CODES = {
    "80KLIKESLETSGOO",
    "SORRYABOUTUPD",
    "SOLOHUNTERS",
    "RELEASE",
    "UPDATE1",
}

local codesRedeemedThisSession = false  -- FIX 2: session guard

local function doRedeemCodes(forceRetry)
    -- forceRetry = true allows the manual button to bypass the guard
    if codesRedeemedThisSession and not forceRetry then return end
    local ctrl = RS_inner and RS_inner:FindFirstChild("Controllers")
    local cr   = ctrl and ctrl:FindFirstChild("CodeRedemption")
    local rf   = cr  and cr:FindFirstChild("RedeemCode")
    if not rf then return end
    for _, code in ipairs(CODES) do
        pcall(function() rf:InvokeServer(code) end)
        task.wait(rnd(0.5, 1.0))
    end
    codesRedeemedThisSession = true  -- mark so the farm loop won't repeat
end

-- ════════════════════════════════════════════════════════════
-- DUNGEON STATE MACHINE
--
-- States: LOBBY → ENTERING → FIGHTING → COLLECTING → LEAVING → QUESTING
--
-- FIX 4: Added QUESTING state. Previously QUESTING was listed
-- in the architecture header but had no corresponding branch;
-- quest calls were crammed into LOBBY. QUESTING now runs after
-- LEAVING: teleports to QuestGiver, calls doAutoQuest(), then
-- advances back to LOBBY for the next run.
-- ════════════════════════════════════════════════════════════
local DungeonState = "LOBBY"
local dungeonThread = nil
local DungeonTimeout = 120  -- seconds before we force-leave a stuck dungeon

-- FIX A: nil-safe predicate for distinguishing dungeon mobs from lobby mobs.
-- MobFolder may be nil if Workspace.Mobs doesn't exist in the dungeon instance.
-- model:IsDescendantOf(nil) throws; this predicate handles that case cleanly.
local function isDungeonMob(model)
    return not MobFolder or not model:IsDescendantOf(MobFolder)
end

local function hasDungeonMobs()
    local mobs = getMobs()
    for _, e in ipairs(mobs) do
        if isDungeonMob(e.model) then  -- FIX A
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
        -- FIX B: use actual delta from task.wait(), not the requested value.
        -- task.wait() overshoots under scheduler load; using the requested 0.5
        -- caused the 15s timeout to silently extend — identical bug to FIX 6.
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
            if isDungeonMob(e.model) then  -- FIX A: nil-safe predicate
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
        -- FIX 6: use the actual delta returned by task.wait() rather than
        -- the requested value. task.wait() can overshoot under load; using
        -- the requested value caused the timeout counter to undercount real
        -- elapsed time, making DungeonTimeout effectively longer than set.
        local actual = task.wait(rnd(0.15, 0.28))
        elapsed = elapsed + actual
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

                -- FIX 2: Auto redeem codes — guarded, fires once per session only
                if Flags.AutoRedeemCodes then
                    doRedeemCodes(false)
                end

                -- Find best portal and enter
                local portal = getBestPortal()
                if not portal then
                    task.wait(2); continue  -- no portal found or all out of reach
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
                -- FIX 4: advance to QUESTING state if AutoQuest is on,
                -- otherwise skip straight back to LOBBY.
                DungeonState = Flags.AutoQuest and "QUESTING" or "LOBBY"

            -- ── QUESTING ──────────────────────────────────────
            -- FIX 4: QUESTING state — previously missing entirely.
            -- Teleports to the quest NPC in the lobby, fires turn-in
            -- and request-new calls, then returns to LOBBY.
            elseif DungeonState == "QUESTING" then

                if HRP and LobbyFolder then
                    -- Attempt to navigate to the quest giver
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
            if Flags.AntiAFK and Hum and Hum.Parent then
                -- FIX M: Humanoid.Jump boolean setter is deprecated.
                -- Humanoid:ChangeState() with Jumping is the current API.
                pcall(function()
                    Hum:ChangeState(Enum.HumanoidStateType.Jumping)
                end)
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

-- FIX 8: pool size increased from 80 to Config.TracerPoolSize (default 200)
-- to handle high ESPMaxDist values without silently clipping entries.
-- FIX 10: wrapped in pcall. Under Xeno's CoreGui-corescript execution model,
-- an unprotected top-level Drawing error surfaces as a "CoreGui.XXX" error
-- and kills the script before Rayfield loads. If Drawing fails we disable
-- Tracers gracefully rather than crashing the entire script.
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

-- FIX N: tracer color constants hoisted to module level.
-- Previously allocated inside the Heartbeat slow-path every ~100ms.
-- Color3.fromRGB is cheap but allocation inside a hot path is wasteful.
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
    drawingOk = false  -- FIX P: reset so drawTr() doesn't index a nil pool after destroy
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
    for k, o in pairs(tbl[key]) do
        -- FIX E: disconnect stored RBXScriptConnections to prevent leaking
        -- AncestryChanged listeners when ESP is manually removed.
        if typeof(o) == "RBXScriptConnection" then
            pcall(function() o:Disconnect() end)
        elseif typeof(o) == "Instance" then
            pcall(function() o:Destroy() end)
        end
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
    dl.TextScaled=true; dl.Font=Enum.Font.Gotham
    dl.Text = ""   -- FIX 7: initialize to prevent blank flash
    dl.Parent=bb
    -- FIX E: store AncestryChanged connection in the table so cleanESP
    -- can disconnect it when ESP is manually removed, preventing leaks.
    MobESPObjs[model] = {bb=bb, lbl=lbl, dl=dl, conn=nil}
    MobESPObjs[model].conn = model.AncestryChanged:Connect(function()
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
    dl.TextScaled=true; dl.Font=Enum.Font.Gotham
    dl.Text = ""   -- FIX 7: initialize to prevent blank flash
    dl.Parent=bb
    PlrESPObjs[p] = {bb=bb, lbl=lbl, dl=dl}
    p.CharacterRemoving:Connect(function() cleanESP(PlrESPObjs, p) end)
    -- FIX F: bind CharacterAdded so ESP is recreated when the player respawns.
    -- Previously only CharacterRemoving was bound; players who died lost their
    -- ESP label permanently for the rest of the session.
    p.CharacterAdded:Connect(function()
        task.wait(0.5)
        if Flags.PlayerESP then addPlayerESP(p) end
    end)
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
    -- FIX E: store AncestryChanged connection so cleanESP can disconnect it
    ChamsObjs[model].conn = model.AncestryChanged:Connect(function()
        if not model:IsDescendantOf(game) and ChamsObjs[model] then
            for k, b in pairs(ChamsObjs[model]) do
                if typeof(b) == "Instance" then pcall(function() b:Destroy() end) end
                if typeof(b) == "RBXScriptConnection" then pcall(function() b:Disconnect() end) end
            end
            ChamsObjs[model] = nil
        end
    end)
end
local function removeChams(model)
    if not ChamsObjs[model] then return end
    for k, b in pairs(ChamsObjs[model]) do
        if typeof(b) == "Instance" then pcall(function() b:Destroy() end) end
        if typeof(b) == "RBXScriptConnection" then pcall(function() b:Disconnect() end) end
    end
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

    -- FIX 12 (Layer 1): Heartbeat health floor — primary god mode defense.
    -- Restores health to MaxHealth every ~100ms. Catches server-replicated
    -- damage that the __namecall hook cannot see (property writes bypass it).
    -- FIX 15: guarded with Hum.Parent so stale upvalue during the 500ms
    -- respawn window never attempts to write to a destroyed Humanoid.
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
        -- FIX N: use module-level constants instead of allocating per tick
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
-- RAYFIELD
-- ════════════════════════════════════════════════════════════
-- FIX H: fallback CDN if the primary Rayfield URL is unreachable.
-- CDN outages, DNS failures, or HttpService domain blocks all caused
-- the script to exit entirely with no UI. The GitHub raw source is
-- the canonical backup maintained by the Rayfield developers.
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
if not ok or not Rayfield then warn("[ENI] Rayfield failed — all endpoints exhausted."); return end

local W = Rayfield:CreateWindow({
    Name = "Solo Hunters — ENI Build",
    LoadingTitle    = "Solo Hunters",
    LoadingSubtitle = "ENI Build v6.4",
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
    -- FIX 2: manual button resets the session guard so the user can
    -- force a re-fire without reloading the entire script.
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
        -- FIX 16: notify on enable so the user knows which protection
        -- layers are actually running (hook may have failed to install).
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
        -- FIX I: TeleportService:Teleport() is deprecated. TeleportAsync is
        -- the current API. Wrapped in pcall because teleport can throw in
        -- executor contexts where the operation is restricted.
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
    Title   = "ENI Build v6.4",
    Content = "Solo Hunters loaded  |  RightShift = toggle UI",
    Duration = 5,
})
