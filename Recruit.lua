local _, ns = ...

-- The client wants a key press or click for channel posts, /who and guild invites, so those go out only on a press
-- (GuildRecruit_Next: the key binding, the window's button, /gr next or a macro). One press does all that's due: the
-- invite someone asked for, an ad in every channel whose interval has passed, and a /who of the newest Danish
-- speaker. Whispers need no press: a candidate the /who found without a guild is whispered on its own, within the
-- rate limit, unless /gr auto off puts whispers back on the press.

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
local NAME_RETRY = 5
local LOGIN_DELAY = 10
local NOTE_REPEAT = 5 * 60

local pendingWho
local whisperScheduled = false
local lateKeys = {} -- people whose /who timed out this session: a late answer about them belongs to nobody else
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
table.sort(NOT_REFUSALS, function(a, b) return #a > #b end)
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
-- The words come from the whole line ("har ingen guild, invite pls" names the guild); the refusal check and the
-- bare-inv test read it without the not-refusal phrases.
function ns.IsInviteRequest(text, afterAd)
	local cleaned = Clean(text)
	if Classify(cleaned) == "no" then
		return false
	end
	local invite, guild = false, false
	for _, word in ipairs(ns.Words(text)) do
		if EXPLICIT[word] then
			return true
		end
		invite, guild = invite or INVITE_WORDS[word] == true, guild or GUILD_WORDS[word] == true
	end
	if not invite then
		return false
	elseif guild then
		return true
	end
	local count = 0
	for word in cleaned:gmatch("%S+") do
		count = count + 1
		if not FILLER[word] and not INVITE_WORDS[word] then
			return false
		end
	end
	return afterAd == true and count <= MAX_BARE_WORDS
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

-- Candidates without a guild who were never whispered (nobody gets the pitch twice), checked longest ago first.
-- Left out: whoever whispered the player first (ns.Talked), and a "no guild" too old to trust.
local function Unasked()
	local found, now = {}, ns.Now()
	for _, person in pairs(ns.db.people) do
		if person.state == "free" and not person.asked and not ns.Talked(person.key)
				and not ns.StaleFree(person, now) then
			found[#found + 1] = person
		end
	end
	table.sort(found, Earlier)
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

local function WaitLabel(now, nextAd)
	local parts = {}
	if pendingWho then
		local person = ns.db.people[pendingWho.key]
		parts[#parts + 1] = "waiting for the /who on " .. (person and person.name or "someone")
	end
	if not ns.db.autoWhisper and Unasked()[1] and WhisperWait(now) > 0 then
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

-- "a", "a and b", "a, b and c".
local function Join(items)
	if #items <= 1 then
		return items[1] or ""
	end
	return table.concat(items, ", ", 1, #items - 1) .. " and " .. items[#items]
end

local function TooLongFor(person, text)
	return ("the whisper is too long for %s (%d bytes, a chat message holds %d): /gr whispertext <text> shortens it.")
		:format(person.name, #text, ns.MAX_BYTES)
end

-- The first never-whispered candidate without a guild whose whisper fits, its text, and those it doesn't fit.
local function NextWhisper()
	local skipped = {}
	for _, person in ipairs(Unasked()) do
		local text = ns.Expand(ns.db.whisper, ns.FirstName(person.name))
		if #text <= ns.MAX_BYTES then
			return person, text, skipped
		end
		skipped[#skipped + 1] = { person = person, text = text }
	end
	return nil, nil, skipped
end

-- Each candidate the whisper doesn't fit is named once, not on every try.
local function NameTooLong(skipped)
	for _, entry in ipairs(skipped) do
		if not entry.person.tooLong then
			entry.person.tooLong = true
			ns.Print(TooLongFor(entry.person, entry.text))
		end
	end
end

local function Add(step, label, action)
	step.labels[#step.labels + 1] = label
	step.actions[#step.actions + 1] = action
end

local function AddInvite(step, clock)
	local wants = Oldest("wants")
	if wants and not CanGuildInvite() then
		step.notes[#step.notes + 1] = wants.name .. " wants an invite, but your guild rank can't invite: ask an "
			.. "officer to /ginvite them."
	elseif wants and clock - lastInvite >= INVITE_GAP then
		Add(step, "invite " .. wants.name, { kind = "invite", person = wants })
	end
end

local function AddWhisper(step, now)
	if WhisperWait(now) > 0 or ns.ChatLocked() then
		return
	end
	local person, text, skipped = NextWhisper()
	step.skipped = skipped
	if person then
		Add(step, "whisper " .. person.name, { kind = "whisper", person = person, text = text })
	end
end

local function AddAds(step, now)
	local due, unjoined, nextAd = ns.DueAds(now)
	step.unjoined = unjoined
	if #due > 0 and ns.ChatLocked() then
		step.notes[#step.notes + 1] = "chat is locked during this fight, so the ads wait for the next press after it."
	elseif #due > 0 and ns.AnyAdFits() then
		local keys = {}
		for i, ad in ipairs(due) do
			keys[i] = ad.key
		end
		Add(step, (#due == 1 and "an ad in " or "ads in ") .. Join(keys), { kind = "ads", due = due })
	elseif #due > 0 then
		step.notes[#step.notes + 1] = "every ad text is too long once this guild's name is filled in: /gr ads shows "
			.. "their sizes."
	end
	return nextAd
end

local function AddWho(step, now, clock)
	local candidate = NewestFresh(now)
	if candidate and not pendingWho and clock - lastWho >= WHO_GAP then
		Add(step, "/who " .. candidate.name, { kind = "who", person = candidate })
	end
end

-- What the next press does, without doing it: { kind = "press" | "wait" | "none", label, actions, notes, skipped,
-- unjoined }. Actions: invite, whisper (with /gr auto off), ads (every due channel), who. What can't go out (no
-- invite right, the guild's name not loaded yet, texts too long) leaves a note, and the rest still goes.
function ns.NextStep()
	if not IsInGuild() then
		return { kind = "none", label = "You're not in a guild, so there's nothing to recruit for", actions = {},
			notes = {} }
	end
	local now, clock = ns.Now(), GetTime()
	local step = { kind = "press", actions = {}, labels = {}, notes = {} }
	AddInvite(step, clock)
	local nextAd
	if ns.GuildTag() then
		if not ns.db.autoWhisper then
			AddWhisper(step, now)
		end
		nextAd = AddAds(step, now)
	else
		step.notes[#step.notes + 1] = "the guild's name hasn't loaded yet, so no ad or whisper for a moment."
	end
	AddWho(step, now, clock)
	if #step.actions == 0 then
		step.kind, step.label = "wait", WaitLabel(now, nextAd)
	else
		local label = Join(step.labels)
		step.label = label:sub(1, 1):upper() .. label:sub(2)
	end
	return step
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
		lateKeys[person.key] = true
		if person.state == "checking" then
			ns.SetState(person, "new")
		end
		ns.Print("no answer to the /who on " .. person.name .. " (the server answers /who only every few seconds): "
			.. "press again in a moment.")
	end)
end

-- States a whisper doesn't move back to asked: an invite they asked for, or one they got.
local PAST_ASKING = { wants = true, invited = true, joined = true }

function ns.Whisper(person, text)
	local now = ns.Now()
	C_ChatInfo.SendChatMessage(text, "WHISPER", nil, person.name)
	table.insert(ns.db.whispers, now)
	person.asked = now
	if not PAST_ASKING[person.state] then
		ns.SetState(person, "asked")
	end
	ns.db.stats.whispered = ns.db.stats.whispered + 1
	ns.Log("whisper", person.name)
end

local function ScheduleWhisper(delay)
	if whisperScheduled then
		return
	end
	whisperScheduled = true
	C_Timer.After(math.max(1, delay), function()
		whisperScheduled = false
		ns.AutoWhisper()
	end)
end

-- Whispers the next checked candidate without a guild as soon as the rate limit allows, and keeps going while
-- others wait.
function ns.AutoWhisper()
	if not ns.db or not ns.db.autoWhisper or not IsInGuild() then
		return
	end
	if not ns.GuildTag() or ns.ChatLocked() then
		if Unasked()[1] then
			ScheduleWhisper(ns.ChatLocked() and WHISPER_GAP or NAME_RETRY)
		end
		return
	end
	local person, text, skipped = NextWhisper()
	NameTooLong(skipped)
	if not person then
		return
	end
	local wait = WhisperWait(ns.Now())
	if wait > 0 then
		ScheduleWhisper(wait)
		return
	end
	ns.Whisper(person, text)
	ns.Print(("whispered %s about the guild."):format(person.name))
	if NextWhisper() then
		ScheduleWhisper(WHISPER_GAP)
	end
end

function ns.Invite(person)
	lastInvite, lastInvitedKey = GetTime(), person.key
	C_GuildInfo.Invite(person.name)
	person.invited = ns.Now()
	ns.SetState(person, "invited")
	ns.db.stats.invited = ns.db.stats.invited + 1
	ns.Log("invite", person.name)
end

local function Perform(action)
	if action.kind == "invite" then
		ns.Invite(action.person)
	elseif action.kind == "whisper" then
		ns.Whisper(action.person, action.text)
	elseif action.kind == "ads" then
		for _, ad in ipairs(action.due) do
			ns.PostAd(ad.key, ad.slot, ad.position)
		end
	elseif action.kind == "who" then
		Who(action.person)
	end
end

-- Inside an instance General and the city channels aren't there to join, so missing them needs no advice.
local function TellUnjoined(unjoined)
	if IsInInstance() then
		return
	end
	for _, key in ipairs(unjoined or {}) do
		ns.Tell(("not in the %s channel on this character, so no ad there (/join %s; Trade channels need a city).")
			:format(key, key), NOTE_REPEAT)
	end
end

-- One press. `quiet` (/gr next quiet, for a macro pressed all the time) leaves out "nothing to do now". A press also
-- restarts automatic whispers a dead end stopped (the guild unknown at login, a text that fit nobody).
function ns.DoNext(quiet)
	if not ns.db then
		return
	end
	local step = ns.NextStep()
	for _, note in ipairs(step.notes) do
		ns.Tell(note, NOTE_REPEAT)
	end
	TellUnjoined(step.unjoined)
	NameTooLong(step.skipped or {})
	for _, action in ipairs(step.actions) do
		Perform(action)
	end
	if #step.actions == 0 and not quiet then
		ns.Print(step.label .. ".")
	end
	ns.AutoWhisper()
	ns.Changed()
end

GuildRecruit_Next = function() ns.DoNext() end
BINDING_HEADER_GUILDRECRUIT = "GuildRecruit"
BINDING_NAME_GUILDRECRUIT_NEXT = "Next recruiting step"

ns.On("PLAYER_LOGIN", function()
	ScheduleWhisper(LOGIN_DELAY)
end)

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
		ns.Print(("%s (level %d) has no guild."):format(person.name, info.level))
		ns.AutoWhisper()
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

-- Letters another spelling of a name may write in ASCII ("Bjorn" for "Bjørn"), both cases.
local FOLD = {
	["\195\134"] = "ae", ["\195\166"] = "ae", ["\195\152"] = "o", ["\195\184"] = "o", ["\195\133"] = "a",
	["\195\165"] = "a", ["\195\132"] = "a", ["\195\164"] = "a", ["\195\150"] = "o", ["\195\182"] = "o",
	["\195\156"] = "u", ["\195\188"] = "u", ["\195\137"] = "e", ["\195\169"] = "e",
}

local function Folded(key)
	return (key:gsub("\195[\128-\191]", function(letter) return FOLD[letter] or letter end):lower())
end

-- Another spelling of the same name: a realm after it, or æ/ø/å written in ASCII.
local function SameName(theirKey, key)
	return theirKey:sub(1, #key) == key or Folded(theirKey) == Folded(key)
end

-- An exact-name /who answers with that player alone, perhaps spelled otherwise, or with nobody when they're
-- offline. A /who that timed out may still answer late; any other name is the player's own /who, or a name format
-- GuildRecruit doesn't know.
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
	for _, info in ipairs(readable) do
		local theirKey = ns.Key(info.fullName)
		if theirKey == key then
			FinishWho()
			return person and Checked(person, info)
		elseif lateKeys[theirKey] then
			lateKeys[theirKey] = nil
			return
		end
	end
	FinishWho()
	if not person or person.state ~= "checking" then
		return
	elseif count == 0 then
		ns.SetState(person, "offline")
		ns.Print(person.name .. " isn't online any more.")
	elseif count == 1 and readable[1] and SameName(ns.Key(readable[1].fullName), key) then
		Checked(person, readable[1])
	else
		Missed(person, table.concat(names, ", "))
	end
end)

-- The invite is the one step that waits for the player, so it rings and shows mid-screen like a raid warning.
local function Alert(text)
	ns.Print(text)
	PlaySound(SOUNDKIT.RAID_WARNING)
	if RaidWarningUtil and RaidWarningUtil.AddMessage then
		RaidWarningUtil.AddMessage("GuildRecruit: " .. text, ChatTypeInfo.RAID_WARNING)
	end
end

local function Wants(person, text)
	person.said = ns.Cut(ns.Plain(text), 200)
	ns.SetState(person, "wants")
	local key = GetBindingKey("GUILDRECRUIT_NEXT")
	Alert(("%s wants to join: %s invites them."):format(person.name, key and ("press " .. key) or "/gr next"))
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
	ns.db.talked[ns.Key(sender)] = ns.Now()
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
