local mod	= DBM:NewMod("Algalon", "DBM-Ulduar")
local L		= mod:GetLocalizedStrings()

mod:SetRevision("20261008000000")
mod:SetCreatureID(32871)
mod:SetEncounterID(757)
mod:RegisterCombat("yell", L.YellPull)
mod:RegisterKill("yell", L.YellKill)
mod:SetWipeTime(20)

-- One "Collapsing Stars" section, drawn above the General Announces area; options are listed by name,
-- so this must come before they are added (HealthFrame is re-added below and moves in too)
mod:GroupSpells(L.CollapsingStar, "HealthFrame", "SetIconOnStars") -- localized in every language
mod:AddBoolOption("HealthFrame", true) -- Collapsing Star bars, counted from the combat log
mod:AddBoolOption("DoomCountdown", true) -- a "Cast Dooms" countdown bar over the star bars
mod:SetBossHealthInfo() -- stars only: no Algalon bar on pull
mod:AddSetIconOption("SetIconOnStars", nil, true, false) -- no DBM icon-setter election: every assist marks
mod:SetUsedIcons(1, 2, 3, 4) -- star marks when no raid member holds one at pull

mod:RegisterEvents(
	"CHAT_MSG_MONSTER_YELL",
	"UPDATE_WORLD_STATES"
)

mod:RegisterEventsInCombat(
	"SPELL_CAST_START 64584 64443",
	"SPELL_CAST_SUCCESS 65108 64122 64598 62301 64412 64592 65184",
	"SPELL_AURA_APPLIED 64412",
	"SPELL_AURA_APPLIED_DOSE 64412",
	"SPELL_AURA_REMOVED 64412",
	"CHAT_MSG_RAID_BOSS_EMOTE",
	"UNIT_SPELLCAST_SUCCEEDED",
	"UNIT_HEALTH"
)

local warnPhase2				= mod:NewPhaseAnnounce(2, 2, nil, nil, nil, nil, nil, 2)
local warnPhase2Soon			= mod:NewPrePhaseAnnounce(2, 2)
local announcePreBigBang		= mod:NewPreWarnAnnounce(64584, 10, 3)
local announceBlackHole			= mod:NewSpellAnnounce(65108, 2)
local announcePhasePunch		= mod:NewStackAnnounce(64412, 4, nil, "Tank|Healer")

local specwarnStarLow			= mod:NewSpecialWarning("warnStarLow", "Tank|Healer", nil, nil, 1, 2)
local specWarnPhasePunch		= mod:NewSpecialWarningStack(64412, nil, 4, nil, nil, 1, 6)
local specWarnBigBang			= mod:NewSpecialWarningSpell(64584, nil, nil, nil, 3, 2)
local specWarnCosmicSmash		= mod:NewSpecialWarningDodge(64596, nil, nil, nil, 2, 2)

local timerNextBigBang			= mod:NewNextTimer(90.5, 64584, nil, nil, nil, 2)
local bigBangName, _, bigBangIcon = GetSpellInfo(64584)
local timerBigBangCast			= mod:NewCastTimer(8, 64584, nil, nil, nil, 2, nil, DBM_COMMON_L.DEADLY_ICON)
local timerNextCollapsingStar	= mod:NewTimer(60, "NextCollapsingStar", "Interface\\Icons\\INV_Enchant_EssenceCosmicGreater", nil, nil, 2, DBM_COMMON_L.HEALER_ICON)
local timerCDCosmicSmash		= mod:NewCDTimer(25.5, 64596, nil, nil, nil, 3)
local timerCastCosmicSmash		= mod:NewCastTimer(4.5, 64596)
local timerPhasePunch			= mod:NewTargetTimer(45, 64412, nil, false, 2, 5, nil, DBM_COMMON_L.TANK_ICON)
local timerNextPhasePunch		= mod:NewNextCountTimer(15.5, 64412, nil, "Tank", 2, 5, nil, DBM_COMMON_L.TANK_ICON, true)
local enrageTimer				= mod:NewBerserkTimer(360, nil, nil, nil, false) -- berserk default OFF
local timerCombatStart 			= mod:NewTimer(26, "TimerCombatStart", "Interface\\Icons\\ability_warrior_offensivestance")

mod.vb.warned_preP2 = false

