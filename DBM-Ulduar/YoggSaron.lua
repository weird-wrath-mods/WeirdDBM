local mod	= DBM:NewMod("YoggSaron", "DBM-Ulduar")
local L		= mod:GetLocalizedStrings()

mod:SetRevision("20268317220131")
mod:SetCreatureID(33288)
mod:SetEncounterID(756)
mod:RegisterCombat("combat_yell", L.YellPull)
--The raid can drop combat during Sara's transform dialogue: boss_yoggsaron.cpp spawns the P2
--tentacles 18.5s after the lucid dream yell, and once the last Guardian dies nothing hostile touches
--anyone until then. The default 5s wipe confirm ended the fight there and P2 never started.
mod:SetWipeTime(18.5)
mod:SetUsedIcons(1, 2, 3, 4, 5, 6, 7, 8)

mod:RegisterEventsInCombat(
	"SPELL_CAST_START 64059 64189 63138 63830 63802 63134 63147",
	"SPELL_CAST_SUCCESS 64144 64465", --64167 64163",
	"SPELL_SUMMON 62979",
	"SPELL_AURA_APPLIED 63802 63830 63881 64126 64125 63138 63894 64775 64163 64465",
	"SPELL_AURA_REMOVED 63802 63894 64163 63830 63138 63881 64465",
	"SPELL_AURA_REMOVED_DOSE 63050",
	"CHAT_MSG_MONSTER_YELL",
	"UNIT_HEALTH"
--	"UNIT_SPELLCAST_START boss1"
)

--General
local enrageTimer					= mod:NewBerserkTimer(900, nil, nil, nil, false) -- berserk default OFF
local timerAchieve					= mod:NewAchievementTimer(420, 3012)

-- I have hidden most NPC TimerLines and only kept stage and brain TimerLines to prevent GUI clutter.
-- Stage One: The Lucid Dream
mod:AddTimerLine(L.S1TheLucidDream)
-- Sara
-- mod:AddTimerLine(L.Sara)
local warnFervor					= mod:NewTargetAnnounce(63138, 4)

local specWarnFervor				= mod:NewSpecialWarningYou(63138, nil, nil, nil, 1, 2)

local timerFervor					= mod:NewTargetTimer(15, 63138, nil, false, 2)

mod:AddSetIconOption("SetIconOnFervorTarget", 63138, false, false, {7})
mod:AddBoolOption("ShowSaraHealth", false)

-- Guardian of Yogg-Saron
-- mod:AddTimerLine(L.GuardianofYoggSaron)
local warnGuardianSpawned			= mod:NewAnnounce("WarningGuardianSpawned", 3, 62979, nil, nil, nil, 62979)

local timerNextGuardian				= mod:NewTimer(10, "NextGuardian", 62979, nil, nil, 1, nil, nil, nil, nil, nil, nil, nil, 62979)
local timerGuardianAfter			= mod:NewTimer(20, "GuardianAfter", 62979, nil, nil, 1, nil, nil, nil, nil, nil, nil, nil, 62979)

local specWarnGuardianLow			= mod:NewSpecialWarning("SpecWarnGuardianLow", false, nil, nil, nil, nil, nil, 62979, 62979)

-- Stage Two: Descent Into Madness
mod:AddTimerLine(L.S2DescentIntoMadness)
local warnP2						= mod:NewPhaseAnnounce(2, 2, nil, nil, nil, nil, nil, 2)
local warnSanity					= mod:NewAnnounce("WarningSanity", 3, 63050, nil, nil, nil, 63050)

local specWarnSanity				= mod:NewSpecialWarning("SpecWarnSanity", nil, nil, nil, nil, nil, nil, 63050, 63050)--Warning, no voice pack support

mod:AddInfoFrameOption(63050)

-- Sara
-- mod:AddTimerLine(L.Sara)
local warnBrainLink					= mod:NewTargetAnnounce(63802, 3)

