pcall(function()
	if getgenv and getgenv().RUEY_OFFICE_STOP then
		getgenv().RUEY_OFFICE_STOP()
	end
end)

local h = {}
local x, y
setthreadidentity(2)
for i, v in getgc(true) do
	if typeof(v) == "table" then
		local a = rawget(v, "Detected")
		local b = rawget(v, "Kill")
		if typeof(a) == "function" and not x then
			x = a
			local o; o = hookfunction(x, function(c, f, n) return true end)
			table.insert(h, x)
		end
		if rawget(v, "Variables") and rawget(v, "Process") and typeof(b) == "function" and not y then
			y = b
			local o; o = hookfunction(y, function(f) end)
			table.insert(h, y)
		end
	end
end
local o; o = hookfunction(getrenv().debug.info, newcclosure(function(...)
	local a, f = ...
	if x and a == x then return coroutine.yield(coroutine.running()) end
	return o(...)
end))
setthreadidentity(7)

if not game:IsLoaded() then game.Loaded:Wait() end
task.wait(2)

local Players         = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local GuiService      = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser     = game:GetService("VirtualUser")

local Player    = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local CHAIR_AREA   = Vector3.new(-5927.33, 4.57, -228.61)
local CHAIR_RADIUS = 50

local PRINTER_POS = {
	Print_1 = Vector3.new(-6008.84, 4.58, -210.84),
	Print_2 = Vector3.new(-6008.84, 4.58, -224.52),
	Print_3 = Vector3.new(-6008.84, 4.58, -238.36),
	Print_4 = Vector3.new(-5868.43, 4.58, -213.19),
	Print_5 = Vector3.new(-5868.43, 4.58, -249.96),
}

local toggled    = false
local active     = false
local farmBooted = false

local remCorrectAnswer = nil
local remGenQuestion   = nil
local remAssignPrint   = nil
local remotesReady     = false

local currentSeat            = nil
local pendingPrint           = nil
local isDoingPrinterJob      = false
local printerVerifyName      = nil
local printerVerifyStartedAt = 0
local printerVerifyQCount    = 0
local seatBlockActive        = false
local seatBlockToken         = 0

local questionsAnswered = 0
local printersCompleted = 0
local sessionStartMoney = nil
local sessionStartTime  = nil

local answering          = false
local lastQKey           = ""
local lastQAt            = 0
local activeToken        = 0
local MAX_RETRIES        = 8
local RETRY_DELAY        = 0.65
local ANS_DELAY_MIN      = 0.0
local ANS_DELAY_MAX      = 1.0
local lastAfkAction      = os.clock()

local connections = {}

local function formatNumber(n)
	n = tonumber(n) or 0
	local sign = n < 0 and "-" or ""
	local s = tostring(math.floor(math.abs(n)))
	return sign .. s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function getMoney()
	local pd = Player:FindFirstChild("PlayerData")
	if pd then
		local v = pd:FindFirstChild("RPValue") or pd:FindFirstChild("Money") or pd:FindFirstChild("Cash")
		if v and v.Value ~= nil then return tonumber(v.Value) or 0 end
	end
	local ls = Player:FindFirstChild("leaderstats")
	if ls then
		local v = ls:FindFirstChild("RP") or ls:FindFirstChild("Money") or ls:FindFirstChild("Cash")
		if v and v.Value ~= nil then return tonumber(v.Value) or 0 end
	end
	return 0
end

local function getChar()
	return Player.Character or Player.CharacterAdded:Wait()
end

local function releaseSprint()
	pcall(function() VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game) end)
end

local function sendKey(key)
	VirtualInputManager:SendKeyEvent(true, key, false, game)
	task.wait(0.1)
	VirtualInputManager:SendKeyEvent(false, key, false, game)
end

local function antiAfkTick()
	local now = os.clock()
	if now - lastAfkAction >= 25 then
		lastAfkAction = now
		pcall(function() VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.new()) end)
		pcall(function()
			VirtualInputManager:SendMouseMoveEvent(0, 1, game)
			task.wait(0.05)
			VirtualInputManager:SendMouseMoveEvent(0, -1, game)
		end)
	end