-- Collapsing Star health, counted from the combat log because almost nobody targets the stars.
-- Server (boss_algalon_the_observer.cpp, creature_template 32955/34215): 88200 HP in 10, 176400 in 25,
-- and Collapse (62018) takes 1% of max per second through DealDamage, which is never logged. Each
-- summon emote tops the stars back up to 4. Each star keeps its damage HP: max minus all damage seen,
-- with Collapse never in it, so it holds only what was observed (hits, unit reads). A client inside a
-- Black Hole (62169) is phased and gets no star damage, so clients sync damage HP and keep the lowest:
-- missed damage only ever raises it.
local STAR_GUID = "0xF1300080BB" -- creature 32955 (the 25-man entry keeps the base entry in the GUID)
local STAR_COUNT, STAR_SYNC_EVERY, STAR_DEAD_SYNC_FOR = 4, 2, 10
local starMax = 88200
local starSlots = {} -- {hp, spawn, scheduled, wave, guid, dead, warned}: hp is damage HP
local starByGuid = {}
local starDiedAt = {} -- guid -> time; synced as 0 so a phased client still learns about the death
local starRows = {} -- the 4 bars, which never move; row.star is the star shown, if any

-- Fixed slot marks, the same every pull: square, moon, triangle, diamond. Skull and cross stay free
-- for kill targets, star and circle for tanks. A mark is on one unit at a time, so a player wearing
-- one of these loses it to the star.
local STAR_MARKS = {6, 5, 4, 3}

local playerGUID, phased, lastStarSync = nil, false, 0

-- Collapse taken so far: a tick every whole second after the summon (the wave's emote); in the logs,
-- decay deaths in one wave land whole seconds apart, within 0.2s. A star bound without its emote
-- (late join, reload) has no tick schedule and decays smoothly from when we first saw it.
local function collapsed(s, now)
	if s.scheduled then return starMax * 0.01 * math.floor(now - s.spawn) end
	return starMax * 0.01 * (now - s.spawn)
end

local function starHP(s, now)
	return s.hp - collapsed(s, now)
end

-- The next Collapse tick, or nil for a star without a tick schedule
local function nextTick(s, now)
	return s.scheduled and s.spawn + math.floor(now - s.spawn) + 1
end

-- Raid mark from combat log unit flags (COMBATLOG_OBJECT_RAIDTARGET1..8 = 0x00100000..0x08000000)
local function raidMark(flags)
	local marks = bit.band(flags or 0, 0x0FF00000)
	for i = 1, 8 do
		if marks == 2 ^ (19 + i) then return i end
	end
end

-- Safe range: a star that dies while the raid is phased in a Black Hole for Big Bang explodes on
-- nobody. Logs (23 Big Bangs, T = cast start): Big Bang lands at T+7.98; the last raider is in by T+5.8
-- typically but as late as T+7.8; the first is released at T+9.03 typically, T+8.83 at the earliest.
-- The target is T+6.5..T+8.8. A Doom is aimed at T+8.0..T+8.8, after Big Bang has hit, when everyone
-- alive is phased whatever the raid does. Damage from here on is known exactly: Collapse ticks
-- on its schedule, and Curse of Doom hits 60s after it lands (logs: 59.9 to 60.0s, never a crit), with
-- no partial resists on a level 80 star. Its amount isn't fixed: unresisted on Algalon our locks did
-- 17.3k to 26.8k, with the +13% spell damage taken debuff a star won't carry, so 15.3k to 23.8k on a
-- star; a lock with no raid buffs did 13.4k to 13.9k. DOOM_HP sits at the low end, and the take-off aims
-- a Collapse tick under it: a bigger Doom still kills when it lands, while one more than a tick smaller
-- leaves the star to Collapse ticks after the raid is released.
-- So the HP that dies inside the target is a range: Collapse alone, about 2 ticks wide, and DOOM_HP wider
-- once a Doom is out that lands inside the target (aimed at T+8.4).
local HOLD_TO, BIG_BANG_EVERY = 9, 90.5
local SAFE_FROM, SAFE_TO = 6.5, 8.8
local DOOM_HP, DOOM_DELAY = 14000, 60
local DOOM_FROM, DOOM_POP = 8.0, 8.4 -- a Doom lands after Big Bang has hit; aimed at the middle
-- How far DOOM NOW leads the window. With the bars redrawn every 0.1s, a press made as the prompt
-- appeared reached the server at once in our tests, so no lead: it lands at the window's start or just after
local REACTION = 0
local DOOM = {[603] = true, [30910] = true, [47867] = true} -- ranks 1-3
local DOOM_ICON = select(3, GetSpellInfo(47867)) or "Interface\\Icons\\Spell_Shadow_AuraOfDarkness"
local bigBangAt -- start of the Big Bang casting now, else the next one
-- Dooms are for the first Big Bang only. On AC's schedule (waves at 16.5s then every 60s, Big Bang at 90s
-- then every 90.5s, a star living at most 100s) the second Big Bang can't have a star Doomed for it at all,
-- and the third is near the 6 min enrage. Once the first Big Bang's DOOM NOW has closed, stars without a
-- Doom are plain bars and the Cast Dooms bar goes.
local doomsUntil
local GREEN, YELLOW, RED = {0.2, 0.8, 0.2}, {0.95, 0.8, 0.15}, {0.85, 0.2, 0.2}
local PURPLE = {0.6, 0.35, 0.85}

