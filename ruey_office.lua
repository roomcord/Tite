pcall(function()
	if getgenv and getgenv().RUEY_OFFICE_STOP then
		getgenv().RUEY_OFFICE_STOP()
	end
end)

local d = false
local h = {}
local x, y
setthreadidentity(2)
for i, v in getgc(true) do
	if typeof(v) == "table" then
		local a = rawget(v, "Detected")
		local b = rawget(v, "Kill")
		if typeof(a) == "function" and not x then
			x = a
			local o; o = hookfunction(x, function(c, f, n)
				return true
			end)
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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local CHAIR_SEARCH_AREA = Vector3.new(-5927.33, 4.57, -228.61)
local CHAIR_SEARCH_RADIUS = 50

local PRINTER_POS = {
	Print_1 = Vector3.new(-6008.84, 4.58, -210.84),
	Print_2 = Vector3.new(-6008.84, 4.58, -224.52),
	Print_3 = Vector3.new(-6008.84, 4.58, -238.36),
	Print_4 = Vector3.new(-5868.43, 4.58, -213.19),
	Print_5 = Vector3.new(-5868.43, 4.58, -249.96),
}

local MIN_DELAY = 0.0
local MAX_DELAY = 10.0
local answerDelayMin = 0.0
local answerDelayMax = 1.0

local active = false
local farmRunning = false
local joiningTeam = false
local currentSeat = nil
local pendingPrint = nil
local isDoingPrinterJob = false
local printerVerifyName = nil
local printerVerifyStartedAt = 0
local printerVerifyQuestionCount = 0

local questionsAnswered = 0
local printersCompleted = 0
local sessionStartTime = nil
local sessionStartMoney = nil

local remCorrectAnswer = nil
local remGenQuestion = nil
local remAssignPrint = nil
local questionConnection = nil
local printConnection = nil
local connections = {}
local seatBlockActive = false
local seatBlockToken = 0
local answeringQuestion = false
local lastQuestionKey = nil
local lastQuestionAt = 0
local lastAnswerAt = 0
local activeQuestionToken = 0
local MAX_ANSWER_RETRIES = 8
local ANSWER_RETRY_DELAY = 0.65

local lastAfkAction = os.clock()
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

local function formatNumber(n)
	n = tonumber(n) or 0
	local sign = n < 0 and "-" or ""
	local s = tostring(math.floor(math.abs(n)))
	return sign .. s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function formatTime(t)
	t = math.max(0, math.floor(tonumber(t) or 0))
	return string.format("%02d:%02d:%02d", math.floor(t / 3600) % 24, math.floor(t / 60) % 60, t % 60)
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

local function randomDelay(mn, mx)
	mn = math.clamp(tonumber(mn) or MIN_DELAY, MIN_DELAY, MAX_DELAY)
	mx = math.clamp(tonumber(mx) or mn, mn, MAX_DELAY)
	return mn + math.random() * (mx - mn)
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
	VirtualInputManager:SendKeyEvent(true, key, false, game)
	task.wait(0.1)
	VirtualInputManager:SendKeyEvent(false, key, false, game)
end

local function releaseSprint()
	pcall(function()
		VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
	end)
end

local function setSeatBlocking(enabled)
	seatBlockActive = enabled
	seatBlockToken = seatBlockToken + 1
	local token = seatBlockToken
	local function update()
		local char = Player.Character
		local hum = char and char:FindFirstChild("Humanoid")
		if not hum then return end
		pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Seated, not enabled) end)
		if enabled and hum.SeatPart then
			hum.Sit = false
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
		end
	end
	update()
	if enabled then
		task.spawn(function()
			while seatBlockActive and seatBlockToken == token do
				update()
				task.wait(0.1)
			end
		end)
	end
end

local function interactWithPrinter()
	pcall(function() VirtualUser:CaptureController() VirtualUser:SetKeyDown("0x65") end)
	task.wait(1.8)
	pcall(function() VirtualUser:SetKeyUp("0x65") end)
	return true
end

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