local specWarnBrainLink				= mod:NewSpecialWarningYou(63802, nil, nil, nil, 1, 2)
local specWarnMalady				= mod:NewSpecialWarningYou(63830, nil, nil, nil, 1, 2)
local specWarnMaladyNear			= mod:NewSpecialWarningClose(63830, nil, nil, nil, 1, 2)
local yellMalady					= mod:NewYell(63830)

local timerBrainLinkCD				= mod:NewCDTimer(30, 63802, nil, nil, nil, 3) --30s on AC
local timerMaladyCD					= mod:NewCDTimer(20, 63830, nil, nil, nil, 3) --20s on AC

mod:AddSetIconOption("SetIconOnBrainLinkTarget", 63802, true, false, {1, 2})
mod:AddSetIconOption("SetIconOnFearTarget", 63830, true, false, {6})
mod:AddArrowOption("MaladyArrow", 63830, true)

-- Crusher Tentacle
-- mod:AddTimerLine(L.CrusherTentacle)
local warnCrusherTentacleSpawned	= mod:NewAnnounce("WarningCrusherTentacleSpawned", 2, "Interface\\Icons\\achievement_boss_yoggsaron_01", nil, nil, nil, 64139)

-- Corruptor Tentacle
-- mod:AddTimerLine(L.CorruptorTentacle)

-- Constrictor Tentacle
-- mod:AddTimerLine(L.ConstrictorTentacle)
local warnSqueeze					= mod:NewTargetNoFilterAnnounce(64125, 3)

local yellSqueeze					= mod:NewYell(64125)  -- Constrictor Tentacle

-- Descent into Madness
mod:AddTimerLine(L.DescentIntoMadness)
local warnBrainPortalSoon			= mod:NewAnnounce("WarnBrainPortalSoon", 2, 57687, nil, nil, nil, 64027) -- 10 second pre-warn

local specWarnBrainPortalSoon		= mod:NewSpecialWarning("SpecWarnBrainPortalSoon", false, nil, nil, nil, nil, nil, 57687, 64027) -- 3 second special pre-warn

local timerBrainPortal				= mod:NewTimer(20, "NextPortal", 57687, nil, nil, 5, nil, nil, nil, nil, nil, nil, nil, 64027)

-- Influence Tentacle
-- mod:AddTimerLine(L.InfluenceTentacle)

-- Laughing Skull
-- mod:AddTimerLine(L.LaughingSkull)

-- Brain of Yogg-Saron
-- mod:AddTimerLine(L.BrainofYoggSaron)
local warnMadness					= mod:NewCastAnnounce(64059, 2)

local specWarnMadnessOutNow			= mod:NewSpecialWarning("SpecWarnMadnessOutNow", nil, nil, nil, nil, nil, nil, 64059, 64059)  -- Brain of Yogg-Saron. Warning, no voice pack support

local timerMadness					= mod:NewCastTimer(60, 64059, nil, nil, nil, 5, nil, DBM_COMMON_L.DEADLY_ICON, nil, 3)  -- Brain of Yogg-Saron

-- Stage Three: True Face of Death
mod:AddTimerLine(L.S3TrueFaceofDeath)
local warnP3						= mod:NewPhaseAnnounce(3, 2, nil, nil, nil, nil, nil, 2)

-- Yogg-Saron
-- mod:AddTimerLine(L.YoggSaron)
local specWarnLunaticGaze			= mod:NewSpecialWarningLookAway(64163, nil, nil, nil, 1, 2)

local timerLunaticGaze				= mod:NewCastTimer(4, 64163, nil, nil, nil, 2, nil, DBM_COMMON_L.IMPORTANT_ICON) -- Yogg-Saron's Gaze
local timerNextLunaticGaze			= mod:NewCDTimer("v8-18", 64163, nil, nil, nil, 2, nil, DBM_COMMON_L.IMPORTANT_ICON) -- 13-22 on AC = from aura-removed 9–18s

mod:AddSetIconOption("SetIconOnBeacon", 64465, true, true, {1, 2, 3, 4, 5, 6, 7, 8})

