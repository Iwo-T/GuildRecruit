local _, ns = ...

local HELP = {
	"/gr next - the next recruiting step (also a key binding: Key Bindings > AddOns > GuildRecruit, or a macro).",
	"/gr show - the window; /gr list - the people found; /gr invite <name>; /gr skip <name>.",
	"/gr ads - the ad texts; /gr ad add <text> | ad set <n> <text> | ad del <n> | ad reset ({guild} is the guild).",
	"/gr whisper [<text> | reset] - the whisper to Danish speakers without a guild ({name} is their first name).",
	"/gr channels; /gr channel add|del <name> - where ads go; /gr interval <minutes>; /gr watch on|off.",
}

local function Status()
	local counts = {}
	for _, person in pairs(ns.db.people) do
		counts[person.state] = (counts[person.state] or 0) + 1
	end
	ns.Print("next press: " .. ns.NextStep().label .. ".")
	ns.Print(("people: %d to check, %d without a guild, %d whispered, %d want an invite, %d invited, %d joined."):format(
		counts.new or 0, counts.free or 0, counts.asked or 0, counts.wants or 0, counts.invited or 0,
		counts.joined or 0))
	ns.Print(ns.StatusLine() .. ".")
	if not ns.db.watching then
		ns.Print("chat watching is off: /gr watch on starts it again.")
	end
	if C_ClubFinder and C_ClubFinder.IsEnabled and C_ClubFinder.IsEnabled() then
		ns.Print("the Guild Finder works here: list the guild there too (Guild & Communities > Guild Finder).")
	end
	for _, line in ipairs(HELP) do
		ns.Print(line)
	end
end

local function FindOrAdd(name)
	return ns.db.people[ns.Key(name)] or ns.AddPerson(name)
end

local function InviteName(name)
	if name == "" then
		ns.Print("/gr invite <name> invites them to the guild.")
	elseif not IsInGuild() or not CanGuildInvite() then
		ns.Print("your guild rank can't invite: ask an officer to /ginvite " .. name .. ".")
	else
		ns.Invite(FindOrAdd(name))
	end
end

local function SkipName(name)
	if name == "" then
		ns.Print("/gr skip <name> drops them for good.")
		return
	end
	local person = FindOrAdd(name)
	ns.SetState(person, "skipped")
	ns.Print(person.name .. " is skipped: no /who, whisper or invite from GuildRecruit.")
end

local function List()
	local people = ns.ShownPeople(20)
	if #people == 0 then
		ns.Print("nobody in play right now.")
	end
	for _, person in ipairs(people) do
		ns.Print(ns.DescribePerson(person) .. (person.said and (': "' .. person.said .. '"') or ""))
	end
end

