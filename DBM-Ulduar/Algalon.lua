local mod	= DBM:NewMod("Algalon", "DBM-Ulduar")
local L		= mod:GetLocalizedStrings()

mod:SetRevision("20261003000000")
mod:SetCreatureID(32871)
mod:SetEncounterID(757)
mod:RegisterCombat("yell", L.YellPull)
mod:RegisterKill("yell", L.YellKill)
mod:SetWipeTime(20)

-- One "Collapsing Stars" section, drawn above the General Announces area; options are listed by name,
-- so this must come before they are added (HealthFrame is re-added below and moves in too)
mod:GroupSpells(L.CollapsingStar, "HealthFrame", "SetIconOnStars") -- localized in every language
mod:AddBoolOption("HealthFrame", true) -- Collapsing Star bars, counted from the combat log
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
-- summon emote tops the stars back up to 4. A client inside a Black Hole (62169) is phased and gets
-- no star damage, so clients sync estimates and keep the lowest: missed damage only ever inflates one.
local STAR_GUID = "0xF1300080BB" -- creature 32955 (the 25-man entry keeps the base entry in the GUID)
local STAR_COUNT, STAR_SYNC_EVERY, STAR_DEAD_SYNC_FOR = 4, 2, 10
local starMax = 88200
local starSlots = {} -- {name, hp, t, wave, guid, dead, warned}: hp is health at time t, before decay
local starByGuid = {}
local starDiedAt = {} -- guid -> time; synced as 0 so a phased client still learns about the death
local starRows = {} -- the 4 bars, which never move; row.star is the star shown, if any
local starMarks = {} -- fixed slot -> raid mark, picked on pull

-- Lowest marks (never skull) not already on a raid member; if fewer than 4 are free, take the lowest
-- ones in use, since stealing a player's mark is the last resort
local function pickStarMarks()
	local used, marks = {}, {}
	for uId in DBM:GetGroupMembers() do
		local m = GetRaidTargetIndex(uId)
		if m then used[m] = true end
	end
	for m = 1, 7 do
		if not used[m] and #marks < STAR_COUNT then marks[#marks + 1] = m end
	end
	for m = 1, 7 do
		if used[m] and #marks < STAR_COUNT then marks[#marks + 1] = m end
	end
	return marks
end
local playerGUID, phased, lastStarSync = nil, false, 0

local function starHP(s, now)
	return s.hp - starMax * 0.01 * (now - s.t)
end

-- Raid mark from combat log unit flags (COMBATLOG_OBJECT_RAIDTARGET1..8 = 0x00100000..0x08000000)
local function raidMark(flags)
	local marks = bit.band(flags or 0, 0x0FF00000)
	for i = 1, 8 do
		if marks == 2 ^ (19 + i) then return i end
	end
end

local function starBarValue(s)
	if not s then return 0 end -- empty bar
	return math.max(starHP(s, GetTime()) / starMax * 100, 0), s.icon
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
	local s = {hp = starMax, t = now, wave = wave}
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
	local want = starMarks[s.row.index]
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

local function correctStar(guid, hp, now, exact)
	local s = getStar(guid, now)
	if not s or s.dead then return end
	if exact or hp < starHP(s, now) then
		s.hp, s.t = hp, now
	end
end

local function clearStars()
	starSlots, starByGuid, starDiedAt, starRows = {}, {}, {}, {}
end

-- A mark we just set only shows in GetRaidTargetIndex and hit flags once the server confirms it; an
-- unmarked reading in that gap must not undo it
local function seeStarIcon(s, icon, now)
	if icon or not s.markedAt or now - s.markedAt > 1 then s.icon = icon end
end

