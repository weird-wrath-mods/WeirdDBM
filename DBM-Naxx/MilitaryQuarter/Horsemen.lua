local mod	= DBM:NewMod("Horsemen", "DBM-Naxx", 4)
local L		= mod:GetLocalizedStrings()

mod:SetRevision("20260222210600")
mod:SetCreatureID(16063, 16064, 16065, 30549)
mod:SetEncounterID(1121)

mod:RegisterCombat("combat", 16063, 16064, 16065, 30549)

mod:RegisterEventsInCombat(
	"SPELL_CAST_START 28884 57467",
	"SPELL_CAST_SUCCESS 28832 28833 28834 28835 28883 53638 57466 32455 57463",
	"SPELL_AURA_APPLIED 29061",
	"SPELL_AURA_REMOVED 29061",
	"SPELL_AURA_APPLIED_DOSE 28832 28833 28834 28835",
	"UNIT_DIED"
)

--TODO, first marks
local warnMarkSoon				= mod:NewAnnounce("WarningMarkSoon", 1, 28835, false, nil, nil, 28835)
local warnMeteor				= mod:NewSpellAnnounce(57467, 4, nil, false) -- default OFF
local warnVoidZone				= mod:NewTargetNoFilterAnnounce(28863, 3)--Only warns for nearby targets, to reduce spam (Blaumeux: kept ON)
local warnHolyWrath				= mod:NewTargetNoFilterAnnounce(28883, 3, nil, false)
local warnBoneBarrier			= mod:NewTargetNoFilterAnnounce(29061, 2, nil, false) -- default OFF

local specWarnMarkOnPlayer		= mod:NewSpecialWarning("SpecialWarningMarkOnPlayer", nil, nil, nil, 1, 6, nil, nil, 28835)
local specWarnVoidZone			= mod:NewSpecialWarningYou(28863, nil, nil, nil, 1, 2)
local yellVoidZone				= mod:NewYell(28863)

-- Marks combined into 2 bars: Korth'azz+Rivendare share the 12s cadence, Blaumeux+Zeliek the 15s
local timerMarkMelee			= mod:NewNextTimer(12, 28832, "Mark: Thane/Baron", nil, nil, 3)
local timerMarkCaster			= mod:NewNextTimer(16, 28833, "Mark: Blaumeux/Zeliek", nil, nil, 3)
local timerMeteorCD				= mod:NewCDTimer(15, 57467, nil, false, nil, 3, nil, nil, true) -- default OFF
--local timerVoidZoneCD			= mod:NewCDTimer(12.9, 28863, nil, nil, nil, 3)-- 12.9-16
local timerHolyWrathCD			= mod:NewCDTimer(15, 28883, nil, false, nil, 3) -- default OFF
local timerBoneBarrier			= mod:NewTargetTimer(20, 29061, nil, false, nil, 5) -- default OFF

mod:AddRangeFrameOption("12", nil, false) -- range frame default OFF

mod:SetBossHealthInfo(
	16064, L.Korthazz,	-- Thane
	30549, L.Rivendare,	-- Baron
	16065, L.Blaumeux,	-- Lady
	16063, L.Zeliek		-- Zeliek
)

function mod:OnCombatStart()
	self.vb.meleeAlive = 2
	self.vb.casterAlive = 2
	-- Server starts the 24s mark timer only once each horseman reaches its corner; add run-to-position offset
	timerMarkCaster:Start(31)	-- Blaumeux/Zeliek: 24 + ~7s positioning
	timerMarkMelee:Start(33)	-- Korth'azz/Rivendare: 24 + ~9s positioning
	warnMarkSoon:Schedule(19)
	timerMeteorCD:Start("v10-15")
	timerHolyWrathCD:Start(15)
	if self.Options.RangeFrame then
		DBM.RangeCheck:Show(12)
	end
end

function mod:OnCombatEnd()
	if self.Options.RangeFrame then
		DBM.RangeCheck:Hide()
	end
end

function mod:SPELL_CAST_START(args)
	if args:IsSpellID(28884, 57467) then
		warnMeteor:Show()
		timerMeteorCD:Start()
	end
end

function mod:SPELL_CAST_SUCCESS(args)
	if args:IsSpellID(28832, 28834) and self:AntiSpam(5, "markmelee") then -- Korth'azz/Rivendare share the 12s mark
		timerMarkMelee:Start(12)
		warnMarkSoon:Schedule(12)
	elseif args:IsSpellID(28833, 28835) and self:AntiSpam(5, "markcaster") then -- Blaumeux/Zeliek share the ~16s mark
		timerMarkCaster:Start(16)
		warnMarkSoon:Schedule(16)
	elseif args.spellId == 57463 then
--		timerVoidZoneCD:Start()
		if args:IsPlayer() then
			specWarnVoidZone:Show()
			specWarnVoidZone:Play("targetyou")
			yellVoidZone:Yell()
		elseif self:CheckNearby(12, args.destName) then
			warnVoidZone:Show(args.destName)
		end
	elseif args:IsSpellID(28883, 53638, 57466, 32455) then
		warnHolyWrath:Show(args.destName)
		timerHolyWrathCD:Start()
	end
end

function mod:SPELL_AURA_APPLIED(args)
	if args.spellId == 29061 then
		warnBoneBarrier:Show(args.destName)
		timerBoneBarrier:Start(20, args.destName)
	end
end

function mod:SPELL_AURA_REMOVED(args)
	if args.spellId == 29061 then
		timerBoneBarrier:Stop(args.destName)
	end
end

function mod:SPELL_AURA_APPLIED_DOSE(args)
	if args:IsSpellID(28832, 28833, 28834, 28835) and args:IsPlayer() then
		local amount = args.amount or 1
		if amount >= 4 then
			specWarnMarkOnPlayer:Show(args.spellName, amount)
			specWarnMarkOnPlayer:Play("stackhigh")
		end
	end
end

function mod:UNIT_DIED(args)
	local cid = self:GetCIDFromGUID(args.destGUID)
	if cid == 16064 then -- Thane Korth'azz
		timerMeteorCD:Cancel()
		self.vb.meleeAlive = self.vb.meleeAlive - 1
		if self.vb.meleeAlive <= 0 then timerMarkMelee:Cancel() end
	elseif cid == 30549 then -- Baron Rivendare
		self.vb.meleeAlive = self.vb.meleeAlive - 1
		if self.vb.meleeAlive <= 0 then timerMarkMelee:Cancel() end
	elseif cid == 16065 then -- Lady Blaumeux
		self.vb.casterAlive = self.vb.casterAlive - 1
		if self.vb.casterAlive <= 0 then timerMarkCaster:Cancel() end
	elseif cid == 16063 then -- Sir Zeliek
		self.vb.casterAlive = self.vb.casterAlive - 1
		if self.vb.casterAlive <= 0 then timerMarkCaster:Cancel() end
	end
end
