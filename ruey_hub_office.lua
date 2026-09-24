-- ============================================
-- RUEY HUB — Office Autofarm
-- Logic: extracted & cleaned from _ForkyHUB
-- UI: custom ruey hub (all black, draggable)
-- ============================================

-- stop previous instance if re-injected
pcall(function()
    if getgenv and getgenv().RUEYHUB_OFFICE_STOP then
        getgenv().RUEYHUB_OFFICE_STOP()
    end
end)

-- ============================================
-- ADONIS BYPASS
-- hooks Detected() to always return true,
-- hooks Kill() to swallow the kick,
-- patches debug.info so Adonis can't identify
-- our hooked function via coroutine walk
-- ============================================
local _adonisDebugMode = false   -- set true para makita kung ano ino-catch ni Adonis
local _hookedFns = {}
local _detectedFn, _killFn

setthreadidentity(2)
for _, v in getgc(true) do
    if typeof(v) == "table" then
        local detected = rawget(v, "Detected")
        local kill     = rawget(v, "Kill")

        -- hook Detected() → always returns true (legit)
        if typeof(detected) == "function" and not _detectedFn then
            _detectedFn = detected
            local _orig; _orig = hookfunction(_detectedFn, function(method, info, name)
                if method ~= "_" then
                    if _adonisDebugMode then
                        warn(("[RueyHub] Adonis flagged — Method: %s | Info: %s"):format(tostring(method), tostring(info)))
                    end
                end
                return true   -- spoof: "yep totally clean bro"
            end)
            table.insert(_hookedFns, _detectedFn)
        end

        -- hook Kill() → swallow silently
        if rawget(v, "Variables") and rawget(v, "Process")
           and typeof(kill) == "function" and not _killFn then
            _killFn = kill
            local _orig; _orig = hookfunction(_killFn, function(target)
                if _adonisDebugMode then
                    warn(("[RueyHub] Adonis tried to kill: %s"):format(tostring(target)))
                end
                -- returns nothing, kick never fires
            end)
            table.insert(_hookedFns, _killFn)
        end
    end
end

-- patch debug.info so Adonis coroutine-walk can't fingerprint our hook
local _origDebugInfo
_origDebugInfo = hookfunction(getrenv().debug.info, newcclosure(function(...)
    local a, f = ...
    -- if Adonis passes our hooked Detected fn as thread arg → yield it out
    if _detectedFn and a == _detectedFn then
        return coroutine.yield(coroutine.running())
    end
    return _origDebugInfo(...)
end))

setthreadidentity(7)

-- ============================================
-- SERVICES
-- ============================================
if not game:IsLoaded() then game.Loaded:Wait() end
task.wait(2)

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local PathfindingService  = game:GetService("PathfindingService")
local GuiService          = game:GetService("GuiService")
local UserInputService    = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser         = game:GetService("VirtualUser")

local Player    = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

-- ============================================
-- CONSTANTS
-- ============================================
local MIN_DELAY       = 0.0
local MAX_DELAY       = 10.0
local answerDelayMin  = 0.0
local answerDelayMax  = 1.0

-- office worker spawn + chair cluster
local CHAIR_SEARCH_AREA   = Vector3.new(-5927.33, 4.57, -228.61)
local CHAIR_SEARCH_RADIUS = 50

-- printer teleport targets
local PRINTER_POS = {
    Print_1 = Vector3.new(-6008.84, 4.58, -210.84),
    Print_2 = Vector3.new(-6008.84, 4.58, -224.52),
    Print_3 = Vector3.new(-6008.84, 4.58, -238.36),
    Print_4 = Vector3.new(-5868.43, 4.58, -213.19),
    Print_5 = Vector3.new(-5868.43, 4.58, -249.96),
}

local MAX_ANSWER_RETRIES = 8
local ANSWER_RETRY_DELAY = 0.65

-- ============================================
-- STATE
-- ============================================
local active            = false
local farmRunning       = false
local joiningTeam       = false
local currentSeat       = nil
local pendingPrint      = nil
local isDoingPrinterJob = false
local printerVerifyName         = nil
local printerVerifyStartedAt    = 0
local printerVerifyQuestionCount= 0

local questionsAnswered  = 0
local printersCompleted  = 0
local sessionStartTime   = nil
local sessionStartMoney  = nil

local remCorrectAnswer = nil
local remGenQuestion   = nil
local remAssignPrint   = nil
local questionConnection = nil
local printConnection    = nil
local connections        = {}

local seatBlockActive = false
local seatBlockToken  = 0
local answeringQuestion   = false
local lastQuestionKey     = ""
local lastQuestionAt      = 0
local activeQuestionToken = 0
local lastAfkAction       = os.clock()

-- ============================================
-- ANTI-AFK
-- ============================================
local function antiAfkTick()
    local now = os.clock()
    if now - lastAfkAction >= 25 then
        lastAfkAction = now
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
        pcall(function()
            VirtualInputManager:SendMouseMoveEvent(0, 1, game)
            task.wait(0.05)
            VirtualInputManager:SendMouseMoveEvent(0, -1, game)
        end)
    end
end

-- ============================================
-- HELPERS
-- ============================================
local function formatNumber(n)
    n = tonumber(n) or 0
    local sign = n < 0 and "-" or ""
    local s = tostring(math.floor(math.abs(n)))
    return sign .. s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function formatTime(t)
    t = math.max(0, math.floor(tonumber(t) or 0))
    return string.format("%02d:%02d:%02d",
        math.floor(t / 3600) % 24,
        math.floor(t / 60) % 60,
        t % 60)