-- Immortal Guardian
-- mod:AddTimerLine(L.ImmortalGuardian)
local warnEmpowerSoon				= mod:NewSoonAnnounce(64486, 4)

--64158 "Immortal Guardian" is the client's summon spell for NPC 33988, so it gives this its own
--options section the way 62979 does for the phase 1 waves. The server spawns the add with
--SummonCreature rather than casting it, so it never appears in the combat log.
local timerNextImmortalGuardian		= mod:NewTimer(10, "NextImmortalGuardian", 64158, "Tank", nil, 1, nil, nil, nil, nil, nil, nil, nil, 64158)

local timerEmpower					= mod:NewCDTimer(45.0, 64486, nil, nil, nil, 3) -- 45s on AC
local timerEmpowerDuration			= mod:NewBuffActiveTimer(10, 64486, nil, nil, nil, 3)

mod:GroupSpells(64486, 64465) -- Empowering Shadows, Shadow Beacon

-- Hard Mode
mod:AddTimerLine(DBM_COMMON_L.HEROIC_ICON..DBM_CORE_L.HARD_MODE)
-- Stage Three: True Face of Death
mod:AddTimerLine(L.S3TrueFaceofDeath)
local warnDeafeningRoarSoon			= mod:NewPreWarnAnnounce(64189, 5, 3)

local specWarnDeafeningRoar			= mod:NewSpecialWarningSpell(64189, nil, nil, nil, 1, 2)

local timerCastDeafeningRoar		= mod:NewCastTimer(2.3, 64189, nil, nil, nil, 2)
local timerNextDeafeningRoar		= mod:NewNextTimer(60, 64189, nil, nil, nil, 2) -- 60s on AC

local targetWarningsShown = {}
local brainLinkTargets = {}
local SanityBuff = DBM:GetSpellInfoNew(63050)
mod.vb.brainLinkIcon = 2
mod.vb.beaconIcon = 8
mod.vb.Guardians = 0
mod.vb.guardianWave = 0

--boss_yoggsaron.cpp: EVENT_SARA_P1_SUMMON comes due at the pull and repeats on a 20s interval that
--shrinks 2s per wave to a 10s floor (:919). Two things bend that schedule. Sara's UpdateAI returns
--early while she is casting (:906) and Repeat() runs off execution time, so a tick that comes due
--mid-cast is pushed to the end of that cast and every later wave inherits the shift permanently.
--Her P1 selector repeats every 4.9s (:939) and the spell it triggers casts for 4s, so most ticks do
--land mid-cast. Rather than assume that cycle we watch her casts live and push as each one starts.
--The informed cloud then trails its tick by a fixed delay: it takes 63031, whose Spell.dbc entry is
--a 10s periodic trigger (EffectAuraPeriod_1 = 10000) of 62979, the summon itself. So the guardian
--appears exactly GUARDIAN_CLOUD_DELAY after its tick executed, first wave included.
--That relation runs both ways, which is what keeps this honest: a stall is knife-edge (a 0.2s error
--in where a due time falls decides whether a 4s cast swallows it), and a free-running chain can
--never shed a boundary miss. So each spawn is read back as ground truth for when its tick really
--ran. Spawns nowhere near the prediction are players walking into a cloud (:1120), which summon
--without touching the server's schedule, and are ignored.
local GUARDIAN_CLOUD_DELAY = 10--63031 EffectAuraPeriod_1
--A tick can only ever run at one of two moments: when it came due, or at the end of the one cast
--that swallowed it. So a spawn is only believed when the tick it implies matches one of those two
--to within event jitter, rather than anywhere in a window. That rejects player-triggered clouds
--(:1120), which have no reason to land on either, and it still catches the case we got wrong: if
--we judged a cast boundary the other way to the server, the spawn matches the other candidate and
--pulls us straight. A cloud coinciding with a candidate can still fool it, but only by GUARDIAN_JITTER.
local GUARDIAN_JITTER = 0.4--event latency spread between the cast and summon we time this from
local SARA_P1_CAST = 4--63134/63138/63147 CastingTimeIndex 15 = 4000ms; the selector she casts is instant, this is the visible cast that holds her in UNIT_STATE_CASTING
local guardianGaps = {20, 18, 16, 14, 12}--gap after wave N, 10s from wave 6 on

