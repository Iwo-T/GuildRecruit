local addonName, ns = ...

ns.SCHEMA = 1

local MAX_PEOPLE = 2000
local HEARD_WINDOW = 30 * 60
local MAX_HEARD = 500
local SAID_BYTES = 200
local GUILDED_RECHECK = 7 * 24 * 60 * 60
local STAFF_FLAGS = { GM = true, DEV = true }

-- Chat that can turn up a Danish speaker, and what to call where they spoke; channel lines use the channel's name.
-- Guild and officer chat are left out: those players are members already.
local WATCHED = {
	CHAT_MSG_CHANNEL = true, CHAT_MSG_SAY = "Say", CHAT_MSG_YELL = "Yell", CHAT_MSG_EMOTE = "Emote",
	CHAT_MSG_WHISPER = "Whisper", CHAT_MSG_PARTY = "Party", CHAT_MSG_PARTY_LEADER = "Party", CHAT_MSG_RAID = "Raid",
	CHAT_MSG_RAID_LEADER = "Raid", CHAT_MSG_INSTANCE_CHAT = "Instance", CHAT_MSG_INSTANCE_CHAT_LEADER = "Instance",
}
-- States a Danish line can still move along; the rest are outcomes (asked, wants, invited, joined, declined,
-- skipped, unreachable) that chat doesn't undo, besides offline and a week-old guilded.
local OPEN = { new = true, checking = true, free = true }

local eventFrame = CreateFrame("Frame")
local handlers = {}
local heard = {} -- this session's language evidence per person key: { strong, weak, at }
ns.byGuid = {}

function ns.On(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	for _, fn in ipairs(handlers[event]) do
		xpcall(fn, geterrorhandler(), ...)
	end
end)

function ns.Print(message)
	print("|cff4fc3f7GuildRecruit|r: " .. message)
end

-- luacheck-optional: DevHarness
function ns.Log(...)
	if DevHarness and DevHarness.Log then
		DevHarness.Log(addonName, ...)
	end
end

function ns.Now()
	return GetServerTime()
end

-- Chat says "First Surname", /who may say "First-Surname": people are keyed without case, spaces or hyphens.
function ns.Key(name)
	return (name:lower():gsub("[%s%-]", ""))
end

function ns.FirstName(name)
	return name:match("^[^%s%-]+") or name
end

-- Chat payloads turn secret during encounters and other lockdowns; such a line is skipped whole.
function ns.Readable(...)
	for i = 1, select("#", ...) do
		if issecretvalue((select(i, ...))) then
			return false
		end
	end
	return true
end

-- Cuts text to at most `bytes` without splitting a UTF-8 letter: the cut moves back while the next byte continues one.
function ns.Cut(text, bytes)
	if #text <= bytes then
		return text
	end
	local cut = bytes
	while cut > 0 and text:byte(cut + 1) >= 128 and text:byte(cut + 1) < 192 do
		cut = cut - 1
	end
	return text:sub(1, cut) .. "..."
end

function ns.IsGuildMember(name)
	return C_GuildInfo.MemberExistsByName ~= nil and C_GuildInfo.MemberExistsByName(name) == true
end

function ns.Changed()
	if ns.OnChanged then
		ns.OnChanged()
	end
end

function ns.SetState(person, state)
	person.state, person.at = state, ns.Now()
	ns.Changed()
end

function ns.AddPerson(name, guid)
	local db, now = ns.db, ns.Now()
	db.seq = db.seq + 1
	local person = { name = name, key = ns.Key(name), n = db.seq, first = now, seen = now, at = now, state = "new" }
	if type(guid) == "string" and guid ~= "" then
		person.guid = guid
		ns.byGuid[guid] = person.key
		local _, classFile = GetPlayerInfoByGUID(guid)
		if ns.Readable(classFile) and type(classFile) == "string" and classFile ~= "" then
			person.class = classFile
		end
	end
	db.people[person.key] = person
	return person
end

local function Requeues(person, now)
	return person.state == "offline" or (person.state == "guilded" and now - person.at >= GUILDED_RECHECK)
end

local heardCount = 0
local function ForgetOldEvidence(now)
	for key, evidence in pairs(heard) do
		if now - evidence.start > HEARD_WINDOW then
			heard[key], heardCount = nil, heardCount - 1
		end
	end
end

-- The evidence someone's lines add up to in the half hour since their first one.
local function Evidence(key, now)
	local evidence = heard[key]
	if evidence and now - evidence.start <= HEARD_WINDOW then
		return evidence
	end
	if not evidence then
		heardCount = heardCount + 1
		if heardCount > MAX_HEARD then
			ForgetOldEvidence(now)
		end
	end
	evidence = { start = now, strong = { 0, 0, 0 }, weak = { 0, 0, 0 } }
	heard[key] = evidence
	return evidence
end