end

local function getMoney()
    local playerData = Player:FindFirstChild("PlayerData")
    if playerData then
        local v = playerData:FindFirstChild("RPValue")
                or playerData:FindFirstChild("Money")
                or playerData:FindFirstChild("Cash")
        if v and v.Value ~= nil then return tonumber(v.Value) or 0 end
    end
    local ls = Player:FindFirstChild("leaderstats")
    if ls then
        local v = ls:FindFirstChild("RP")
                or ls:FindFirstChild("Money")
                or ls:FindFirstChild("Cash")
        if v and v.Value ~= nil then return tonumber(v.Value) or 0 end
    end
    return 0
end

local function randomDelay(lo, hi)
    lo = math.clamp(tonumber(lo) or 0, MIN_DELAY, MAX_DELAY)
    hi = math.clamp(tonumber(hi) or lo, lo, MAX_DELAY)
    return lo + math.random() * (hi - lo)
end

local function safeFireServer(remote, ...)
    if not remote then return end
    local args = { ... }
    task.spawn(function()
        if setthreadidentity then pcall(setthreadidentity, 2) end
        pcall(function() remote:FireServer(unpack(args)) end)
        if setthreadidentity then pcall(setthreadidentity, 7) end
    end)
end

local function getChar()
    return Player.Character or Player.CharacterAdded:Wait()
end

local function sendKey(key)
    VirtualInputManager:SendKeyEvent(true,  key, false, game)
    task.wait(0.1)
    VirtualInputManager:SendKeyEvent(false, key, false, game)
end

local function releaseSprint()
    pcall(function()
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
    end)
end

-- ============================================
-- SEAT BLOCK
-- keeps humanoid from auto-sitting in wrong seats
-- ============================================
local function setSeatBlocking(enabled)
    seatBlockActive = enabled
    seatBlockToken  = seatBlockToken + 1
    local token = seatBlockToken

    local function updateHumanoid()
        local char = Player.Character
        local hum  = char and char:FindFirstChild("Humanoid")
        if not hum then return end
        pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Seated, not enabled) end)
        if enabled and hum.SeatPart then
            hum.Sit = false
            pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
        end
    end

    updateHumanoid()
    if enabled then
        task.spawn(function()
            while seatBlockActive and seatBlockToken == token do
                updateHumanoid()
                task.wait(0.1)
            end
        end)
    end
end

-- ============================================
-- MOVEMENT
-- ============================================
local function walkTo(targetPos)
    local char = getChar()
    local hum  = char:FindFirstChild("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")
    if not hum or not root then return false end
    releaseSprint()

    local path = PathfindingService:CreatePath({
        AgentRadius  = 2,
        AgentHeight  = 5,
        AgentCanJump = true,
        AgentJumpHeight = 7.5,
        AgentMaxSlope   = 45,
    })

    local ok = pcall(function() path:ComputeAsync(root.Position, targetPos) end)
    if not ok or path.Status ~= Enum.PathStatus.Success then
        hum:MoveTo(targetPos)
        local t0 = os.clock()
        while active and (root.Position - targetPos).Magnitude > 4 and os.clock() - t0 < 10 do
            task.wait(0.1)
        end
        return (root.Position - targetPos).Magnitude <= 6
    end

    for _, wp in ipairs(path:GetWaypoints()) do
        if not active then break end
        if wp.Action == Enum.PathWaypointAction.Jump then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
        hum:MoveTo(wp.Position)
        local timeout = 0
        while active and (root.Position - wp.Position).Magnitude > 4 and timeout < 50 do
            task.wait(0.1)
            timeout += 1
        end
    end
    releaseSprint()
    return true
end

local function seatTP(seat)
    if not seat then return false end
    local char = getChar()
    local hum  = char:WaitForChild("Humanoid")
    local root = char:WaitForChild("HumanoidRootPart")
    local orig = seat.CFrame
    seat.CFrame = root.CFrame * CFrame.new(0, -2, -3)
    task.wait(0.2)
    seat:Sit(hum)
    task.wait(0.3)
    if hum.SeatPart ~= seat then seat:Sit(hum) task.wait(0.4) end
    if hum.SeatPart ~= seat then seat.CFrame = orig return false end
    seat.CFrame = orig
    task.wait(0.5)
    return hum.SeatPart == seat
end

local function findAvailableChair()
    local best, bestDist = nil, math.huge
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Seat") or obj:IsA("VehicleSeat") then
            local d = (obj.Position - CHAIR_SEARCH_AREA).Magnitude
            if d < CHAIR_SEARCH_RADIUS and not obj.Occupant and d < bestDist then
                bestDist = d
                best = obj
            end
        end
    end
    return best
end

local function interactWithPrinter()
    pcall(function() VirtualUser:CaptureController() VirtualUser:SetKeyDown("0x65") end)
    task.wait(1.8)
    pcall(function() VirtualUser:SetKeyUp("0x65") end)
    return true
end

-- ============================================
-- QUESTION SOLVING
-- ============================================
local function solveQuestion(question)
    local a, op, b = tostring(question):match("(%d+)%s*([%+%-%*%/])%s*(%d+)")
    if not a then return nil end
    a, b = tonumber(a), tonumber(b)
    if op == "+" then return a + b
    elseif op == "-" then return a - b
    elseif op == "*" then return a * b
    elseif op == "/" and b ~= 0 then return math.floor(a / b)
    end
    return nil
end