end

local function setSeatBlocking(enabled)
	seatBlockActive = enabled
	seatBlockToken  = seatBlockToken + 1
	local token = seatBlockToken
	local function upd()
		local char = Player.Character
		local hum  = char and char:FindFirstChild("Humanoid")
		if not hum then return end
		pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Seated, not enabled) end)
		if enabled and hum.SeatPart then
			hum.Sit = false
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
		end
	end
	upd()
	if enabled then
		task.spawn(function()
			while seatBlockActive and seatBlockToken == token do upd() task.wait(0.1) end
		end)
	end
end

local function walkTo(pos)
	local char = getChar()
	local hum  = char:FindFirstChild("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root then return end
	releaseSprint()
	local path = PathfindingService:CreatePath({ AgentRadius=2, AgentHeight=5, AgentCanJump=true, AgentJumpHeight=7.5, AgentMaxSlope=45 })
	local ok = pcall(function() path:ComputeAsync(root.Position, pos) end)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		hum:MoveTo(pos)
		local t = os.clock()
		while active and (root.Position-pos).Magnitude > 4 and os.clock()-t < 10 do task.wait(0.1) end
		return
	end
	for _, wp in ipairs(path:GetWaypoints()) do
		if not active then break end
		if wp.Action == Enum.PathWaypointAction.Jump then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
		hum:MoveTo(wp.Position)
		local t2 = 0
		while active and (root.Position-wp.Position).Magnitude > 4 and t2 < 50 do task.wait(0.1) t2=t2+1 end
	end
	releaseSprint()
end

local function seatTP(seat)
	if not seat then return false end
	local char = getChar()
	local hum  = char:WaitForChild("Humanoid")
	local root = char:WaitForChild("HumanoidRootPart")
	local orig = seat.CFrame
	seat.CFrame = root.CFrame * CFrame.new(0,-2,-3)
	task.wait(0.2)
	seat:Sit(hum)
	task.wait(0.3)
	if hum.SeatPart ~= seat then seat:Sit(hum) task.wait(0.4) end
	if hum.SeatPart ~= seat then seat.CFrame = orig return false end
	seat.CFrame = orig
	task.wait(0.5)
	return hum.SeatPart == seat
end

local function findChair()
	local best, bd = nil, math.huge
	for _, obj in ipairs(workspace:GetDescendants()) do
		if obj:IsA("Seat") or obj:IsA("VehicleSeat") then
			local d = (obj.Position - CHAIR_AREA).Magnitude
			if d < CHAIR_RADIUS and not obj.Occupant and d < bd then bd=d best=obj end
		end
	end
	return best
end

local function interactPrinter()
	pcall(function() VirtualUser:CaptureController() VirtualUser:SetKeyDown("0x65") end)
	task.wait(1.8)
	pcall(function() VirtualUser:SetKeyUp("0x65") end)
end

local function safeFireServer(rem, ...)
	if not rem then return end
	local args = {...}
	task.spawn(function()
		pcall(setthreadidentity, 2)
		pcall(function() rem:FireServer(unpack(args)) end)
		pcall(setthreadidentity, 7)
	end)
end

local function normalizeText(t)
	return tostring(t or ""):lower():gsub("%s+",""):gsub(",","")
end

local function solveQ(q)
	local a, op, b = tostring(q):match("(%d+)%s*([%+%-%*%/])%s*(%d+)")
	if not a then return nil end
	a, b = tonumber(a), tonumber(b)
	if op=="+" then return a+b
	elseif op=="-" then return a-b
	elseif op=="*" then return a*b
	elseif op=="/" and b~=0 then return math.floor(a/b)
	end
	return nil
end

local function getGuiText(obj)
	if obj:IsA("TextButton") or obj:IsA("TextLabel") or obj:IsA("TextBox") then return obj.Text or "" end
	for _, c in ipairs(obj:GetDescendants()) do
		if c:IsA("TextLabel") or c:IsA("TextButton") or c:IsA("TextBox") then
			if c.Text and c.Text ~= "" then return c.Text end
		end
	end
	return ""
end

local function isVisible(obj)
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

local function numMatches(btnText, solved)
	local nb = tonumber(normalizeText(btnText):match("%-?%d+"))
	return nb ~= nil and nb == tonumber(solved)
end

local function textMatches(btnText, ansText, solved)
	local nb = normalizeText(btnText)
	if nb == "" then return false end
	if nb == normalizeText(ansText) then return true end
	if nb == normalizeText(tostring(solved)) then return true end
	return numMatches(btnText, solved)
end

local function getRootOrder(obj)
	local cur = obj
	while cur do
		if cur:IsA("ScreenGui") then return cur.DisplayOrder or 0 end
		cur = cur.Parent
	end
	return 0
end

local function guiHasQ(root, qText)
	local nq = normalizeText(qText)
	if nq == "" then return false end
	for _, obj in ipairs(root:GetDescendants()) do
		if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
			if normalizeText(obj.Text):find(nq, 1, true) then return true end
		end
	end
	return false
end

local function scoreBtn(btn, qText)
	local score = getRootOrder(btn) * 4 + (btn.ZIndex or 0)
	score = score + math.min(30, btn.AbsoluteSize.X * btn.AbsoluteSize.Y / 1000)
	local cur, depth = btn.Parent, 1
	while cur and depth <= 8 do
		local n = cur.Name:lower()
		if n:find("work",1,true) or n:find("question",1,true) or n:find("answer",1,true) then score = score + 6 end
		if qText and guiHasQ(cur, qText) then score = score + (220 - depth*10) break end
		cur = cur.Parent depth = depth+1
	end
	return score
end

-- Search WorkGui in PlayerGui ONLY — the actual answer buttons are there, not in workspace SurfaceGui
local function findAnswerButton(ansText, solved, qText)
	local workGui = PlayerGui:FindFirstChild("WorkGui")
	if not workGui then return nil, {} end
	local candidates, seen = {}, {}
	for _, obj in ipairs(workGui:GetDescendants()) do
		if (obj:IsA("TextButton") or obj:IsA("ImageButton")) and isVisible(obj) then
			local matchObj = nil
			local text = getGuiText(obj)
			if textMatches(text, ansText, solved) then
				matchObj = obj
			else
				for _, c in ipairs(obj:GetDescendants()) do
					if (c:IsA("TextLabel") or c:IsA("TextButton") or c:IsA("TextBox")) and isVisible(c) then
						if textMatches(getGuiText(c), ansText, solved) then matchObj = obj break end
					end
				end
			end
			if matchObj then
				local dk = normalizeText(getGuiText(matchObj))
				if dk ~= "" and not seen[dk] then
					seen[dk] = true
					table.insert(candidates, { Btn=matchObj, Score=scoreBtn(matchObj, qText) })
				end
			end
		end
	end
	table.sort(candidates, function(a,b) return a.Score > b.Score end)
	return candidates[1] and candidates[1].Btn or nil, candidates
end

local function fireBtn(btn)
	if not btn or not btn.Parent then return false end
	local fired = false
	for _, sig in ipairs({btn.MouseButton1Click, btn.Activated}) do
		if firesignal then pcall(function() firesignal(sig) fired=true end) end
		if getconnections then
			local ok, conns = pcall(getconnections, sig)
			if ok then
				for _, c in ipairs(conns) do
					pcall(function()
						if c.Fire then c:Fire() fired=true
						elseif c.Function then c.Function() fired=true end
					end)
				end
			end
		end
	end
	pcall(function()
		local center = btn.AbsolutePosition + btn.AbsoluteSize/2
		VirtualInputManager:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
		task.wait(0.03)
		VirtualInputManager:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
		fired = true
	end)
	return fired
end

local function clickAndWait(btn, timeout)
	local done, result = false, nil
	local conn = remCorrectAnswer.OnClientEvent:Connect(function(r) result=r done=true end)
	fireBtn(btn)
	local t = os.clock()
	while not done and os.clock()-t < timeout do task.wait(0.05) end
	conn:Disconnect()
	return result, done
end

local StatusLabel, MoneyLabel, EarnedLabel, QLabel, PLabel, ToggleBtn
local RueyGui

local function setStatus(txt)
	if StatusLabel then StatusLabel.Text = txt end
	print("[ruey] " .. txt)
end

local function doAnswer(question, answers, sessionId, attempt, token)
	attempt = attempt or 1
	if not active or token ~= activeToken then return end
	if answering then
		task.delay(0.1, function() doAnswer(question, answers, sessionId, attempt, token) end)
		return
	end
	answering = true
	task.spawn(function()
		local ok, err = pcall(function()
			if not active or token ~= activeToken then return end
			local solved = solveQ(question)
			if not solved then answering=false return end

			local ansText = tostring(solved)
			if type(answers) == "table" then
				for _, a in ipairs(answers) do
					if type(a) == "table" and tonumber(a.Text) == solved then ansText = tostring(a.Text) break end
				end
			end

			local delay = ANS_DELAY_MIN + math.random() * (ANS_DELAY_MAX - ANS_DELAY_MIN)
			task.wait(delay)
			if not active or token ~= activeToken then answering=false return end

			local btn, candidates = findAnswerButton(ansText, solved, question)
			if not btn then
				answering = false
				if attempt < MAX_RETRIES and token == activeToken then
					task.delay(RETRY_DELAY, function() doAnswer(question, answers, sessionId, attempt+1, token) end)
				else
					setStatus("no button found")
				end
				return
			end

			local result, confirmed = nil, false
			for _, cand in ipairs(candidates) do
				if not active or token ~= activeToken then break end
				local r, done = clickAndWait(cand.Btn, 2.5)
				if done then result=r confirmed=true end
				if r == true or tostring(r):lower() == "success" then break end
				task.wait(0.1)
			end

			answering = false

			if result == true or tostring(result):lower() == "success" then
				questionsAnswered = questionsAnswered + 1
				if QLabel then QLabel.Text = tostring(questionsAnswered) end
				if printerVerifyName then
					printersCompleted = printersCompleted + 1
					if PLabel then PLabel.Text = tostring(printersCompleted) end
					printerVerifyName = nil printerVerifyStartedAt = 0 printerVerifyQCount = 0
				end
				setStatus("answered ✓")
			elseif attempt < MAX_RETRIES and token == activeToken then
				task.delay(RETRY_DELAY, function() doAnswer(question, answers, sessionId, attempt+1, token) end)
			else
				setStatus("answer failed")
			end
		end)
		if not ok then
			answering = false
			warn("[ruey] answer error: " .. tostring(err))
		end
	end)
end

local function onQuestion(question, answers, sessionId)
	if not active then return end
	local key = tostring(sessionId or "") .. "|" .. normalizeText(question)
	local now = os.clock()
	-- only dedup if literally same question within 2 seconds
	if key == lastQKey and now - lastQAt < 2 then return end
	lastQKey = key
	lastQAt  = now
	activeToken = activeToken + 1
	answering = false
	doAnswer(question, answers, sessionId, 1, activeToken)
end

local function setupRemotes()
	if remotesReady then return true end
	local je = ReplicatedStorage:WaitForChild("JobEvents", 10)
	if not je then return false end
	remCorrectAnswer = je:WaitForChild("CorrectAnswer", 10)
	remGenQuestion   = je:WaitForChild("GenerateQuestion", 10)
	remAssignPrint   = je:WaitForChild("AssignPrintJob", 10)
	if not remCorrectAnswer or not remGenQuestion or not remAssignPrint then return false end
	remGenQuestion.OnClientEvent:Connect(onQuestion)
	remAssignPrint.OnClientEvent:Connect(function(name)
		if not active then return end
		pendingPrint = name
		setStatus("print: " .. tostring(name))
	end)
	remotesReady = true
	return true
end

local function farmLoop()
	local tpDone = false
	while true do
		task.wait(0.2)
		if not toggled then continue end
		if not active then continue end
		local char = getChar()
		local hum  = char:WaitForChild("Humanoid")
		setStatus("finding chair...")
		local seat = findChair()
		if not seat then setStatus("no chair...") task.wait(3) continue end
		currentSeat = seat
		local seated = false
		if not tpDone then
			seated = seatTP(seat)
			tpDone = seated
		else
			walkTo(seat.Position)
			task.wait(0.3)
			seat:Sit(hum)
			task.wait(0.5)
			seated = hum.SeatPart == seat
		end
		if not seated then setStatus("seat fail") task.wait(2) continue end
		setStatus("seated — running")
		while toggled and active do
			antiAfkTick()
			if pendingPrint then
				local pos = PRINTER_POS[pendingPrint]
				if pos then
					isDoingPrinterJob = true
					local savedSeat  = currentSeat
					local savedPrint = pendingPrint
					printerVerifyName = nil printerVerifyStartedAt = 0 printerVerifyQCount = 0
					setSeatBlocking(true)
					sendKey(Enum.KeyCode.Space)
					task.wait(0.5)
					walkTo(pos)
					task.wait(0.5)
					setStatus("collecting print...")
					interactPrinter()
					task.wait(1)
					pendingPrint = nil
					if savedSeat and savedSeat.Parent then
						walkTo(savedSeat.Position)
						task.wait(0.5)
						setSeatBlocking(false)
						savedSeat:Sit(hum)
						task.wait(0.5)
						currentSeat = savedSeat
						printerVerifyName     = savedPrint
						printerVerifyStartedAt = hum.SeatPart == savedSeat and os.clock() or 0
						printerVerifyQCount   = questionsAnswered
						setStatus("back in chair")
					else
						setSeatBlocking(false)
					end
					isDoingPrinterJob = false
					setSeatBlocking(false)
				else
					pendingPrint = nil
				end
			elseif printerVerifyName and currentSeat and hum.SeatPart == currentSeat then
				if questionsAnswered > printerVerifyQCount then
					printerVerifyName = nil printerVerifyStartedAt = 0 printerVerifyQCount = 0
				elseif printerVerifyStartedAt <= 0 then
					printerVerifyStartedAt = os.clock()
				elseif os.clock() - printerVerifyStartedAt >= 15 then
					pendingPrint = printerVerifyName
					printerVerifyName = nil printerVerifyStartedAt = 0 printerVerifyQCount = 0
				end
			elseif not isDoingPrinterJob and currentSeat and hum.SeatPart ~= currentSeat then
				if currentSeat.Parent then
					walkTo(currentSeat.Position)
					task.wait(0.3)
					currentSeat:Sit(hum)
					task.wait(0.5)
				else
					break
				end
			end
			task.wait(0.2)
		end
		task.wait(0.5)
	end
end

-- ============ UI ============
do
	local guiP = (typeof(gethui)=="function" and gethui()) or PlayerGui
	local sg = Instance.new("ScreenGui")
	sg.Name = "RueyHub_OfficeFarm"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 50
	sg.Parent = guiP
	RueyGui = sg

	local panel = Instance.new("Frame", sg)
	panel.Name = "Panel"
	panel.Size = UDim2.new(0, 200, 0, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Position = UDim2.new(0, 12, 0.5, 0)
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.BackgroundColor3 = Color3.fromRGB(0,0,0)
	panel.BackgroundTransparency = 0.15
	panel.BorderSizePixel = 0
	local pc = Instance.new("UICorner", panel) pc.CornerRadius = UDim.new(0,8)
	local pl = Instance.new("UIListLayout", panel)
	pl.FillDirection = Enum.FillDirection.Vertical
	pl.Padding = UDim.new(0,0)
	pl.SortOrder = Enum.SortOrder.LayoutOrder

	local dragging, dragStart, startPos = false, nil, nil
	panel.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
			dragging=true dragStart=inp.Position startPos=panel.Position
		end
	end)
	panel.InputEnded:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then dragging=false end
	end)
	UserInputService.InputChanged:Connect(function(inp)
		if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
			local d = inp.Position - dragStart
			panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset+d.X, startPos.Y.Scale, startPos.Y.Offset+d.Y)
		end
	end)

	local function makeRow(order, h)
		local f = Instance.new("Frame", panel)
		f.Size = UDim2.new(1,0,0,h)
		f.BackgroundTransparency = 1
		f.LayoutOrder = order
		return f
	end

	local titleRow = makeRow(1, 28)
	local tl = Instance.new("TextLabel", titleRow)
	tl.Text = "ruey hub" tl.Size = UDim2.new(1,-28,1,0) tl.Position = UDim2.new(0,8,0,0)
	tl.BackgroundTransparency=1 tl.TextColor3=Color3.new(1,1,1)
	tl.Font=Enum.Font.GothamBold tl.TextSize=12 tl.TextXAlignment=Enum.TextXAlignment.Left

	local closeBtn = Instance.new("TextButton", titleRow)
	closeBtn.Text="×" closeBtn.Size=UDim2.new(0,22,0,22) closeBtn.Position=UDim2.new(1,-24,0,3)
	closeBtn.BackgroundColor3=Color3.fromRGB(30,30,30) closeBtn.TextColor3=Color3.fromRGB(200,200,200)
	closeBtn.Font=Enum.Font.GothamBold closeBtn.TextSize=14 closeBtn.BorderSizePixel=0
	local ccc=Instance.new("UICorner",closeBtn) ccc.CornerRadius=UDim.new(0,4)

	local openBtn = Instance.new("TextButton", sg)
	openBtn.Text="ruey" openBtn.Size=UDim2.new(0,50,0,22)
	openBtn.Position=UDim2.new(0,12,0.5,0) openBtn.AnchorPoint=Vector2.new(0,0.5)
	openBtn.BackgroundColor3=Color3.fromRGB(0,0,0) openBtn.BackgroundTransparency=0.2
	openBtn.TextColor3=Color3.new(1,1,1) openBtn.Font=Enum.Font.GothamBold
	openBtn.TextSize=11 openBtn.BorderSizePixel=0 openBtn.Visible=false
	local occ=Instance.new("UICorner",openBtn) occ.CornerRadius=UDim.new(0,5)

	closeBtn.MouseButton1Click:Connect(function() panel.Visible=false openBtn.Visible=true end)
	openBtn.MouseButton1Click:Connect(function() panel.Visible=true openBtn.Visible=false end)

	local sep0=Instance.new("Frame",panel)
	sep0.Size=UDim2.new(1,0,0,1) sep0.BackgroundColor3=Color3.fromRGB(40,40,40)
	sep0.BorderSizePixel=0 sep0.LayoutOrder=2

	local function makeStatRow(order, labelStr)
		local row = makeRow(order, 24)
		local lbl = Instance.new("TextLabel", row)
		lbl.Text=labelStr lbl.Size=UDim2.new(0.45,0,1,0) lbl.Position=UDim2.new(0,8,0,0)
		lbl.BackgroundTransparency=1 lbl.TextColor3=Color3.fromRGB(160,160,160)
		lbl.Font=Enum.Font.Gotham lbl.TextSize=10 lbl.TextXAlignment=Enum.TextXAlignment.Left
		local val = Instance.new("TextLabel", row)
		val.Text="—" val.Size=UDim2.new(0.55,-8,1,0) val.Position=UDim2.new(0.45,0,0,0)
		val.BackgroundTransparency=1 val.TextColor3=Color3.new(1,1,1)
		val.Font=Enum.Font.GothamBold val.TextSize=10 val.TextXAlignment=Enum.TextXAlignment.Right
		return val
	end

	StatusLabel = makeStatRow(3, "status")
	MoneyLabel  = makeStatRow(4, "money")
	EarnedLabel = makeStatRow(5, "earned")
	QLabel      = makeStatRow(6, "questions")
	PLabel      = makeStatRow(7, "printers")

	local sep1=Instance.new("Frame",panel)
	sep1.Size=UDim2.new(1,0,0,1) sep1.BackgroundColor3=Color3.fromRGB(40,40,40)
	sep1.BorderSizePixel=0 sep1.LayoutOrder=8

	local tRow = makeRow(9, 32)
	local tPad = Instance.new("UIPadding", tRow)
	tPad.PaddingLeft=UDim.new(0,8) tPad.PaddingRight=UDim.new(0,8)
	tPad.PaddingTop=UDim.new(0,4) tPad.PaddingBottom=UDim.new(0,4)
	ToggleBtn = Instance.new("TextButton", tRow)
	ToggleBtn.Size=UDim2.new(1,0,1,0) ToggleBtn.BackgroundColor3=Color3.fromRGB(160,30,30)
	ToggleBtn.TextColor3=Color3.new(1,1,1) ToggleBtn.Font=Enum.Font.GothamBold
	ToggleBtn.TextSize=12 ToggleBtn.Text="OFF" ToggleBtn.BorderSizePixel=0
	local tc=Instance.new("UICorner",ToggleBtn) tc.CornerRadius=UDim.new(0,6)

	StatusLabel.Text="idle" MoneyLabel.Text="Rp. 0"
	EarnedLabel.Text="Rp. 0" QLabel.Text="0" PLabel.Text="0"