local guardianWave--forward declaration, SaraCastStall reschedules it

--The pending wave is done; advance to the next. exec is when its tick actually ran, read back from
--the spawn; without one we fall back to where we predicted it would run.
function guardianWave(self, exec)
	local gap = guardianGaps[self.vb.guardianWave] or 10
	self.vb.guardianWave = self.vb.guardianWave + 1
	--guardianDue is where the tick runs if nothing stalls it; guardianStalled is the one cast end it
	--slips to if one does. Both stay live so a spawn can tell us which the server picked.
	local due = (exec or self.vb.guardianStalled or self.vb.guardianDue) + gap
	self.vb.guardianDue = due
	--A cast already running when the tick comes due swallows it just the same, and only this catches
	--that: once the gap is down to 10s it equals the cloud delay, so the next tick comes due the very
	--instant this guardian appears and no later SPELL_CAST_START can ever speak for it.
	local castEnd = self.vb.saraCastEnd
	self.vb.guardianStalled = (castEnd and castEnd > due and due >= castEnd - SARA_P1_CAST) and castEnd or nil
	local nextIn = (self.vb.guardianStalled or due) + GUARDIAN_CLOUD_DELAY - GetTime()
	timerNextGuardian:Start(nextIn)
	timerGuardianAfter:Start(nextIn + (guardianGaps[self.vb.guardianWave] or 10))
	self:Unschedule(guardianWave)
	--the spawn normally advances us; this only fires if it never arrives
	self:Schedule(nextIn + SARA_P1_CAST + GUARDIAN_JITTER, guardianWave, self)
end

--A guardian appeared. Believe it only if the tick it implies is one the server could have run.
local function guardianSpawned(self)
	local exec = GetTime() - GUARDIAN_CLOUD_DELAY
	local stalled, due = self.vb.guardianStalled, self.vb.guardianDue
	if stalled and math.abs(exec - stalled) <= GUARDIAN_JITTER then
		guardianWave(self, stalled)--snap to the candidate, not to our own latency
	elseif due and math.abs(exec - due) <= GUARDIAN_JITTER then
		guardianWave(self, due)--the server did not stall it after all
	end
end

--Sara started a P1 cast: if the pending tick is due inside it, it slips to the end of the cast.
--Recorded separately from guardianDue so the spawn can still vouch for either reading.
local function saraCastStall(self)
	local castEnd = GetTime() + SARA_P1_CAST
	self.vb.saraCastEnd = castEnd--remembered so a tick coming due mid-cast can see it too
	local due = self.vb.guardianDue
	if not due or self.vb.guardianStalled or due <= GetTime() or due >= castEnd then return end
	timerNextGuardian:AddTime(castEnd - due)
	timerGuardianAfter:AddTime(castEnd - due)--the whole chain is relative to due, so the wave after next shifts with it
	self.vb.guardianStalled = castEnd
	self:Unschedule(guardianWave)
	self:Schedule(castEnd + GUARDIAN_CLOUD_DELAY - GetTime() + GUARDIAN_JITTER, guardianWave, self)
end

--Sara drops to 1 health and says this in the same breath as events.SetPhase(EVENT_PHASE_TWO) (:787),
--which masks EVENT_SARA_P1_SUMMON off for good: no further tick can run, so nothing more is armed.
--The wave after the pending one is now impossible, so that bar goes at once. The pending one is left
--to run out, since a cloud already carrying the aura can still tick until ACTION_UNSUMMON_CLOUDS
--strips it 4s later (:879).
local function guardianStop(self)
	self:Unschedule(guardianWave)
	timerGuardianAfter:Stop()
	self.vb.guardianDue = nil--also stops a spawn or a cast from arming anything further
	self.vb.guardianStalled = nil