local function seg(from, to, c, a) return {from, to, c[1], c[2], c[3], a} end
local function kHP(hp) return ("%.1fk"):format(hp / 1000) end
local function collapseBetween(s, now, t) return collapsed(s, t) - collapsed(s, now) end

-- The Big Bang the star is aimed at: the first whose target it can still die in, if even untouched
-- it lives that long
local function targetBigBang(s, now)
	if not bigBangAt then return end
	local bb = bigBangAt
	while now > bb + SAFE_TO do bb = bb + BIG_BANG_EVERY end
	if starMax - collapsed(s, bb + SAFE_FROM) > 0 then return bb end
end

-- When a Doom that is out lands, if it is still to come: only to tell one cast off its moment, since
-- the range always assumes a Doom landing on time
local function doomLands(s, now)
	return s.doomAt and s.doomAt > now and s.doomAt or nil
end

-- The star dies inside the target if more damage than its HP lands by T+8.5, but no more than its HP
-- before T+6.5: low < hp <= high
local function safeRange(s, now, bb, lands)
	local from, to = bb + SAFE_FROM, bb + SAFE_TO
	local low, high = collapseBetween(s, now, from - 0.001), collapseBetween(s, now, to)
	if lands and lands < from then low = low + DOOM_HP end
	if lands and lands <= to then high = high + DOOM_HP end
	return low, high
end

-- The bar is one instruction: the HP fill in one colour and one word or number before the percent.
--   green, blue number: HP still to take off to the zone a Doom landing on time gives; the same number
--   before and after the Doom is cast, so it can be worked to ahead of time
--   purple, DOOM IN Xs / DOOM NOW: in that zone, waiting for the Doom moment
--   yellow STOP: Doomed and it dies inside the target; leave it alone
--   red TOO LOW: it dies before the target, whatever happens now
--   red DOOM EARLY / DOOM LATE: its Doom lands outside the target, so the number can't be trusted
--   green, percent only: no Doom can land in time and it isn't Doomed, so there is nothing to aim
--   for (those stars are killed on purpose, spread out); every undoomed star once the first Big Bang's
--   DOOM NOW has closed
-- A Doomed star also gets the Doom icon after its name.
local function starStyle(s, h, c, text, doomed)
	local style = {segs = {seg(0, h, c)}, text = text}
	if doomed then style.nameSuffix = " |T" .. DOOM_ICON .. ":0|t" end
	return h, s.icon, style
end

-- When to press for a Doom to land DOOM_FROM..SAFE_TO after Big Bang bb starts casting
local function doomWindow(bb)
	return bb + DOOM_FROM - DOOM_DELAY - REACTION, bb + SAFE_TO - DOOM_DELAY - REACTION
end

local function simpleBar(s, now, hp, h, bb)
	local doomed = s.doomAt ~= nil
	if not bb then return starStyle(s, h, GREEN, nil, doomed) end
	-- a Doom that already hit on the way to this Big Bang: its damage is in hp now, so the bar carries on
	-- with Collapse alone rather than dropping to green while the star still needs taking off
	local hit = s.doomHit and s.doomHit > bb - 30
	local pressFrom, pressTo = doomWindow(bb)
	if not doomed and not hit and (now > pressTo or doomsUntil and now > doomsUntil) then
		return starStyle(s, h, GREEN, nil, doomed)
	end
	-- one number whether or not the Doom is out yet: always worked out for a Doom landing on time. One
	-- that lands outside the target is flagged rather than quietly changing the number
	local lands = doomLands(s, now)
	if lands and lands < bb + SAFE_FROM then return starStyle(s, h, RED, "|cffd93333" .. L.StarDoomEarly .. "|r", true) end
	if lands and lands > bb + SAFE_TO then return starStyle(s, h, RED, "|cffd93333" .. L.StarDoomLate .. "|r", true) end
	local low, high = safeRange(s, now, bb, not hit and bb + DOOM_POP or nil)
	if hp <= low then return starStyle(s, h, RED, "|cffd93333" .. L.StarTooLow .. "|r", doomed) end
	-- with a Doom still to land, take off to a Collapse tick under the top, so a Doom up to a tick short of
	-- DOOM_HP still kills in time; the Doom zone is DOOM_HP wide, so this stays well above TOO LOW
	local target = hit and high or high - starMax * 0.01
	if hp > target then return starStyle(s, h, GREEN, "|cff5aa0ff" .. kHP(hp - target) .. "|r", doomed) end
	if doomed or hit then return starStyle(s, h, YELLOW, "|cfff2cc26" .. L.StarStop .. "|r", doomed) end
	local word = now < pressFrom and L.StarDoomIn:format(pressFrom - now) or L.StarDoomNow
	return starStyle(s, h, PURPLE, "|cffb070ff" .. word .. "|r")
