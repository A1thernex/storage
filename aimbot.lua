local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local lp = Players.LocalPlayer
local camera = Workspace.CurrentCamera

--// Settings
local Settings = {
    Enabled = true,

    Bone = "Head", -- Head, Torso, HumanoidRootPart, or custom

    Smoothing = {
        Enabled = true,
        Method = "Lerp", -- "Lerp" "Slerp" "Exponential"
        Speed = 0.15, -- 0..1, lower = smoother/slower
    },

    FOV = {
        Enabled = true,
        Radius = 120, -- pixels
        UseRadiusFor3D = false, -- if true, use stud radius instead of screen px
        Radius3D = 80, -- stud radius for 3D mode
        CircleColor = Color3.fromRGB(255, 255, 255),
        CircleTransparency = 0.5, -- 0..1, 0 = opaque
        CircleThickness = 1,
        CircleFilled = false,
        CircleNumSides = 64,
    },

    Deadzone = {
        Enabled = false,
        Radius = 8, -- pixels from crosshair, ignore targets inside
    },

    MaxDistance = 500, -- studs
    MinDistance = 0, -- studs

    TargetPriority = "FOV", -- "Distance" "Health" "FOV" "ScreenProximity"
    StickyAim = true, -- prefer current locked target
    StickyThreshold = 1.5, -- multiplier, new target must be X times better
    OneShotLock = false, -- never switch target while alive
    AutoUnlockOnDeath = true,

    Wallbang = false, -- aim through walls
    TeamCheck = true,
    FriendCheck = false,

    SkipAirborne = false, -- skip targets that are jumping/falling
    SkipDead = true,
    RequireVisible = true, -- if false, ignores visibility
    VisibilityCheckInterval = 0.05, -- seconds between raycast checks

    Prediction = {
        Enabled = false,
        -- Predicts target position using smoothed velocity * travel time
        -- Travel time = ping * PingScale (one-way estimate from round-trip ping)
        TimeScale = 1.0, -- multiplier on computed travel time (>1 = over-lead)
        AccelerationSmoothing = 0.3, -- 0..1, smooth out target velocity changes
        PingScale = 0.5, -- fraction of round-trip ping to use as one-way travel time
    },

    TriggerBot = {
        Enabled = false,
        Radius = 4, -- pixels from crosshair to target bone
        Delay = 0.05, -- seconds between press and release
        MouseButton = "MB1", -- "MB1" "MB2" "MB3"
    },

    RefreshInterval = 0, -- seconds between full target rescans, 0 = every frame

    SilentAim = {
        Enabled = false,
        UseAimbotTarget = true, -- share aimbot locked target
        Bone = "Head", -- independent bone if UseAimbotTarget=false
        HitChance = 100, -- 0..100 percent chance to redirect

        -- prediction settings, nil = inherit from Settings.Prediction
        Prediction = {
            Enabled = nil,
            TimeScale = nil,
            AccelerationSmoothing = nil,
            PingScale = nil,
        },

        Wallbang = false, -- redirect even through walls (force include target)
        RequireVisible = true, -- only redirect if target visible
        RequireFOV = true, -- only redirect if crosshair near target in FOV
        FOVRadius = 120, -- pixel radius for FOV check

        Hooks = {
            Raycast = true, -- WorldRoot:Raycast + BasePart:Raycast
            LegacyRay = true, -- FindPartOnRay + variants
            Spherecast = true,
            Blockcast = true,
            Shaftcast = true,
            MouseHit = true, -- Mouse.Hit, Mouse.Target, Mouse.TargetSurface, Mouse.UnitRay, Mouse.Origin
            CameraRay = true, -- Camera:ScreenPointToRay, ViewportPointToRay
            Overlap = true, -- GetPartsInPart, GetPartBoundsInBox, GetPartBoundsInRadius
        },

        MaxDistance = 1000, -- max distance for silent aim target
    },
}