end

--The bar marks the summon itself. The add is rooted and passive for SPAWN_STASIS_TIME after it
--(:2001), but it is there and attackable throughout, and hitting one releases it early via
--JustEngagedWith, so there is nothing to wait for: raid logs have each add taking its first damage
--1.5-3.6s after its tick, which is just how long it takes someone to reach it.

--Lunatic Gaze is channeled (64163 carries SPELL_ATTR1_CHANNELED_2 with a 4000ms duration), so it
--holds Yogg in UNIT_STATE_CASTING and his UpdateAI returns early for all of it (:1338). A summon
--tick due inside the channel runs only when it ends, and Repeat(10s) measures from execution, so
--every later add inherits that shift. He rolls the gaze on Repeat(13s, 22s), which is not
--predictable, so the channel is watched live the way Sara's casts are in phase 1.
local LUNATIC_GAZE_CHANNEL = 4

local immortalGuardianWave--forward declaration, lunaticGazeStall reschedules it

--Fired as an add spawns; arm the bar for the one after it. immortalDue is the tick, absolute, so a
--stall can move it without the chain drifting.
function immortalGuardianWave(self)
	self.vb.immortalDue = self.vb.immortalDue + 10
	local nextIn = self.vb.immortalDue - GetTime()
	timerNextImmortalGuardian:Start(nextIn)
	self:Unschedule(immortalGuardianWave)--Phase3 is synced by every raider who sees the aura drop
	self:Schedule(nextIn, immortalGuardianWave, self)
end

--Yogg started channeling: a tick due inside it slips to the end of the channel.
local function lunaticGazeStall(self)
	local channelEnd = GetTime() + LUNATIC_GAZE_CHANNEL
	local due = self.vb.immortalDue
	if not due or due <= GetTime() or due >= channelEnd then return end
	timerNextImmortalGuardian:AddTime(channelEnd - due)
	self.vb.immortalDue = channelEnd
	self:Unschedule(immortalGuardianWave)
	self:Schedule(channelEnd - GetTime(), immortalGuardianWave, self)
end

function mod:CHAT_MSG_MONSTER_YELL(msg)
	if msg == L.YellLucidDream or msg:find(L.YellLucidDream) then
		guardianStop(self)
	end
end

function mod:OnCombatStart()
	self:SetStage(1)
	self.vb.brainLinkIcon = 2
	self.vb.beaconIcon = 8
	self.vb.Guardians = 0
	--Wave 1 comes due with the aggro yell itself, so the bar opens on the cloud delay alone.
	self.vb.guardianWave = 1
	self.vb.guardianDue = GetTime()
	self.vb.guardianStalled = nil
	self.vb.saraCastEnd = nil
	timerNextGuardian:Start(GUARDIAN_CLOUD_DELAY)
	timerGuardianAfter:Start(guardianGaps[1] + GUARDIAN_CLOUD_DELAY)
	self:Schedule(GUARDIAN_CLOUD_DELAY + SARA_P1_CAST + GUARDIAN_JITTER, guardianWave, self)
	enrageTimer:Start()
	timerAchieve:Start()
	table.wipe(targetWarningsShown)
	table.wipe(brainLinkTargets)
	if self.Options.InfoFrame then
		DBM.InfoFrame:SetHeader(SanityBuff)
		DBM.InfoFrame:Show(30, "playerdebuffstacks", SanityBuff, 2)--Sorted lowest first (highest first is default of arg not given)
	end
	if self.Options.ShowSaraHealth then
		if not self.Options.HealthFrame then
			DBM.BossHealth:Show(L.name)
		else
			DBM.BossHealth:AddBoss(33134, L.Sara)
		end
	end
end

function mod:OnCombatEnd()
	if self.Options.InfoFrame then
		DBM.InfoFrame:Hide()
	end
end