end

-- Bar position, in % of max: smooth between hits and moved by exactly the damage of each hit, so
-- the zone colours can be placed against it without flickering on Collapse ticks
local function starBarPct(s, now, hp)
	local nt, tick = nextTick(s, now), starMax * 0.01
	if not nt then return hp / tick end
	return nt - now + hp / tick - 1
end

local function starBarValue(s)
	if not s then return 0 end -- empty bar
	local now = GetTime()
	local hp = starHP(s, now)
	if hp <= 0 then return 0, s.icon end
	local h = math.max(starBarPct(s, now, hp), 0)
	while bigBangAt and now > bigBangAt + HOLD_TO do bigBangAt = bigBangAt + BIG_BANG_EVERY end
	if s.doomAt and now > s.doomAt + 1 then s.doomHit, s.doomAt = s.doomAt, nil end -- its end went unseen (phased)
	return simpleBar(s, now, hp, h, targetBigBang(s, now))
end

-- The press window for the next Big Bang. A bar over the star bars counts down to it, full until
-- DOOM_BAR_SPAN before and empty at it, then NOW while a Doom still lands in time; after that it counts
-- to the next Big Bang's.
local DOOM_BAR_SPAN = BIG_BANG_EVERY + DOOM_FROM - DOOM_DELAY - REACTION -- Big Bang cast start to the next window
local function doomPressAfter(now)
	if not bigBangAt then return end
	local bb = bigBangAt
	while now > bb + SAFE_TO - DOOM_DELAY - REACTION do bb = bb + BIG_BANG_EVERY end
	return doomWindow(bb)
end

local function doomBarValue()
	local now = GetTime()
	local from = doomPressAfter(now)
	if not from then return 100, nil, {segs = {seg(0, 100, PURPLE)}, valueText = ""} end -- intro: no Big Bang yet
	if now >= from then return 100, nil, {segs = {seg(0, 100, PURPLE)}, valueText = "|cffb070ff" .. L.CastDoomsNow .. "|r"} end
	local pct = math.min((from - now) / DOOM_BAR_SPAN, 1) * 100
	return pct, nil, {segs = {seg(0, pct, PURPLE)}, valueText = ("%.1fs"):format(from - now)}
end

-- A star takes the first free bar; with more than 4 known at once (a misjudged wave) it goes unshown
local function showStar(s)
	for _, row in ipairs(starRows) do
		if not row.star then
			row.star, s.row = s, row
			return
		end
	end
end

local function hideStar(s)
	if s.row then s.row.star, s.row = nil, nil end
end