local function findAvailableChair()
	local best, bestDist = nil, math.huge
	for _, obj in ipairs(workspace:GetDescendants()) do
		if obj:IsA("Seat") or obj:IsA("VehicleSeat") then
			local dist = (obj.Position - CHAIR_SEARCH_AREA).Magnitude
			if dist < CHAIR_SEARCH_RADIUS and not obj.Occupant and dist < bestDist then
				bestDist = dist
				best = obj
			end
		end
	end
	return best
end

local function seatTP(targetSeat)
	if not targetSeat then return false end
	local char = getChar()
	local hum = char:WaitForChild("Humanoid")
	local root = char:WaitForChild("HumanoidRootPart")
	local orig = targetSeat.CFrame
	targetSeat.CFrame = root.CFrame * CFrame.new(0, -2, -3)
	task.wait(0.2)
	targetSeat:Sit(hum)
	task.wait(0.3)
	if hum.SeatPart ~= targetSeat then targetSeat:Sit(hum) task.wait(0.4) end
	if hum.SeatPart ~= targetSeat then targetSeat.CFrame = orig return false end
	targetSeat.CFrame = orig
	task.wait(0.5)
	return hum.SeatPart == targetSeat
end

local function walkTo(targetPos)
	local char = getChar()
	local hum = char:FindFirstChild("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root then return false end
	releaseSprint()
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentJumpHeight = 7.5,
		AgentMaxSlope = 45,
	})
	local success = pcall(function() path:ComputeAsync(root.Position, targetPos) end)
	if not success or path.Status ~= Enum.PathStatus.Success then
		hum:MoveTo(targetPos)
		local started = os.clock()
		while active and (root.Position - targetPos).Magnitude > 4 and os.clock() - started < 10 do
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
			timeout = timeout + 1
		end
	end
	releaseSprint()
	return true
end

local function ensureRemotes()
	local jobEvents = ReplicatedStorage:WaitForChild("JobEvents", 10)
	if not jobEvents then return false, "JobEvents not found" end
	remCorrectAnswer = jobEvents:WaitForChild("CorrectAnswer", 10)
	remGenQuestion = jobEvents:WaitForChild("GenerateQuestion", 10)
	remAssignPrint = jobEvents:WaitForChild("AssignPrintJob", 10)
	if not remCorrectAnswer or not remGenQuestion or not remAssignPrint then
		return false, "Office remotes not found"
	end
	return true
end

local RueyGui, StatusLabel, QLabel, PLabel, MoneyLabel, EarnedLabel
local OverlayVisible = true