function mod:FervorTarget(targetname)
	if not targetname then return end
	if targetname == UnitName("player") and self:AntiSpam(4, 1) then
		specWarnFervor:Show()
		specWarnFervor:Play("targetyou")
	end
end

local function warnBrainLinkWarning(self)
	warnBrainLink:Show(table.concat(brainLinkTargets, "<, >"))
	table.wipe(brainLinkTargets)
	self.vb.brainLinkIcon = 2
end

function mod:SPELL_CAST_START(args)
	local spellId = args.spellId
	if spellId == 64059 then	-- Induce Madness
		timerMadness:Start()
		warnMadness:Show()
		timerBrainPortal:Schedule(60) -- Log reviewed [60 schedule + 20 timer] (25 man NM log 2022/07/10 || S3 HM log 2022/07/21) - 80.0 || 80.0, 80.1 ; 80.0, 80.0, 80.0
		warnBrainPortalSoon:Schedule(70)
		specWarnBrainPortalSoon:Schedule(77)
		specWarnMadnessOutNow:Schedule(55) -- TO DO: implement brain room check?
	elseif spellId == 64189 then		--Deafening Roar
		timerNextDeafeningRoar:Start()
		warnDeafeningRoarSoon:Schedule(55)
		timerCastDeafeningRoar:Start()
		specWarnDeafeningRoar:Show()
		specWarnDeafeningRoar:Play("silencesoon")
	elseif spellId == 63138 then		--Sara's Fervor
		self:BossTargetScanner(args.sourceGUID, "FervorTarget", 0.1, 12, true, nil, nil, nil, true)
	elseif spellId == 63830 then	-- Malady of the Mind
		timerMaladyCD:Start()
	elseif spellId == 63802 then	-- Brain Link
		timerBrainLinkCD:Start()
	end
	if self.vb.phase == 1 and (spellId == 63138 or spellId == 63134 or spellId == 63147) then	-- Sara's Fervor/Blessing/Anger
		saraCastStall(self)
	end
end

function mod:SPELL_CAST_SUCCESS(args)
	local spellId = args.spellId
	if spellId == 64144 and self:GetUnitCreatureId(args.sourceGUID) == 33966 then -- Never fires on Warmane
		DBM:AddMsg("Erupt unhidden from combat log. Notify Zidras on Discord or GitHub")
		warnCrusherTentacleSpawned:Show()
	elseif spellId == 64465 then -- Shadow Beacon
		timerEmpower:Start()
		timerEmpowerDuration:Start()
		warnEmpowerSoon:Schedule(40)
--	elseif args:IsSpellID(64167, 64163) and self:AntiSpam(3, 3) then	-- Lunatic Gaze, not needed since it's running below on SAA/SAR
--		timerLunaticGaze:Start()
--		timerBrainPortal:Start(60) -- Why?
--		warnBrainPortalSoon:Schedule(50) -- Why?
	end
end

function mod:SPELL_SUMMON(args)
	if args.spellId == 62979 then
		self.vb.Guardians = self.vb.Guardians + 1
		warnGuardianSpawned:Show(self.vb.Guardians)
		if self.vb.phase == 1 then
			guardianSpawned(self)
		end
	end
end