local function normalizeText(t)
    return tostring(t or ""):lower():gsub("%s+", ""):gsub(",", "")
end

local function getGuiText(obj)
    if obj:IsA("TextButton") or obj:IsA("TextLabel") or obj:IsA("TextBox") then
        return obj.Text or ""
    end
    for _, c in ipairs(obj:GetDescendants()) do
        if c:IsA("TextButton") or c:IsA("TextLabel") or c:IsA("TextBox") then
            local t = c.Text
            if t and t ~= "" then return t end
        end
    end
    return ""
end

local function isVisibleGui(obj)
    if obj:IsDescendantOf(PlayerGui:FindFirstChild("RueyHub_UI") or Instance.new("Folder")) then return false end
    if not obj:IsA("GuiObject") then return false end
    if obj.AbsoluteSize.X <= 0 or obj.AbsoluteSize.Y <= 0 then return false end
    local cur = obj
    while cur do
        if cur:IsA("GuiObject") and not cur.Visible then return false end
        if (cur:IsA("ScreenGui") or cur:IsA("SurfaceGui") or cur:IsA("BillboardGui")) and not cur.Enabled then return false end
        cur = cur.Parent
    end
    return true
end

local function textMatches(btnText, ansText, solved)
    local nb = normalizeText(btnText)
    if nb == "" then return false end
    if normalizeText(ansText) ~= "" and nb == normalizeText(ansText) then return true end
    if normalizeText(solved) ~= "" and nb == normalizeText(solved) then return true end
    local numBtn = tonumber(btnText:match("%-?%d+"))
    local numSol = tonumber(solved)
    return numBtn and numSol and numBtn == numSol
end

