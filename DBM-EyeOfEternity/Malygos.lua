local mod	= DBM:NewMod("Malygos", "DBM-EyeOfEternity")
local L		= mod:GetLocalizedStrings()

mod:SetRevision("20260327025043")
mod:SetCreatureID(28859)

mod:RegisterCombat("yell", L.YellPull)
--mod:RegisterCombat("combat")
mod:SetWipeTime(45)

mod:RegisterEvents(
	"CHAT_MSG_MONSTER_YELL",
	"UNIT_SPELLCAST_START",
	"UNIT_SPELLCAST_STOP",
	"UNIT_SPELLCAST_INTERRUPTED"
)

mod:RegisterEventsInCombat(
	"SPELL_AURA_APPLIED 60936 57407 56263 57429 57428 55853",
	"SPELL_CAST_START 56505",
	"SPELL_CAST_SUCCESS 56105 57430",
	"CHAT_MSG_RAID_BOSS_EMOTE"
--	"UNIT_SPELLCAST_SUCCEEDED boss1"
)
-- General
local enrageTimer				= mod:NewBerserkTimer(615)
local timerAchieve				= mod:NewAchievementTimer(360, 1875)

-- Stage One
mod:AddTimerLine(DBM_CORE_L.SCENARIO_STAGE:format(1))
local warnSummonPowerSpark		= mod:NewSpellAnnounce(56140, 2, 59381)
local warnVortex				= mod:NewSpellAnnounce(56105, 3)
local warnVortexSoon			= mod:NewSoonAnnounce(56105, 2)

local timerSummonPowerSpark		= mod:NewCDTimer("v20-30", 56140, nil, nil, nil, 1, 59381, DBM_COMMON_L.DAMAGE_ICON)
local timerVortex				= mod:NewCastTimer(10, 56105, nil, nil, nil, 5, nil, DBM_COMMON_L.HEALER_ICON)
local timerVortexCD				= mod:NewCDTimer("v72-74", 56105, nil, nil, nil, 2) --or normal timer cd timer with 72?

-- Stage Two
mod:AddTimerLine(DBM_CORE_L.SCENARIO_STAGE:format(2))
local warnPhase2				= mod:NewPhaseAnnounce(2)
local warnBreathInc				= mod:NewSoonAnnounce(56505, 3)

local specWarnBreath			= mod:NewSpecialWarningSpell(56505, nil, nil, nil, 2, 2)

local timerBreath				= mod:NewBuffActiveTimer(8, 56505, nil, nil, nil, 5) --lasts 5 seconds plus 3 sec cast.
local timerBreathCD				= mod:NewCDTimer(65, 56505, nil, nil, nil, 2)
local timerIntermission			= mod:NewPhaseTimer(22)

-- Stage Three
mod:AddTimerLine(DBM_CORE_L.SCENARIO_STAGE:format(3))
local warnPhase3				= mod:NewPhaseAnnounce(3)
local warnSurge					= mod:NewTargetAnnounce(60936, 3)
--local warnStaticField			= mod:NewTargetNoFilterAnnounce(57430, 3)

local specWarnSurge				= mod:NewSpecialWarningDefensive(60936, nil, nil, nil, 1, 2)
local specWarnP3SurgeOfPowerSoon= mod:NewSpecialWarningYou(60936, nil, nil, nil, 1, 2)
local specWarnStaticField		= mod:NewSpecialWarningYou(57430, nil, nil, nil, 1, 2)
--local specWarnStaticFieldNear	= mod:NewSpecialWarningClose(57430, nil, nil, nil, 1, 2)
local yellStaticField			= mod:NewYellMe(57430, nil, false)

local timerStaticFieldCD		= mod:NewCDTimer(12, 57430, nil, nil, nil, 3)

local tableBuild = false
local guids = {}
local startedPhase1 = false