--// State
local state = {
    lockedTarget = nil,
    lockedBone = nil,
    lastVisibleCheck = 0,
    lastRefresh = 0,
    currentFovRadius = 120,
    aiming = false, -- set by UI keybind
    triggerDown = false,
    lastTrigger = 0,

    silentTarget = nil,
    lastSilentRefresh = 0,
    silentHooksInstalled = false,
}

--// Silent aim: get current target
local function getSilentTargetPos()
    local sa = Settings.SilentAim
    if not sa.Enabled then return nil end

    local target
    if sa.UseAimbotTarget and state.lockedTarget then
        target = state.lockedTarget
    else
        local now = tick()
        if not state.silentTarget or (now - state.lastSilentRefresh) > 0.1 then
            state.lastSilentRefresh = now
            state.silentTarget = findTarget()
        end
        target = state.silentTarget
    end

    if not target or not target.char or not target.char.Parent then return nil end
    if target.humanoid.Health <= 0 then return nil end

    local myChar = lp.Character
    local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
    if not myHrp then return nil end

    local targetHrp = target.char:FindFirstChild("HumanoidRootPart")
    if not targetHrp then return nil end

    -- use prediction-aware position
    local pos, part = getTargetPos(myHrp, target.char, targetHrp, sa.Prediction)
    if not pos or not part then return nil end

    -- visibility check
    if sa.RequireVisible and not sa.Wallbang then
        if not isVisible(camera.CFrame.Position, part) then return nil end
    end

    -- fov check
    if sa.RequireFOV then
        local sdist = screenDistance(pos)
        if sdist > sa.FOVRadius then return nil end
    end

    -- distance check
    local dist = (myHrp.Position - pos).Magnitude
    if dist > sa.MaxDistance then return nil end

    -- hit chance
    if sa.HitChance < 100 then
        if math.random(1, 100) > sa.HitChance then return nil end
    end

    return pos, part, target
end

