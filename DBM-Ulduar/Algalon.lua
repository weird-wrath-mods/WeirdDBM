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
mod:GroupSpells(L.CollapsingStar, "HealthFrame", "SetIconOnStars", "StarBarsLock", L.MoveStarBars) -- localized in every language
mod:AddBoolOption("HealthFrame", true) -- Collapsing Star bars, counted from the combat log
mod:SetBossHealthInfo() -- stars only: no Algalon bar on pull
mod:AddSetIconOption("SetIconOnStars", nil, true, false) -- no DBM icon-setter election: every assist marks
-- the star bars have a spot of their own (DBM's health frame elsewhere stays where it is): moved and locked here
mod:AddBoolOption("StarBarsLock", false)
mod:AddButton(L.MoveStarBars, function() mod:MoveStarBars() end, nil, 200, 20)
mod:SetUsedIcons(1, 2, 3, 4) -- star marks when no raid member holds one at pull
mod.PrefightRoom = L.Planetarium -- the cooldown plan's prefight card shows only here (CooldownPlan.lua's tellMine)
-- the cooldown plan's card and timeline (DBM-Core/modules/CooldownPlan.lua): each optional, movable, lockable
-- the buttons sit under the checkboxes: a button that comes first in its area has nothing to place itself below
mod:GroupSpells(L.CooldownPlan, "CooldownPlanCard", "CooldownPlanStrip", "CooldownPlanLock", L.MoveCooldownPlan, L.TestCooldownPlan)
mod:AddBoolOption("CooldownPlanCard", true)
mod:AddBoolOption("CooldownPlanStrip", true)
mod:AddBoolOption("CooldownPlanLock", false, nil, function() DBM.CooldownPlan.ApplyLock(mod) end)
mod:AddButton(L.MoveCooldownPlan, function() DBM.CooldownPlan.ShowToMove(mod) end, nil, 200, 20)
mod:AddButton(L.TestCooldownPlan, function() DBM.CooldownPlan.TestFight(mod) end, nil, 200, 20)
DBM.CooldownPlan.Prepare(mod) -- the raid leader's plan, made now and again on each pull

mod:RegisterEvents(
	"CHAT_MSG_MONSTER_YELL",
	"UPDATE_WORLD_STATES",
	"UPDATE_MOUSEOVER_UNIT",
	"ZONE_CHANGED",
	"ZONE_CHANGED_INDOORS",
	"ZONE_CHANGED_NEW_AREA"
)