-- Focusing Iris pull timer (rank-agnostic, synced).
-- The key cast happens pre-combat, so each player detects their OWN cast and broadcasts it;
-- every client renders DBM's pull timer locally from that synced state (DBM:StartPullTimer with
-- noSync) -- the rank-gated network PT path is never touched, so it can't be abused elsewhere.
local irisNormalName	= GetSpellInfo(61003)	-- "Key to the Focusing Iris"
local irisHeroicName	= GetSpellInfo(61004)	-- "Heroic Key to the Focusing Iris"
local irisCasters		= {}					-- [casterName] = { endTime = GetTime-based, seq = n }
local irisPrimary, irisPrimaryEnd
local myIrisCasting		= false
local myIrisEnd			= 0
local myIrisSeq			= 0						-- bumps each cast so cancels never collide with the 8s sync throttle
local mhuge, mabs		= math.huge, math.abs

local function irisRecompute()
	local primary, endTime = nil, mhuge
	for caster, c in pairs(irisCasters) do
		if c.endTime < endTime then endTime, primary = c.endTime, caster end
	end
	-- "First caster wins": a later caster's endTime is larger, so it never overtakes the first
	-- while the first is live. Only (re)set the bar when the primary changes, or the same primary
	-- re-casts (endTime shifts) -- additional casters don't disturb the running timer.
	if primary ~= irisPrimary or (primary and irisPrimaryEnd and mabs(endTime - irisPrimaryEnd) > 0.3) then
		irisPrimary, irisPrimaryEnd = primary, endTime
		if primary then
			local remaining = endTime - GetTime()
			DBM:Debug(("Iris: pull primary = %s, %.2fs left"):format(primary, remaining), 2)
			if remaining > 0.5 then
				DBM:StartPullTimer(remaining, primary, true)	-- start/reset, local-only render
			end
		else
			DBM:Debug("Iris: no casters left, cancelling pull", 2)
			DBM:StartPullTimer(0)								-- last caster cancelled -> cancel the pull
		end
	end
end

local function buildGuidTable()
	table.wipe(guids)
	for uId in DBM:GetGroupMembers() do
		local name, server = UnitName(uId)
		local fullName = name .. (server and server ~= "" and ("-" .. server) or "")
		guids[UnitGUID(uId.."pet") or "none"] = fullName
	end
	tableBuild = true
end

--[[function mod:StaticFieldTarget()
	local targetname, uId = self:GetBossTarget(28859)
	if not targetname or not uId then return end
	local targetGuid = UnitGUID(uId)
	if not tableBuild then
		buildGuidTable()
	end
	local announcetarget = guids[targetGuid]
	if announcetarget == UnitName("player") then
		specWarnStaticField:Show()
		specWarnStaticField:Play("runaway")
		yellStaticField:Yell()
	elseif announcetarget and self:CheckNearby(13, announcetarget) then
		specWarnStaticFieldNear:Show(announcetarget)
		specWarnStaticFieldNear:Play("runaway")
	else
		warnStaticField:Show(announcetarget)
	end
end]]

function mod:OnCombatStart(delay)
	tableBuild = false
	enrageTimer:Start(-delay)
	timerAchieve:Start(-delay)
	startedPhase1 = false
	table.wipe(guids)
	-- Iris pull is resolved once we're in combat; clear tracking for any future re-pull
	table.wipe(irisCasters)
	irisPrimary, irisPrimaryEnd = nil, nil
	myIrisCasting = false
	self:RegisterShortTermEvents(
		"SWING_DAMAGE",
		"SWING_MISSED"
	)
end

function mod:StartPhase1()
	if startedPhase1 then return end
	startedPhase1 = true
	self:SetStage(1)
	self:UnregisterShortTermEvents()
	timerVortexCD:Start(29)
	timerSummonPowerSpark:Start("v10-15")
end

function mod:SWING_DAMAGE(sourceGUID, sourceName)
	if self:GetCIDFromGUID(sourceGUID) == 28859 then
		self:StartPhase1()
	end
end

