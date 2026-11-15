local _, ns = ...

-- One key press, one recruiting step (GuildRecruit_Next: the key binding, the window's button or /gr next). The
-- client wants a key press or click for channel posts, /who and guild invites, so nothing here sends those on its
-- own; whispers don't need one but go out on a press too, so every message the player sends is one they chose.
-- Each press takes the first of: invite someone who asked, whisper a checked Danish speaker without a guild, post
-- a due ad, /who the newest Danish speaker.

local WHO_TIMEOUT = 6
local WHO_GAP = 5
local MAX_WHO_MISSES = 2
local WHISPER_GAP = 30
local WHISPERS_PER_HOUR = 10
local UNDELIVERED_SECONDS = 10
local REPLY_WINDOW = 24 * 60 * 60
local INVITE_GAP = 2
local REFUSAL_SECONDS = 5
local FRESH = 60 * 60
local AD_WINDOW = 15 * 60
local HOUR = 60 * 60

local pendingWho
local whoToken = 0
local lastWho, lastInvite = -math.huge, -math.huge
local lastInvitedKey

local function Set(list)
	local set = {}
	for word in list:gmatch("%S+") do
		set[word] = true
	end
	return set
end

local YES = Set("ja jaa jaaa jah jep jeps jo gerne yes yep yeah ya yea yup sure ok okay oki okey inv invite ginv "
	.. "klart selvfølgelig selvf gladeligt y")
local NO = Set("nej nope no nah nix næ nææ")
local UNSURE = Set("måske maybe senere later")
-- Taken out before anything else: they hold a no-word but say the player has no guild, or is in no hurry.
local NOT_REFUSALS = { "not in a guild", "not in guild", "no guild", "ingen guild", "ikke i en guild",
	"ikke i et guild", "ikke i nogen guild", "ikke i noget guild", "har ikke en guild", "har ikke et guild",
	"har ikke nogen guild", "har ikke noget guild", "har ingen guild", "no rush", "no problem", "no worries",
	"no stress", "ingen stress", "ingen problem", "intet problem" }
local NO_PHRASES = { "ikke interesseret", "not interested", "not for me", "ikke noget for mig", "har en guild",
	"har et guild", "har guild", "har allerede en guild", "har allerede et guild", "allerede i en guild",
	"allerede i et guild", "er i en guild", "er i et guild", "m in a guild", "am in a guild", "already in a guild",
	"in a guild already", "have a guild", "got a guild" }
local UNSURE_PHRASES = { "ikke lige nu", "ikke nu", "not now", "not right now" }
local YES_PHRASES = { "hvorfor ikke", "why not" }
local INVITE_WORDS = Set("inv invite invites invitation inviter invitere inviteret join joine")
local GUILD_WORDS = Set("guild guilden guildet guilds gilde gilden")
local EXPLICIT = Set("ginv ginvite guildinv guildinvite")
local FILLER = Set("pls plz please plx plox pliz tak ty thx thanks me mig i jeg kan få faa en a an hej hey hi hello "
	.. "yo ja yes gerne lige til to os the for")
local MAX_BARE_WORDS = 6

-- The line's words as " word word ", without the phrases that only look like refusals.
local function Clean(text)
	local joined = " " .. table.concat(ns.Words(text), " ") .. " "
	for _, phrase in ipairs(NOT_REFUSALS) do
		joined = joined:gsub(" " .. phrase .. " ", " ")
	end
	return joined
end

local function HasWord(joined, set)
	for word in joined:gmatch("%S+") do
		if set[word] then
			return true
		end
	end
	return false
end

local function HasPhrase(joined, phrases)
	for _, phrase in ipairs(phrases) do
		if joined:find(" " .. phrase .. " ", 1, true) then
			return true
		end
	end
	return false
end

local function Classify(joined)
	if HasWord(joined, NO) or HasPhrase(joined, NO_PHRASES) then
		return "no"
	elseif HasWord(joined, UNSURE) or HasPhrase(joined, UNSURE_PHRASES) then
		return nil
	elseif HasWord(joined, YES) or HasPhrase(joined, YES_PHRASES) then
		return "yes"
	end
end

-- "yes", "no" or nil (can't tell) for a reply to the whisper.
function ns.Answer(text)
	return Classify(Clean(text))
end

-- A whisper asking for a guild invite. A bare "inv" may be about a group, so it counts only shortly after an ad.
function ns.IsInviteRequest(text, afterAd)
	local joined = Clean(text)
	if Classify(joined) == "no" then
		return false
	end
	local invite, guild, onlyFiller, count = false, false, true, 0
	for word in joined:gmatch("%S+") do
		count = count + 1
		if EXPLICIT[word] then
			return true
		elseif INVITE_WORDS[word] then
			invite = true
		elseif GUILD_WORDS[word] then
			guild = true
		elseif not FILLER[word] then
			onlyFiller = false
		end
	end
	return invite and (guild or (afterAd and onlyFiller and count <= MAX_BARE_WORDS))
end

local function Earlier(a, b)
	return a.at < b.at or (a.at == b.at and a.n < b.n)
end

local function Oldest(state)
	local found
	for _, person in pairs(ns.db.people) do
		if person.state == state and (not found or Earlier(person, found)) then
			found = person
		end
	end
	return found
end

-- The candidate without a guild checked longest ago who was never whispered: nobody gets the pitch twice.
local function OldestUnasked()
	local found
	for _, person in pairs(ns.db.people) do
		if person.state == "free" and not person.asked and (not found or Earlier(person, found)) then
			found = person
		end
	end
	return found
end

local function NewestFresh(now)
	local found
	for _, person in pairs(ns.db.people) do
		if person.state == "new" and now - person.seen <= FRESH
				and (not found or person.seen > found.seen or (person.seen == found.seen and person.n > found.n)) then
			found = person
		end
	end
	return found
end

local function RecentWhispers(now)
	local recent = {}
	for _, sent in ipairs(ns.db.whispers) do
		if now - sent < HOUR then
			recent[#recent + 1] = sent
		end
	end
	ns.db.whispers = recent
	return recent
end

-- Seconds until the next whisper may go: 30 s apart, 10 in any hour.
local function WhisperWait(now)
	local recent = RecentWhispers(now)
	local wait = 0
	if #recent > 0 then
		wait = recent[#recent] + WHISPER_GAP - now
	end
	if #recent >= WHISPERS_PER_HOUR then
		wait = math.max(wait, recent[#recent - WHISPERS_PER_HOUR + 1] + HOUR - now)
	end
	return math.max(0, wait)
end

function ns.WhispersThisHour()
	return #RecentWhispers(ns.Now()), WHISPERS_PER_HOUR
end

local function Duration(seconds)
	if seconds < 90 then
		return ("%d s"):format(math.ceil(seconds))
	end
	return ("%d min"):format(math.ceil(seconds / 60))
end

local function WaitLabel(now, free, nextAd)
	local parts = {}
	if pendingWho then
		local person = ns.db.people[pendingWho.key]
		parts[#parts + 1] = "waiting for the /who on " .. (person and person.name or "someone")
	end
	if free and WhisperWait(now) > 0 then
		parts[#parts + 1] = "next whisper in " .. Duration(WhisperWait(now))
	end
	if nextAd then
		parts[#parts + 1] = "next ad in " .. Duration(nextAd - now)
	end
	if #parts == 0 then
		parts[1] = "listening for Danish speakers"
	end
	return "Nothing to do now: " .. table.concat(parts, ", ")
end

local function Step(notes, kind, label, fields)
	local step = fields or {}
	step.kind, step.label = kind, label
	if #notes > 0 then
		step.note = table.concat(notes, " ")
	end
	return step
end

-- What the next press does, without doing it: { kind, label, person, text, channel, slot, note, unjoined }. A step
-- that can't go out (no invite right, a text too long for this guild's name) leaves a note and yields to the next.
function ns.NextStep()
	if not IsInGuild() then
		return Step({}, "none", "You're not in a guild, so there's nothing to recruit for")
	end
	local now, clock, notes = ns.Now(), GetTime(), {}
	local wants = Oldest("wants")
	if wants and not CanGuildInvite() then
		notes[#notes + 1] = wants.name .. " wants an invite, but your guild rank can't invite: ask an officer to "
			.. "/ginvite them."
	elseif wants and clock - lastInvite >= INVITE_GAP then
		return Step(notes, "invite", "Invite " .. wants.name .. " to the guild", { person = wants })
	end
	local named = ns.GuildTag() ~= nil
	if not named then
		notes[#notes + 1] = "the guild's name hasn't loaded yet, so no ad or whisper for a moment."
	end
	local free = OldestUnasked()
	if free and named and WhisperWait(now) == 0 then
		local text = ns.Expand(ns.db.whisper, ns.FirstName(free.name))
		if #text <= ns.MAX_BYTES then
			return Step(notes, "whisper", "Whisper " .. free.name .. " about the guild", { person = free, text = text })
		end
		notes[#notes + 1] = ("the whisper is too long for %s (%d bytes, a chat message holds %d): /gr whisper <text> "
			.. "shortens it."):format(free.name, #text, ns.MAX_BYTES)
	end
	local unjoined, nextAd
	if named then
		local channel, slot
		channel, slot, unjoined, nextAd = ns.DueAd(now)
		if channel and ns.AnyAdFits() then
			return Step(notes, "ad", "Post an ad in " .. channel, { channel = channel, slot = slot })
		elseif channel then
			notes[#notes + 1] = "every ad text is too long once this guild's name is filled in: /gr ads shows their sizes."
		end
	end
	local candidate = NewestFresh(now)
	if candidate and not pendingWho and clock - lastWho >= WHO_GAP then
		return Step(notes, "who", "Check " .. candidate.name .. " (/who)", { person = candidate })
	end
	return Step(notes, "wait", WaitLabel(now, free, nextAd), { unjoined = unjoined })
end

local function RestoreWhoSetting()
	C_FriendList.SetWhoToUi(LFGWhoListFrame ~= nil and LFGWhoListFrame:IsShown() == true)
end

local function FinishWho()
	pendingWho = nil
	RestoreWhoSetting()
end

-- An exact-name /who with its results kept out of chat (SetWhoToUi), the way Blizzard queries a clicked name.
local function Who(person)
	local linkName = C_NameUtil and C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator
		and C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator(person.name) or person.name
	local filter = WHO_TAG_EXACT .. linkName
	C_FriendList.SetWhoToUi(true)
	C_FriendList.SendWho(filter, Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Social)
	whoToken = whoToken + 1
	local token = whoToken
	pendingWho, lastWho = { key = person.key, token = token }, GetTime()
	ns.SetState(person, "checking")
	ns.Log("who sent", filter)
	C_Timer.After(WHO_TIMEOUT, function()
		if not pendingWho or pendingWho.token ~= token then
			return
		end
		FinishWho()
		if person.state == "checking" then
			ns.SetState(person, "new")
		end
		ns.Print("no answer to the /who on " .. person.name .. " (the server answers /who only every few seconds): "
			.. "press again in a moment.")
	end)
end

local function Whisper(person, text)
	local now = ns.Now()
	C_ChatInfo.SendChatMessage(text, "WHISPER", nil, person.name)
	table.insert(ns.db.whispers, now)
	person.asked = now
	ns.SetState(person, "asked")
	ns.db.stats.whispered = ns.db.stats.whispered + 1
end

function ns.Invite(person)
	lastInvite, lastInvitedKey = GetTime(), person.key
	C_GuildInfo.Invite(person.name)
	person.invited = ns.Now()
	ns.SetState(person, "invited")
	ns.db.stats.invited = ns.db.stats.invited + 1
	ns.Log("invite", person.name)
end

local function PrintUnjoined(unjoined)
	for _, key in ipairs(unjoined or {}) do
		ns.Print(("not in the %s channel on this character, so no ad there (/join %s; Trade channels need a city)."):
			format(key, key))
	end
end

function ns.DoNext()
	if not ns.db then
		return
	end
	local step = ns.NextStep()
	if step.note then
		ns.Print(step.note)
	end
	if step.kind == "invite" then
		ns.Invite(step.person)
	elseif step.kind == "whisper" then
		Whisper(step.person, step.text)
	elseif step.kind == "ad" then
		ns.PostAd(step.channel, step.slot)
	elseif step.kind == "who" then
		Who(step.person)
	else
		ns.Print(step.label .. ".")
		PrintUnjoined(step.unjoined)
	end
	ns.Changed()
end

GuildRecruit_Next = ns.DoNext
BINDING_HEADER_GUILDRECRUIT = "GuildRecruit"
BINDING_NAME_GUILDRECRUIT_NEXT = "Next recruiting step"

-- The facts of a /who answer always count; the state only if nothing (a skip, an invite request) came first.
local function Checked(person, info)
	person.level, person.class = info.level, info.filename or person.class
	if person.state ~= "checking" then
		return
	end
	if info.fullGuildName ~= "" then
		person.guild = info.fullGuildName
		ns.SetState(person, "guilded")
		ns.Print(("%s is in <%s> already."):format(person.name, info.fullGuildName))
	elseif person.asked then
		ns.SetState(person, "asked")
	else
		ns.SetState(person, "free")
		ns.Print(("%s (level %d) has no guild: the next press whispers them."):format(person.name, info.level))
	end
end

local function Missed(person, names)
	person.whoMisses = (person.whoMisses or 0) + 1
	if person.whoMisses >= MAX_WHO_MISSES then
		ns.SetState(person, "unreachable")
		ns.Print(("the /who on %s keeps finding others (%s), so GuildRecruit leaves them be; /gr invite %s still "
			.. "works."):format(person.name, names, person.name))
	else
		ns.SetState(person, "new")
		ns.Print(("the /who on %s found others (%s); a later press asks again."):format(person.name, names))
	end
end

-- An exact-name /who answers with that one player, perhaps spelled otherwise ("Bjorn" for "Bjørn"), or with nobody
-- when they're offline. Other names mean someone else's /who answered, or a name format GuildRecruit doesn't know.
ns.On("WHO_LIST_UPDATE", function()
	if not pendingWho then
		return
	end
	local key = pendingWho.key
	local person = ns.db.people[key]
	local count = C_FriendList.GetNumWhoResults() or 0
	local readable, names = {}, {}
	for index = 1, count do
		local info = C_FriendList.GetWhoInfo(index)
		if info and ns.Readable(info.fullName, info.fullGuildName) then
			readable[#readable + 1], names[#names + 1] = info, info.fullName
		end
	end
	ns.Log("who answer", count, table.concat(names, ", "))
	FinishWho()
	if not person then
		return
	end
	for _, info in ipairs(readable) do
		if ns.Key(info.fullName) == key then
			return Checked(person, info)
		end
	end
	if person.state ~= "checking" then
		return
	elseif count == 0 then
		ns.SetState(person, "offline")
		ns.Print(person.name .. " isn't online any more.")
	elseif count == 1 and readable[1] then
		Checked(person, readable[1])
	else
		Missed(person, table.concat(names, ", "))
	end
end)

local function Wants(person, text)
	person.said = ns.Cut(ns.Plain(text), 200)
	ns.SetState(person, "wants")
	local key = GetBindingKey("GUILDRECRUIT_NEXT")
	ns.Print(("%s wants to join: %s invites them."):format(person.name, key and ("press " .. key) or "/gr next"))
end

local function OnReply(person, text)
	local answer = ns.Answer(text)
	if answer == "yes" then
		Wants(person, text)
	elseif answer == "no" then
		ns.SetState(person, "declined")
		ns.Print(person.name .. " said no thanks.")
	else
		ns.Print(('%s answered "%s": /gr invite %s invites them, /gr skip %s drops them.'):format(person.name,
			ns.Plain(text), person.name, person.name))
	end
end

local NO_REQUEST = { skipped = true, joined = true, wants = true }

ns.On("CHAT_MSG_WHISPER", function(text, sender, _, _, _, flags, _, _, _, _, _, guid)
	if not ns.db or not ns.Readable(text, sender, flags, guid) or type(text) ~= "string" or type(sender) ~= "string"
			or sender == "" or guid == ns.playerGUID or not IsInGuild() or ns.IsGuildMember(sender) then
		return
	end
	local person = ns.db.people[ns.Key(sender)]
	if person and person.state == "asked" and ns.Now() - (person.asked or 0) <= REPLY_WINDOW then
		OnReply(person, text)
	elseif not (person and NO_REQUEST[person.state])
			and ns.IsInviteRequest(text, ns.Now() - ns.db.lastAdAny <= AD_WINDOW) then
		Wants(person or ns.AddPerson(sender, guid), text)
	end
end)

-- What the server reports about invites and whispers, by the client's own format strings. "Already invited" means
-- an invite (ours or another guild's) is waiting on them: nothing to redo.
local NAMED_RESULTS = {
	{ "ERR_GUILD_INVITE_S", "invited" },
	{ "ERR_ALREADY_IN_GUILD_S", "guilded" },
	{ "ERR_ALREADY_INVITED_TO_GUILD_S", "invited" },
	{ "ERR_GUILD_DECLINE_S", "declined" },
	{ "ERR_GUILD_DECLINE_AUTO_S", "declined" },
	{ "ERR_GUILD_JOIN_S", "joined" },
	{ "ERR_GUILD_PLAYER_NOT_FOUND_S", "offline" },
	{ "ERR_CHAT_PLAYER_NOT_FOUND_S", "unwhispered" },
}
-- Refusals that don't name the player: they answer an invite sent a moment ago.
local UNNAMED_RESULTS = { "ERR_GUILD_NOT_ALLIED", "ERR_GUILD_INVITE_BAD_SUPER_DISTRICT" }
local patterns

local function Pattern(format)
	local escaped = format:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
	return "^" .. escaped:gsub("%%%%s", "(.+)") .. "$"
end

local function Patterns()
	if not patterns then
		patterns = {}
		for _, result in ipairs(NAMED_RESULTS) do
			local format = _G[result[1]]
			if type(format) == "string" then
				patterns[#patterns + 1] = { pattern = Pattern(format), state = result[2], global = result[1] }
			end
		end
	end
	return patterns
end

local UNCONTACTED = { new = true, checking = true, free = true }
local INVITE_FAILED_FROM = { new = true, checking = true, free = true, wants = true, invited = true }

-- A whisper to someone offline never arrived. Right after GuildRecruit's own whisper that undoes it; otherwise it
-- came from the player's own whispers and only says an uncontacted candidate is gone.
local function Unwhispered(person)
	if person.state == "asked" and ns.Now() - (person.asked or 0) <= UNDELIVERED_SECONDS then
		person.asked = nil
		ns.SetState(person, "offline")
	elseif UNCONTACTED[person.state] then
		ns.SetState(person, "offline")
	end
end

local function Apply(person, state)
	if person.state == "joined" then
		return
	elseif state == "joined" then
		ns.db.stats.joined = ns.db.stats.joined + 1
		ns.SetState(person, "joined")
		ns.Print(person.name .. " joined the guild!")
	elseif state == "unwhispered" then
		Unwhispered(person)
	elseif state ~= "offline" or INVITE_FAILED_FROM[person.state] then
		ns.SetState(person, state)
	end
end

ns.On("CHAT_MSG_SYSTEM", function(text)
	if not ns.db or not ns.Readable(text) or type(text) ~= "string" then
		return
	end
	for _, result in ipairs(Patterns()) do
		local name = text:match(result.pattern)
		if name then
			local person = ns.db.people[ns.Key(name)]
			if person then
				ns.Log("server", result.global, name)
				Apply(person, result.state)
			end
			return
		end
	end
	if text == ERR_GUILD_PERMISSIONS then
		ns.Print("the server says your guild rank can't do that.")
		return
	end
	local person = lastInvitedKey and ns.db.people[lastInvitedKey]
	if not person or person.state ~= "invited" or GetTime() - lastInvite > REFUSAL_SECONDS then
		return
	end
	for _, global in ipairs(UNNAMED_RESULTS) do
		if text == _G[global] then
			lastInvitedKey = nil
			ns.Print(person.name .. " can't be invited: " .. text)
			Apply(person, "unreachable")
			return
		end
	end
end)