local function readStarUnit(uId, now)
	local guid = UnitGUID(uId)
	if guid and guid:sub(1, #STAR_GUID) == STAR_GUID and UnitHealthMax(uId) > 0 and not UnitIsDead(uId) then
		correctStar(guid, UnitHealth(uId) / UnitHealthMax(uId) * starMax, now, true)
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
			parts[#parts + 1] = s.guid:sub(#STAR_GUID + 1) .. ":" .. math.floor(math.max(starHP(s, now), 1)) .. (s.icon and ":" .. s.icon or "")
		end
	end
	for guid, t in pairs(starDiedAt) do
		if now - t < STAR_DEAD_SYNC_FOR then parts[#parts + 1] = guid:sub(#STAR_GUID + 1) .. ":0" end
	end
	if parts[1] then
		lastStarSync = now
		mod:SendSync("StarHP", table.concat(parts, ","))
	end
end

-- Any mark this client sets on a star (DBM's scan or by hand) is known now, not after a server round
-- trip, and goes out to the raid at once instead of waiting for the next sync
hooksecurefunc("SetRaidTarget", function(unit, icon)
	local s = starByGuid[UnitGUID(unit) or ""]
	if s and not s.dead then
		local now = GetTime()
		s.icon = icon ~= 0 and icon or nil
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
	if starByGuid[destGUID] then seeStarIcon(starByGuid[destGUID], raidMark(destFlags), now) end
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
		seeStarIcon(s, raidMark(destFlags), now)
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
	enrageTimer:Start(360)
end

function mod:OnCombatStart(delay)
	self:SetStage(1)
	clearStars()
	starMax = self:IsDifficulty("normal25") and 176400 or 88200
	playerGUID, phased, lastStarSync = UnitGUID("player"), false, 0
	starLog:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED") -- own frame: DBM filters SPELL_DAMAGE by any mod's spell list
	for _, e in ipairs(STAR_UNIT_EVENTS) do starLog:RegisterEvent(e) end
	DBM.BossHealth:SetHeaderText(L.CollapsingStars) -- DBM-Core opened it under Algalon's name just before this
	DBM.BossHealth:SetBarSpacing(6) -- 4 stacked star bars: a bit under the default 8px gap
	DBM.BossHealth:SetHeaderOffset(2) -- a little clear of the first bar
	starMarks = pickStarMarks()
	for i = 1, STAR_COUNT do
		local row = {index = i}
		starRows[i] = row
		DBM.BossHealth:AddBoss(function() return starBarValue(row.star) end, L["StarBar" .. i])
	end
	self.vb.warned_preP2 = false
	local text = select(3, GetWorldStateUIInfo(1))
	local minutes = tonumber(text and text:match("%d+")) or 0 -- before firstpull there is no timer yet
	if minutes == 0 then
		timerCombatStart:Start(-delay)			-- 26s Roleplay
		self:ScheduleMethod(26 - delay, "startTimers")
	else
		timerCombatStart:Start(8 - delay)		-- 8s Roleplay
		self:ScheduleMethod(8 - delay, "startTimers")
	end
end

function mod:OnCombatEnd()
	starLog:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	for _, e in ipairs(STAR_UNIT_EVENTS) do starLog:UnregisterEvent(e) end
	clearStars()
	DBM.BossHealth:Clear()
end

function mod:SPELL_CAST_START(args)
	if args:IsSpellID(64584, 64443) then	-- Big Bang
		timerBigBangCast:Start()
		timerNextBigBang:Start()
		announcePreBigBang:Cancel()
		announcePreBigBang:Schedule(80.5)
		specWarnBigBang:Show()
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
	if msg ~= "StarHP" or sender == UnitName("player") or not payload then return end
	local now = GetTime()
	for suffix, hp, icon in payload:gmatch("(%x+):(%d+):?(%d*)") do
		local guid, hp = STAR_GUID .. suffix, tonumber(hp)
		if hp == 0 then
			starDied(guid, now)
		else
			correctStar(guid, hp, now)
			-- a mark we saw ourselves (hit flags, our own units) wins; this fills in stars we never saw marked
			local s = starByGuid[guid]
			if s and not s.icon then s.icon = tonumber(icon) end
		end
	end
end

function mod:UNIT_SPELLCAST_SUCCEEDED(_, spellName)
	if spellName == GetSpellInfo(65184) then
		DBM:EndCombat(self)
	end
end

mod:RegisterOnUpdateHandler(function(self)
	if not self:IsInCombat() or not starSlots[1] then return end
	local now = GetTime()
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