mod.SWING_MISSED = mod.SWING_DAMAGE

function mod:SPELL_AURA_APPLIED(args)
	if args:IsSpellID(55853) then
		timerVortex:Start()
	elseif args:IsSpellID(60936, 57407) then
		DBM:Debug("SURGE " .. (guids[args.destGUID] or "Unknown"), 2)
		local target = guids[args.destGUID]
		if target then
			warnSurge:CombinedShow(0.5, target)
			if target == UnitName("player") then
				specWarnSurge:Show()
				specWarnSurge:Play("defensive")
			end
		end
	elseif args:IsSpellID(57429) then
			timerStaticFieldCD:Start()
		local target = guids[args.destGUID]
		if target == UnitName("player") then
			specWarnStaticField:Show()
			specWarnStaticField:Play("runaway")
			yellStaticField:Yell()
		end
	end
end

-- not really sure which one this spell is casted by. Use both i guess
function mod:SPELL_CAST_START(args)
	local spellId = args.spellId
	if self:GetCIDFromGUID(args.sourceGUID) == 28859 then
		DBM:Debug("SCStart " .. spellId .. GetSpellLink(spellId) , 2)
	end
	if spellId == 56505 then--His deep breath
		specWarnBreath:Show()
		specWarnBreath:Play("findshield")
		timerBreath:Start()
		timerBreathCD:Start()
	end
end

function mod:SPELL_CAST_SUCCESS(args)
	local spellId = args.spellId
	if self:GetCIDFromGUID(args.sourceGUID) == 28859 then
		DBM:Debug("SCSuccess " .. spellId .. GetSpellLink(spellId) , 2)
	end
--	if spellId == 56105 then
--		timerVortexCD:Start()
---		warnVortexSoon:Schedule(54)
--		warnVortex:Show()
--		timerVortex:Start()
		-- Commenting this block out, since Sparks are fixed on a 30s interval... no need to correct anything on the fly
--		if timerSummonPowerSpark:GetTime() < 11 and timerSummonPowerSpark:IsStarted() then
--			timerSummonPowerSpark:Update(18, 30)
--		end
	if spellId == 57430 then
		self:ScheduleMethod(0.1, "StaticFieldTarget")
		--warnStaticField:Show()
		timerStaticFieldCD:Start()
	end
end

function mod:CHAT_MSG_MONSTER_YELL(msg)
	--Secondary pull trigger
	if (msg == L.YellPull or msg:find(L.YellPull)) and not self:IsInCombat() then
		DBM:StartCombat(self, 0)
	elseif msg == L.YellVortex or msg:find(L.YellVortex) then
		timerVortexCD:Start()
		warnVortexSoon:Schedule(67)
		warnVortex:Show()
		local elapsed, total = timerSummonPowerSpark:GetTime()
		if elapsed and total and total > 0 then
			local remaining = total - elapsed
			local newMax = remaining + 25
			local newMin = newMax - 10
			timerSummonPowerSpark:Stop()
			timerSummonPowerSpark:Start(("v%.1f-%.1f"):format(newMin, newMax))
		end
	elseif msg:sub(0, L.YellPhase2:len()) == L.YellPhase2 then
		self:SendSync("Phase2")
	elseif msg == L.YellBreath or msg:find(L.YellBreath) then
		self:SendSync("BreathSoon")
	elseif msg:sub(0, L.YellPhase3:len()) == L.YellPhase3 then
		self:SendSync("Phase3")
	elseif msg == L.EnoughScream then
		timerBreathCD:Stop()
--		timerAttackable:Start()
--		timerStaticFieldCD:Start(6)
	end
end

function mod:CHAT_MSG_RAID_BOSS_EMOTE(msg)
	if msg == L.EmoteSpark or msg:find(L.EmoteSpark) then
		warnSummonPowerSpark:Show()
		timerSummonPowerSpark:Start()
	end
	if msg == L.EmoteSurge or msg:find(L.EmoteSurge) then
		self:SendSync("MalygosSurge", UnitName("player"))
	end