local function addStarSlot(now, wave)
	local s = {hp = starMax, spawn = now, scheduled = wave ~= nil, wave = wave}
	starSlots[#starSlots + 1] = s
	if wave then wave.slots[#wave.slots + 1] = s end
	showStar(s)
	return s
end

local function addStarWave(now)
	local alive = 0
	for _, s in ipairs(starSlots) do
		if not s.dead then alive = alive + 1 end
	end
	-- slots in creation order, which is ascending free bar order; lo/hi: GUID counters bound so far
	local wave = {n = STAR_COUNT - alive, slots = {}}
	for _ = alive + 1, STAR_COUNT do addStarSlot(now, wave) end
end

-- The summon loop gives a wave's stars consecutive GUID counters, so a star only fits a wave whose
-- counters, with it added, still span fewer than the wave's star count.
local function fitsWave(wave, c)
	if not wave or not wave.lo then return true end
	return math.max(wave.hi, c) - math.min(wave.lo, c) < wave.n
end

-- A raid mark needs a unit token, so a star is marked the moment one of ours points at it (mouseover,
-- target, focus, a raid member's target). Not DBM's ScanForMobs: Icons.lua keeps its own copy of
-- SetRaidTarget, so its marks never reach the hook below and the bar would wait for the server.
-- Every leader/assist marks, not just an elected one; all clients map a star to the same slot mark.
local function markStarUnit(s, uId)
	if s.marked or not s.row or not mod.Options.SetIconOnStars or DBM.Options.DontSetIcons then return end
	if DBM:IsInGroup() and DBM:GetRaidRank() == 0 then return end -- only leader/assist can mark; solo can
	s.marked = true
	local want = STAR_MARKS[s.row.index]
	if GetRaidTargetIndex(uId) ~= want then SetRaidTarget(uId, want) end
end

-- Stars first show up when something hits or points at them, in a different order on each client.
-- The wave is the oldest one the GUID fits. Within it the slot comes from the GUID alone: a wave's k
-- stars have consecutive counters, so counter mod k is distinct per star and every client puts a star
-- in the same bar (and so gives it the same mark) whatever it saw first.
-- ponytail: oldest unbound slot when no wave has a star seen yet to pin the wave down
local function getStar(guid, now, noCreate)
	local s = starByGuid[guid]
	if s or starDiedAt[guid] then return s end
	local c = tonumber(guid:sub(#STAR_GUID + 1), 16)
	local fallback
	for _, slot in ipairs(starSlots) do
		if not slot.guid and not slot.dead then
			fallback = fallback or slot
			if fitsWave(slot.wave, c) then s = slot break end
		end
	end
	local w = s and s.wave
	local pick = w and w.slots[c % w.n + 1]
	if pick and not pick.guid and not pick.dead then s = pick end -- taken/dead only if the wave was misjudged
	s = s or fallback
	if not s and noCreate then return end
	s = s or addStarSlot(now) -- missed the emote (late join, reload): full HP, sync corrects it
	s.guid = guid
	starByGuid[guid] = s
	local w = s.wave
	if w then w.lo, w.hi = math.min(w.lo or c, c), math.max(w.hi or c, c) end
	return s
end

local function removeStar(s, now)
	if s.dead then return end
	s.dead = true
	if s.guid then starDiedAt[s.guid] = now end
	hideStar(s)
end

-- A death can be the first we hear of a star (never hit, or hit while we were phased)
local function starDied(guid, now)
	local s = getStar(guid, now, true)
	if s then removeStar(s, now) end
	starDiedAt[guid] = now
end

-- A unit read is the HP right now: taken as is
local function readStar(guid, hp, now)
	local s = getStar(guid, now)
	if s and not s.dead then s.hp = hp + collapsed(s, now) end
end

-- Another client's damage HP: lower means it saw damage we missed. A star without a tick schedule
-- has a damage HP of its own making, so it neither sends nor takes one.
local function syncStar(guid, hp, now)
	local s = getStar(guid, now)
	if s and not s.dead and s.scheduled and hp < s.hp then s.hp = hp end
end

local function clearStars()
	starSlots, starByGuid, starDiedAt, starRows = {}, {}, {}, {}
end

-- A raid mark sits on one unit at a time, so a star taking a mark takes it off any other star
local function setStarIcon(s, icon)
	if icon then
		for _, other in ipairs(starSlots) do
			if other ~= s and other.icon == icon then other.icon = nil end
		end
	end
	s.icon = icon
end

-- A mark we just set only shows in GetRaidTargetIndex and hit flags once the server confirms it; an
-- unmarked reading in that gap must not undo it. Hit flags (fromLog) never clear a mark: the client
-- leaves the mark bits out when not in a group (solo test logs: 0 of 582 hits on marked stars).
local function seeStarIcon(s, icon, now, fromLog)
	if icon then
		setStarIcon(s, icon)
	elseif not fromLog and (not s.markedAt or now - s.markedAt > 1) then
		s.icon = nil
	end
end

-- In a Black Hole the server sends nothing about stars (raid logs show no star lines at all while
-- phased), so a star seen through a raid member's target is stale and would undo the raid's lows
local function readStarUnit(uId, now)
	if phased then return end
	local guid = UnitGUID(uId)
	if guid and guid:sub(1, #STAR_GUID) == STAR_GUID and UnitHealthMax(uId) > 0 and not UnitIsDead(uId) then
		readStar(guid, UnitHealth(uId) / UnitHealthMax(uId) * starMax, now)
		local s = starByGuid[guid]
		if s then
			seeStarIcon(s, GetRaidTargetIndex(uId), now)
			markStarUnit(s, uId)
		end
	end
end

local function readAllStarUnits(now)
	readStarUnit("target", now)
	readStarUnit("focus", now)
	readStarUnit("mouseover", now)
	readStarUnit("targettarget", now)
	readStarUnit("mouseovertarget", now)
	for uId in DBM:GetGroupMembers() do
		readStarUnit(uId .. "target", now)
	end
end

local function sendStarSync(now)
	if phased then return end -- our counting misses damage in a Black Hole; others have better numbers
	local parts = {}
	for _, s in ipairs(starSlots) do
		if not s.dead and s.guid then
			local hp = s.scheduled and math.floor(math.max(s.hp, 1)) or "" -- "" : mark only
			parts[#parts + 1] = s.guid:sub(#STAR_GUID + 1) .. ":" .. hp .. (s.icon and ":" .. s.icon or "")
		end
	end
	for guid, t in pairs(starDiedAt) do
		if now - t < STAR_DEAD_SYNC_FOR then parts[#parts + 1] = guid:sub(#STAR_GUID + 1) .. ":0" end
	end
	if parts[1] then
		lastStarSync = now
		mod:SendSync("StarDmgHP", table.concat(parts, ",")) -- not "StarHP": older clients sent current HP
	end
end

-- Any mark this client sets on a star (DBM's scan or by hand) is known now, not after a server round
-- trip, and goes out to the raid at once instead of waiting for the next sync
hooksecurefunc("SetRaidTarget", function(unit, icon)
	local s = starByGuid[UnitGUID(unit) or ""]
	if s and not s.dead then
		local now = GetTime()
		setStarIcon(s, icon ~= 0 and icon or nil)
		s.markedAt = s.icon and now
		sendStarSync(now)
	end
end)

-- Combat log, plus unit events so a star nobody has hit gets bound (and so marked) the instant it is
-- moused over or targeted, not on the next 0.5s tick
local onStarLog
local starLog = CreateFrame("Frame")
local STAR_UNIT_EVENTS = {"UPDATE_MOUSEOVER_UNIT", "UNIT_TARGET", "PLAYER_FOCUS_CHANGED", "RAID_TARGET_UPDATE"}
starLog:SetScript("OnEvent", function(_, frameEvent, arg1, ...)
	if frameEvent == "COMBAT_LOG_EVENT_UNFILTERED" then
		onStarLog(...)
	elseif frameEvent == "UPDATE_MOUSEOVER_UNIT" then
		readStarUnit("mouseover", GetTime())
		readStarUnit("mouseovertarget", GetTime())
	elseif frameEvent == "UNIT_TARGET" then -- arg1 "target" covers our target's target changing
		readStarUnit(arg1 .. "target", GetTime())
		if arg1 == "player" then readStarUnit("targettarget", GetTime()) end
	elseif frameEvent == "PLAYER_FOCUS_CHANGED" then
		readStarUnit("focus", GetTime())
	elseif frameEvent == "RAID_TARGET_UPDATE" then -- someone (maybe not us) changed a mark
		readAllStarUnits(GetTime())
	end
end)
function onStarLog(event, _, _, _, destGUID, _, destFlags, a1, a2, a3, a4, a5)
	local now = GetTime()
	if destGUID == playerGUID and a1 == 62169 then
		if event == "SPELL_AURA_APPLIED" then phased = true elseif event == "SPELL_AURA_REMOVED" then phased = false end
	end
	if not destGUID or destGUID:sub(1, #STAR_GUID) ~= STAR_GUID then return end
	if starByGuid[destGUID] then seeStarIcon(starByGuid[destGUID], raidMark(destFlags), now, true) end
	if DOOM[a1] and (event == "SPELL_AURA_APPLIED" or event == "SPELL_AURA_REFRESH") then
		local s = getStar(destGUID, now)
		if s and not s.dead then s.doomAt = now + DOOM_DELAY end
		return
	elseif DOOM[a1] and event == "SPELL_AURA_REMOVED" then -- the Doom hit and the star lived
		local s = starByGuid[destGUID]
		if s then s.doomHit, s.doomAt = now, nil end
		return
	end
	local amount, overkill
	if event == "SWING_DAMAGE" then
		amount, overkill = a1, a2
	elseif event == "SPELL_DAMAGE" or event == "SPELL_PERIODIC_DAMAGE" or event == "RANGE_DAMAGE" or event == "DAMAGE_SHIELD" then
		amount, overkill = a4, a5
	elseif event == "UNIT_DIED" then
		starDied(destGUID, now)
		return
	else
		return
	end
	local s = getStar(destGUID, now)
	if s and not s.dead then
		s.hp = s.hp - (amount - math.max(overkill or 0, 0))
		seeStarIcon(s, raidMark(destFlags), now, true)
	end
end

-- Big Bang can hold a punch past its timer; the kept bar waits at 0 for at most 12s (8s cast plus
-- Algalon getting back into melee range).
local function stopNextPunch()
	timerNextPhasePunch:Stop()
end

local function startNextPunch(self, count)
	timerNextPhasePunch:Start(15.5, count)
	self:Unschedule(stopNextPunch)
	self:Schedule(15.5 + 12, stopNextPunch)
end

local function matches(msg, str)
	return str ~= nil and (msg == str or msg:find(str, nil, true) ~= nil)
end
 
function mod:startTimers()
	startNextPunch(self, 1)
	timerNextCollapsingStar:Start(16.5)
	timerCDCosmicSmash:Start(26)
	announcePreBigBang:Cancel()
	announcePreBigBang:Schedule(80)
	timerNextBigBang:Start(90)
	bigBangAt = GetTime() + 90
	doomsUntil = select(2, doomWindow(bigBangAt))
	if self.Options.DoomCountdown then
		self:Schedule(doomsUntil - GetTime(), function() DBM.BossHealth:RemoveBoss(L.CastDooms) end)
	end
	enrageTimer:Start(360)
end

function mod:OnCombatStart(delay)
	self:SetStage(1)
	clearStars()
	starMax = self:IsDifficulty("normal25") and 176400 or 88200
	playerGUID, phased, lastStarSync, bigBangAt, doomsUntil = UnitGUID("player"), false, 0, nil, nil
	starLog:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED") -- own frame: DBM filters SPELL_DAMAGE by any mod's spell list
	for _, e in ipairs(STAR_UNIT_EVENTS) do starLog:RegisterEvent(e) end
	-- DBM-Core opened it under Algalon's name just before this. With the Cast Dooms bar on top, the
	-- "Collapsing Stars" title goes between it and the stars instead.
	DBM.BossHealth:SetHeaderText(self.Options.DoomCountdown and "" or L.CollapsingStars)
	DBM.BossHealth:SetBarSpacing(6) -- 4 stacked star bars: a bit under the default 8px gap
	DBM.BossHealth:SetHeaderOffset(2) -- a little clear of the first bar
	DBM.BossHealth:SetUpdateInterval(0.1) -- the Doom countdowns run to a tenth of a second
	if self.Options.DoomCountdown then DBM.BossHealth:AddBoss(doomBarValue, L.CastDooms) end
	for i = 1, STAR_COUNT do
		local row = {index = i}
		starRows[i] = row
		local label = i == 1 and self.Options.DoomCountdown and L.CollapsingStars
		DBM.BossHealth:AddBoss(function()
			local pct, icon, style = starBarValue(row.star)
			if label then
				style = style or {}
				style.label = label
			end
			return pct, icon, style
		end, L["StarBar" .. i])
	end
	self.vb.warned_preP2 = false
	local text = select(3, GetWorldStateUIInfo(1))
	local minutes = tonumber(text and text:match("%d+")) or 0 -- before firstpull there is no timer yet
	if minutes == 0 then
		timerCombatStart:Start(-delay)			-- 26s Roleplay
		self:ScheduleMethod(26 - delay, "startTimers")
	else
		timerCombatStart:Start(8.5 - delay)		-- 8.5s Roleplay (AC introDelay on later pulls)
		self:ScheduleMethod(8.5 - delay, "startTimers")
	end
end

function mod:OnCombatEnd()
	starLog:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	for _, e in ipairs(STAR_UNIT_EVENTS) do starLog:UnregisterEvent(e) end
	clearStars()
	DBM.BossHealth:Clear()
	DBM.WarningSign:Hide(bigBangIcon)
end

function mod:SPELL_CAST_START(args)
	if args:IsSpellID(64584, 64443) then	-- Big Bang
		timerBigBangCast:Start()
		timerNextBigBang:Start()
		bigBangAt = GetTime()
		announcePreBigBang:Cancel()
		announcePreBigBang:Schedule(80.5)
		specWarnBigBang:Show()
		if self.Options.SpecWarn64584spell then DBM.WarningSign:Show(bigBangIcon, 8, bigBangName:upper(), "Interface\\AddOns\\DBM-Core\\sounds\\alarm1.wav") end -- the sweep times the cast for the raid
		if self:IsTank() then
			specWarnBigBang:Play("defensive")
		else
			specWarnBigBang:Play("findshelter")
		end
	end
end

function mod:SPELL_CAST_SUCCESS(args)
	if args:IsSpellID(65108, 64122) then	-- Black Hole Explosion
		announceBlackHole:Show()
	elseif args:IsSpellID(64598, 62301) then	-- Cosmic Smash
		timerCastCosmicSmash:Start()
		timerCDCosmicSmash:Start()
		specWarnCosmicSmash:Show()
		specWarnCosmicSmash:Play("watchstep")
	end
end

function mod:SPELL_AURA_APPLIED(args)
	if args.spellId == 64412 then
		local amount = args.amount or 1
		startNextPunch(self, amount + 1)	-- stack the next punch applies unless tanks swap
		if args:IsPlayer() and amount >= 4 then
			specWarnPhasePunch:Show(amount)
			specWarnPhasePunch:Play("stackhigh")
		end
		timerPhasePunch:Start(args.destName)
		announcePhasePunch:Show(args.destName, amount)
	end
end
mod.SPELL_AURA_APPLIED_DOSE = mod.SPELL_AURA_APPLIED

function mod:SPELL_AURA_REMOVED(args)
	if args.spellId == 64412 then
		timerPhasePunch:Cancel(args.destName)
	end
end

function mod:CHAT_MSG_RAID_BOSS_EMOTE(msg)
	if msg == L.Emote_CollapsingStar or msg:find(L.Emote_CollapsingStar, nil, true) then
		timerNextCollapsingStar:Start()	-- flat 60s on AC
		addStarWave(GetTime())
	end
end

function mod:CHAT_MSG_MONSTER_YELL(msg)
	if matches(msg, L.Phase2) then
		self:SetStage(2)
		self.vb.warned_preP2 = true
		timerNextCollapsingStar:Stop()
		warnPhase2:Show()
		warnPhase2:Play("ptwo")
		clearStars()
		DBM.BossHealth:Hide() -- no more stars in phase 2
	end
end

function mod:UNIT_HEALTH(uId)
	if self:GetUnitCreatureId(uId) == 32871 and UnitHealth(uId) / UnitHealthMax(uId) <= 0.23 and not self.vb.warned_preP2 then
		self.vb.warned_preP2 = true
		warnPhase2Soon:Show()
	end
end

function mod:OnSync(msg, payload, sender)
	if msg ~= "StarDmgHP" or sender == UnitName("player") or not payload then return end
	local now = GetTime()
	for suffix, hp, icon in payload:gmatch("(%x+):(%d*):?(%d*)") do
		local guid, hp = STAR_GUID .. suffix, tonumber(hp)
		if hp == 0 then
			starDied(guid, now)
		else
			if hp then syncStar(guid, hp, now) else getStar(guid, now) end
			-- a mark we saw ourselves (hit flags, our own units) wins; this fills in stars we never saw marked
			local s = starByGuid[guid]
			if s and not s.icon and tonumber(icon) then setStarIcon(s, tonumber(icon)) end
		end
	end
end

function mod:UNIT_SPELLCAST_SUCCEEDED(_, spellName)
	if spellName == GetSpellInfo(65184) then
		DBM:EndCombat(self)
	end
end

mod:RegisterOnUpdateHandler(function(self)
	if not self:IsInCombat() then return end
	local now = GetTime()
	if not starSlots[1] then return end
	readAllStarUnits(now)
	for _, s in ipairs(starSlots) do
		if not s.dead then
			local hp = starHP(s, now)
			if hp <= 0 then
				removeStar(s, now)
			else
				if not s.warned and hp < starMax * 0.25 then
					s.warned = true
					specwarnStarLow:Show()
					specwarnStarLow:Play("aesoon")
				end
			end
		end
	end
	-- ponytail: every DBM client sends every 2s while stars are up; send only on disagreement if traffic matters
	if now - lastStarSync >= STAR_SYNC_EVERY then sendStarSync(now) end
end, 0.5)
local wsWasActive = false

function mod:UPDATE_WORLD_STATES()
	if not self.inCombat then return end
	local anyActive = false
	for i = 1, GetNumWorldStateUI() do
		local _, state = GetWorldStateUIInfo(i)
		if state == 1 then
			anyActive = true
			break
		end
	end
	if anyActive then
		wsWasActive = true
	elseif wsWasActive then
		wsWasActive = false
		if self.vb.phase == 2 then
			DBM:EndCombat(self)
		end
	end
end