local function guiHasQuestion(root, question)
    local needles = {}
    local nq = normalizeText(question)
    if nq ~= "" then needles[#needles+1] = nq end
    local a, op, b = tostring(question or ""):match("(%d+)%s*([%+%-%*%/])%s*(%d+)")
    if a and op and b then
        local ne = normalizeText(a .. op .. b)
        if ne ~= "" then needles[#needles+1] = ne end
    end
    if #needles == 0 then return false end
    for _, obj in ipairs(root:GetDescendants()) do
        if obj:IsA("TextButton") or obj:IsA("TextLabel") or obj:IsA("TextBox") then
            local hay = normalizeText(obj.Text)
            if hay ~= "" then
                for _, n in ipairs(needles) do
                    if hay:find(n, 1, true) then return true end
                end
            end
        end
    end
    return false
end

local function getRootDisplayOrder(obj)
    local cur = obj
    while cur do
        if cur:IsA("ScreenGui") then return cur.DisplayOrder or 0 end
        cur = cur.Parent
    end
    return 0
end

local function getTopmostScore(btn)
    local center = btn.AbsolutePosition + btn.AbsoluteSize / 2
    local ok, objs = pcall(function() return GuiService:GetGuiObjectsAtPosition(center.X, center.Y) end)
    if not ok or type(objs) ~= "table" then return 0 end
    for i, obj in ipairs(objs) do
        if obj == btn or obj:IsDescendantOf(btn) or btn:IsDescendantOf(obj) then
            return math.max(0, 80 - i)
        end
    end
    return 0
end

local function scoreBtn(btn, question)
    local score = 0
    local area  = btn.AbsoluteSize.X * btn.AbsoluteSize.Y
    score += getRootDisplayOrder(btn) * 4
    score += getTopmostScore(btn)
    score += math.min(30, area / 1000)
    score += (btn.ZIndex or 0)
    local cur, depth = btn.Parent, 1
    while cur and depth <= 8 do
        local nm = cur.Name:lower()
        if nm:find("work",1,true) or nm:find("question",1,true) or nm:find("answer",1,true) then
            score += 6
        end
        if question and guiHasQuestion(cur, question) then
            score += (220 - depth * 10)
            break
        end
        cur = cur.Parent
        depth += 1
    end
    return score
end

local function isOfficeCandidate(obj)
    local cur = obj
    while cur do
        local nm = cur.Name:lower()
        if nm == "workgui" then return true end
        if cur:IsA("SurfaceGui") or cur:IsA("BillboardGui") then
            return nm:find("work",1,true) or nm:find("office",1,true) or nm:find("computer",1,true)
        end
        if cur == PlayerGui or cur == workspace then break end
        cur = cur.Parent
    end
    return false
end

local function findMatchTarget(btn, ansText, solved)
    local best, bestArea = nil, math.huge
    local function consider(obj, text)
        if not obj:IsA("GuiObject") or not isVisibleGui(obj) then return end
        if not textMatches(text, ansText, solved) then return end
        local area = obj.AbsoluteSize.X * obj.AbsoluteSize.Y
        if area > 0 and area < bestArea then best = obj bestArea = area end
    end
    if btn:IsA("TextButton") then consider(btn, btn.Text or "") end
    for _, c in ipairs(btn:GetDescendants()) do
        if c:IsA("TextButton") or c:IsA("TextLabel") or c:IsA("TextBox") then
            consider(c, c.Text or "")
        end
    end
    return best
end

local function findAnswerButton(ansText, solved, question)
    local best, bestScore = nil, -math.huge
    local candidates = {}
    local seen = {}
    local root = PlayerGui:FindFirstChild("WorkGui")
    if not root then return nil, 0, {} end
    for _, obj in ipairs(root:GetDescendants()) do
        if obj:IsA("TextButton") or obj:IsA("ImageButton") then
            local target = findMatchTarget(obj, ansText, solved)
            if target and isVisibleGui(obj) and isOfficeCandidate(obj) then
                local key = normalizeText(getGuiText(target))
                if key == "" then key = normalizeText(getGuiText(obj)) end
                if key ~= "" and seen[key] then continue end
                if key ~= "" then seen[key] = true end
                local s = scoreBtn(obj, question) + getTopmostScore(target)
                table.insert(candidates, { Button = obj, Target = target, Score = s })
                if s >= bestScore then best = obj bestScore = s end
            end
        end
    end
    table.sort(candidates, function(a, b) return a.Score > b.Score end)
    return best, #candidates, candidates
end

local function fireGuiButton(btn)
    if not btn or not btn.Parent or not btn:IsA("GuiButton") then return false end
    local fired = false
    for _, signal in ipairs({ btn.MouseButton1Click, btn.Activated }) do
        if firesignal then
            fired = pcall(function() firesignal(signal) end) or fired
        end
        if getconnections then
            local ok, conns = pcall(function() return getconnections(signal) end)
            if ok and type(conns) == "table" then
                for _, c in ipairs(conns) do
                    local ok2 = pcall(function()
                        if c.Fire then c:Fire()
                        elseif c.Function then c.Function() end
                    end)
                    fired = ok2 or fired
                end
            end
        end
    end
    pcall(function()
        local center = btn.AbsolutePosition + btn.AbsoluteSize / 2
        VirtualInputManager:SendMouseButtonEvent(center.X, center.Y, 0, true,  game, 0)
        task.wait(0.03)
        VirtualInputManager:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
        fired = true
    end)
    return fired
end

local function clickAndWait(btn, timeout, target)
    local response, done = nil, false
    local conn = remCorrectAnswer.OnClientEvent:Connect(function(r) response = r done = true end)
    local t0 = os.clock()
    local clicked = fireGuiButton(btn)
    if target and target ~= btn and target:IsA("GuiButton") then
        clicked = fireGuiButton(target) or clicked
    end
    while active and not done and os.clock() - t0 < timeout do task.wait(0.05) end
    conn:Disconnect()
    return response, clicked
end

local function answerQuestion(question, answers, sessionId, attempt, qToken)
    attempt = tonumber(attempt) or 1
    qToken  = tonumber(qToken)  or activeQuestionToken
    if not active or answeringQuestion or qToken ~= activeQuestionToken then return end
    answeringQuestion = true

    task.spawn(function()
        local ok, err = pcall(function()
            if not active or qToken ~= activeQuestionToken then return end

            local solved = solveQuestion(question)
            if not solved then return end
            local ansText = tostring(solved)

            if type(answers) == "table" then
                for _, a in ipairs(answers) do
                    if type(a) == "table" and tonumber(a.Text) == solved then
                        ansText = tostring(a.Text)
                        break
                    end
                end
            end

            task.wait(randomDelay(answerDelayMin, answerDelayMax))
            if not active or qToken ~= activeQuestionToken then return end

            local btn, count, cands = findAnswerButton(ansText, solved, question)
            if not btn then
                if attempt < MAX_ANSWER_RETRIES and qToken == activeQuestionToken then
                    task.delay(ANSWER_RETRY_DELAY, function()
                        answerQuestion(question, answers, sessionId, attempt + 1, qToken)
                    end)
                end
                return
            end

            local finalResp, clickedAny = nil, false
            for i, cand in ipairs(cands) do
                if not active or qToken ~= activeQuestionToken then return end
                local tout = i == #cands and 4 or 1.3
                local resp, clicked = clickAndWait(cand.Button, tout, cand.Target)
                clickedAny = clickedAny or clicked
                if resp == true or tostring(resp):lower() == "success" then
                    finalResp = resp
                    break
                end
                task.wait(0.12)
            end

            if finalResp == true or tostring(finalResp):lower() == "success" then
                questionsAnswered += 1
                if printerVerifyName then
                    printersCompleted  += 1
                    printerVerifyName   = nil
                    printerVerifyStartedAt = 0
                    printerVerifyQuestionCount = 0
                end
                _G._RueyHub_UpdateStats and _G._RueyHub_UpdateStats()
            elseif clickedAny and attempt < MAX_ANSWER_RETRIES then
                if qToken == activeQuestionToken then
                    task.delay(ANSWER_RETRY_DELAY, function()
                        answerQuestion(question, answers, sessionId, attempt + 1, qToken)
                    end)
                end
            elseif attempt < MAX_ANSWER_RETRIES then
                if qToken == activeQuestionToken then
                    task.delay(ANSWER_RETRY_DELAY, function()
                        answerQuestion(question, answers, sessionId, attempt + 1, qToken)
                    end)
                end
            end
        end)
        answeringQuestion = false
        if not ok then warn("[RueyHub] question error: " .. tostring(err)) end
    end)
end

local function onQuestion(question, answers, sessionId)
    if not active then return end
    local key = tostring(sessionId or "") .. "|" .. normalizeText(question)
    local now = os.clock()
    if key == lastQuestionKey and now - lastQuestionAt < 4 then return end
    lastQuestionKey = key
    lastQuestionAt  = now
    activeQuestionToken += 1
    answerQuestion(question, answers, sessionId, 1, activeQuestionToken)
end

-- ============================================
-- REMOTE SETUP
-- ============================================
local function ensureRemotes()
    local jobEvents = ReplicatedStorage:WaitForChild("JobEvents", 10)
    if not jobEvents then return false, "JobEvents not found" end
    remCorrectAnswer = jobEvents:WaitForChild("CorrectAnswer",   10)
    remGenQuestion   = jobEvents:WaitForChild("GenerateQuestion",10)
    remAssignPrint   = jobEvents:WaitForChild("AssignPrintJob",  10)
    if not remCorrectAnswer or not remGenQuestion or not remAssignPrint then
        return false, "Office remotes missing"
    end
    return true
end

local function hookOfficeRemotes()
    if questionConnection or printConnection then return end
    questionConnection = remGenQuestion.OnClientEvent:Connect(onQuestion)
    printConnection    = remAssignPrint.OnClientEvent:Connect(function(printerName)
        if not active then return end
        pendingPrint = printerName
    end)
    table.insert(connections, questionConnection)
    table.insert(connections, printConnection)
end

-- ============================================
-- TEAM JOIN
-- ============================================
local function joinOfficeTeam()
    if joiningTeam then return true end
    joiningTeam = true
    local menuToggle = ReplicatedStorage:WaitForChild("menuToggleRequest", 10)
    if menuToggle then safeFireServer(menuToggle) task.wait(1) end
    local jobEvents = ReplicatedStorage:WaitForChild("JobEvents", 10)
    if not jobEvents then joiningTeam = false return false end
    local teamChange = jobEvents:WaitForChild("TeamChangeRequest", 10)
    if not teamChange then joiningTeam = false return false end
    safeFireServer(teamChange, "Office Worker", 0, 0, 0, "MainMenu")
    task.wait(3)
    joiningTeam = false
    return true
end

-- ============================================
-- FARM LOOP
-- ============================================
local function mainFarmLoop()
    local usedInitialTP = false
    while active do
        local char = getChar()
        local hum  = char:WaitForChild("Humanoid")
        local seat = findAvailableChair()
        if not seat then task.wait(3) continue end
        currentSeat = seat

        local seated = false
        if not usedInitialTP then
            seated = seatTP(seat)
            usedInitialTP = seated
        else
            walkTo(seat.Position)
            task.wait(0.3)
            seat:Sit(hum)
            task.wait(0.5)
            seated = hum.SeatPart == seat
        end

        if not seated then task.wait(2) continue end

        while active do
            antiAfkTick()

            if pendingPrint then
                local pos = PRINTER_POS[pendingPrint]
                if pos then
                    isDoingPrinterJob = true
                    local savedSeat   = currentSeat
                    local savedPrint  = pendingPrint
                    printerVerifyName = nil
                    printerVerifyStartedAt = 0
                    printerVerifyQuestionCount = 0

                    setSeatBlocking(true)
                    sendKey(Enum.KeyCode.Space)
                    task.wait(0.5)
                    walkTo(pos)
                    task.wait(0.5)
                    interactWithPrinter()
                    task.wait(1)
                    pendingPrint = nil

                    if savedSeat and savedSeat.Parent then
                        walkTo(savedSeat.Position)
                        task.wait(0.5)
                        setSeatBlocking(false)
                        savedSeat:Sit(hum)
                        task.wait(0.5)
                        currentSeat            = savedSeat
                        printerVerifyName      = savedPrint
                        printerVerifyStartedAt = hum.SeatPart == savedSeat and os.clock() or 0
                        printerVerifyQuestionCount = questionsAnswered
                    else
                        setSeatBlocking(false)
                    end
                    isDoingPrinterJob = false
                    setSeatBlocking(false)
                else
                    pendingPrint = nil
                end

            elseif printerVerifyName and currentSeat and hum.SeatPart == currentSeat then
                if questionsAnswered > printerVerifyQuestionCount then
                    printerVerifyName = nil
                    printerVerifyStartedAt = 0
                    printerVerifyQuestionCount = 0
                elseif printerVerifyStartedAt <= 0 then
                    printerVerifyStartedAt = os.clock()
                elseif os.clock() - printerVerifyStartedAt >= 15 then
                    pendingPrint = printerVerifyName
                    printerVerifyName = nil
                    printerVerifyStartedAt = 0
                    printerVerifyQuestionCount = 0
                end

            elseif not isDoingPrinterJob and hum.SeatPart ~= currentSeat then
                if currentSeat and currentSeat.Parent then
                    walkTo(currentSeat.Position)
                    task.wait(0.3)
                    currentSeat:Sit(hum)
                    task.wait(0.5)
                    if hum.SeatPart ~= currentSeat then task.wait(1) end
                else
                    break
                end
            end
            task.wait(0.2)
        end
        task.wait(1)
    end
end

local function stopFarm()
    if not farmRunning then return end
    active      = false
    farmRunning = false
    releaseSprint()
    setSeatBlocking(false)
    sessionStartTime  = nil
    sessionStartMoney = nil
    pendingPrint      = nil
    isDoingPrinterJob = false
    printerVerifyName = nil
end

local function startFarm()
    if farmRunning then return true end
    local joined = joinOfficeTeam()
    if not joined then return false end

    local t0 = os.clock()
    repeat task.wait(0.5)
    until (Player.Character
       and Player.Character:FindFirstChild("HumanoidRootPart")
       and Player.Character:FindFirstChild("Humanoid"))
       or os.clock() - t0 > 15

    if not (Player.Character
        and Player.Character:FindFirstChild("HumanoidRootPart")
        and Player.Character:FindFirstChild("Humanoid")) then
        return false
    end

    local ok = ensureRemotes()
    if not ok then return false end

    active            = true
    farmRunning       = true
    questionsAnswered = 0
    printersCompleted = 0
    pendingPrint      = nil
    currentSeat       = nil
    printerVerifyName = nil
    printerVerifyStartedAt = 0
    printerVerifyQuestionCount = 0
    sessionStartTime  = os.time()
    sessionStartMoney = getMoney()

    hookOfficeRemotes()
    task.spawn(mainFarmLoop)
    return true
end

-- ============================================
-- RUEY HUB — CUSTOM UI
-- all black, small, draggable, toggle, close
-- ============================================
do
    -- destroy old if re-injected
    local old = PlayerGui:FindFirstChild("RueyHub_UI")
    if old then old:Destroy() end

    local guiParent = (typeof(gethui) == "function" and gethui()) or PlayerGui

    local sg = Instance.new("ScreenGui")
    sg.Name             = "RueyHub_UI"
    sg.IgnoreGuiInset   = true
    sg.ResetOnSpawn     = false
    sg.DisplayOrder     = 99
    sg.Parent           = guiParent

    -- ── OPEN BUTTON (shown when panel is hidden) ──
    local openBtn = Instance.new("TextButton", sg)
    openBtn.Size            = UDim2.new(0, 76, 0, 24)
    openBtn.Position        = UDim2.new(0, 8, 0, 8)
    openBtn.BackgroundColor3= Color3.fromRGB(0, 0, 0)
    openBtn.TextColor3      = Color3.fromRGB(200, 200, 200)
    openBtn.Font            = Enum.Font.GothamBold
    openBtn.TextSize        = 11
    openBtn.Text            = "RUEY HUB"
    openBtn.BorderSizePixel = 0
    openBtn.Visible         = false
    local oc = Instance.new("UICorner", openBtn) oc.CornerRadius = UDim.new(0, 5)
    local os2 = Instance.new("UIStroke", openBtn)
    os2.Color     = Color3.fromRGB(50, 50, 50)
    os2.Thickness = 1

    -- ── MAIN PANEL ──
    local panel = Instance.new("Frame", sg)
    panel.Name              = "Panel"
    panel.Size              = UDim2.new(0, 220, 0, 0)
    panel.AutomaticSize     = Enum.AutomaticSize.Y
    panel.Position          = UDim2.new(0, 8, 0, 8)
    panel.BackgroundColor3  = Color3.fromRGB(0, 0, 0)
    panel.BorderSizePixel   = 0
    panel.ClipsDescendants  = false
    local pc = Instance.new("UICorner", panel) pc.CornerRadius = UDim.new(0, 6)
    local ps = Instance.new("UIStroke", panel)
    ps.Color     = Color3.fromRGB(40, 40, 40)
    ps.Thickness = 1
    local pl = Instance.new("UIListLayout", panel)
    pl.FillDirection       = Enum.FillDirection.Vertical
    pl.SortOrder           = Enum.SortOrder.LayoutOrder
    pl.Padding             = UDim.new(0, 0)

    -- ── TITLE BAR (draggable) ──
    local titleBar = Instance.new("Frame", panel)
    titleBar.Size            = UDim2.new(1, 0, 0, 28)
    titleBar.BackgroundColor3= Color3.fromRGB(10, 10, 10)
    titleBar.BorderSizePixel = 0
    titleBar.LayoutOrder     = 0
    local tbl = Instance.new("UICorner", titleBar) tbl.CornerRadius = UDim.new(0, 6)

    local titleLabel = Instance.new("TextLabel", titleBar)
    titleLabel.Size             = UDim2.new(1, -56, 1, 0)
    titleLabel.Position         = UDim2.new(0, 8, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.TextColor3       = Color3.fromRGB(210, 210, 210)
    titleLabel.Font             = Enum.Font.GothamBold
    titleLabel.TextSize         = 11
    titleLabel.Text             = "RUEY HUB"
    titleLabel.TextXAlignment   = Enum.TextXAlignment.Left

    -- close btn
    local closeBtn = Instance.new("TextButton", titleBar)
    closeBtn.Size            = UDim2.new(0, 22, 0, 22)
    closeBtn.Position        = UDim2.new(1, -26, 0.5, -11)
    closeBtn.BackgroundColor3= Color3.fromRGB(30, 30, 30)
    closeBtn.TextColor3      = Color3.fromRGB(180, 180, 180)
    closeBtn.Font            = Enum.Font.GothamBold
    closeBtn.TextSize        = 11
    closeBtn.Text            = "✕"
    closeBtn.BorderSizePixel = 0
    local cc = Instance.new("UICorner", closeBtn) cc.CornerRadius = UDim.new(0, 4)

    -- ── CONTENT ──
    local content = Instance.new("Frame", panel)
    content.Size              = UDim2.new(1, 0, 0, 0)
    content.AutomaticSize     = Enum.AutomaticSize.Y
    content.BackgroundTransparency = 1
    content.BorderSizePixel   = 0
    content.LayoutOrder       = 1
    local cl = Instance.new("UIListLayout", content)
    cl.FillDirection = Enum.FillDirection.Vertical
    cl.SortOrder     = Enum.SortOrder.LayoutOrder
    cl.Padding       = UDim.new(0, 2)
    local cp = Instance.new("UIPadding", content)
    cp.PaddingLeft   = UDim.new(0, 8)
    cp.PaddingRight  = UDim.new(0, 8)
    cp.PaddingTop    = UDim.new(0, 6)
    cp.PaddingBottom = UDim.new(0, 8)

    -- helper: stat row (label : value)
    local function makeStatRow(parent, labelStr, order)
        local row = Instance.new("Frame", parent)
        row.Size              = UDim2.new(1, 0, 0, 18)
        row.BackgroundTransparency = 1
        row.BorderSizePixel   = 0
        row.LayoutOrder       = order

        local lbl = Instance.new("TextLabel", row)
        lbl.Size              = UDim2.new(0.5, 0, 1, 0)
        lbl.BackgroundTransparency = 1
        lbl.TextColor3        = Color3.fromRGB(110, 110, 110)
        lbl.Font              = Enum.Font.Gotham
        lbl.TextSize          = 10
        lbl.Text              = labelStr
        lbl.TextXAlignment    = Enum.TextXAlignment.Left

        local val = Instance.new("TextLabel", row)
        val.Size              = UDim2.new(0.5, 0, 1, 0)
        val.Position          = UDim2.new(0.5, 0, 0, 0)
        val.BackgroundTransparency = 1
        val.TextColor3        = Color3.fromRGB(220, 220, 220)
        val.Font              = Enum.Font.GothamBold
        val.TextSize          = 10
        val.Text              = "—"
        val.TextXAlignment    = Enum.TextXAlignment.Right

        return val
    end

    -- helper: section divider
    local function makeDivider(parent, order)
        local d = Instance.new("Frame", parent)
        d.Size              = UDim2.new(1, 0, 0, 1)
        d.BackgroundColor3  = Color3.fromRGB(30, 30, 30)
        d.BorderSizePixel   = 0
        d.LayoutOrder       = order
        return d
    end

    -- ── TOGGLE ALL ──
    local toggleRow = Instance.new("Frame", content)
    toggleRow.Size              = UDim2.new(1, 0, 0, 30)
    toggleRow.BackgroundTransparency = 1
    toggleRow.LayoutOrder       = 0

    local toggleBtn = Instance.new("TextButton", toggleRow)
    toggleBtn.Size            = UDim2.new(1, 0, 0, 26)
    toggleBtn.Position        = UDim2.new(0, 0, 0.5, -13)
    toggleBtn.BackgroundColor3= Color3.fromRGB(15, 15, 15)
    toggleBtn.TextColor3      = Color3.fromRGB(200, 200, 200)
    toggleBtn.Font            = Enum.Font.GothamBold
    toggleBtn.TextSize        = 11
    toggleBtn.Text            = "▶  START FARM"
    toggleBtn.BorderSizePixel = 0
    local tbc = Instance.new("UICorner", toggleBtn) tbc.CornerRadius = UDim.new(0, 5)
    local tbs = Instance.new("UIStroke", toggleBtn)
    tbs.Color     = Color3.fromRGB(50, 50, 50)
    tbs.Thickness = 1

    local function refreshToggle()
        if farmRunning then
            toggleBtn.Text             = "■  STOP FARM"
            toggleBtn.TextColor3       = Color3.fromRGB(230, 90, 90)
            tbs.Color                  = Color3.fromRGB(100, 30, 30)
        else
            toggleBtn.Text             = "▶  START FARM"
            toggleBtn.TextColor3       = Color3.fromRGB(200, 200, 200)
            tbs.Color                  = Color3.fromRGB(50, 50, 50)
        end
    end

    makeDivider(content, 1)

    -- ── STATS ──
    local valStatus   = makeStatRow(content, "Status",       2)
    local valMoney    = makeStatRow(content, "Money",        3)
    local valEarned   = makeStatRow(content, "Session +",   4)
    local valPerHour  = makeStatRow(content, "/ Hour",       5)
    local valTime     = makeStatRow(content, "Session Time", 6)
    local valQ        = makeStatRow(content, "Questions",    7)
    local valP        = makeStatRow(content, "Printers",     8)

    makeDivider(content, 9)

    -- ── DELAY SETTINGS ──
    local delayHeader = Instance.new("TextLabel", content)
    delayHeader.Size              = UDim2.new(1, 0, 0, 16)
    delayHeader.BackgroundTransparency = 1
    delayHeader.TextColor3        = Color3.fromRGB(90, 90, 90)
    delayHeader.Font              = Enum.Font.GothamBold
    delayHeader.TextSize          = 9
    delayHeader.Text              = "ANSWER DELAY"
    delayHeader.TextXAlignment    = Enum.TextXAlignment.Left
    delayHeader.LayoutOrder       = 10

    local function makeDelayRow(parent, labelStr, defaultVal, order, onChange)
        local row = Instance.new("Frame", parent)
        row.Size              = UDim2.new(1, 0, 0, 24)
        row.BackgroundTransparency = 1
        row.LayoutOrder       = order

        local lbl = Instance.new("TextLabel", row)
        lbl.Size              = UDim2.new(0.62, 0, 1, 0)
        lbl.BackgroundTransparency = 1
        lbl.TextColor3        = Color3.fromRGB(110, 110, 110)
        lbl.Font              = Enum.Font.Gotham
        lbl.TextSize          = 10
        lbl.Text              = labelStr
        lbl.TextXAlignment    = Enum.TextXAlignment.Left

        local box = Instance.new("TextBox", row)
        box.Size              = UDim2.new(0.36, 0, 0, 20)
        box.Position          = UDim2.new(0.64, 0, 0.5, -10)
        box.BackgroundColor3  = Color3.fromRGB(15, 15, 15)
        box.TextColor3        = Color3.fromRGB(210, 210, 210)
        box.Font              = Enum.Font.GothamBold
        box.TextSize          = 10
        box.Text              = string.format("%.1f", defaultVal)
        box.TextXAlignment    = Enum.TextXAlignment.Center
        box.ClearTextOnFocus  = false
        box.BorderSizePixel   = 0
        local bxc = Instance.new("UICorner", box) bxc.CornerRadius = UDim.new(0, 4)
        local bxs = Instance.new("UIStroke", box)
        bxs.Color     = Color3.fromRGB(35, 35, 35)
        bxs.Thickness = 1

        box.FocusLost:Connect(function()
            local n = tonumber(box.Text)
            if n then onChange(n, box)
            else box.Text = string.format("%.1f", defaultVal) end
        end)
        return box
    end

    local boxMin = makeDelayRow(content, "Min (sec)", answerDelayMin, 11, function(v, b)
        answerDelayMin = math.clamp(v, MIN_DELAY, MAX_DELAY)
        b.Text = string.format("%.1f", answerDelayMin)
    end)
    local boxMax = makeDelayRow(content, "Max (sec)", answerDelayMax, 12, function(v, b)
        answerDelayMax = math.clamp(v, answerDelayMin, MAX_DELAY)
        b.Text = string.format("%.1f", answerDelayMax)
    end)

    -- ── STATUS LABEL (bottom) ──
    local statusLabel = Instance.new("TextLabel", content)
    statusLabel.Size              = UDim2.new(1, 0, 0, 14)
    statusLabel.BackgroundTransparency = 1
    statusLabel.TextColor3        = Color3.fromRGB(60, 60, 60)
    statusLabel.Font              = Enum.Font.Gotham
    statusLabel.TextSize          = 9
    statusLabel.Text              = "idle"
    statusLabel.TextXAlignment    = Enum.TextXAlignment.Left
    statusLabel.LayoutOrder       = 13

    -- ── LOGIC WIRING ──
    local function setStatus(text)
        statusLabel.Text = text
        print("[RueyHub] " .. text)
    end

    _G._RueyHub_UpdateStats = function()
        valQ.Text = tostring(questionsAnswered)
        valP.Text = tostring(printersCompleted)
    end

    -- override internal setStatus for farm loop
    -- (farm functions call setStatus via upvalue chain;
    --  re-define it here so UI label gets updated too)

    toggleBtn.MouseButton1Click:Connect(function()
        if farmRunning then
            stopFarm()
            setStatus("Stopped")
            refreshToggle()
        else
            setStatus("Starting...")
            refreshToggle()
            task.spawn(function()
                local ok = startFarm()
                if ok then
                    setStatus("Running")
                else
                    setStatus("Start failed")
                    stopFarm()
                end
                refreshToggle()
            end)
        end
    end)

    closeBtn.MouseButton1Click:Connect(function()
        panel.Visible   = false
        openBtn.Visible = true
    end)

    openBtn.MouseButton1Click:Connect(function()
        panel.Visible   = true
        openBtn.Visible = false
    end)

    -- ── DRAG ──
    do
        local dragging, dragStart, startPos = false, nil, nil

        titleBar.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
                dragging  = true
                dragStart = input.Position
                startPos  = panel.Position
                input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then
                        dragging = false
                    end
                end)
            end
        end)

        UserInputService.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                          or input.UserInputType == Enum.UserInputType.Touch) then
                local delta = input.Position - dragStart
                panel.Position = UDim2.new(
                    startPos.X.Scale,
                    startPos.X.Offset + delta.X,
                    startPos.Y.Scale,
                    startPos.Y.Offset + delta.Y
                )
            end
        end)
    end

    -- ── UI UPDATE LOOP ──
    task.spawn(function()
        while sg.Parent do
            task.wait(0.5)
            local money         = getMoney()
            local elapsed       = sessionStartTime and (os.time() - sessionStartTime) or 0
            local earned        = sessionStartMoney and math.max(0, money - sessionStartMoney) or 0
            local perHour       = elapsed > 60 and math.floor((earned / elapsed) * 3600) or 0

            valMoney.Text   = "Rp " .. formatNumber(money)
            valEarned.Text  = "+" .. formatNumber(earned)
            valPerHour.Text = elapsed > 60 and (formatNumber(perHour) .. "/hr") or "..."
            valTime.Text    = formatTime(elapsed)
            valQ.Text       = tostring(questionsAnswered)
            valP.Text       = tostring(printersCompleted)
            valStatus.Text  = farmRunning and "running" or "idle"
        end
    end)

    -- anti-afk
    table.insert(connections, Player.Idled:Connect(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end))

    -- auto-start on inject
    task.spawn(function()
        statusLabel.Text = "auto-starting..."
        local ok = startFarm()
        if ok then
            statusLabel.Text = "running"
        else
            statusLabel.Text = "start failed — toggle manually"
        end
        refreshToggle()
    end)
end

-- ============================================
-- CLEANUP HOOK
-- ============================================
local function cleanup()
    active      = false
    farmRunning = false
    releaseSprint()
    setSeatBlocking(false)
    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    local ui = PlayerGui:FindFirstChild("RueyHub_UI")
    if ui then ui:Destroy() end
    local uig = (typeof(gethui) == "function" and gethui()) and (gethui()):FindFirstChild("RueyHub_UI")
    if uig then uig:Destroy() end
end

if getgenv then getgenv().RUEYHUB_OFFICE_STOP = cleanup end

print("[RueyHub] Office autofarm loaded. Adonis bypass active. Auto-starting.")