--// Construct a fake RaycastResult by doing a real raycast towards target
local function makeRaycastResult(origin, direction, params, targetPos, targetPart)
    local sa = Settings.SilentAim

    if sa.Wallbang then
        -- force include only the target character
        local newParams = RaycastParams.new()
        newParams.FilterType = Enum.RaycastFilterType.Include
        newParams.FilterDescendantsInstances = { targetPart.Parent }
        newParams.IgnoreWater = true
        newParams.RespectCanCollide = params and params.RespectCanCollide or false
        local dir = (targetPos - origin)
        local result = Workspace:Raycast(origin, dir, newParams)
        if result then return result end
        -- fallback: if raycast didn't hit (edge case), construct manually
    end

    -- redirect direction towards target
    local newDir = targetPos - origin
    local dist = newDir.Magnitude
    -- preserve original direction magnitude or use distance, whichever is larger
    if direction.Magnitude > dist then
        newDir = newDir.Unit * direction.Magnitude
    end

    local result = Workspace:Raycast(origin, newDir, params)
    if result then return result end

    -- if nothing hit (shouldn't happen if target visible), return nil
    -- construct a synthetic result pointing at target
    return nil
end

--// Build a synthetic RaycastResult-like table (for edge cases)
-- RaycastResult is a userdata, we can't construct it directly.
-- Best practice: redirect the ray so engine produces real result.

--// Silent aim hook installation
local function installSilentHooks()
    if state.silentHooksInstalled then return end
    state.silentHooksInstalled = true

    local sa = Settings.SilentAim
    local hooks = sa.Hooks

    --// Hook WorldRoot:Raycast
    if hooks.Raycast then
        local oldRaycast
        oldRaycast = hookfunction(Workspace.Raycast, function(self, origin, direction, params, ...)
            if self == Workspace and sa.Enabled then
                local targetPos, targetPart = getSilentTargetPos()
                if targetPos and targetPart then
                    local result = makeRaycastResult(origin, direction, params, targetPos, targetPart)
                    if result then return result end
                end
            end
            return oldRaycast(self, origin, direction, params, ...)
        end)
    end

    --// Hook BasePart:Raycast (some games raycast from the weapon part)
    -- All BaseParts share the same Raycast method, so hooking one hooks all
    if hooks.Raycast then
        local tempPart = Instance.new("Part")
        local oldPartRaycast = tempPart.Raycast
        tempPart:Destroy()
        if oldPartRaycast then
            hookfunction(oldPartRaycast, function(self, origin, direction, params, ...)
                if typeof(self) == "Instance" and self:IsA("BasePart") and sa.Enabled then
                    local targetPos, targetPart = getSilentTargetPos()
                    if targetPos and targetPart then
                        local result = makeRaycastResult(origin, direction, params, targetPos, targetPart)
                        if result then return result end
                    end
                end
                return oldPartRaycast(self, origin, direction, params, ...)
            end)
        end
    end

    --// Hook legacy FindPartOnRay, FindPartOnRayWithIgnoreList, FindPartOnRayWithWhitelist
    if hooks.LegacyRay then
        for _, methodName in ipairs({ "FindPartOnRay", "FindPartOnRayWithIgnoreList", "FindPartOnRayWithWhitelist" }) do
            local method = Workspace[methodName]
            if method then
                local oldMethod
                oldMethod = hookfunction(method, function(self, ray, ...)
                    if self == Workspace and sa.Enabled then
                        local targetPos, targetPart = getSilentTargetPos()
                        if targetPos and targetPart then
                            local origin = ray.Origin
                            local newDir = targetPos - origin
                            local newRay = Ray.new(origin, newDir)
                            if sa.Wallbang and methodName == "FindPartOnRayWithWhitelist" then
                                return oldMethod(self, newRay, { targetPart.Parent }, ...)
                            end
                            return oldMethod(self, newRay, ...)
                        end
                    end
                    return oldMethod(self, ray, ...)
                end)
            end
        end
    end

    --// Hook Spherecast, Blockcast, Shaftcast
    if hooks.Spherecast or hooks.Blockcast or hooks.Shaftcast then
        local castMethods = {}
        if hooks.Spherecast then table.insert(castMethods, "Spherecast") end
        if hooks.Blockcast then table.insert(castMethods, "Blockcast") end
        if hooks.Shaftcast then table.insert(castMethods, "Shaftcast") end

        for _, methodName in ipairs(castMethods) do
            local method = Workspace[methodName]
            if method then
                local oldMethod
                oldMethod = hookfunction(method, function(self, ...)
                    if self == Workspace and sa.Enabled then
                        local targetPos, targetPart = getSilentTargetPos()
                        if targetPos and targetPart then
                            -- redirect the ray origin/direction to point at target
                            local args = { ... }
                            -- signature: (origin, direction, radius/cframe, params)
                            -- we modify direction to point at target
                            if typeof(args[1]) == "Vector3" and typeof(args[2]) == "Vector3" then
                                local origin = args[1]
                                args[2] = targetPos - origin
                            end
                            return oldMethod(self, table.unpack(args))
                        end
                    end
                    return oldMethod(self, ...)
                end)
            end
        end
    end

    --// Hook Mouse properties via __index
    if hooks.MouseHit then
        local mouse = lp:GetMouse()
        local oldIndex
        oldIndex = hookmetamethod(mouse, "__index", function(self, key)
            if sa.Enabled and self == mouse then
                local targetPos, targetPart = getSilentTargetPos()
                if targetPos and targetPart then
                    if key == "Hit" or key == "hit" then
                        local camPos = camera.CFrame.Position
                        local dir = targetPos - camPos
                        return CFrame.new(targetPos, targetPos + dir)
                    elseif key == "Target" or key == "target" then
                        return targetPart
                    elseif key == "TargetSurface" then
                        -- return a surface facing the camera
                        local normal = (camera.CFrame.Position - targetPos).Unit
                        local bestFace = Enum.NormalId.Front
                        local bestDot = -math.huge
                        for _, face in ipairs({
                            Enum.NormalId.Front, Enum.NormalId.Back,
                            Enum.NormalId.Left, Enum.NormalId.Right,
                            Enum.NormalId.Top, Enum.NormalId.Bottom,
                        }) do
                            local faceNormal = Vector3.FromNormalId(face)
                            local dot = faceNormal:Dot(normal)
                            if dot > bestDot then
                                bestDot = dot
                                bestFace = face
                            end
                        end
                        return bestFace
                    elseif key == "UnitRay" then
                        local camPos = camera.CFrame.Position
                        local dir = (targetPos - camPos).Unit
                        return Ray.new(camPos, dir)
                    elseif key == "Origin" then
                        return camera.CFrame.Position
                    end
                end
            end
            return oldIndex(self, key)
        end)
    end

    --// Hook Camera:ScreenPointToRay, ViewportPointToRay
    if hooks.CameraRay then
        for _, methodName in ipairs({ "ScreenPointToRay", "ViewportPointToRay" }) do
            local method = camera[methodName]
            if method then
                local oldMethod
                oldMethod = hookfunction(method, function(self, x, y, depth, ...)
                    if self == camera and sa.Enabled then
                        local targetPos, targetPart = getSilentTargetPos()
                        if targetPos and targetPart then
                            local origin = self.CFrame.Position
                            local dir = (targetPos - origin).Unit
                            return Ray.new(origin + dir * (depth or 0), dir)
                        end
                    end
                    return oldMethod(self, x, y, depth, ...)
                end)
            end
        end
    end

    --// Hook overlap queries: GetPartsInPart, GetPartBoundsInBox, GetPartBoundsInRadius
    if hooks.Overlap then
        for _, methodName in ipairs({ "GetPartsInPart", "GetPartBoundsInBox", "GetPartBoundsInRadius" }) do
            local method = Workspace[methodName]
            if method then
                local oldMethod
                oldMethod = hookfunction(method, function(self, ...)
                    if self == Workspace and sa.Enabled then
                        local targetPos, targetPart = getSilentTargetPos()
                        if targetPos and targetPart then
                            -- include the target part in results
                            local args = { ... }
                            local result = oldMethod(self, ...)
                            -- check if target part is already in results
                            local found = false
                            for _, part in ipairs(result) do
                                if part == targetPart or part:IsDescendantOf(targetPart.Parent) then
                                    found = true
                                    break
                                end
                            end
                            if not found then
                                table.insert(result, targetPart)
                            end
                            return result
                        end
                    end
                    return oldMethod(self, ...)
                end)
            end
        end
    end
end

--// Camera FOV drawing for visualization (optional)
local fovCircle
local function updateFovDraw()
    if not fovCircle then
        local ok = pcall(function()
            fovCircle = Drawing.new("Circle")
        end)
        if not ok then return end
    end
    local f = Settings.FOV
    fovCircle.Visible = f.Enabled
    fovCircle.Radius = state.currentFovRadius
    fovCircle.Color = f.CircleColor
    fovCircle.Transparency = f.CircleTransparency
    fovCircle.Thickness = f.CircleThickness
    fovCircle.Filled = f.CircleFilled
    fovCircle.NumSides = f.CircleNumSides
    local center = UserInputService:GetMouseLocation()
    fovCircle.Position = Vector2.new(center.X, center.Y)
end

--// Get character and humanoid
local function getChar(player)
    return player.Character
end

local function getHumanoid(char)
    return char and char:FindFirstChildOfClass("Humanoid")
end

--// Get aim part
local function getAimPart(char, bone)
    if not char then return nil end
    local part = char:FindFirstChild(bone, true)
    if part then return part end
    return char:FindFirstChild("HumanoidRootPart", true)
        or char:FindFirstChild("Head", true)
        or char:FindFirstChild("Torso", true)
        or char:FindFirstChild("UpperTorso", true)
end

--// Prediction system (ping-based)
-- Predicts target position: currentPos + smoothedVelocity * (ping * PingScale)
local velocityCache = {}
local function getSmoothedVelocity(char, currentVel, smoothing)
    if not velocityCache[char] then
        velocityCache[char] = { vel = currentVel }
        return currentVel
    end
    local entry = velocityCache[char]
    entry.vel = entry.vel:Lerp(currentVel, smoothing or 0.3)
    return entry.vel
end

--// Ping measurement (seconds)
local function getPing()
    local ok, val = pcall(function()
        return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(val) == "number" and val > 0 then
        return val / 1000 -- ms -> seconds
    end
    return 0.05 -- fallback 50ms
end

--// Resolve prediction config (handles silent aim inheritance)
local function resolvePredictionConfig(override)
    local base = Settings.Prediction
    if not override then return base end
    return {
        Enabled = (override.Enabled ~= nil) and override.Enabled or base.Enabled,
        TimeScale = override.TimeScale or base.TimeScale,
        AccelerationSmoothing = override.AccelerationSmoothing or base.AccelerationSmoothing,
        PingScale = override.PingScale or base.PingScale,
    }
end

--// Get target position with prediction
local function getTargetPos(hrp, targetChar, targetHrp, configOverride)
    if not targetHrp then return nil end
    local bone = Settings.Bone
    local part = getAimPart(targetChar, bone)
    if not part then return nil end

    local pos = part.Position

    local predConfig = resolvePredictionConfig(configOverride)
    if predConfig.Enabled then
        local rawVel = targetHrp.AssemblyLinearVelocity
        local smoothedVel = getSmoothedVelocity(targetChar, rawVel, predConfig.AccelerationSmoothing)
        local t = getPing() * (predConfig.PingScale or 0.5) * (predConfig.TimeScale or 1.0)
        pos = pos + smoothedVel * t
    end

    return pos, part
end

--// Visibility check
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function isVisible(fromPos, targetPart)
    if Settings.Wallbang or not Settings.RequireVisible then
        return true
    end
    raycastParams.FilterDescendantsInstances = { lp.Character }
    local result = Workspace:Raycast(fromPos, targetPart.Position - fromPos, raycastParams)
    if not result then return true end
    return result.Instance:IsDescendantOf(targetPart.Parent)
end

--// World-to-screen distance
local function screenDistance(worldPos)
    local screenPos, onScreen = camera:WorldToViewportPoint(worldPos)
    if not onScreen then return math.huge end
    local mousePos = UserInputService:GetMouseLocation()
    return (Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude, screenPos
end

--// Team check
local function isTeammate(player)
    if not Settings.TeamCheck then return false end
    if player.Team == nil then return false end
    return player.Team == lp.Team
end

--// Friend check
local function isFriend(player)
    if not Settings.FriendCheck then return false end
    local ok, friends = pcall(function()
        return lp:IsFriendsWith(player.UserId)
    end)
    return ok and friends
end

--// Get all valid candidates
local function getCandidates()
    local candidates = {}
    local myChar = lp.Character
    if not myChar then return candidates end
    local myHrp = myChar:FindFirstChild("HumanoidRootPart")
    if not myHrp then return candidates end

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp then
            local char = getChar(player)
            local hum = getHumanoid(char)
            if char and hum and hum.Health > 0 then
                if not isTeammate(player) and not isFriend(player) then
                    table.insert(candidates, { char = char, humanoid = hum, player = player })
                end
            end
        end
    end

    return candidates
end

--// Score a candidate
local function scoreCandidate(c, myHrp)
    local char = c.char
    local hum = c.humanoid
    local targetHrp = char:FindFirstChild("HumanoidRootPart")
    if not targetHrp then return -math.huge end

    local dist = (myHrp.Position - targetHrp.Position).Magnitude
    if dist > Settings.MaxDistance then return -math.huge end
    if dist < Settings.MinDistance then return -math.huge end

    if Settings.SkipAirborne then
        if hum:GetState() == Enum.HumanoidStateType.Freefall
        or hum:GetState() == Enum.HumanoidStateType.Jumping then
            return -math.huge
        end
    end

    local pos, part = getTargetPos(myHrp, char, targetHrp)
    if not pos or not part then return -math.huge end

    local visible = isVisible(camera.CFrame.Position, part)
    if not visible and not Settings.Wallbang then return -math.huge end

    local sdist, screenPos = screenDistance(pos)
    if Settings.FOV.Enabled then
        local fovR = state.currentFovRadius
        if Settings.FOV.UseRadiusFor3D then
            if dist > Settings.FOV.Radius3D then return -math.huge end
        else
            if sdist > fovR then return -math.huge end
        end
    end

    if Settings.Deadzone.Enabled and sdist < Settings.Deadzone.Radius then
        return -math.huge
    end

    local score
    local prio = Settings.TargetPriority
    if prio == "Distance" then
        score = -dist
    elseif prio == "Health" then
        score = -hum.Health
    elseif prio == "FOV" then
        score = -sdist
    elseif prio == "ScreenProximity" then
        score = -sdist
    else
        score = -sdist
    end

    return score, pos, part, visible, sdist
end

--// Find best target
local function findTarget()
    local myChar = lp.Character
    if not myChar then return nil end
    local myHrp = myChar:FindFirstChild("HumanoidRootPart")
    if not myHrp then return nil end

    local candidates = getCandidates()
    if #candidates == 0 then return nil end

    local bestScore = -math.huge
    local best = nil
    local bestPos, bestPart, bestVisible, bestSdist

    for _, c in ipairs(candidates) do
        local score, pos, part, visible, sdist = scoreCandidate(c, myHrp)
        if score > bestScore then
            bestScore = score
            best = c
            bestPos = pos
            bestPart = part
            bestVisible = visible
            bestSdist = sdist
        end
    end

    if not best then return nil end
    return {
        char = best.char,
        humanoid = best.humanoid,
        player = best.player,
        part = bestPart,
        position = bestPos,
        visible = bestVisible,
        screenDist = bestSdist,
        score = bestScore,
    }
end

--// Sticky aim check
local function shouldKeepLocked(newTarget)
    if not Settings.StickyAim or not state.lockedTarget then return false end
    if not state.lockedTarget.char or not state.lockedTarget.char.Parent then return false end
    if state.lockedTarget.humanoid.Health <= 0 then return false end

    if Settings.OneShotLock then
        return true
    end

    -- new target must be StickyThreshold times better
    if newTarget and newTarget.score < state.lockedTarget.score * Settings.StickyThreshold then
        return true
    end
    return false
end

--// Smoothing functions
local function applySmoothing(currentCFrame, targetPos)
    local targetCFrame = CFrame.new(camera.CFrame.Position, targetPos)
    if not Settings.Smoothing.Enabled then
        return targetCFrame
    end

    local method = Settings.Smoothing.Method
    local speed = Settings.Smoothing.Speed
    speed = math.clamp(speed, 0.001, 1)

    if method == "Lerp" then
        return currentCFrame:Lerp(targetCFrame, speed)
    elseif method == "Exponential" then
        return currentCFrame:Lerp(targetCFrame, speed)
    elseif method == "Slerp" then
        local r = currentCFrame.Rotation:Slerp(targetCFrame.Rotation, speed)
        return CFrame.new(currentCFrame.Position) * r
    else
        return currentCFrame:Lerp(targetCFrame, speed)
    end
end

--// Aim camera
local function aimAt(pos)
    local smoothed = applySmoothing(camera.CFrame, pos)
    camera.CFrame = smoothed
end

--// Trigger bot
local triggerKeyMap = {
    MB1 = Enum.UserInputType.MouseButton1,
    MB2 = Enum.UserInputType.MouseButton2,
    MB3 = Enum.UserInputType.MouseButton3,
}

local function runTriggerBot(target)
    if not Settings.TriggerBot.Enabled then return end
    if not target then
        state.triggerDown = false
        return
    end

    local sdist = target.screenDist or math.huge
    if sdist <= Settings.TriggerBot.Radius then
        if not state.triggerDown then
            state.triggerDown = true
            state.lastTrigger = tick()
        end
        if state.triggerDown and tick() - state.lastTrigger >= Settings.TriggerBot.Delay then
            local btn = triggerKeyMap[Settings.TriggerBot.MouseButton]
            if btn then
                UserInputService:InputStart(btn, false)
                task.wait()
                UserInputService:InputEnd(btn, false)
            end
            state.lastTrigger = tick()
        end
    else
        state.triggerDown = false
    end
end

--// Main loop
RunService.RenderStepped:Connect(function(dt)
    if not Settings.Enabled then return end
    updateFovDraw()

    state.currentFovRadius = Settings.FOV.Radius

    -- input check (set by UI keybind via state.aiming)
    if not state.aiming then
        if Settings.AutoUnlockOnDeath and state.lockedTarget then
            if not state.lockedTarget.char
            or not state.lockedTarget.char.Parent
            or state.lockedTarget.humanoid.Health <= 0 then
                state.lockedTarget = nil
            end
        end
        return
    end

    local now = tick()

    -- refresh target
    local shouldRefresh = (now - state.lastRefresh) >= Settings.RefreshInterval
    if Settings.RefreshInterval == 0 then shouldRefresh = true end

    -- check if locked target still valid
    local lockedValid = state.lockedTarget ~= nil
        and state.lockedTarget.char
        and state.lockedTarget.char.Parent
        and state.lockedTarget.humanoid.Health > 0

    if not lockedValid then
        state.lockedTarget = nil
        shouldRefresh = true
    end

    local target = state.lockedTarget

    if shouldRefresh or not target then
        state.lastRefresh = now

        local newTarget = findTarget()
        if newTarget then
            if shouldKeepLocked(newTarget) then
                -- keep old target, update its position
                local myChar = lp.Character
                local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
                if myHrp then
                    local pos, part = getTargetPos(myHrp, state.lockedTarget.char, state.lockedTarget.char:FindFirstChild("HumanoidRootPart"))
                    if pos and part then
                        state.lockedTarget.position = pos
                        state.lockedTarget.part = part
                        local sdist = screenDistance(pos)
                        state.lockedTarget.screenDist = sdist
                    end
                end
                target = state.lockedTarget
            else
                state.lockedTarget = newTarget
                target = newTarget
            end
        else
            if not lockedValid then
                state.lockedTarget = nil
            end
            target = state.lockedTarget
        end
    else
        -- update position of locked target
        local myChar = lp.Character
        local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
        if myHrp then
            local pos, part = getTargetPos(myHrp, target.char, target.char:FindFirstChild("HumanoidRootPart"))
            if pos and part then
                target.position = pos
                target.part = part
                local sdist = screenDistance(pos)
                target.screenDist = sdist
                -- recheck visibility periodically
                if now - state.lastVisibleCheck >= Settings.VisibilityCheckInterval then
                    state.lastVisibleCheck = now
                    target.visible = isVisible(camera.CFrame.Position, part)
                end
            end
        end
    end

    if target and target.position then
        -- visibility recheck if needed
        if not target.visible and not Settings.Wallbang then
            state.lockedTarget = nil
            return
        end
        aimAt(target.position)
    end

    runTriggerBot(target)

    --// Silent aim: refresh independent target cache
    if Settings.SilentAim.Enabled and not Settings.SilentAim.UseAimbotTarget then
        state.silentTarget = target
    end
end)

--// Install silent aim hooks
installSilentHooks()

--// Expose API
getgenv().AimbotSettings = Settings
getgenv().AimbotState = state

getgenv().AimbotUnload = function()
    if fovCircle then fovCircle:Remove() end
    Settings.Enabled = false
    Settings.SilentAim.Enabled = false
end

return Settings
