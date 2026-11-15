local _, ns = ...

-- A chat message holds 255 bytes of UTF-8; æ, ø and å take two each.
ns.MAX_BYTES = 255
ns.DEFAULT_AD_MINUTES = 15
ns.MIN_AD_MINUTES, ns.MAX_AD_MINUTES = 5, 120
ns.DEFAULT_CHANNELS = { "LookingForGroup" }

-- {guild} becomes "<Guild Name>", {name} the player's first name. They say only what the guild told us is true.
ns.DEFAULT_ADS = {
	"{guild} er et dansk, socialt guild, der søger flere! Vi tager dungeons, raids og PvP sammen og hygger os "
		.. "undervejs. Alle levels og classes er velkomne. /w mig for en invite!",
	"Leder du efter et dansk guild? I {guild} spiller vi dungeons, raids og PvP sammen, hjælper hinanden og har det "
		.. "hyggeligt. Uanset level og class er du velkommen. Skriv til mig, så får du en invite :)",
	"Dansker uden guild? Kom med i {guild}! Et socialt fællesskab med dungeons, raids, PvP og masser af hygge. Alle "
		.. "levels og classes er velkomne, nye som garvede. Send mig en /w, så sender jeg en invite.",
	"{guild} - dansk socialt guild med dungeons, raids, PvP og hygge. Alle levels og classes er velkomne. /w for invite!",
}
ns.DEFAULT_WHISPER = "Hej {name}! Er du på udkig efter et guild? Vi er {guild}, et dansk socialt guild med dungeons, "
	.. "raids, PvP og hygge, og alle levels og classes er velkomne. Skriv bare ja, hvis du vil have en invite :)"

-- The longest {name} could be: a twelve-letter first name in two-byte letters.
local LONGEST_FIRST_NAME = string.rep("\195\184", 12)

-- Channels found by their ChatChannels DB2 ID wherever the client names them by city; others by name.
local KNOWN_CHANNELS = { General = 1, Trade = 2, LocalDefense = 22, LookingForGroup = 26, Services = 42 }
local MAX_CHANNEL_SLOTS = 20
local seenSlots = {}

function ns.GuildTag()
	local guild = GetGuildInfo("player")
	if type(guild) == "string" and guild ~= "" then
		return "<" .. guild .. ">"
	end
end

function ns.Expand(template, firstName)
	local tag = ns.GuildTag() or "<guild>"
	local text = template:gsub("{guild}", function() return tag end)
	return (text:gsub("{name}", function() return firstName or "" end))
end

function ns.ExpandedBytes(template)
	return #ns.Expand(template, LONGEST_FIRST_NAME)
end

function ns.TooLongMessage(bytes)
	return ("that text is %d bytes once filled in, and a chat message holds %d (æ, ø and å take 2 each)."):format(
		bytes, ns.MAX_BYTES)
end

function ns.CanonicalChannel(name)
	for known in pairs(KNOWN_CHANNELS) do
		if known:lower() == name:lower() then
			return known
		end
	end
	return name
end

local function Matches(info, key)
	local id = KNOWN_CHANNELS[key]
	if id and info.zoneChannelID == id then
		return true
	end
	return info.name == key or info.name:sub(1, #key + 3) == key .. " - "
end

-- The slot a channel has on this character, or nil when it isn't joined. Slots seen on incoming channel lines stand
-- in only if the client's lookup answers for no slot at all.
function ns.ChannelSlot(key)
	local most = Constants.ChatFrameConstants and Constants.ChatFrameConstants.MaxChatChannels or MAX_CHANNEL_SLOTS
	local answered = false
	for slot = 1, most do
		local info = C_ChatInfo.GetChannelInfoFromIdentifier(slot)
		if info then
			answered = true
			if Matches(info, key) then
				return slot
			end
		end
	end
	if not answered then
		return seenSlots[key] or seenSlots[KNOWN_CHANNELS[key] or false]
	end
end

ns.On("CHAT_MSG_CHANNEL", function(_, _, _, _, _, _, zoneChannelID, channelIndex, channelBaseName)
	if not ns.Readable(zoneChannelID, channelIndex, channelBaseName) or type(channelIndex) ~= "number" then
		return
	end
	if type(channelBaseName) == "string" and channelBaseName ~= "" then
		seenSlots[channelBaseName] = channelIndex
	end
	if type(zoneChannelID) == "number" and zoneChannelID > 0 then
		seenSlots[zoneChannelID] = channelIndex
	end
end)

-- The first configured channel whose interval has passed and that this character has joined; otherwise nil, the
-- due channels it hasn't joined and when the next ad is due.
function ns.DueAd(now)
	local db = ns.db
	if #db.ads == 0 then
		return nil, nil, {}
	end
	local unjoined, nextDue = {}, nil
	for _, key in ipairs(db.channels) do
		local due = (db.lastAd[key] or 0) + db.adMinutes * 60
		if now >= due then
			local slot = ns.ChannelSlot(key)
			if slot then
				return key, slot
			end
			unjoined[#unjoined + 1] = key
		else
			nextDue = math.min(nextDue or due, due)
		end
	end
	return nil, nil, unjoined, nextDue
end

function ns.AnyAdFits()
	for _, ad in ipairs(ns.db.ads) do
		if #ns.Expand(ad) <= ns.MAX_BYTES then
			return true
		end
	end
	return false
end

local function NextAdText()
	local db = ns.db
	for _ = 1, #db.ads do
		local index = (db.nextAd - 1) % #db.ads + 1
		db.nextAd = index % #db.ads + 1
		local text = ns.Expand(db.ads[index])
		if #text <= ns.MAX_BYTES then
			return text
		end
		ns.Print(("ad %d: %s /gr ad set %d <text> shortens it."):format(index, ns.TooLongMessage(#text), index))
	end
end

function ns.PostAd(key, slot)
	local text = NextAdText()
	if not text then
		return
	end
	local now = ns.Now()
	C_ChatInfo.SendChatMessage(text, "CHANNEL", nil, slot)
	ns.db.lastAd[key], ns.db.lastAdAny = now, now
	ns.db.stats.ads = ns.db.stats.ads + 1
	ns.Log("ad", key, slot)
end