-- One line someone said: once their lines read Danish they join the line of people to check.
function ns.Hear(name, guid, text, where)
	local now, key = ns.Now(), ns.Key(name)
	local person = ns.db.people[key]
	if person then
		person.seen = now
		if not OPEN[person.state] and not Requeues(person, now) then
			return
		end
	end
	local evidence = Evidence(key, now)
	ns.ScoreLanguage(text, evidence.strong, evidence.weak)
	if not ns.IsDanishScore(evidence.strong, evidence.weak) then
		return
	end
	person = person or ns.AddPerson(name, guid)
	if not OPEN[person.state] then
		ns.SetState(person, "new")
	end
	person.said, person.where = ns.Cut(ns.Plain(text), SAID_BYTES), where
	ns.Changed()
end

local function OnChat(event, text, sender, _, _, _, flags, _, _, channelBaseName, _, _, guid)
	if not ns.db or not ns.db.watching or not ns.Readable(text, sender, flags, channelBaseName, guid) then
		return
	end
	if type(text) ~= "string" or type(sender) ~= "string" or sender == "" or guid == ns.playerGUID
			or STAFF_FLAGS[flags] or not IsInGuild() or ns.IsGuildMember(sender) then
		return
	end
	local where = WATCHED[event]
	if where == true then
		where = type(channelBaseName) == "string" and channelBaseName ~= "" and channelBaseName or "Channel"
	end
	ns.Hear(sender, guid, text, where)
end

for event in pairs(WATCHED) do
	ns.On(event, function(...)
		OnChat(event, ...)
	end)
end

-- A candidate seen up close shows their guild without a /who. An empty answer may only mean the client hasn't
-- loaded it yet, so only a guild name counts.
local function Sighted(unit)
	if not ns.db or not UnitExists(unit) or not UnitIsPlayer(unit) then
		return
	end
	local guid = UnitGUID(unit)
	if not ns.Readable(guid) or not guid then
		return
	end
	local person = ns.db.people[ns.byGuid[guid] or false]
	if not person or not OPEN[person.state] then
		return
	end
	local guild = GetGuildInfo(unit)
	if ns.Readable(guild) and type(guild) == "string" and guild ~= "" then
		person.guild = guild
		ns.SetState(person, "guilded")
	end
end

ns.On("UPDATE_MOUSEOVER_UNIT", function() Sighted("mouseover") end)
ns.On("PLAYER_TARGET_CHANGED", function() Sighted("target") end)

local function Defaults()
	return {
		schema = ns.SCHEMA, people = {}, seq = 0, ads = CopyTable(ns.DEFAULT_ADS), whisper = ns.DEFAULT_WHISPER,
		channels = CopyTable(ns.DEFAULT_CHANNELS), adMinutes = ns.DEFAULT_AD_MINUTES, nextAd = 1, lastAd = {},
		lastAdAny = 0, whispers = {}, watching = true, stats = { ads = 0, whispered = 0, invited = 0, joined = 0 },
	}
end

-- Over the cap, people never contacted go first, those heard from longest ago first: forgetting whom GuildRecruit
-- whispered, invited or was told no would let it contact them again.
local function Prune(db)
	local all = {}
	for _, person in pairs(db.people) do
		all[#all + 1] = person
	end
	if #all <= MAX_PEOPLE then
		return
	end
	table.sort(all, function(a, b)
		local aOpen, bOpen = OPEN[a.state] or a.state == "offline", OPEN[b.state] or b.state == "offline"
		if aOpen ~= bOpen then
			return aOpen
		end
		return a.seen < b.seen
	end)
	for i = 1, #all - MAX_PEOPLE do
		db.people[all[i].key] = nil
	end
end

-- A database from another schema starts over but keeps its people, for the same reason.
local function LoadDB()
	local db = GuildRecruitDB
	if type(db) ~= "table" then
		db, ns.firstRun = Defaults(), true
	elseif db.schema ~= ns.SCHEMA then
		local people = type(db.people) == "table" and db.people or {}
		db = Defaults()
		db.people = people
	end
	for key, value in pairs(Defaults()) do
		if db[key] == nil then
			db[key] = value
		end
	end
	GuildRecruitDB, ns.db = db, db
	Prune(db)
	for key, person in pairs(db.people) do
		if person.state == "checking" then
			person.state = "new"
		end
		if person.guid then
			ns.byGuid[person.guid] = key
		end
		db.seq = math.max(db.seq, person.n or 0)
	end
end

ns.On("ADDON_LOADED", function(name)
	if name == addonName then
		LoadDB()
	end
end)

ns.On("PLAYER_LOGIN", function()
	ns.playerGUID = UnitGUID("player")
	if ns.firstRun then
		ns.Print("listening for Danish speakers. Bind Key Bindings > AddOns > GuildRecruit > Next recruiting step "
			.. "(or make a /gr next macro): each press does one step. /gr show opens the window, /gr lists the commands.")
	end
end)