end

local function refreshBtn()
	if not ToggleBtn then return end
	if toggled then
		ToggleBtn.Text="ON" ToggleBtn.BackgroundColor3=Color3.fromRGB(30,160,60)
	else
		ToggleBtn.Text="OFF" ToggleBtn.BackgroundColor3=Color3.fromRGB(160,30,30)
	end
end

local function turnOn()
	if not setupRemotes() then setStatus("remotes not found") return end
	if not farmBooted then
		farmBooted = true
		local menuT = ReplicatedStorage:WaitForChild("menuToggleRequest", 10)
		if menuT then safeFireServer(menuT) task.wait(1) end
		local je = ReplicatedStorage:WaitForChild("JobEvents", 10)
		if je then
			local tcr = je:WaitForChild("TeamChangeRequest", 10)
			if tcr then safeFireServer(tcr, "Office Worker", 0, 0, 0, "MainMenu") task.wait(3) end
		end
		local ws = os.clock()
		repeat task.wait(0.5)
		until (Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")) or os.clock()-ws > 15
		task.spawn(farmLoop)
	end
	-- reset answering state on every ON press so nothing is stuck
	answering    = false
	activeToken  = activeToken + 1
	lastQKey     = ""
	lastQAt      = 0
	toggled      = true
	active       = true
	questionsAnswered = 0
	printersCompleted = 0
	pendingPrint = nil
	sessionStartTime  = os.time()
	sessionStartMoney = getMoney()
	if QLabel then QLabel.Text = "0" end
	if PLabel then PLabel.Text = "0" end
	if EarnedLabel then EarnedLabel.Text = "Rp. 0" end
	setStatus("running")
	refreshBtn()
end

local function turnOff()
	toggled = false
	active  = false
	answering = false
	activeToken = activeToken + 1
	releaseSprint()
	setSeatBlocking(false)
	isDoingPrinterJob = false
	sessionStartTime  = nil
	sessionStartMoney = nil
	if EarnedLabel then EarnedLabel.Text = "Rp. 0" end
	setStatus("idle")
	refreshBtn()
end

ToggleBtn.MouseButton1Click:Connect(function()
	if toggled then turnOff() else turnOn() end
end)

table.insert(connections, Player.Idled:Connect(function()
	VirtualUser:CaptureController()
	VirtualUser:ClickButton2(Vector2.new())
end))

task.spawn(function()
	while RueyGui and RueyGui.Parent do
		task.wait(0.5)
		local money = getMoney()
		if MoneyLabel then MoneyLabel.Text = "Rp. " .. formatNumber(money) end
		if EarnedLabel and toggled and sessionStartMoney then
			EarnedLabel.Text = "Rp. " .. formatNumber(math.max(0, money - sessionStartMoney))
		end
	end
end)

local function cleanup()
	toggled = false active = false
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	if RueyGui and RueyGui.Parent then RueyGui:Destroy() end
end

if getgenv then getgenv().RUEY_OFFICE_STOP = cleanup end
print("[ruey hub] loaded — press ON")