mod:RegisterEventsInCombat(
	"SPELL_CAST_START 64584 64443",
	"SPELL_CAST_SUCCESS 65108 64122 64598 62301 64412 64592 64395 65184",
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
-- ends a little before the pull's first hit (Quantum Strike) so tank cooldowns are surely up when it lands
local timerFirstQuantumStrike	= mod:NewTimer(3, "TimerBeginCDs", 64395, "Tank", nil, 5, DBM_COMMON_L.TANK_ICON)
local BEGIN_CDS_LEEWAY = 1 -- ends as the plan's pull cooldown is due (2.5s), 1s before the first Quantum Strike
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
local killPicked = {} -- star -> true: stars this client (as raid leader) named for a timeline kill window

-- Fixed slot marks, the same every pull: square, moon, triangle, diamond. Skull and cross stay free
-- for kill targets, star and circle for tanks. A mark is on one unit at a time, so a player wearing
-- one of these loses it to the star.
local STAR_MARKS = {6, 5, 4, 3}
-- The opening wave's bar by spawn point (see placeOpening): north-east moon, north-west triangle, south-east
-- square, south-west diamond
local POINT_BAR = {2, 3, 1, 4}

local playerGUID, phased, lastStarSync = nil, false, 0
-- A star GUID this client finds itself goes out at once, at the end of the event that found it (so with any mark
-- the same event showed), not on the next 2s sync: the opening wave's corners wait on the raid seeing its GUIDs.
-- One learned from the raid's sync isn't sent back out.
local sendStarSync -- below
local inSync, foundStar = false, false
local function sendFoundStar(now)
	if foundStar then
		foundStar = false
		sendStarSync(now)
	end
end

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

local GREEN, YELLOW, RED, GREY = {0.2, 0.8, 0.2}, {0.95, 0.8, 0.15}, {0.85, 0.2, 0.2}, {0.5, 0.5, 0.5}

local function seg(from, to, c, a) return {from, to, c[1], c[2], c[3], a} end
local function kHP(hp) return ("%.1fk"):format(hp / 1000) end

local function starStyle(s, h, c)
	return h, s.icon, {segs = {seg(0, h, c)}}
end

-- Bar position, in % of max: smooth between hits and moved by exactly the damage of each hit, so
-- the yellow can be placed against it without flickering on Collapse ticks; it is the seconds until the star dies
-- by itself
local function starBarPct(s, now, hp)
	local nt, tick = nextTick(s, now), starMax * 0.01
	if not nt then return hp / tick end
	return nt - now + hp / tick - 1
end

-- The timeline's kill zone a star is named for, still ahead: its zone or nil
local function starZone(s)
	local CP = DBM.CooldownPlan
	local t = CP.FightTime and CP.FightTime()
	if not t then return end
	for _, w in ipairs(CP.SafeWindows(t, t + 200)) do
		for _, p in pairs(CP.StarKillPicks[w.index] or {}) do
			if p.star == s and not p.gone and not w.expires then return w, t end
		end
	end
end

-- A star named for a kill zone: the health to take off to have it die by itself before the zone ends, in yellow
-- at the top of the bar and as a number before the percent. The bar is in seconds until it dies alone (starBarPct),
-- so that's down to (zone end - now) on it, and both fall 1% a second from there: a star brought into the green
-- stays there and dies in the zone. Taken below (zone start - now) it would die before the zone: red. The bar is
-- smooth but the star dies on a whole-second tick, up to 1s after the bar says, so the yellow reaches a tick
-- further down: all of it taken off, it dies inside the zone, and the timeline shows it there.
local function zoneBar(s, h, w, t)
	if h < w.from - t then return starStyle(s, h, RED) end
	local top = math.max(w.to - t - 1, 0)
	if h <= top then return starStyle(s, h, GREEN) end
	return h, s.icon, {segs = {seg(0, top, GREEN), seg(top, h, YELLOW)}, text = "|cff5aa0ff" .. kHP((h - top) * starMax * 0.01) .. "|r"}
end

-- A star past the plan: it runs out after the last kill zone and no kill names it, so nobody needs to do anything
-- about it. Those are the last 4 stars in the kill order (the 4:16.5 wave, running out at 5:56.5, a few seconds before
-- Ascend ends the fight, and the 5:16.5 refill, which outlasts it), and the one before them, left to run out at 4:56.5.
local function starIgnored(s, now)
	local CP = DBM.CooldownPlan
	local t = CP.FightTime and CP.FightTime()
	if not t then return end
	local last
	for _, w in ipairs(CP.SafeWindows(0, math.huge)) do
		if not w.expires then
			last = w
			for _, p in pairs(CP.StarKillPicks[w.index] or {}) do if p.star == s then return end end
		end
	end
	return last and s.spawn + 100 > now + last.to - t
end

local function starBarLook(s, now)
	local hp = starHP(s, now)
	if hp <= 0 then return 0, s.icon end
	local h = math.max(starBarPct(s, now, hp), 0)
	if starIgnored(s, now) then
		local h2, icon, style = starStyle(s, h, GREY)
		style.name = L.StarBarIgnore -- still marked like the rest, to be seen: until then the bar asks for it
		return h2, icon, style
	end
	local zone, t = starZone(s)
	if zone then return zoneBar(s, h, zone, t) end
	return starStyle(s, h, GREEN)
end

-- The spawn timing says a star is up before anyone has pointed at it: until one of ours does, it has no mark
-- The bars sit by the timeline: their background as dark as its strip
local STAR_BAR_BG = 0.75
local function starBarValue(s)
	if not s then return 0, nil, {bg = STAR_BAR_BG} end -- empty bar
	local h, icon, style = starBarLook(s, GetTime())
	style = style or {}
	style.bg = STAR_BAR_BG
	if not icon and h > 0 then style.name = L.StarBarUnmarked end
	return h, icon, style
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
	local wave = {n = STAR_COUNT - alive, slots = {}, opening = not starSlots[1]}
	for _ = alive + 1, STAR_COUNT do addStarSlot(now, wave) end
end

-- The summon loop gives a wave's stars consecutive GUID counters, so a star only fits a wave whose
-- counters, with it added, still span fewer than the wave's star count.
local function fitsWave(wave, c)
	if not wave or not wave.lo then return true end
	return math.max(wave.hi, c) - math.min(wave.lo, c) < wave.n
end

-- The opening wave puts one star on each spawn point, summoned in point order (CollapsingStarPos), so its GUID
-- counters run c0..c0+3 by point. Once the raid has seen its lowest and highest, every client knows each star's
-- point, and each star moves to its point's bar (POINT_BAR): the same mark on the same corner every pull. Until then its
-- stars are neither marked nor picked for a kill, so no mark ever changes; the bars may reorder once. One of
-- them dead by then (a few seconds in, so rare) leaves the bars as they are.
local STAR_FIXED = {row = true, wave = true, spawn = true, scheduled = true} -- a slot's, not its star's
local function openingUnknown(s)
	return s.wave and s.wave.opening and not s.wave.placed
end
local function placeOpening(w)
	w.placed = true
	for _, s in ipairs(w.slots) do if s.dead then return end end
	w.c0 = w.lo
	local moved = {}
	for _, s in ipairs(w.slots) do
		if s.guid then
			local star = {}
			for k, v in pairs(s) do if not STAR_FIXED[k] then star[k], s[k] = v, nil end end
			s.hp = starMax
			moved[#moved + 1] = star
		end
	end
	for _, star in ipairs(moved) do
		local s = w.slots[POINT_BAR[tonumber(star.guid:sub(#STAR_GUID + 1), 16) - w.c0 + 1]]
		for k, v in pairs(star) do s[k] = v end
		starByGuid[star.guid] = s
	end
end

-- A raid mark needs a unit token, so a star is marked the moment one of ours points at it (mouseover,
-- target, focus, a raid member's target). Not DBM's ScanForMobs: Icons.lua keeps its own copy of
-- SetRaidTarget, so its marks never reach the hook below and the bar would wait for the server.
-- Every leader/assist marks, not just an elected one; all clients map a star to the same slot mark.
local function markStarUnit(s, uId)
	if s.marked or not s.row or openingUnknown(s) or not mod.Options.SetIconOnStars or DBM.Options.DontSetIcons then return end
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
	local pick = w and w.slots[w.c0 and POINT_BAR[c - w.c0 + 1] or c % w.n + 1]
	if pick and not pick.guid and not pick.dead then s = pick end -- taken/dead only if the wave was misjudged
	s = s or fallback
	if not s and noCreate then return end
	s = s or addStarSlot(now) -- missed the emote (late join, reload): full HP, sync corrects it
	s.guid = guid
	starByGuid[guid] = s
	local w = s.wave
	if w then w.lo, w.hi = math.min(w.lo or c, c), math.max(w.hi or c, c) end
	if w and w.opening and not w.placed and w.hi - w.lo == w.n - 1 then
		placeOpening(w)
		s = starByGuid[guid]
	end
	if not inSync then foundStar = true end
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

-- A unit read is the HP right now. Like a sync it only ever lowers a star's damage HP: one that would raise it is a
-- health update a moment behind a hit the log already counted, or the server's Collapse tick a moment off ours,
-- and taking it would bounce the bar and the timeline's death tick by a tick. A star without a tick schedule has no
-- count of its own to keep: its reads are taken as is.
local function readStar(guid, hp, now)
	local s = getStar(guid, now)
	if not s or s.dead then return end
	local damageHP = hp + collapsed(s, now)
	if not s.scheduled or damageHP < s.hp then s.hp = damageHP end
end

-- Another client's damage HP: lower means it saw damage we missed. A star without a tick schedule
-- has a damage HP of its own making, so it neither sends nor takes one.
local function syncStar(guid, hp, now)
	local s = getStar(guid, now)
	if s and not s.dead and s.scheduled and hp < s.hp then s.hp = hp end
end

local function clearStars()
	starSlots, starByGuid, starDiedAt, starRows = {}, {}, {}, {}
	killPicked = {}
	local picks = {}
	for index, marks in pairs(DBM.CooldownPlan.FIXED_STAR_PICKS or {}) do
		picks[index] = {}
		for k, mark in ipairs(marks) do picks[index][k] = {mark = mark} end
	end
	DBM.CooldownPlan.StarKillPicks = picks -- every client knows these already: nothing to sync
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

function sendStarSync(now)
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

-- The timeline's kill labels show the named star's health: the star in the bar with that mark
DBM.CooldownPlan.StarHP = function(mark)
	for i, row in ipairs(starRows) do
		local s = row.star
		if STAR_MARKS[i] == mark and s and not s.dead then return starHP(s, GetTime()) / starMax * 100 end
	end
end

-- And where it dies if left alone, in seconds from now: Collapse takes 1% of max on each whole second from the
-- summon, so it dies on the tick that takes it to 0, a fixed moment until someone hits it. A star without a tick
-- schedule drains smoothly: its health % in seconds.
DBM.CooldownPlan.StarDeathIn = function(mark)
	for i, row in ipairs(starRows) do
		local s = row.star
		if STAR_MARKS[i] == mark and s and not s.dead then
			local now = GetTime()
			local hp, tick = starHP(s, now), nextTick(s, now)
			if not tick then return hp / starMax * 100 end
			return tick - now + math.max(math.ceil(hp / (starMax * 0.01)) - 1, 0)
		end
	end
end

-- The timeline's kill zones name their stars by mark. Only the raid leader (or a solo player) picks, from its
-- own HP readings, so no two clients can name different stars; everyone shows the synced marks. Every zone still
-- ahead picks as soon as it can, in time order, so a star is named (and its bar shows what to take off) the
-- moment it spawns: the lowest HP stars not already picked that won't run out before their kill, which keeps a
-- wave's stars to the zones that wave is for. A zone whose star hasn't spawned yet keeps a "?" until a later tick
-- picks it. A pick never changes: ties within a wave come down to a few hits, and a flip would send the raid onto
-- another star.
local function pickStarKills(now)
	local CP = DBM.CooldownPlan
	local t = CP.FightTime and CP.FightTime()
	if not t or (DBM:IsInGroup() and DBM:GetRaidRank() < 2) then return end
	-- the opening stars a fixed pick names are taken: their bars carry those marks once the wave is placed
	local fixed = {}
	for _, marks in pairs(CP.FIXED_STAR_PICKS or {}) do for _, m in ipairs(marks) do fixed[m] = true end end
	for _, s in ipairs(starSlots) do
		if s.wave and s.wave.opening and s.row and not openingUnknown(s) and fixed[STAR_MARKS[s.row.index]] then killPicked[s] = true end
	end
	for _, w in ipairs(CP.SafeWindows(t, t + 400)) do
		local picks = CP.StarKillPicks[w.index] or {}
		-- a star left to run out is named too: the one that turns 100s old there
		if w.expires and not picks[1] then
			local at = now + w.from - t
			for _, s in ipairs(starSlots) do
				if not s.dead and s.row and not openingUnknown(s) and not killPicked[s] and math.abs(s.spawn + 100 - at) < 1.5 then
					killPicked[s] = true
					mod:SendSync("StarKill", ("%d:1:%d"):format(w.index, STAR_MARKS[s.row.index]))
					picks[1] = {mark = STAR_MARKS[s.row.index], star = s}
					break
				end
			end
		end
		for k = 1, w.from > t and w.kills or 0 do
			if not picks[k] then
				local due = now + w.from + CP.STAR_SECOND * (k - 1) - t
				local best
				for _, s in ipairs(starSlots) do
					if not s.dead and s.row and not openingUnknown(s) and not killPicked[s] and s.spawn + 100 > due
						and (not best or starHP(s, now) < starHP(best, now)) then best = s end
				end
				if not best then break end
				killPicked[best] = true
				mod:SendSync("StarKill", ("%d:%d:%d"):format(w.index, k, STAR_MARKS[best.row.index]))
				picks[k] = {mark = STAR_MARKS[best.row.index], star = best} -- also here: our own sync comes back after a round trip
			end
		end
		CP.StarKillPicks[w.index] = picks
	end
end

-- A named star that dies takes its zone off the timeline. Each pick is tied to the star in its mark's bar the
-- first time that bar shows one: a pick is made or synced while its star is up, and the opening's fixed ones wait
-- for the wave's spawn points to be known.
local function bindStarKills()
	for _, picks in pairs(DBM.CooldownPlan.StarKillPicks) do
		for _, p in pairs(picks) do
			if not p.star then
				for i, row in ipairs(starRows) do
					local s = row.star
					if STAR_MARKS[i] == p.mark and s and not s.dead and not openingUnknown(s) then p.star = s end
				end
			end
			if p.star and p.star.dead then p.gone = true end
		end
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
	sendFoundStar(GetTime())
end)
function onStarLog(event, _, _, _, destGUID, _, destFlags, a1, a2, a3, a4, a5)
	local now = GetTime()
	if destGUID == playerGUID and a1 == 62169 then
		if event == "SPELL_AURA_APPLIED" then phased = true elseif event == "SPELL_AURA_REMOVED" then phased = false end
	end
	if not destGUID or destGUID:sub(1, #STAR_GUID) ~= STAR_GUID then return end
	if starByGuid[destGUID] then seeStarIcon(starByGuid[destGUID], raidMark(destFlags), now, true) end
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

local function startNextPunch(self, count, left)
	left = left or 15.5
	timerNextPhasePunch:Start(left, count)
	self:Unschedule(stopNextPunch)
	self:Schedule(left + 12, stopNextPunch)
end

local function matches(msg, str)
	return str ~= nil and (msg == str or msg:find(str, nil, true) ~= nil)
end
 
-- the fight's timers from the end of the intro; elapsed: how long ago that was (the first Quantum Strike restarts
-- them from it, 3.5s on)
function mod:startTimers(elapsed)
	elapsed = elapsed or 0
	startNextPunch(self, 1, 15.5 - elapsed)
	timerNextCollapsingStar:Start(16.5 - elapsed)
	timerCDCosmicSmash:Start(26 - elapsed)
	announcePreBigBang:Cancel()
	announcePreBigBang:Schedule(80 - elapsed)
	timerNextBigBang:Start(90 - elapsed)
	enrageTimer:Start(360 - elapsed)
end

local starUpdate -- registered per pull: EndCombat drops it

-- the health frame dressed as the star bars, at their own spot: StarBarsPermanentPos (kept by DBM for its "Permanent"),
-- saved once they're dragged; until then right of centre, under the cooldown timeline
local STAR_BARS_AT = {"CENTER", 329, -78}
local function starBarsHere(self)
	local pos = self.Options.StarBarsPermanentPos or STAR_BARS_AT
	DBM.BossHealth:SetHeaderText(L.CollapsingStars)
	DBM.BossHealth:SetBarSpacing(6) -- 4 stacked star bars: a bit under the default 8px gap
	DBM.BossHealth:SetHeaderOffset(2) -- a little clear of the first bar
	DBM.BossHealth:SetPlace(pos and pos[1], pos and pos[2], pos and pos[3], function() return self.Options.StarBarsLock end,
		function(point, x, y) self.Options.StarBarsPermanentPos = {point, x, y} end)
end

-- Move (the options): the star bars with stand-ins, to be dragged where they go, or hidden again; not in a fight
function mod:MoveStarBars()
	if self:IsInCombat() then return end
	if DBM.BossHealth:IsShown() then
		DBM.BossHealth:Hide()
		return
	end
	DBM.BossHealth:Show(L.CollapsingStars)
	starBarsHere(self)
	for i = 1, STAR_COUNT do DBM.BossHealth:AddBoss(function() return 100 - 15 * i end, L["StarBar" .. i]) end
end

function mod:OnCombatStart(delay)
	self:SetStage(1)
	clearStars()
	DBM.CooldownPlan.StarKillSafe = true -- the timeline's Star kill safe windows, while there are stars
	self:RegisterOnUpdateHandler(starUpdate, 0.5)
	starMax = self:IsDifficulty("normal25") and 176400 or 88200
	playerGUID, phased, lastStarSync = UnitGUID("player"), false, 0
	starLog:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED") -- own frame: DBM filters SPELL_DAMAGE by any mod's spell list
	for _, e in ipairs(STAR_UNIT_EVENTS) do starLog:RegisterEvent(e) end
	-- DBM-Core opened it under Algalon's name just before this
	starBarsHere(self)
	DBM.BossHealth:SetUpdateInterval(0.1) -- the bars slide with the 1%/s Collapse, smoothly
	for i = 1, STAR_COUNT do
		local row = {index = i}
		starRows[i] = row
		DBM.BossHealth:AddBoss(function() return starBarValue(row.star) end, L["StarBar" .. i])
	end
	self.vb.warned_preP2 = false
	self.vb.introFixed = false
	-- The first pull is the one with the long intro. Before it there is no despawn timer; the server starts it (at
	-- 60 minutes) on that pull, in the same moment as the pull yell, so it can already read 60 here. A later pull
	-- can't see 60: Algalon comes back 20s after a wipe, so the timer has ticked by then.
	local text = select(3, GetWorldStateUIInfo(1))
	local minutes = tonumber(text and text:match("%d+")) or 0
	if minutes == 0 or minutes >= 60 then
		timerCombatStart:Start(-delay)			-- 26s Roleplay
		timerFirstQuantumStrike:Start(26 + 3.5 - BEGIN_CDS_LEEWAY - delay)
		self:ScheduleMethod(26 - delay, "startTimers")
	else
		timerCombatStart:Start(8.5 - delay)		-- 8.5s Roleplay (AC introDelay on later pulls)
		timerFirstQuantumStrike:Start(8.5 + 3.5 - BEGIN_CDS_LEEWAY - delay)
		self:ScheduleMethod(8.5 - delay, "startTimers")
	end
end

function mod:OnCombatEnd()
	starLog:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	for _, e in ipairs(STAR_UNIT_EVENTS) do starLog:UnregisterEvent(e) end
	clearStars()
	DBM.CooldownPlan.StarKillSafe = nil
	DBM.BossHealth:Clear()
	DBM.WarningSign:Hide(bigBangIcon)
end

function mod:SPELL_CAST_START(args)
	if args:IsSpellID(64584, 64443) then	-- Big Bang
		timerBigBangCast:Start()
		timerNextBigBang:Start()
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
	elseif args:IsSpellID(64592, 64395) and not self.vb.introFixed then	-- the pull's first Quantum Strike
		-- the server casts it 3.5s after the intro, whichever intro it was: the timers and the plan's clock run
		-- from it, whatever the pull guessed
		self.vb.introFixed = true
		timerCombatStart:Stop()
		timerFirstQuantumStrike:Stop()
		self:UnscheduleMethod("startTimers")
		self:startTimers(3.5)
		if DBM.CooldownPlan.SetFightTime then DBM.CooldownPlan.SetFightTime(3.5) end
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

-- the raid leader hears before the pull when the plan won't find its two tanks: on reaching his room (and which two
-- it found, when it does), and on each look at him (a warning only; CooldownPlan.lua's CheckTanks keeps it to every 5s)
function mod:UPDATE_MOUSEOVER_UNIT()
	if self:GetUnitCreatureId("mouseover") == 32871 then DBM.CooldownPlan.CheckTanks(self) end
end

-- everyone in his room before the pull sees their part of the plan (the card, CooldownPlan.lua's Prefight); it goes
-- when they leave
function mod:ZONE_CHANGED()
	if GetSubZoneText() == L.Planetarium then
		DBM.CooldownPlan.CheckTanks(self, true)
		DBM.CooldownPlan.Prefight(self)
	else
		DBM.CooldownPlan.HidePrefight()
	end
end
mod.ZONE_CHANGED_INDOORS = mod.ZONE_CHANGED
mod.ZONE_CHANGED_NEW_AREA = mod.ZONE_CHANGED

function mod:CHAT_MSG_MONSTER_YELL(msg)
	if matches(msg, L.Phase2) then
		self:SetStage(2)
		self.vb.warned_preP2 = true
		timerNextCollapsingStar:Stop()
		warnPhase2:Show()
		warnPhase2:Play("ptwo")
		clearStars()
		DBM.CooldownPlan.StarKillSafe = nil
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
	if msg == "StarKill" and payload then
		local index, k, mark = payload:match("^(%d+):(%d+):(%d+)$")
		local picks = DBM.CooldownPlan.StarKillPicks
		if index then
			index = tonumber(index)
			picks[index] = picks[index] or {}
			picks[index][tonumber(k)] = {mark = tonumber(mark)}
		end
		return
	end
	if msg ~= "StarDmgHP" or sender == UnitName("player") or not payload then return end
	local now = GetTime()
	inSync = true
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
	inSync = false
end

function mod:UNIT_SPELLCAST_SUCCEEDED(_, spellName)
	if spellName == GetSpellInfo(65184) then
		DBM:EndCombat(self)
	end
end

function starUpdate(self)
	if not self:IsInCombat() then return end
	local now = GetTime()
	if not starSlots[1] then return end
	readAllStarUnits(now)
	sendFoundStar(now)
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
	pickStarKills(now)
	bindStarKills()
end
local wsWasActive = false

local function timerUp()
	for i = 1, GetNumWorldStateUI() do
		local _, state = GetWorldStateUIInfo(i)
		if state == 1 then return true end
	end
	return false
end

function mod:UPDATE_WORLD_STATES()
	if not self.inCombat then return end
	local anyActive = timerUp()
	if anyActive then
		wsWasActive = true
	elseif wsWasActive then
		wsWasActive = false
		if self.vb.phase == 2 then
			DBM:EndCombat(self)
		end
	end
end