function mod:SPELL_AURA_APPLIED(args)
	local spellId = args.spellId
	if spellId == 63802 then		-- Brain Link
		self:Unschedule(warnBrainLinkWarning)
		brainLinkTargets[#brainLinkTargets + 1] = args.destName
		if self.Options.SetIconOnBrainLinkTarget then
			self:SetIcon(args.destName, self.vb.brainLinkIcon)
		end
		self.vb.brainLinkIcon = self.vb.brainLinkIcon - 1
		if args:IsPlayer() then
			specWarnBrainLink:Show()
			specWarnBrainLink:Play("linegather")
		end
		if #brainLinkTargets == 2 then
			warnBrainLinkWarning(self)
		else
			self:Schedule(0.5, warnBrainLinkWarning, self)
		end
--		if self:AntiSpam(5, 2) then
--			timerBrainLinkCD:Start()
--		end
	elseif args:IsSpellID(63830, 63881) then   -- Malady of the Mind (Death Coil)
		if self.Options.SetIconOnFearTarget then
			self:SetIcon(args.destName, 6, 30)
		end
		if args:IsPlayer() then
			specWarnMalady:Show()
			specWarnMalady:Play("targetyou")
			yellMalady:Yell()
		elseif self:CheckNearby(11, args.destName) then
			specWarnMaladyNear:Show(args.destName)
			specWarnMaladyNear:Play("runaway")
			if self.Options.MaladyArrow then
				local uId = DBM:GetRaidUnitId(args.destName)
				if uId then
					local x, y = GetPlayerMapPosition(uId)
					if x == 0 and y == 0 then
						SetMapToCurrentZone()
						x, y = GetPlayerMapPosition(uId)
					end
					DBM.Arrow:ShowRunAway(x, y, 12, 5)
				end
			end
		end
--		timerMaladyCD:Start() -- malady jumps would refire this and mess with the timer. Revert to cast_start
	elseif args:IsSpellID(64126, 64125) then	-- Squeeze
		warnSqueeze:Show(args.destName)
		if args:IsPlayer() then
			yellSqueeze:Yell()
		end
	elseif spellId == 63138 then	-- Sara's Fervor
		warnFervor:Show(args.destName)
		timerFervor:Start(args.destName)
		if self.Options.SetIconOnFervorTarget then
			self:SetIcon(args.destName, 7, 15)
		end
		if args:IsPlayer() and self:AntiSpam(4, 1) then
			specWarnFervor:Show()
			specWarnFervor:Play("targetyou")
		end
	elseif args:IsSpellID(63894, 64775) and self.vb.phase < 2 then	-- Shadowy Barrier of Yogg-Saron (this is happens when p2 starts, ~1s after IEEU, so correction factor is needed). Bugged on Warmane, 63894 is never applied (only removed), instead 64775 is applied to Sara
		self:SetStage(2)
		self:Unschedule(guardianWave)
		self.vb.guardianDue = nil
		self.vb.guardianStalled = nil
		self.vb.immortalDue = nil
		timerNextGuardian:Stop()
		timerGuardianAfter:Stop()
		timerMaladyCD:Start(12)	-- 12s AC
		timerBrainLinkCD:Start(18)	--  18s AC
		timerBrainPortal:Start(60)	-- 60s AC
		warnBrainPortalSoon:Schedule(50)
		specWarnBrainPortalSoon:Schedule(56)
		warnP2:Show()
		warnP2:Play("ptwo")
		if self.Options.ShowSaraHealth then
			DBM.BossHealth:RemoveBoss(33134)
			if not self.Options.HealthFrame then
				DBM.BossHealth:Hide()
			end
		end
	elseif spellId == 64163 then	-- Lunatic Gaze phase 3 (reduces sanity) ; 64167 Lunatic Gaze is related to Laughing Skulls, which is not important
		specWarnLunaticGaze:Show(args.sourceName)
		specWarnLunaticGaze:Play("turnaway")
		timerLunaticGaze:Start()
		lunaticGazeStall(self)
	elseif spellId == 64465 then -- Shadow Beacon
		if self.Options.SetIconOnBeacon then
			self:ScanForMobs(args.destGUID, 2, self.vb.beaconIcon, 1, nil, 6, "SetIconOnBeacon", true, nil, nil, true)
		end
		self.vb.beaconIcon = self.vb.beaconIcon - 1
		if self.vb.beaconIcon == 0 then
			self.vb.beaconIcon = 8
		end
	end
end

function mod:SPELL_AURA_REMOVED(args)
	local spellId = args.spellId
	if spellId == 63802 and self.Options.SetIconOnBrainLinkTarget then		-- Brain Link
		self:SetIcon(args.destName, 0)
	elseif spellId == 63138 and self.Options.SetIconOnFervorTarget then	-- Sara's Fervor
		self:SetIcon(args.destName, 0)
	elseif spellId == 63894 then		-- Shadowy Barrier removed from Yogg-Saron (start p3)
		-- "<298.03 19:54:54> [CLEU] SPELL_AURA_REMOVED:0xF150008208000F6B:Yogg-Saron:0xF150008208000F6B:Yogg-Saron:63894:Shadowy Barrier:BUFF:nil:", -- [15528]
		self:SendSync("Phase3")			-- Sync this because you don't get it in your combat log if you are in brain room.
	elseif spellId == 64163 then	-- Lunatic Gaze phase 3 ; 64167 Lunatic Gaze is related to Laughing Skulls, which is not important
		timerNextLunaticGaze:Start() -- 12s interval - 4s cast = 8s for next cast
	elseif args:IsSpellID(63830, 63881) and self.Options.SetIconOnFearTarget then   -- Malady of the Mind (Death Coil)
		self:SetIcon(args.destName, 0)
	elseif spellId == 64465 then -- Shadow Beacon
		if self.Options.SetIconOnBeacon then
			self:ScanForMobs(args.destGUID, 2, 0, 1, nil, 6, "SetIconOnBeacon", true, nil, nil, true)
		end
		self.vb.beaconIcon = 8
	end
end

function mod:SPELL_AURA_REMOVED_DOSE(args)
	if args.spellId == 63050 and args.destGUID == UnitGUID("player") then
		local amount = args.amount or 1
		if amount == 50 then
			warnSanity:Show(args.amount)
		elseif amount == 35 or amount == 25 or amount == 15 then
			specWarnSanity:Show(amount)
		end
	end
end

function mod:UNIT_HEALTH(uId)
	if self.vb.phase == 1 and uId == "target" and self:GetUnitCreatureId(uId) == 33136 and UnitHealth(uId) / UnitHealthMax(uId) <= 0.3 and not targetWarningsShown[UnitGUID(uId)] then
		targetWarningsShown[UnitGUID(uId)] = true
		specWarnGuardianLow:Show()
	end
end

--[[function mod:UNIT_SPELLCAST_START(_, spellName)
	if spellName == GetSpellInfo(64189) then
		timerNextDeafeningRoar:Start()
		warnDeafeningRoarSoon:Schedule(53)
		timerCastDeafeningRoar:Start()
		specWarnDeafeningRoar:Show()
		specWarnDeafeningRoar:Play("silencesoon")
	end
end]]

--Yogg arms EVENT_YS_SUMMON_GUARDIAN at 0ms as the Shadowy Barrier comes off and repeats it flat
--every 10s (:1290, :1361), so the first add lands on the phase change itself and the bar counts to
--the one after. SummonImmortalGuardian spawns the add directly rather than through a spell (:1199),
--so it is there on the tick with no delay -- and with no combat log event either, which is why this
--runs open loop with nothing to resync against. Safe here: of his phase 3 casts only Deafening Roar
--has a cast time to stall a tick on, and that one is hard mode only (:1297).
function mod:OnSync(msg)
	if msg == "Phase3" then
		self:SetStage(3)
		timerBrainPortal:Cancel()
		warnBrainPortalSoon:Cancel()
		timerMaladyCD:Cancel()
		timerBrainLinkCD:Cancel()
		timerEmpower:Start(45.0) -- (S3 HM log 2022/07/21) - 45.0
		--The first add is summoned by the phase change itself, so the bar opens on the one after it.
		self:Unschedule(immortalGuardianWave)
		self.vb.immortalDue = GetTime()
		immortalGuardianWave(self)
		warnP3:Show()
		warnP3:Play("pthree")
		warnEmpowerSoon:Schedule(40)
		timerNextDeafeningRoar:Start(30) -- 30s AC
		warnDeafeningRoarSoon:Schedule(25)
		timerNextLunaticGaze:Start(7) -- 7s AC
	end
end
