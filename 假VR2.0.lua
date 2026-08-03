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
        -- 速度独立控制倍率
        moveSpeedMult = 1,
        verticalSpeedMult = 1,
        -- 抓取范围补偿配置
        grabRangeAutoCompensate = true,
        grabRangeMult = 1,
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
    -- 抓取范围自动补偿 + 倍率调节
    pcall(function()
        local pmMT = getrawmetatable(vrm.PropManager)
        if pmMT and rawget(pmMT, "GetBestGrabPartInRadius") then
            local orig = pmMT.GetBestGrabPartInRadius
            setreadonly(pmMT, false)
            pmMT.GetBestGrabPartInRadius = function(self, root, prox, radius, scale, ...)
                local finalRadius = radius
                if S.grabRangeAutoCompensate then
                    local scaleRatio = S.scale / 10
                    finalRadius = finalRadius / scaleRatio
                end
                finalRadius = finalRadius * S.grabRangeMult
                return orig(self, root, prox, finalRadius, scale, ...)
            end
            setreadonly(pmMT, true)
        end
        local cmMT = getrawmetatable(vrm.CharacterManager)
        if cmMT and rawget(cmMT, "GetClosestCharacterInRadius") then
            local orig = cmMT.GetClosestCharacterInRadius
            setreadonly(cmMT, false)
            cmMT.GetClosestCharacterInRadius = function(self, pos, radius, ...)
                local finalRadius = radius
                if S.grabRangeAutoCompensate then
                    local scaleRatio = S.scale / 10
                    finalRadius = finalRadius / scaleRatio
                end
                finalRadius = finalRadius * S.grabRangeMult
                return orig(self, pos, finalRadius, ...)
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
    UIS.InputBegan:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.Keyboard then
            keys[io.KeyCode] = true
            if io.KeyCode == Enum.KeyCode.LeftAlt then setLook(not S.look) end
            if io.KeyCode == Enum.KeyCode.Equals then setScale(S.scale + 1) end
            if io.KeyCode == Enum.KeyCode.Minus then setScale(S.scale - 1) end
            if Input and io.KeyCode == Enum.KeyCode.E then Input.rIndex = 1; Input.rFist = 0; Input.rThumb = 0 end
            if Input and io.KeyCode == Enum.KeyCode.Q then Input.lIndex = 1; Input.lFist = 0; Input.lThumb = 0 end
        elseif io.UserInputType == Enum.UserInputType.MouseButton1 then
            if Input then Input.rFist = 1; Input.rIndex = 1 end
        elseif io.UserInputType == Enum.UserInputType.MouseButton2 then
            if Input then Input.lFist = 1; Input.lIndex = 1 end
        end
    end)
    UIS.InputEnded:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.Keyboard then
            keys[io.KeyCode] = false
            if Input and io.KeyCode == Enum.KeyCode.E then Input.rIndex = 0 end
            if Input and io.KeyCode == Enum.KeyCode.Q then Input.lIndex = 0 end
        elseif io.UserInputType == Enum.UserInputType.MouseButton1 then
            if Input then Input.rFist = 0; Input.rIndex = 0 end
        elseif io.UserInputType == Enum.UserInputType.MouseButton2 then
            if Input then Input.lFist = 0; Input.lIndex = 0 end
        end
    end)
    -- 突破手长限制：0.15-2.5放宽到0.05-20
    UIS.InputChanged:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.MouseWheel then
            S.reach = math.clamp(S.reach - io.Position.Z * 0.07, 0.05, 20)
        end
    end)
    RunService:BindToRenderStep("NoVR_Control", Enum.RenderPriority.Camera.Value + 1, function(dt)
        if S.look and not UIS.TouchEnabled then
            local d = UIS:GetMouseDelta()
            yaw = yaw - d.X * S.sens
            pitch = math.clamp(pitch - d.Y * S.sens, -1.45, 1.45)
            UIS.MouseBehavior = Enum.MouseBehavior.LockCenter
        end
        local rot = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
        local hs = cam.HeadScale; if hs <= 1 then hs = S.scale * 6 end
        -- 水平与垂直速度独立控制
        local baseSpeed = (10 + S.scale * 4) * hs * S.moveK
        local moveSpeed = baseSpeed * S.moveSpeedMult
        local vertSpeed = baseSpeed * S.verticalSpeedMult

        local horizontal = Vector3.zero
        if keys[Enum.KeyCode.W] then horizontal += Vector3.new(0,0,-1) end
        if keys[Enum.KeyCode.S] then horizontal += Vector3.new(0,0, 1) end
        if keys[Enum.KeyCode.A] then horizontal += Vector3.new(-1,0,0) end
        if keys[Enum.KeyCode.D] then horizontal += Vector3.new( 1,0,0) end
        if horizontal.Magnitude > 0 then
            camPos = camPos + (rot * horizontal.Unit) * moveSpeed * dt
        end
        if keys[Enum.KeyCode.Space] then camPos += Vector3.new(0, vertSpeed * dt, 0) end
        if keys[Enum.KeyCode.LeftShift] then camPos += Vector3.new(0, -vertSpeed * dt, 0) end

        cam.CameraType = Enum.CameraType.Scriptable
        cam.CFrame = CFrame.new(camPos) * rot
        if Input then
            Input.directionLateral = Vector2.zero
            Input.directionVertical = 0
            Input.turnDirection = 0
        end
    end)
    -- 键位提示框移到右上角
    pcall(function()
        local gui = Instance.new("ScreenGui")
        gui.Name = "NoVR_HUD"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true
        gui.Parent = lp:WaitForChild("PlayerGui")
        local lbl = Instance.new("TextLabel", gui)
        lbl.AnchorPoint = Vector2.new(1, 0)
        lbl.Position = UDim2.new(1, -10, 0, 10)
        lbl.Size = UDim2.new(0, 340, 0, 170)
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
            .."LeftAlt - free the cursor")
            :format(S.scale)
        end)
    end)
    -- 移动端全功能控制UI
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
            -- 滑块创建函数
            local function createSlider(parent, label, yPos, initVal, minVal, maxVal, onChange)
                local container = Instance.new("Frame")
                container.Size = UDim2.new(1, 0, 0, 36)
                container.Position = UDim2.new(0, 0, 0, yPos)
                container.BackgroundTransparency = 1
                container.Parent = parent

                local labelTxt = Instance.new("TextLabel")
                labelTxt.Text = string.format("%s: %.1f", label, initVal)
                labelTxt.Size = UDim2.new(1, 0, 0, 14)
                labelTxt.Position = UDim2.new(0, 0, 0, 0)
                labelTxt.BackgroundTransparency = 1
                labelTxt.TextColor3 = Color3.new(1,1,1)
                labelTxt.TextXAlignment = Enum.TextXAlignment.Left
                labelTxt.TextSize = 12
                labelTxt.Parent = container

                local track = Instance.new("Frame")
                track.Size = UDim2.new(1, 0, 0, 6)
                track.Position = UDim2.new(0, 0, 0, 20)
                track.BackgroundColor3 = Color3.fromRGB(30,30,40)
                track.CornerRadius = UDim.new(1,0)
                track.Parent = container

                local fill = Instance.new("Frame")
                fill.Size = UDim2.fromScale((initVal-minVal)/(maxVal-minVal), 1)
                fill.BackgroundColor3 = Color3.fromRGB(90, 150, 255)
                fill.CornerRadius = UDim.new(1,0)
                fill.Parent = track

                local knob = Instance.new("TextButton")
                knob.Size = UDim2.fromOffset(16, 16)
                knob.Position = UDim2.fromScale((initVal-minVal)/(maxVal-minVal), 0.5)
                knob.AnchorPoint = Vector2.new(0.5, 0.5)
                knob.BackgroundColor3 = Color3.new(1,1,1)
                knob.Text = ""
                knob.Parent = track

                local dragging = false
                local function updateValue(input)
                    local percent = math.clamp((input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
                    local value = minVal + (maxVal - minVal) * percent
                    knob.Position = UDim2.fromScale(percent, 0.5)
                    fill.Size = UDim2.fromScale(percent, 1)
                    labelTxt.Text = string.format("%s: %.1f", label, value)
                    onChange(value)
                end

                knob.InputBegan:Connect(function(input)
                    if input.UserInputType == Enum.UserInputType.Touch then
                        dragging = true
                        updateValue(input)
                    end
                end)
                UIS.InputChanged:Connect(function(input)
                    if dragging and input.UserInputType == Enum.UserInputType.Touch then
                        updateValue(input)
                    end
                end)
                UIS.InputEnded:Connect(function(input)
                    if input.UserInputType == Enum.UserInputType.Touch then
                        dragging = false
                    end
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

            -- 3. 左侧参数调节滑块面板
            local sliderPanel = Instance.new("Frame")
            sliderPanel.Size = UDim2.fromOffset(170, 130)
            sliderPanel.Position = UDim2.fromScale(0.03, 0.62)
            sliderPanel.AnchorPoint = Vector2.new(0, 1)
            sliderPanel.BackgroundColor3 = Color3.fromRGB(0,0,0)
            sliderPanel.BackgroundTransparency = 0.45
            sliderPanel.Parent = mobileGui
            Instance.new("UICorner", sliderPanel).CornerRadius = UDim.new(0, 6)
            local padding = Instance.new("UIPadding")
            padding.PaddingLeft = UDim.new(0, 8)
            padding.PaddingRight = UDim.new(0, 8)
            padding.PaddingTop = UDim.new(0, 8)
            padding.Parent = sliderPanel

            createSlider(sliderPanel, "移动速度", 0, 1, 0.2, 3, function(val)
                S.moveSpeedMult = val
            end)
            createSlider(sliderPanel, "上下速度", 42, 1, 0.2, 3, function(val)
                S.verticalSpeedMult = val
            end)
            createSlider(sliderPanel, "抓取范围", 84, 1, 0.5, 3, function(val)
                S.grabRangeMult = val
            end)

            -- 4. 右下角：抓取+捏取（切换模式）
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

            local grabState = {l = false, r = false}
            local pinchState = {l = false, r = false}
            local activeColor = Color3.fromRGB(90, 150, 255)
            local normalColor = Color3.fromRGB(0, 0, 0)

            -- 左手抓取切换
            grabL.MouseButton1Click:Connect(function()
                if not Input then return end
                grabState.l = not grabState.l
                if grabState.l then
                    Input.lFist = 1; Input.lIndex = 1
                    grabL.BackgroundTransparency = 0.2
                    grabL.BackgroundColor3 = activeColor
                else
                    Input.lFist = 0; Input.lIndex = 0
                    grabL.BackgroundTransparency = 0.5
                    grabL.BackgroundColor3 = normalColor
                end
            end)
            -- 右手抓取切换
            grabR.MouseButton1Click:Connect(function()
                if not Input then return end
                grabState.r = not grabState.r
                if grabState.r then
                    Input.rFist = 1; Input.rIndex = 1
                    grabR.BackgroundTransparency = 0.2
                    grabR.BackgroundColor3 = activeColor
                else
                    Input.rFist = 0; Input.rIndex = 0
                    grabR.BackgroundTransparency = 0.5
                    grabR.BackgroundColor3 = normalColor
                end
            end)
            -- 左手捏取切换
            pinchL.MouseButton1Click:Connect(function()
                if not Input then return end
                pinchState.l = not pinchState.l
                if pinchState.l then
                    Input.lIndex = 1; Input.lFist = 0; Input.lThumb = 0
                    pinchL.BackgroundTransparency = 0.2
                    pinchL.BackgroundColor3 = activeColor
                else
                    Input.lIndex = 0
                    pinchL.BackgroundTransparency = 0.5
                    pinchL.BackgroundColor3 = normalColor
                end
            end)
            -- 右手捏取切换
            pinchR.MouseButton1Click:Connect(function()
                if not Input then return end
                pinchState.r = not pinchState.r
                if pinchState.r then
                    Input.rIndex = 1; Input.rFist = 0; Input.rThumb = 0
                    pinchR.BackgroundTransparency = 0.2
                    pinchR.BackgroundColor3 = activeColor
                else
                    Input.rIndex = 0
                    pinchR.BackgroundTransparency = 0.5
                    pinchR.BackgroundColor3 = normalColor
                end
            end)

            -- 5. 右上角功能区
            local func = Instance.new("Frame")
            func.Size = UDim2.fromScale(0.26, 0.2)
            func.Position = UDim2.fromScale(0.97, 0.18)
            func.AnchorPoint = Vector2.new(1, 0)
            func.BackgroundTransparency = 1
            func.Parent = mobileGui
            local scaleUp = createBtn(func, "ScaleUp", UDim2.fromScale(0, 0), UDim2.fromScale(0.48, 0.28), "变大", 12)
            local scaleDown = createBtn(func, "ScaleDown", UDim2.fromScale(1, 0), UDim2.fromScale(0.48, 0.28), "变小", 12)
            scaleDown.AnchorPoint = Vector2.new(1, 0)
            scaleUp.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch then setScale(S.scale + 1) end
            end)
            scaleDown.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch then setScale(S.scale - 1) end
            end)
            local reachUp = createBtn(func, "ReachUp", UDim2.fromScale(0, 0.36), UDim2.fromScale(0.48, 0.28), "伸长", 12)
            local reachDown = createBtn(func, "ReachDown", UDim2.fromScale(1, 0.36), UDim2.fromScale(0.48, 0.28), "缩短", 12)
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
            local toggleLook = createBtn(func, "ToggleLook", UDim2.fromScale(0.5, 1), UDim2.fromScale(0.96, 0.28), "解锁视角", 12)
            toggleLook.AnchorPoint = Vector2.new(0.5, 1)
            toggleLook.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.Touch then
                    setLook(not S.look)
                    toggleLook.Text = S.look and "解锁视角" or "锁定视角"
                end
            end)

            -- 6. 右半屏滑动视角（多指防鬼畜优化）
            local activeTouch = nil
            local lastTouchPos = Vector2.zero
            local touchSens = S.sens
            UIS.TouchStarted:Connect(function(input)
                if activeTouch then return end
                local vp = workspace.CurrentCamera.ViewportSize
                if input.Position.X > vp.X * 0.5
                    and input.Position.Y < vp.Y * 0.85
                    and input.Position.Y > vp.Y * 0.15 then
                    activeTouch = input
                    lastTouchPos = input.Position
                end
            end)
            UIS.TouchMoved:Connect(function(input)
                if input ~= activeTouch then return end
                local delta = input.Position - lastTouchPos
                yaw = yaw - delta.X * touchSens
                pitch = math.clamp(pitch - delta.Y * touchSens, -1.45, 1.45)
                lastTouchPos = input.Position
            end)
            UIS.TouchEnded:Connect(function(input)
                if input == activeTouch then
                    activeTouch = nil
                end
            end)
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
