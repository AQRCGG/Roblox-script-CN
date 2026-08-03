do
    local qot = queue_on_teleport or (syn and syn.queue_on_teleport)
    local checks = {
        { "getrawmetatable", getrawmetatable },
        { "setreadonly", setreadonly },
        { "newcclosure", newcclosure },
        { "getnamecallmethod", getnamecallmethod },
        { "getgc", getgc },
        { "queue_on_teleport", qot },
    }
    local missing, report = {}, "[VR Hands No-VR] UNC test:\n"
    for _, c in ipairs(checks) do
        local ok = type(c[2]) == "function"
        report = report .. (" [%s] %s\n"):format(ok and "+" or "-", c[1])
        if not ok then table.insert(missing, c[1]) end
    end
    print(report)
    if #missing > 0 then
        warn("[VR Hands No-VR] Missing functions: " .. table.concat(missing, ", "))
        warn("[VR Hands No-VR] Executor not supported - aborting (no teleport).")
        return
    end
    print("[VR Hands No-VR] UNC test passed - launching.")
end
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local hrs = [==[
local VRService = game:GetService("VRService")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local identity = CFrame.identity
do
    local mt = getrawmetatable(game)
    local oldIndex = mt.__index
    local oldNamecall = mt.__namecall
    setreadonly(mt, false)
    mt.__index = newcclosure(function(self, k)
        if k == "VREnabled" and (self == VRService or self == UIS) then return true end
        return oldIndex(self, k)
    end)
    mt.__namecall = newcclosure(function(self, ...)
        if self == VRService then
            local m = getnamecallmethod()
            if m == "GetUserCFrameEnabled" then return true end
            if m == "GetUserCFrame" then return identity end
        end
        return oldNamecall(self, ...)
    end)
    setreadonly(mt, true)
end
task.spawn(function()
    local function ensureFolder(p, n)
        local f = p:FindFirstChild(n)
        if not f then f = Instance.new("Folder"); f.Name = n; f.Parent = p end
        return f
    end
    local function ensurePart(p, n)
        local x = p:FindFirstChild(n)
        if not x then
            x = Instance.new("Part"); x.Name = n
            x.Anchored = true; x.CanCollide = false; x.Transparency = 1
            x.Size = Vector3.new(1,1,1); x.Parent = p
        end
        return x
    end
    local function populate(cam)
        if not cam then return end
        ensurePart(ensureFolder(cam, "VRCoreEffectParts"), "Cursor")
        ensurePart(ensureFolder(cam, "VRCorePanelParts"), "BottomBar_Part")
    end
    populate(workspace.CurrentCamera)
    workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        populate(workspace.CurrentCamera)
    end)
    local t0 = os.clock()
    while os.clock() - t0 < 30 do
        populate(workspace.CurrentCamera)
        task.wait(0.1)
    end
end)
task.spawn(function()
    local lp = Players.LocalPlayer
    while not lp do task.wait() lp = Players.LocalPlayer end
    local uid = tostring(lp.UserId)
    local vrPlayers = workspace:WaitForChild("VRPlayers", 60)
    if not vrPlayers then warn("[NoVR] no VRPlayers") return end
    local rig = vrPlayers:WaitForChild(uid, 60)
    if not rig then warn("[NoVR] The server did not issue a rig") return end
    rig:WaitForChild("VRHead", 20)
    rig:WaitForChild("LeftHand", 20)
    rig:WaitForChild("RightHand", 20)
    local scaleVal = rig:FindFirstChild("VRScale")
    local cam = workspace.CurrentCamera
    local S = {
        reach = 0.55, spread = 0.34, height = -0.25,
        sens = 0.0025, moveK = 0.16, look = true,
        scale = 10,
        grabRadiusMult = 1,    -- 抓取范围倍率
        toggleGrabMode = false, -- 抓取模式：false=长按 true=切换
        speedMult = 1,         -- 移动速度倍率
    }
    local ok, VRUtils = pcall(function()
        return require(lp.PlayerScripts.ClientLoader.PlayerModule.VRModule.VRUtils)
    end)
    if ok and type(VRUtils) == "table" then
        VRUtils.GetUserCFrame = function(uc, scale)
            scale = scale or cam.HeadScale
            if scale <= 1 then scale = math.max((scaleVal and scaleVal.Value or 1) * 60, 6) end
            if uc == Enum.UserCFrame.LeftHand then
                local c = CFrame.new(-S.spread, S.height, -S.reach)
                return c.Rotation + c.Position * scale
            elseif uc == Enum.UserCFrame.RightHand then
                local c = CFrame.new(S.spread, S.height, -S.reach)
                return c.Rotation + c.Position * scale
            end
            return identity
        end
    else
        warn("[NoVR] failed to intercept VRUtils")
    end
    local vrm, Input
    for _ = 1, 250 do
        for _, o in pairs(getgc(true)) do
            if type(o) == "table"
            and rawget(o,"HeadsetPart") ~= nil and rawget(o,"Input") ~= nil
            and rawget(o,"CharacterScale") ~= nil and rawget(o,"DataManager") ~= nil then
                vrm = o; Input = rawget(o,"Input"); break
            end
        end
        if Input then break end
        for _, o in pairs(getgc(true)) do
            if type(o) == "table" and rawget(o,"directionLateral") ~= nil
            and rawget(o,"rFist") ~= nil and rawget(o,"turnDirection") ~= nil then
                Input = o; break
            end
        end
        if Input then break end
        task.wait(0.1)
    end
    if not Input then warn("[NoVR] Input object not found - grip will not work") end
    task.spawn(function()
        for _ = 1, 100 do
            pcall(function() RunService:UnbindFromRenderStep("Inputs") end)
            task.wait(0.1)
        end
    end)

    -- ========== 修复1：抓取范围体型补偿 + 倍率调节 ==========
    pcall(function()
        local pmMT = getrawmetatable(vrm.PropManager)
        if pmMT and rawget(pmMT, "GetBestGrabPartInRadius") then
            local orig = pmMT.GetBestGrabPartInRadius
            setreadonly(pmMT, false)
            pmMT.GetBestGrabPartInRadius = function(self, root, prox, radius, scale, ...)
                -- 以scale=10为基准，缩小体型时自动补偿抓取半径
                local scaleComp = 10 / math.max(S.scale, 0.1)
                local adjustedRadius = radius * scaleComp * S.grabRadiusMult
                return orig(self, root, prox, adjustedRadius, scale, ...)
            end
            setreadonly(pmMT, true)
        end
        local cmMT = getrawmetatable(vrm.CharacterManager)
        if cmMT and rawget(cmMT, "GetClosestCharacterInRadius") then
            local orig = cmMT.GetClosestCharacterInRadius
            setreadonly(cmMT, false)
            cmMT.GetClosestCharacterInRadius = function(self, pos, radius, ...)
                local scaleComp = 10 / math.max(S.scale, 0.1)
                local adjustedRadius = radius * scaleComp * S.grabRadiusMult
                return orig(self, pos, adjustedRadius, ...)
            end
            setreadonly(cmMT, true)
        end
    end)

    -- 突破体型限制：1-10放宽到0.1-100
    local function setScale(n)
        n = math.clamp(n, 0.1, 100)
        S.scale = n
        if scaleVal then pcall(function() scaleVal.Value = n / 10 end) end
        if vrm and vrm.DataManager and vrm.DataManager.SettingsManager then
            pcall(function() vrm.DataManager.SettingsManager:SetValue("vrscale", n) end)
        end
    end
    setScale(10)
    cam.HeadLocked = true
    local yaw, pitch
    do
        local lv = cam.CFrame.LookVector
        yaw = math.atan2(-lv.X, -lv.Z)
        pitch = math.asin(math.clamp(lv.Y, -1, 1))
    end
    local camPos = cam.CFrame.Position
    local keys = {}
    local function setLook(v)
        S.look = v
        if not UIS.TouchEnabled then
            UIS.MouseBehavior = v and Enum.MouseBehavior.LockCenter or Enum.MouseBehavior.Default
            UIS.MouseIconEnabled = not v
        end
    end
    setLook(true)

    -- ========== 修复2：输入逻辑适配长按/切换双模式 ==========
    UIS.InputBegan:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.Keyboard then
            keys[io.KeyCode] = true
            if io.KeyCode == Enum.KeyCode.LeftAlt then setLook(not S.look) end
            if io.KeyCode == Enum.KeyCode.Equals then setScale(S.scale + 1) end
            if io.KeyCode == Enum.KeyCode.Minus then setScale(S.scale - 1) end
            -- PC端快捷键：[]调节抓取范围 ;'调节速度 G切换模式
            if io.KeyCode == Enum.KeyCode.LeftBracket then S.grabRadiusMult = math.clamp(S.grabRadiusMult - 0.1, 0.1, 10) end
            if io.KeyCode == Enum.KeyCode.RightBracket then S.grabRadiusMult = math.clamp(S.grabRadiusMult + 0.1, 0.1, 10) end
            if io.KeyCode == Enum.KeyCode.Semicolon then S.speedMult = math.clamp(S.speedMult - 0.1, 0.1, 10) end
            if io.KeyCode == Enum.KeyCode.Quote then S.speedMult = math.clamp(S.speedMult + 0.1, 0.1, 10) end
            if io.KeyCode == Enum.KeyCode.G then S.toggleGrabMode = not S.toggleGrabMode end

            if Input and io.KeyCode == Enum.KeyCode.E then
                if S.toggleGrabMode then
                    Input.rIndex = Input.rIndex == 1 and 0 or 1
                    if Input.rIndex == 1 then Input.rFist = 0; Input.rThumb = 0 end
                else
                    Input.rIndex = 1; Input.rFist = 0; Input.rThumb = 0
                end
            end
            if Input and io.KeyCode == Enum.KeyCode.Q then
                if S.toggleGrabMode then
                    Input.lIndex = Input.lIndex == 1 and 0 or 1
                    if Input.lIndex == 1 then Input.lFist = 0; Input.lThumb = 0 end
                else
                    Input.lIndex = 1; Input.lFist = 0; Input.lThumb = 0
                end
            end
        elseif io.UserInputType == Enum.UserInputType.MouseButton1 then
            if Input then
                if S.toggleGrabMode then
                    Input.rFist = Input.rFist == 1 and 0 or 1
                    Input.rIndex = Input.rIndex == 1 and 0 or 1
                else
                    Input.rFist = 1; Input.rIndex = 1
                end
            end
        elseif io.UserInputType == Enum.UserInputType.MouseButton2 then
            if Input then
                if S.toggleGrabMode then
                    Input.lFist = Input.lFist == 1 and 0 or 1
                    Input.lIndex = Input.lIndex == 1 and 0 or 1
                else
                    Input.lFist = 1; Input.lIndex = 1
                end
            end
        end
    end)
    UIS.InputEnded:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.Keyboard then
            keys[io.KeyCode] = false
            -- 仅长按模式下松开取消
            if Input and io.KeyCode == Enum.KeyCode.E and not S.toggleGrabMode then Input.rIndex = 0 end
            if Input and io.KeyCode == Enum.KeyCode.Q and not S.toggleGrabMode then Input.lIndex = 0 end
        elseif io.UserInputType == Enum.UserInputType.MouseButton1 then
            if Input and not S.toggleGrabMode then Input.rFist = 0; Input.rIndex = 0 end
        elseif io.UserInputType == Enum.UserInputType.MouseButton2 then
            if Input and not S.toggleGrabMode then Input.lFist = 0; Input.lIndex = 0 end
        end
    end)

    -- 突破手长限制：0.15-2.5放宽到0.05-20
    UIS.InputChanged:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.MouseWheel then
            S.reach = math.clamp(S.reach - io.Position.Z * 0.07, 0.05, 20)
        end
    end)

    -- ========== 修复3：速度倍率生效 ==========
    RunService:BindToRenderStep("NoVR_Control", Enum.RenderPriority.Camera.Value + 1, function(dt)
        if S.look and not UIS.TouchEnabled then
            local d = UIS:GetMouseDelta()
            yaw = yaw - d.X * S.sens
            pitch = math.clamp(pitch - d.Y * S.sens, -1.45, 1.45)
            UIS.MouseBehavior = Enum.MouseBehavior.LockCenter
        end
        local rot = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
        local hs = cam.HeadScale; if hs <= 1 then hs = S.scale * 6 end
        local spd = (10 + S.scale * 4) * hs * S.moveK * S.speedMult
        local mv = Vector3.zero
        if keys[Enum.KeyCode.W] then mv += Vector3.new(0,0,-1) end
        if keys[Enum.KeyCode.S] then mv += Vector3.new(0,0, 1) end
        if keys[Enum.KeyCode.A] then mv += Vector3.new(-1,0,0) end
        if keys[Enum.KeyCode.D] then mv += Vector3.new( 1,0,0) end
        if keys[Enum.KeyCode.Space] then mv += Vector3.new(0, 1,0) end
        if keys[Enum.KeyCode.LeftShift] then mv += Vector3.new(0,-1,0) end
        if mv.Magnitude > 0 then camPos = camPos + (rot * mv.Unit) * spd * dt end
        cam.CameraType = Enum.CameraType.Scriptable
        cam.CFrame = CFrame.new(camPos) * rot
        if Input then
            Input.directionLateral = Vector2.zero
            Input.directionVertical = 0
            Input.turnDirection = 0
        end
    end)

    -- ========== HUD新增参数显示 ==========
    pcall(function()
        local gui = Instance.new("ScreenGui")
        gui.Name = "NoVR_HUD"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true
        gui.Parent = lp:WaitForChild("PlayerGui")
        local lbl = Instance.new("TextLabel", gui)
        lbl.AnchorPoint = Vector2.new(1, 0)
        lbl.Position = UDim2.new(1, -10, 0, 10)
        lbl.Size = UDim2.new(0, 360, 0, 220)
        lbl.BackgroundColor3 = Color3.fromRGB(0,0,0); lbl.BackgroundTransparency = 0.45
        lbl.TextColor3 = Color3.fromRGB(255,255,255)
        lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.TextYAlignment = Enum.TextYAlignment.Top
        lbl.Font = Enum.Font.Code; lbl.TextSize = 14
        RunService.Heartbeat:Connect(function()
            lbl.Text = ("[VR Hands :: No-VR]\n"
            .."Mouse - look | WASD - fly\n"
            .."Space/Shift - up / down\n"
            .."LMB/RMB - grab objects (R/L)\n"
            .."E/Q - pinch: grab PLAYERS (R/L)\n"
            .."Wheel - hand reach\n"
            .."+/- - body size: %.1f/100\n"
            .."[/] - grab radius: %.1fx\n"
            ..";/' - move speed: %.1fx\n"
            .."G - grab mode: %s\n"
            .."LeftAlt - free the cursor")
            :format(S.scale, S.grabRadiusMult, S.speedMult, S.toggleGrabMode and "Toggle" or "Hold")
        end)
    end)

    -- ========== 移动端全功能控制UI（新增按钮） ==========
    pcall(function()
        if UIS.TouchEnabled then
            local mobileGui = Instance.new("ScreenGui")
            mobileGui.Name = "NoVR_MobileControls"
            mobileGui.ResetOnSpawn = false
            mobileGui.IgnoreGuiInset = true
            mobileGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
            mobileGui.Parent = lp:WaitForChild("PlayerGui")
            local function createBtn(parent, name, pos, size, text, textSize)
                textSize = textSize or 14
                local btn = Instance.new("TextButton")
                btn.Name = name
                btn.Position = pos
                btn.Size = size
                btn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
                btn.BackgroundTransparency = 0.5
                btn.TextColor3 = Color3.fromRGB(255, 255, 255)
                btn.Text = text
                btn.Font = Enum.Font.SourceSansBold
                btn.TextSize = textSize
                btn.AutoButtonColor = false
                btn.Parent = parent
                Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
                return btn
            end
            local function bindPress(btn)
                btn.InputBegan:Connect(function(i)
                    if i.UserInputType == Enum.UserInputType.Touch then btn.BackgroundTransparency = 0.25 end
                end)
                btn.InputEnded:Connect(function(i)
                    if i.UserInputType == Enum.UserInputType.Touch then btn.BackgroundTransparency = 0.5 end
                end)
            end
            -- 1. 左下角方向键
            local dpad = Instance.new("Frame")
            dpad.Size = UDim2.fromScale(0.28, 0.22)
            dpad.Position = UDim2.fromScale(0.03, 0.97)
            dpad.AnchorPoint = Vector2.new(0, 1)
            dpad.BackgroundTransparency = 1
            dpad.Parent = mobileGui
            local up = createBtn(dpad, "Up", UDim2.fromScale(0.5, 0), UDim2.fromScale(0.35, 0.35), "▲", 18)
            up.AnchorPoint = Vector2.new(0.5, 0)
            local down = createBtn(dpad, "Down", UDim2.fromScale(0.5, 1), UDim2.fromScale(0.35, 0.35), "▼", 18)
            down.AnchorPoint = Vector2.new(0.5, 1)
            local left = createBtn(dpad, "Left", UDim2.fromScale(0, 0.5), UDim2.fromScale(0.35, 0.35), "◀", 18)
            left.AnchorPoint = Vector2.new(0, 0.5)
            local right = createBtn(dpad, "Right", UDim2.fromScale(1, 0.5), UDim2.fromScale(0.35, 0.35), "▶", 18)
            right.AnchorPoint = Vector2.new(1, 0.5)
            local function bindKey(btn, key)
                btn.InputBegan:Connect(function(i)
                    if i.UserInputType == Enum.UserInputType.Touch then keys[key] = true end
                end)
                btn.InputEnded:Connect(function(i)
                    if i.UserInputType == Enum.UserInputType.Touch then keys[key] = false end
                end)
                bindPress(btn)
            end
            bindKey(up, Enum.KeyCode.W)
            bindKey(down, Enum.KeyCode.S)
            bindKey(left, Enum.KeyCode.A)
            bindKey(right, Enum.KeyCode.D)
            -- 2. 左侧升降键
            local vert = Instance.new("Frame")
            vert.Size = UDim2.fromScale(0.09, 0.15)
            vert.Position = UDim2.fromScale(0.03, 0.78)
            vert.AnchorPoint = Vector2.new(0, 1)
            vert.BackgroundTransparency = 1
            vert.Parent = mobileGui
            local ascend = createBtn(vert, "Ascend", UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.45), "↑", 16)
            local descend = createBtn(vert, "Descend", UDim2.fromScale(0, 1), UDim2.fromScale(1, 0.45), "↓", 16)
            descend.AnchorPoint = Vector2.new(0, 1)
            bindKey(ascend, Enum.KeyCode.Space)
            bindKey(descend, Enum.KeyCode.LeftShift)
            -- 3. 右下角：抓取+捏取（适配双模式）
            local grab = Instance.new("Frame")
            grab.Size = UDim2.fromScale(0.3, 0.18)
            grab.Position = UDim2.fromScale(0.97, 0.97)
            grab.AnchorPoint = Vector2.new(1, 1)
            grab.BackgroundTransparency = 1
            grab.Parent = mobileGui
            local grabL = createBtn(grab, "GrabL", UDim2.fromScale(0, 0), UDim2.fromScale(0.45, 0.45), "左抓", 14)
            local grabR = createBtn(grab, "GrabR", UDim2.fromScale(1, 0), UDim2.fromScale(0.45, 0.45), "右抓", 14)
            grabR.AnchorPoint = Vector2.new(1, 0)
            local pinchL = createBtn(grab, "PinchL", UDim2.fromScale(0, 1), UDim2.fromScale(0.45, 0.45), "左捏", 13)
            local pinchR = createBtn(grab, "PinchR", UDim2.fromScale(1, 1), UDim2.fromScale(0.45, 0.45), "右捏", 13)
            pinchL.AnchorPoint = Vector2.new(0, 1)
            pinchR.AnchorPoint = Vector2.new(1, 1)

            -- 左手抓取
            grabL.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch and Input then
                    if S.toggleGrabMode then
                        Input.lFist = Input.lFist == 1 and 0 or 1
                        Input.lIndex = Input.lIndex == 1 and 0 or 1
                    else
                        Input.lFist = 1; Input.lIndex = 1
                    end
                end
            end)
            grabL.InputEnded:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch and Input and not S.toggleGrabMode then
                    Input.lFist = 0; Input.lIndex = 0
                end
            end)
            bindPress(grabL)
            -- 右手抓取
            grabR.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch and Input then
                    if S.toggleGrabMode then
                        Input.rFist = Input.rFist == 1 and 0 or 1
                        Input.rIndex = Input.rIndex == 1 and 0 or 1
                    else
                        Input.rFist = 1; Input.rIndex = 1
                    end
                end
            end)
            grabR.InputEnded:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch and Input and not S.toggleGrabMode then
                    Input.rFist = 0; Input.rIndex = 0
                end
            end)
            bindPress(grabR)
            -- 左手捏取
            pinchL.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch and Input then
                    if S.toggleGrabMode then
                        Input.lIndex = Input.lIndex == 1 and 0 or 1
                        if Input.lIndex == 1 then Input.lFist = 0; Input.lThumb = 0 end
                    else
                        Input.lIndex = 1; Input.lFist = 0; Input.lThumb = 0
                    end
                end
            end)
            pinchL.InputEnded:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch and Input and not S.toggleGrabMode then
                    Input.lIndex = 0
                end
            end)
            bindPress(pinchL)
            -- 右手捏取
            pinchR.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch and Input then
                    if S.toggleGrabMode then
                        Input.rIndex = Input.rIndex == 1 and 0 or 1
                        if Input.rIndex == 1 then Input.rFist = 0; Input.rThumb = 0 end
                    else
                        Input.rIndex = 1; Input.rFist = 0; Input.rThumb = 0
                    end
                end
            end)
            pinchR.InputEnded:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch and Input and not S.toggleGrabMode then
                    Input.rIndex = 0
                end
            end)
            bindPress(pinchR)

            -- 4. 右上角功能区（新增抓距、速度、模式按钮）
            local func = Instance.new("Frame")
            func.Size = UDim2.fromScale(0.28, 0.42)
            func.Position = UDim2.fromScale(0.97, 0.12)
            func.AnchorPoint = Vector2.new(1, 0)
            func.BackgroundTransparency = 1
            func.Parent = mobileGui
            
            -- 体型调节
            local scaleUp = createBtn(func, "ScaleUp", UDim2.fromScale(0, 0), UDim2.fromScale(0.48, 0.14), "变大", 11)
            local scaleDown = createBtn(func, "ScaleDown", UDim2.fromScale(1, 0), UDim2.fromScale(0.48, 0.14), "变小", 11)
            scaleDown.AnchorPoint = Vector2.new(1, 0)
            scaleUp.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch then setScale(S.scale + 1) end
            end)
            scaleDown.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch then setScale(S.scale - 1) end
            end)
            bindPress(scaleUp)
            bindPress(scaleDown)
            
            -- 手长调节
            local reachUp = createBtn(func, "ReachUp", UDim2.fromScale(0, 0.16), UDim2.fromScale(0.48, 0.14), "伸长", 11)
            local reachDown = createBtn(func, "ReachDown", UDim2.fromScale(1, 0.16), UDim2.fromScale(0.48, 0.14), "缩短", 11)
            reachDown.AnchorPoint = Vector2.new(1, 0)
            reachUp.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch then
                    S.reach = math.clamp(S.reach + 0.1, 0.05, 20)
                end
            end)
            reachDown.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch then
                    S.reach = math.clamp(S.reach - 0.1, 0.05, 20)
                end
            end)
            bindPress(reachUp)
            bindPress(reachDown)
            
            -- 抓取范围调节
            local grabUp = createBtn(func, "GrabUp", UDim2.fromScale(0, 0.32), UDim2.fromScale(0.48, 0.14), "抓距+", 11)
            local grabDown = createBtn(func, "GrabDown", UDim2.fromScale(1, 0.32), UDim2.fromScale(0.48, 0.14), "抓距-", 11)
            grabDown.AnchorPoint = Vector2.new(1, 0)
            grabUp.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch then
                    S.grabRadiusMult = math.clamp(S.grabRadiusMult + 0.1, 0.1, 10)
                end
            end)
            grabDown.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch then
                    S.grabRadiusMult = math.clamp(S.grabRadiusMult - 0.1, 0.1, 10)
                end
            end)
            bindPress(grabUp)
            bindPress(grabDown)
            
            -- 速度调节
            local speedUp = createBtn(func, "SpeedUp", UDim2.fromScale(0, 0.48), UDim2.fromScale(0.48, 0.14), "速度+", 11)
            local speedDown = createBtn(func, "SpeedDown", UDim2.fromScale(1, 0.48), UDim2.fromScale(0.48, 0.14), "速度-", 11)
            speedDown.AnchorPoint = Vector2.new(1, 0)
            speedUp.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch then
                    S.speedMult = math.clamp(S.speedMult + 0.1, 0.1, 10)
                end
            end)
            speedDown.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch then
                    S.speedMult = math.clamp(S.speedMult - 0.1, 0.1, 10)
                end
            end)
            bindPress(speedUp)
            bindPress(speedDown)
            
            -- 抓取模式切换
            local toggleGrab = createBtn(func, "ToggleGrab", UDim2.fromScale(0.5, 0.68), UDim2.fromScale(0.96, 0.14), "模式:长按", 11)
            toggleGrab.AnchorPoint = Vector2.new(0.5, 0)
            toggleGrab.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch then
                    S.toggleGrabMode = not S.toggleGrabMode
                    toggleGrab.Text = S.toggleGrabMode and "模式:切换" or "模式:长按"
                end
            end)
            bindPress(toggleGrab)
            
            -- 视角切换
            local toggleLook = createBtn(func, "ToggleLook", UDim2.fromScale(0.5, 0.86), UDim2.fromScale(0.96, 0.14), "解锁视角", 11)
            toggleLook.AnchorPoint = Vector2.new(0.5, 0)
            toggleLook.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch then
                    setLook(not S.look)
                    toggleLook.Text = S.look and "解锁视角" or "锁定视角"
                end
            end)
            bindPress(toggleLook)

            -- 5. 右半屏滑动控制视角
            local touchLook = false
            local lastTouch = Vector2.zero
            local touchSens = 0.0025
            UIS.TouchStarted:Connect(function(i)
                if i.Position.X > workspace.CurrentCamera.ViewportSize.X * 0.5 then
                    local vpY = workspace.CurrentCamera.ViewportSize.Y
                    if i.Position.Y < vpY * 0.85 and i.Position.Y > vpY * 0.15 then
                        touchLook = true
                        lastTouch = i.Position
                    end
                end
            end)
            UIS.TouchMoved:Connect(function(i)
                if touchLook then
                    local delta = i.Position - lastTouch
                    yaw = yaw - delta.X * touchSens
                    pitch = math.clamp(pitch - delta.Y * touchSens, -1.45, 1.45)
                    lastTouch = i.Position
                end
            end)
            UIS.TouchEnded:Connect(function() touchLook = false end)
        end
    end)
    print("[NoVR] control active.")
end)
]==]
-- 修复重新加入服务器：回到当前服务器实例
local function teleportToCurrentServer()
    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, Players.LocalPlayer)
    end)
    if not ok then
        warn("[VR Hands No-VR] 重连当前服务器失败，将进入随机服务器: " .. tostring(err))
        TeleportService:Teleport(game.PlaceId, Players.LocalPlayer)
    end
end
if queue_on_teleport then
    queue_on_teleport(hrs)
    teleportToCurrentServer()
elseif syn and syn.queue_on_teleport then
    syn.queue_on_teleport(hrs)
    teleportToCurrentServer()
else
    warn("[VR Hands No-VR] 当前执行器不支持传送注入，脚本仅在当前服务器生效")
end