local function ListAds()
	if #ns.db.ads == 0 then
		ns.Print("no ad texts: /gr ad add <text> adds one.")
	end
	for index, ad in ipairs(ns.db.ads) do
		ns.Print(("%d. (%d bytes) %s"):format(index, #ns.Expand(ad), ad))
	end
end

-- Accepts a template if it fits a chat message once filled in.
local function Fits(template)
	if not ns.GuildTag() then
		ns.Print("the guild's name hasn't loaded yet, so the text can't be measured: try again in a moment.")
		return false
	end
	local bytes = ns.ExpandedBytes(template)
	if bytes > ns.MAX_BYTES then
		ns.Print(ns.TooLongMessage(bytes))
		return false
	end
	return true
end

local function EditAd(rest)
	local action, args = rest:match("^(%S*)%s*(.-)$")
	local ads = ns.db.ads
	action = action:lower()
	if action == "add" and args ~= "" then
		if Fits(args) then
			ads[#ads + 1] = args
			ns.Print(("ad %d added."):format(#ads))
		end
	elseif action == "set" then
		local index, text = args:match("^(%d+)%s+(.+)$")
		index = tonumber(index)
		if not index or not ads[index] then
			ns.Print("/gr ad set <n> <text>, with n from /gr ads.")
		elseif Fits(text) then
			ads[index] = text
			ns.Print(("ad %d replaced."):format(index))
		end
	elseif action == "del" then
		local index = tonumber(args)
		if not index or not ads[index] then
			ns.Print("/gr ad del <n>, with n from /gr ads.")
		else
			table.remove(ads, index)
			ns.db.nextAd = 1
			ns.Print(("ad %d deleted."):format(index))
		end
	elseif action == "reset" then
		ns.db.ads, ns.db.nextAd = CopyTable(ns.DEFAULT_ADS), 1
		ns.Print("the default ad texts are back.")
	else
		ns.Print("/gr ad add <text> | ad set <n> <text> | ad del <n> | ad reset")
	end
end

local function EditWhisper(rest)
	if rest == "" then
		ns.Print("the whisper: " .. ns.db.whisper)
	elseif rest:lower() == "reset" then
		ns.db.whisper = ns.DEFAULT_WHISPER
		ns.Print("the default whisper is back.")
	elseif Fits(rest) then
		ns.db.whisper = rest
		ns.Print("whisper set.")
	end
end

local function ListChannels()
	local now = ns.Now()
	if #ns.db.channels == 0 then
		ns.Print("no ad channels: /gr channel add LookingForGroup adds one.")
	end
	for _, key in ipairs(ns.db.channels) do
		local slot = ns.ChannelSlot(key)
		local due = (ns.db.lastAd[key] or 0) + ns.db.adMinutes * 60 - now
		ns.Print(("%s: %s, %s."):format(key, slot and ("/" .. slot) or "not joined",
			due > 0 and ("next ad in %d min"):format(math.ceil(due / 60)) or "an ad is due"))
	end
end

local function EditChannels(rest)
	local action, name = rest:match("^(%S*)%s*(.-)$")
	action = action:lower()
	local channels = ns.db.channels
	if name == "" or (action ~= "add" and action ~= "del") then
		ns.Print("/gr channel add|del <name>: LookingForGroup, Services, Trade, General or a channel you /join.")
		return
	end
	name = ns.CanonicalChannel(name)
	for index, key in ipairs(channels) do
		if key:lower() == name:lower() then
			if action == "del" then
				table.remove(channels, index)
				ns.Print("no more ads in " .. key .. ".")
			else
				ns.Print(key .. " is already an ad channel.")
			end
			return
		end
	end
	if action == "add" then
		channels[#channels + 1] = name
		ns.Print("ads go to " .. name .. " too.")
	else
		ns.Print(name .. " isn't an ad channel.")
	end
end

local function SetInterval(rest)
	local minutes = tonumber(rest)
	if not minutes or minutes < ns.MIN_AD_MINUTES or minutes > ns.MAX_AD_MINUTES then
		ns.Print(("/gr interval <minutes>, %d to %d (now %d)."):format(ns.MIN_AD_MINUTES, ns.MAX_AD_MINUTES,
			ns.db.adMinutes))
		return
	end
	ns.db.adMinutes = math.floor(minutes)
	ns.Print(("one ad per channel every %d min."):format(ns.db.adMinutes))
end

local function SetWatching(rest)
	local value = rest:lower()
	if value == "on" or value == "off" then
		ns.db.watching = value == "on"
	end
	ns.Print("chat watching is " .. (ns.db.watching and "on" or "off") .. ".")
end

local COMMANDS = {
	next = function() ns.DoNext() end,
	show = function() ns.ShowWindow(true) end,
	hide = function() ns.ShowWindow(false) end,
	toggle = function() ns.ShowWindow() end,
	list = List,
	invite = InviteName,
	skip = SkipName,
	ads = ListAds,
	ad = EditAd,
	whisper = EditWhisper,
	channels = ListChannels,
	channel = EditChannels,
	interval = SetInterval,
	watch = SetWatching,
}

SLASH_GUILDRECRUIT1, SLASH_GUILDRECRUIT2 = "/recruit", "/gr"
SlashCmdList.GUILDRECRUIT = function(input)
	if not ns.db then
		return
	end
	local command, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	local handler = COMMANDS[command:lower()]
	if handler then
		handler(rest)
	else
		Status()
	end
end