end

--[[localization free triggers that's better but can only be used where boss1 UnitId available
function mod:UNIT_SPELLCAST_SUCCEEDED(_, spellName)
--	"<39.8> [UNIT_SPELLCAST_SUCCEEDED] Malygos:Possible Target<Omegal>:target:Summon Power Spark::0:56140", -- [998]
	if spellName == GetSpellInfo(56140) then
		warnSummonPowerSpark:Show()
		timerSummonPowerSpark:Start()
	end
end]]

-- Detect the local player's own Focusing Iris cast and broadcast it (any rank).
function mod:UNIT_SPELLCAST_START(uId)
	if uId ~= "player" then return end
	local name, _, _, _, _, endMs = UnitCastingInfo("player")
	if name and (name == irisNormalName or name == irisHeroicName) then
		myIrisSeq = myIrisSeq + 1
		myIrisCasting = true
		myIrisEnd = endMs / 1000
		DBM:Debug(("Iris: own cast detected, %.2fs remaining (seq %d)"):format(myIrisEnd - GetTime(), myIrisSeq), 2)
		self:SendSync("IrisStart", ("%.2f"):format(myIrisEnd - GetTime()), UnitName("player"), myIrisSeq)
	end
end

function mod:UNIT_SPELLCAST_STOP(uId)
	if uId ~= "player" or not myIrisCasting then return end
	myIrisCasting = false
	if GetTime() >= myIrisEnd - 0.25 then	-- reached the end -> it went off, fight is starting
		self:SendSync("IrisDone", UnitName("player"))
	else									-- stopped early -> cancelled/interrupted
		self:SendSync("IrisStop", UnitName("player"), myIrisSeq)
	end
end
mod.UNIT_SPELLCAST_INTERRUPTED = mod.UNIT_SPELLCAST_STOP

function mod:OnSync(event, arg, arg2, arg3)
	-- Focusing Iris syncs arrive pre-combat, so handle them before the in-combat guard below.
	if event == "IrisStart" then
		local remaining, caster, seq = tonumber(arg), arg2, tonumber(arg3)
		if caster and remaining and remaining > 0 then
			irisCasters[caster] = { endTime = GetTime() + remaining, seq = seq or 0 }
			irisRecompute()
		end
		return
	elseif event == "IrisStop" then
		local caster, seq = arg, tonumber(arg2)
		local c = caster and irisCasters[caster]
		if c and (not seq or c.seq == seq) then	-- ignore a stale stop for a newer cast
			irisCasters[caster] = nil
			irisRecompute()
		end
		return
	elseif event == "IrisDone" then				-- a cast completed; clear tracking, let the bar ring out
		table.wipe(irisCasters)
		irisPrimary, irisPrimaryEnd = nil, nil
		return
	end
	if not self:IsInCombat() then return end
	if event == "Phase2" then
		self:SetStage(2)
		timerSummonPowerSpark:Cancel()
		timerVortexCD:Cancel()
		warnVortexSoon:Cancel()
		warnPhase2:Show()
		timerIntermission:Start()
		timerBreathCD:Start(79)
	elseif event == "BreathSoon" then
		warnBreathInc:Show()
	elseif event == "Phase3" then
		self:SetStage(3)
		warnPhase3:Show()
		self:Schedule(6, buildGuidTable)
		timerBreathCD:Cancel()
--		timerStaticFieldCD:Start(20.2) -- REVIEW! ~4s variance? (10man Lordaeron 2022/09/27 || 25man Lordaeron 2022/09/27) - Stage 3/24.5 || Stage 3/20.2
	elseif event == "MalygosSurge" then
		warnSurge:CombinedShow(0.2, arg)
		if arg == UnitName("player") then
			specWarnP3SurgeOfPowerSoon:Show()
			specWarnP3SurgeOfPowerSoon:Play("findshield")
		end
	end
end