do
	local guiP = (typeof(gethui) == "function" and gethui()) or PlayerGui
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
	panel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	panel.BackgroundTransparency = 0.15
	panel.BorderSizePixel = 0
	local pc = Instance.new("UICorner", panel)
	pc.CornerRadius = UDim.new(0, 8)
	local pl = Instance.new("UIListLayout", panel)
	pl.FillDirection = Enum.FillDirection.Vertical
	pl.Padding = UDim.new(0, 0)
	pl.SortOrder = Enum.SortOrder.LayoutOrder

	local dragging, dragStart, startPos = false, nil, nil
	panel.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = panel.Position
		end
	end)
	panel.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			panel.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
		end
	end)

	local function makeRow(order, h)
		local f = Instance.new("Frame", panel)
		f.Size = UDim2.new(1, 0, 0, h)
		f.BackgroundTransparency = 1
		f.LayoutOrder = order
		return f
	end

	local titleRow = makeRow(1, 28)
	local titleLabel = Instance.new("TextLabel", titleRow)
	titleLabel.Text = "ruey hub"
	titleLabel.Size = UDim2.new(1, -28, 1, 0)
	titleLabel.Position = UDim2.new(0, 8, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextSize = 12
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left

	local closeBtn = Instance.new("TextButton", titleRow)
	closeBtn.Text = "×"
	closeBtn.Size = UDim2.new(0, 22, 0, 22)
	closeBtn.Position = UDim2.new(1, -24, 0, 3)
	closeBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	closeBtn.TextColor3 = Color3.fromRGB(200, 200, 200)
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 14
	closeBtn.BorderSizePixel = 0
	local cc = Instance.new("UICorner", closeBtn)
	cc.CornerRadius = UDim.new(0, 4)

	local openBtn = Instance.new("TextButton", sg)
	openBtn.Text = "ruey"
	openBtn.Size = UDim2.new(0, 50, 0, 22)
	openBtn.Position = UDim2.new(0, 12, 0.5, 0)
	openBtn.AnchorPoint = Vector2.new(0, 0.5)
	openBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	openBtn.BackgroundTransparency = 0.2
	openBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	openBtn.Font = Enum.Font.GothamBold
	openBtn.TextSize = 11
	openBtn.BorderSizePixel = 0
	openBtn.Visible = false
	local oc = Instance.new("UICorner", openBtn)
	oc.CornerRadius = UDim.new(0, 5)

	closeBtn.MouseButton1Click:Connect(function()
		panel.Visible = false
		openBtn.Visible = true
		OverlayVisible = false
	end)
	openBtn.MouseButton1Click:Connect(function()
		panel.Visible = true
		openBtn.Visible = false
		OverlayVisible = true
	end)

	local sep0 = Instance.new("Frame", panel)
	sep0.Size = UDim2.new(1, 0, 0, 1)
	sep0.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	sep0.BorderSizePixel = 0
	sep0.LayoutOrder = 2

	local function makeStatRow(order, labelStr)
		local row = makeRow(order, 24)
		local lbl = Instance.new("TextLabel", row)
		lbl.Text = labelStr
		lbl.Size = UDim2.new(0.45, 0, 1, 0)
		lbl.Position = UDim2.new(0, 8, 0, 0)
		lbl.BackgroundTransparency = 1
		lbl.TextColor3 = Color3.fromRGB(160, 160, 160)
		lbl.Font = Enum.Font.Gotham
		lbl.TextSize = 10
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		local val = Instance.new("TextLabel", row)
		val.Text = "—"
		val.Size = UDim2.new(0.55, -8, 1, 0)
		val.Position = UDim2.new(0.45, 0, 0, 0)
		val.BackgroundTransparency = 1
		val.TextColor3 = Color3.fromRGB(255, 255, 255)
		val.Font = Enum.Font.GothamBold
		val.TextSize = 10
		val.TextXAlignment = Enum.TextXAlignment.Right
		return val
	end

	StatusLabel = makeStatRow(3, "status")
	MoneyLabel = makeStatRow(4, "money")
	EarnedLabel = makeStatRow(5, "earned")
	QLabel = makeStatRow(6, "questions")
	PLabel = makeStatRow(7, "printers")

	StatusLabel.Text = "starting..."
	MoneyLabel.Text = "Rp. 0"
	EarnedLabel.Text = "Rp. 0"
	QLabel.Text = "0"
	PLabel.Text = "0"
end

local function setStatus(text)
	if StatusLabel then StatusLabel.Text = text end
	print("[ruey office] " .. text)
end

local function normalizeAnswerText(text)
	return tostring(text or ""):lower():gsub("%s+", ""):gsub(",", "")
end

local function getGuiText(obj)
	if obj:IsA("TextButton") or obj:IsA("TextLabel") or obj:IsA("TextBox") then
		return obj.Text or ""
	end
	for _, child in ipairs(obj:GetDescendants()) do
		if child:IsA("TextButton") or child:IsA("TextLabel") or child:IsA("TextBox") then
			local text = child.Text
			if text and text ~= "" then return text end
		end
	end
	return ""
end

local function normalizeAnswerEntries(entries)
	local cleaned, seen = {}, {}
	if type(entries) ~= "table" then return cleaned end
	for _, entry in ipairs(entries) do
		if type(entry) == "table" then
			local text = tostring(entry.Text or "")
			local norm = normalizeAnswerText(text)
			if norm ~= "" and not seen[norm] then
				seen[norm] = true
				table.insert(cleaned, entry)
			end
		end
	end
	return cleaned
end

local function isVisibleGuiObject(obj)
	if obj:IsDescendantOf(RueyGui) then return false end
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

local function answerTextMatches(buttonText, answerText, solvedValue)
	local nb = normalizeAnswerText(buttonText)
	local na = normalizeAnswerText(answerText)
	local ns = normalizeAnswerText(solvedValue)
	if nb == "" then return false end
	if na ~= "" and nb == na then return true end
	if ns ~= "" and nb == ns then return true end
	local numB = tonumber(buttonText:match("%-?%d+"))
	local numS = tonumber(solvedValue)
	return numB ~= nil and numS ~= nil and numB == numS
end

local function findMatchingAnswerTarget(button, answerText, solvedValue)
	local best, bestArea = nil, math.huge
	local function consider(obj, text)
		if not obj:IsA("GuiObject") or not isVisibleGuiObject(obj) then return end
		if not answerTextMatches(text, answerText, solvedValue) then return end
		local area = obj.AbsoluteSize.X * obj.AbsoluteSize.Y
		if area > 0 and area < bestArea then best = obj bestArea = area end
	end
	if button:IsA("TextButton") then consider(button, button.Text or "") end
	for _, child in ipairs(button:GetDescendants()) do
		if child:IsA("TextButton") or child:IsA("TextLabel") or child:IsA("TextBox") then
			consider(child, child.Text or "")
		end
	end
	return best
end

local function guiContainsQuestion(root, questionText)
	local needles = {}
	local nq = normalizeAnswerText(questionText)
	if nq ~= "" then needles[#needles + 1] = nq end
	local a, op, b = tostring(questionText or ""):match("(%d+)%s*([%+%-%*%/])%s*(%d+)")
	if a and op and b then
		local ne = normalizeAnswerText(a .. op .. b)
		if ne ~= "" then needles[#needles + 1] = ne end
	end
	if #needles == 0 then return false end
	for _, obj in ipairs(root:GetDescendants()) do
		if obj:IsA("TextButton") or obj:IsA("TextLabel") or obj:IsA("TextBox") then
			local hay = normalizeAnswerText(obj.Text)
			if hay ~= "" then
				for _, needle in ipairs(needles) do
					if hay:find(needle, 1, true) then return true end
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

local function getTopmostScore(button)
	local center = button.AbsolutePosition + (button.AbsoluteSize / 2)
	local ok, objects = pcall(function() return GuiService:GetGuiObjectsAtPosition(center.X, center.Y) end)
	if not ok or type(objects) ~= "table" then return 0 end
	for index, obj in ipairs(objects) do
		if obj == button or obj:IsDescendantOf(button) or button:IsDescendantOf(obj) then
			return math.max(0, 80 - index)
		end
	end
	return 0
end

local function scoreAnswerButton(button, questionText)
	local score = 0
	local area = button.AbsoluteSize.X * button.AbsoluteSize.Y
	score = score + getRootDisplayOrder(button) * 4
	score = score + getTopmostScore(button)
	score = score + math.min(30, area / 1000)
	score = score + (button.ZIndex or 0)
	local cur = button.Parent
	local depth = 1
	while cur and depth <= 8 do
		local name = cur.Name:lower()
		if name:find("work", 1, true) or name:find("question", 1, true) or name:find("answer", 1, true) then
			score = score + 6
		end
		if questionText and guiContainsQuestion(cur, questionText) then
			score = score + (220 - depth * 10)
			break
		end
		cur = cur.Parent
		depth = depth + 1
	end
	return score
end

local function isOfficeAnswerCandidate(obj)
	local cur = obj
	while cur do
		local name = cur.Name:lower()
		if name == "workgui" then return true end
		if cur:IsA("SurfaceGui") or cur:IsA("BillboardGui") then
			return name:find("work", 1, true) or name:find("office", 1, true) or name:find("computer", 1, true)
		end
		if cur == PlayerGui or cur == workspace then break end
		cur = cur.Parent
	end
	return false
end

local function findAnswerButton(answerText, solvedValue, questionText)
	local bestButton, bestScore = nil, -math.huge
	local candidates = {}
	local seenKeys = {}
	local workGui = PlayerGui:FindFirstChild("WorkGui")
	if not workGui then return nil, 0, {} end
	for _, obj in ipairs(workGui:GetDescendants()) do
		if obj:IsA("TextButton") or obj:IsA("ImageButton") then
			local target = findMatchingAnswerTarget(obj, answerText, solvedValue)
			if target and isVisibleGuiObject(obj) and isOfficeAnswerCandidate(obj) then
				local dk = normalizeAnswerText(getGuiText(target))
				if dk == "" then dk = normalizeAnswerText(getGuiText(obj)) end
				if dk ~= "" and seenKeys[dk] then continue end
				if dk ~= "" then seenKeys[dk] = true end
				local score = scoreAnswerButton(obj, questionText) + getTopmostScore(target)
				table.insert(candidates, { Button = obj, Target = target, Score = score })
				if score >= bestScore then bestButton = obj bestScore = score end
			end
		end
	end
	table.sort(candidates, function(a, b) return a.Score > b.Score end)
	return bestButton, #candidates, candidates
end

local function fireGuiButtonDirectly(button)
	if not button or not button.Parent or not button:IsA("GuiButton") then return false end
	local fired = false
	local signals = { button.MouseButton1Click, button.Activated }
	for _, signal in ipairs(signals) do
		if firesignal then
			local ok = pcall(function() firesignal(signal) end)
			fired = ok or fired
		end
		if getconnections then
			local ok, conns = pcall(function() return getconnections(signal) end)
			if ok and type(conns) == "table" then
				for _, conn in ipairs(conns) do
					local didCall = false
					local okC = pcall(function()
						if conn.Fire then didCall = true conn:Fire()
						elseif conn.Function then didCall = true conn.Function() end
					end)
					fired = (okC and didCall) or fired
				end
			end
		end
	end
	pcall(function()
		local center = button.AbsolutePosition + (button.AbsoluteSize / 2)
		VirtualInputManager:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
		task.wait(0.03)
		VirtualInputManager:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
		fired = true
	end)
	return fired
end

local function clickAnswerButtonAndWait(button, timeout, target)
	local response, done = nil, false
	local conn
	conn = remCorrectAnswer.OnClientEvent:Connect(function(result)
		response = result
		done = true
	end)
	local started = os.clock()
	local clicked = fireGuiButtonDirectly(button)
	if target and target ~= button and target:IsA("GuiButton") then
		clicked = fireGuiButtonDirectly(target) or clicked
	end
	while active and not done and os.clock() - started < timeout do
		task.wait(0.05)
	end
	if conn then conn:Disconnect() end
	return response, clicked
end

local function answerQuestion(question, answers, sessionId, attempt, questionToken)
	attempt = tonumber(attempt) or 1
	questionToken = tonumber(questionToken) or activeQuestionToken
	if not active or answeringQuestion or questionToken ~= activeQuestionToken then return end
	answeringQuestion = true

	task.spawn(function()
		local ok, err = pcall(function()
			if not active or questionToken ~= activeQuestionToken then return end
			local solvedValue = solveQuestion(question)
			if not solvedValue then return end

			local correctAnswerText = tostring(solvedValue)
			local filteredAnswers = normalizeAnswerEntries(answers)
			if #filteredAnswers > 4 then
				local trimmed = {}
				for i = 1, math.min(4, #filteredAnswers) do trimmed[#trimmed + 1] = filteredAnswers[i] end
				filteredAnswers = trimmed
			end
			if #filteredAnswers > 0 then
				for _, answer in ipairs(filteredAnswers) do
					if type(answer) == "table" and tonumber(answer.Text) == solvedValue then
						correctAnswerText = tostring(answer.Text)
						break
					end
				end
			end

			task.wait(randomDelay(answerDelayMin, answerDelayMax))
			if not active or questionToken ~= activeQuestionToken then return end

			local answerButton, candidateCount, candidates = findAnswerButton(correctAnswerText, solvedValue, question)
			if not answerButton then
				if attempt < MAX_ANSWER_RETRIES and questionToken == activeQuestionToken then
					setStatus("retrying answer...")
					task.delay(ANSWER_RETRY_DELAY, function()
						answerQuestion(question, answers, sessionId, attempt + 1, questionToken)
					end)
				else
					setStatus("answer stuck")
				end
				return
			end

			local finalResponse, clickedAny = nil, false
			for index, candidate in ipairs(candidates) do
				if not active or questionToken ~= activeQuestionToken then return end
				local timeout = index == #candidates and 4 or 1.3
				local response, clicked = clickAnswerButtonAndWait(candidate.Button, timeout, candidate.Target)
				clickedAny = clickedAny or clicked
				if response == true or tostring(response):lower() == "success" then
					finalResponse = response
					break
				end
				task.wait(0.12)
			end

			if finalResponse == true or tostring(finalResponse):lower() == "success" then
				questionsAnswered = questionsAnswered + 1
				lastAnswerAt = os.clock()
				if printerVerifyName then
					printersCompleted = printersCompleted + 1
					if PLabel then PLabel.Text = tostring(printersCompleted) end
					printerVerifyName = nil
					printerVerifyStartedAt = 0
					printerVerifyQuestionCount = 0
				end
				if QLabel then QLabel.Text = tostring(questionsAnswered) end
				setStatus("answered")
			elseif clickedAny then
				setStatus("clicked, verifying...")
				if attempt < MAX_ANSWER_RETRIES and questionToken == activeQuestionToken then
					task.delay(ANSWER_RETRY_DELAY, function()
						answerQuestion(question, answers, sessionId, attempt + 1, questionToken)
					end)
				end
			elseif attempt < MAX_ANSWER_RETRIES then
				setStatus("retrying...")
				if questionToken == activeQuestionToken then
					task.delay(ANSWER_RETRY_DELAY, function()
						answerQuestion(question, answers, sessionId, attempt + 1, questionToken)
					end)
				end
			end
		end)
		answeringQuestion = false
		if not ok then warn("[ruey office] question error: " .. tostring(err)) end
	end)
end

local function onQuestionReceived(question, answers, sessionId)
	if not active then return end
	local questionKey = tostring(sessionId or "") .. "|" .. normalizeAnswerText(question)
	local now = os.clock()
	if questionKey == lastQuestionKey and now - lastQuestionAt < 4 then return end
	lastQuestionKey = questionKey
	lastQuestionAt = now
	activeQuestionToken = activeQuestionToken + 1
	answerQuestion(question, answers, sessionId, 1, activeQuestionToken)
end

local function hookOfficeRemotes()
	if questionConnection or printConnection then return end
	questionConnection = remGenQuestion.OnClientEvent:Connect(onQuestionReceived)
	printConnection = remAssignPrint.OnClientEvent:Connect(function(printerName)
		if not active then return end
		pendingPrint = printerName
		setStatus("print assigned: " .. tostring(printerName))
	end)
	table.insert(connections, questionConnection)
	table.insert(connections, printConnection)
end

local function joinOfficeTeam()
	if joiningTeam then return true end
	joiningTeam = true
	setStatus("joining team...")
	local menuToggle = ReplicatedStorage:WaitForChild("menuToggleRequest", 10)
	if menuToggle then safeFireServer(menuToggle) task.wait(1) end
	local jobEvents = ReplicatedStorage:WaitForChild("JobEvents", 10)
	if not jobEvents then joiningTeam = false return false, "JobEvents not found" end
	local teamChange = jobEvents:WaitForChild("TeamChangeRequest", 10)
	if not teamChange then joiningTeam = false return false, "TeamChangeRequest not found" end
	safeFireServer(teamChange, "Office Worker", 0, 0, 0, "MainMenu")
	task.wait(3)
	joiningTeam = false
	return true
end

local function mainFarmLoop()
	local usedInitialTP = false
	while active do
		local char = getChar()
		local hum = char:WaitForChild("Humanoid")
		setStatus("finding chair...")
		local seat = findAvailableChair()
		if not seat then
			setStatus("no chair, retrying...")
			task.wait(3)
			continue
		end
		currentSeat = seat
		local seated = false
		if not usedInitialTP then
			setStatus("teleporting to chair...")
			seated = seatTP(seat)
			usedInitialTP = seated
		else
			setStatus("walking to chair...")
			walkTo(seat.Position)
			task.wait(0.3)
			seat:Sit(hum)
			task.wait(0.5)
			seated = hum.SeatPart == seat
		end
		if not seated then
			setStatus("seat failed, retry...")
			task.wait(2)
			continue
		end
		setStatus("seated — running")
		while active do
			antiAfkTick()

			if pendingPrint then
				local pos = PRINTER_POS[pendingPrint]
				if pos then
					isDoingPrinterJob = true
					local savedSeat = currentSeat
					local savedPrint = pendingPrint
					printerVerifyName = nil
					printerVerifyStartedAt = 0
					printerVerifyQuestionCount = 0
					setStatus("walking to printer...")
					setSeatBlocking(true)
					sendKey(Enum.KeyCode.Space)
					task.wait(0.5)
					walkTo(pos)
					task.wait(0.5)
					setStatus("collecting print...")
					interactWithPrinter()
					task.wait(1)
					setStatus("print submitted")
					pendingPrint = nil
					setStatus("returning to chair...")
					if savedSeat and savedSeat.Parent then
						walkTo(savedSeat.Position)
						task.wait(0.5)
						setSeatBlocking(false)
						savedSeat:Sit(hum)
						task.wait(0.5)
						currentSeat = savedSeat
						printerVerifyName = savedPrint
						printerVerifyStartedAt = hum.SeatPart == savedSeat and os.clock() or 0
						printerVerifyQuestionCount = questionsAnswered
						setStatus("back in chair")
					else
						setSeatBlocking(false)
						setStatus("no return chair")
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
					setStatus("printer retry...")
				end
			elseif not isDoingPrinterJob and hum.SeatPart ~= currentSeat then
				setStatus("returning to chair...")
				if currentSeat and currentSeat.Parent then
					walkTo(currentSeat.Position)
					task.wait(0.3)
					currentSeat:Sit(hum)
					task.wait(0.5)
					if hum.SeatPart ~= currentSeat then
						setStatus("waiting reseat...")
						task.wait(1)
					end
				else
					break
				end
			end
			task.wait(0.2)
		end
		task.wait(1)
	end
end

local function startFarm()
	if farmRunning then return true end
	setStatus("loading...")
	local joined, joinErr = joinOfficeTeam()
	if not joined then
		setStatus(joinErr or "join failed")
		return false
	end
	local waitStart = os.clock()
	repeat task.wait(0.5)
	until (Player.Character
		and Player.Character:FindFirstChild("HumanoidRootPart")
		and Player.Character:FindFirstChild("Humanoid"))
		or os.clock() - waitStart > 15
	if not Player.Character or not Player.Character:FindFirstChild("HumanoidRootPart") then
		setStatus("char not ready")
		return false
	end
	local ok, err = ensureRemotes()
	if not ok then setStatus(err or "remote setup failed") return false end
	active = true
	farmRunning = true
	questionsAnswered = 0
	printersCompleted = 0
	pendingPrint = nil
	currentSeat = nil
	printerVerifyName = nil
	printerVerifyStartedAt = 0
	printerVerifyQuestionCount = 0
	lastAnswerAt = 0
	sessionStartTime = os.time()
	sessionStartMoney = getMoney()
	if QLabel then QLabel.Text = "0" end
	if PLabel then PLabel.Text = "0" end
	setStatus("running")
	hookOfficeRemotes()
	task.spawn(mainFarmLoop)
	return true
end

table.insert(connections, Player.Idled:Connect(function()
	VirtualUser:CaptureController()
	VirtualUser:ClickButton2(Vector2.new())
end))

task.spawn(startFarm)

task.spawn(function()
	while RueyGui.Parent do
		task.wait(0.5)
		local money = getMoney()
		local elapsed = sessionStartTime and (os.time() - sessionStartTime) or 0
		local earned = sessionStartMoney and math.max(0, money - sessionStartMoney) or 0
		if MoneyLabel then MoneyLabel.Text = "Rp. " .. formatNumber(money) end
		if EarnedLabel then EarnedLabel.Text = "Rp. " .. formatNumber(earned) end
	end
end)

local function cleanup()
	active = false
	farmRunning = false
	releaseSprint()
	setSeatBlocking(false)
	for _, conn in ipairs(connections) do
		pcall(function() conn:Disconnect() end)
	end
	if RueyGui and RueyGui.Parent then RueyGui:Destroy() end
end

if getgenv then getgenv().RUEY_OFFICE_STOP = cleanup end

print("[ruey hub] office farm loaded — auto starting")
