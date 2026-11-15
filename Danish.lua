local _, ns = ...

-- Tells Danish chat from its neighbours. Written Danish and Norwegian share most words and æ/ø, Swedish has ä/ö,
-- and many short Scandinavian words are English words too (men, her, for, bare, god, til, at, i), so those are left
-- out. A word only one language uses is strong evidence for it (2, naming the language or country 3); a word two
-- languages share is weak evidence for both (1). A line or a run of lines is Danish when Danish has the most strong
-- evidence and at least 3 points in all. Lines Norwegian would write the same way ("jeg kommer om fem minutter")
-- stay undecided on purpose: whispering a Norwegian costs more than missing a Dane, who usually says more.
local DK, NO, SV = 1, 2, 3
local MIN_STRONG, MIN_TOTAL = 2, 3

local LEXICON = {}
local function Words(list, dk, no, sv)
	for word in list:gmatch("%S+") do
		LEXICON[word] = { dk, no, sv }
	end
end

-- Danish only.
Words("hvad nogen nogle noget meget mere lidt måske tak sgu sku fedt vildt sygt gerne bliver blive blevet havde gør gøre "
	.. "siger sagde søger spørge spørg spørger spørgsmål hjælp hjælpe hjælper fået endnu købe køber købt sælge sælger "
	.. "lige næsten gider gide rigtig rigtigt kører jer jeres vores hyggeligt laver lavet ægte vej alligevel minder "
	.. "overvejer overvejet ligesom dage uge slet tvivler inden opslag møde sidste overskud måde andet tilbyde "
	.. "forældre vidste altid hvornår tager tage gik bedste tænker tænke kæmpe pænt dejligt dejlig undskyld tusind øv "
	.. "skide lad os hende ud ind ude inde kæft fandme lort mand finder allesammen sjovt sjov jamen hvorhenne derhenne "
	.. "derinde derude kigge kigger søde venlig brug bruge bruger kender kende sjældent nogensinde piger drenge godnat "
	.. "godmorgen hyg dk", 2, 0, 0)
Words("dansk danske dansker danskere danmark danish denmark", 3, 0, 0)
Words("af ret mit tit", 1, 0, 0)
-- Danish and Norwegian.
Words("jeg ikke der vil skal godt mange også hvordan hvorfor hvem hvis hvor når før være gruppe koster spiller spille "
	.. "selv sammen venner kun kunne synes ved et hygge virkelig nede oppe nå allerede elsker savner sikker hvilken "
	.. "hvilke skifte guildet velkommen velkomne føler solgt flere derfor nye lille altså vente melde mangler andre "
	.. "siden spillet forhold første engang nok ned hun intet bedre fordi stadig snakker snakke deres hjem langsomt "
	.. "holdt farvel sted egentlig virker vist hjemme mens endelig penge sølv sød samme dit hurtig hurtigt smutte "
	.. "smutter imens lave selvom fanden skynd", 1, 1, 0)
-- Danish and Swedish.
Words("hej nej nu mig dig sig efter igen aldrig guld", 1, 0, 1)
-- Norwegian only.
Words("hva noen noe mye litt takk hei etter ikkje veldig kjempe skjer bli blitt hadde opp kanskje gjør gjøre sier "
	.. "søker spør spørre hjelp hjelpe hjelper ennå kjøpe kjøper selger selge nesten trenger meg deg seg dere vår våre "
	.. "sykt gidder riktig kjører lage ekte vei allikevel dager uke innen siste måte annet tenker deilig faen mann",
	0, 2, 0)
Words("norsk norske nordmann nordmenn norge norway norwegian", 0, 3, 0)
-- Norwegian and Swedish.
Words("blir av ut fått vet mer oss henne ute inne alltid fort bra", 0, 2, 2)
-- Swedish only.
Words("jag inte och att är vad hur någon något några mycket lite tack kanske gör göra säger söker hjälp hjälpa gärna "
	.. "vara hade upp köpa köper säljer sälja sjukt fråga ännu nästan behöver också bara ska vill hon honom från finns "
	.. "ett kul redan vilken vilka flera nya lilla andra sedan spelet dagar vecka innan sista annat nån nåt", 0, 0, 2)
Words("svensk svenska svenskar sverige sweden swedish", 0, 0, 3)

local AE, OE = "\195\166", "\195\184" -- æ ø
local A_UMLAUT, O_UMLAUT = "\195\164", "\195\182" -- ä ö
local MAX_SHAPE_WORDS = 2
local MIN_SUFFIX_BYTES = 6

-- A line as it reads, without colour and texture codes; links keep their [text].
function ns.Plain(text)
	return (text:gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- Lower-cases ASCII and the Latin-1 capitals (Æ Ø Å Ä Ö ...; UTF-8 C3 80-9E, all but ×) and drops what isn't
-- someone's words: links (item names are English), colours, textures and raid target icons.
function ns.PlainLower(text)
	text = text:gsub("|H.-|h.-|h", " "):gsub("|T.-|t", " "):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	text = text:gsub("{.-}", " ")
	text = text:gsub("\195([\128-\158])", function(byte)
		if byte == "\151" then
			return "\195\151"
		end
		return "\195" .. string.char(byte:byte() + 32)
	end)
	return text:lower()
end

-- The words of a line: runs of ASCII letters and UTF-8 bytes, lower-cased.
function ns.Words(text)
	local words = {}
	for word in ns.PlainLower(text):gmatch("[%a\128-\255]+") do
		words[#words + 1] = word
	end
	return words
end

-- Words outside the lexicon still carry their letters and endings: ä/ö are Swedish (or German); æ/ø and a definite
-- plural in -erne are Danish or Norwegian (Danish priserne, but both say spillerne); a past tense in -ede is mostly
-- Danish (Norwegian -et/-te). At most two such words count per line.
local function ShapeEvidence(word, strong, weak, shapes)
	if shapes.n >= MAX_SHAPE_WORDS then
		return
	end
	if word:find(A_UMLAUT, 1, true) or word:find(O_UMLAUT, 1, true) then
		strong[SV] = strong[SV] + 2
	elseif word:find(AE, 1, true) or word:find(OE, 1, true)
			or (#word >= MIN_SUFFIX_BYTES and word:sub(-4) == "erne") then
		weak[DK], weak[NO] = weak[DK] + 1, weak[NO] + 1
	elseif #word >= MIN_SUFFIX_BYTES and word:sub(-3) == "ede" then
		weak[DK] = weak[DK] + 1
	else
		return
	end
	shapes.n = shapes.n + 1
end

-- Adds one line's evidence to strong/weak ({ dk, no, sv } each); new tables when none are given.
function ns.ScoreLanguage(text, strong, weak)
	strong, weak = strong or { 0, 0, 0 }, weak or { 0, 0, 0 }
	local shapes = { n = 0 }
	for _, word in ipairs(ns.Words(text)) do
		local entry = LEXICON[word]
		if entry then
			for language = DK, SV do
				local points = entry[language]
				if points >= 2 then
					strong[language] = strong[language] + points
				else
					weak[language] = weak[language] + points
				end
			end
		else
			ShapeEvidence(word, strong, weak, shapes)
		end
	end
	return strong, weak
end

function ns.IsDanishScore(strong, weak)
	return strong[DK] >= MIN_STRONG and strong[DK] > strong[NO] and strong[DK] > strong[SV]
		and strong[DK] + weak[DK] >= MIN_TOTAL
end

function ns.IsDanish(text)
	return ns.IsDanishScore(ns.ScoreLanguage(text))
end
