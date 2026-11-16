local _, ns = ...

-- A small movable window: the button does what the next press would (its label says what), the line under it sums
-- up ads and whispers, and the rows list the people in play, the ones that need the player first.
local ROWS = 6
local ROW_HEIGHT = 16
local WIDTH = 440
local REFRESH_SECONDS = 1
local RECENT = 24 * 60 * 60
local FRESH = 60 * 60

local ORDER = { wants = 1, free = 2, checking = 3, new = 4, asked = 5, invited = 6 }
local STATE_TEXT = {
	wants = "wants an invite", free = "no guild", checking = "checking...", new = "speaks Danish",
	asked = "whispered", invited = "invited",
}

local frame

-- The people worth showing, best first: those waiting on the player, then the line of candidates, then recent
-- whispers and invites.
function ns.ShownPeople(limit)
	local now, shown = ns.Now(), {}
	for _, person in pairs(ns.db.people) do
		local order = ORDER[person.state]
		local age = now - (person.state == "new" and person.seen or person.at)
		if order and age <= (person.state == "new" and FRESH or RECENT) then
			shown[#shown + 1] = person
		end
	end
	table.sort(shown, function(a, b)
		if ORDER[a.state] ~= ORDER[b.state] then
			return ORDER[a.state] < ORDER[b.state]
		end
		return a.at > b.at
	end)
	for i = #shown, limit + 1, -1 do
		shown[i] = nil
	end
	return shown
end

function ns.DescribePerson(person)
	local name = person.name
	local color = person.class and C_ClassColor.GetClassColor(person.class)
	if color then
		name = color:WrapTextInColorCode(name)
	end
	local parts = { name }
	if person.level then
		parts[#parts + 1] = "level " .. person.level
	end
	parts[#parts + 1] = STATE_TEXT[person.state] or person.state
	if person.state == "free" and ns.Talked(person.key) then
		parts[#parts + 1] = "whispered you"
	end
	if person.where then
		parts[#parts + 1] = person.where
	end
	return table.concat(parts, " - ")
end

function ns.StatusLine()
	local db = ns.db
	local sent, most = ns.WhispersThisHour()
	local ads = #db.channels > 0 and #db.ads > 0
		and ("ads every %d min in %s"):format(db.adMinutes, table.concat(db.channels, ", ")) or "no ads"
	return ("%s; whispers %s, %d/%d this hour; %d joined so far"):format(ads,
		db.autoWhisper and "on their own" or "on a press", sent, most, db.stats.joined)
end

local function ShowTooltip(row)
	local person = row.person
	if not person or not GameTooltip then
		return
	end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:SetText(person.name)
	if person.said then
		GameTooltip:AddLine('"' .. person.said .. '"', 1, 1, 1, true)
	end
	if person.guild then
		GameTooltip:AddLine("<" .. person.guild .. ">", 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end

local function HideTooltip()
	if GameTooltip then
		GameTooltip:Hide()
	end
end

function ns.RefreshWindow()
	if not frame or not frame:IsShown() then
		return
	end
	frame.next:SetText(ns.NextStep().label)
	frame.status:SetText(ns.StatusLine())
	local people = ns.ShownPeople(ROWS)
	for i, row in ipairs(frame.rows) do
		row.person = people[i]
		if row.person then
			row.text:SetText(ns.DescribePerson(row.person))
			row:Show()
		else
			row:Hide()
		end
	end
end
ns.OnChanged = ns.RefreshWindow

local function SavePosition(self)
	self:StopMovingOrSizing()
	local point, _, relativePoint, x, y = self:GetPoint()
	ns.db.window = { point, relativePoint, x, y }
end

local function BuildRow(index)
	local row = CreateFrame("Button", nil, frame)
	row:SetSize(WIDTH - 20, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -78 - (index - 1) * ROW_HEIGHT)
	row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.text:SetAllPoints(row)
	row.text:SetJustifyH("LEFT")
	row.text:SetWordWrap(false)
	row:SetScript("OnEnter", ShowTooltip)
	row:SetScript("OnLeave", HideTooltip)
	row:Hide()
	return row
end

local function Build()
	frame = CreateFrame("Frame", "GuildRecruitFrame", UIParent)
	frame:SetSize(WIDTH, 86 + ROWS * ROW_HEIGHT)
	local saved = ns.db.window
	if saved then
		frame:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
	end
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", SavePosition)

	local background = frame:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints(frame)
	background:SetColorTexture(0, 0, 0, 0.75)
	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -9)
	title:SetText("GuildRecruit")
	frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	frame.close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
	frame.close:SetScript("OnClick", function() ns.ShowWindow(false) end)

	frame.next = CreateFrame("Button", "GuildRecruitFrameNext", frame, "UIPanelButtonTemplate")
	frame.next:SetSize(WIDTH - 20, 24)
	frame.next:SetPoint("TOP", frame, "TOP", 0, -30)
	frame.next:SetScript("OnClick", function() ns.DoNext() end)
	frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.status:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -60)
	frame.status:SetWidth(WIDTH - 20)
	frame.status:SetJustifyH("LEFT")
	frame.rows = {}
	for i = 1, ROWS do
		frame.rows[i] = BuildRow(i)
	end

	-- Labels like "next ad in 4 min" count down, so the window refreshes itself while shown.
	local elapsedSince = 0
	frame:SetScript("OnUpdate", function(_, elapsed)
		elapsedSince = elapsedSince + elapsed
		if elapsedSince >= REFRESH_SECONDS then
			elapsedSince = 0
			ns.RefreshWindow()
		end
	end)
	frame:SetScript("OnShow", ns.RefreshWindow)
	frame:Hide()
end

function ns.ShowWindow(show)
	if not frame then
		Build()
	end
	if show == nil then
		show = not frame:IsShown()
	end
	ns.db.windowShown = show
	frame:SetShown(show)
end

ns.On("PLAYER_LOGIN", function()
	if ns.db and ns.db.windowShown then
		ns.ShowWindow(true)
	end
end)
