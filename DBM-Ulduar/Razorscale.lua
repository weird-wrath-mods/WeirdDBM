local mod	= DBM:NewMod("Razorscale", "DBM-Ulduar")
local L		= mod:GetLocalizedStrings()

mod:SetRevision("20260508220131")
mod:SetCreatureID(33186)
mod:SetEncounterID(746)

mod:RegisterCombat("combat_yell", L.YellAir)

mod:RegisterEventsInCombat(
	"SPELL_CAST_START 63317 64021 63236",
	"SPELL_CAST_SUCCESS 64771 62666",
	"SPELL_AURA_APPLIED 64771",
	"SPELL_AURA_APPLIED_DOSE 64771",
	"SPELL_DAMAGE 64733 64704",
	"SPELL_MISSED 64733 64704",
	"CHAT_MSG_MONSTER_YELL",
	"CHAT_MSG_RAID_BOSS_EMOTE"
)

-- General
local enrageTimer					= mod:NewBerserkTimer(600, nil, nil, nil, false) -- berserk default OFF

-- Stage One
mod:AddTimerLine(DBM_CORE_L.SCENARIO_STAGE:format(1))
local warnTurretsReady				= mod:NewAnnounce("warnTurretsReady", 3, 48642)
local warnDevouringFlame			= mod:NewTargetAnnounce(63236, 2, nil, false) -- Very spammy, requires turning on AND disabling target filter. Power user setting.

local specWarnDevouringFlame		= mod:NewSpecialWarningMove(64733, nil, nil, nil, 1, 2)
local specWarnDevouringFlameYou		= mod:NewSpecialWarningYou(64733, false, nil, nil, 1, 2)
local specWarnDevouringFlameNear	= mod:NewSpecialWarningClose(64733, false, nil, nil, 1, 2)
local yellDevouringFlame			= mod:NewYell(64733)

-- Stage Two
mod:AddTimerLine(DBM_CORE_L.SCENARIO_STAGE:format(2))
local warnFuseArmor					= mod:NewStackAnnounce(64771, 2, nil, "Tank")

local specWarnFuseArmor				= mod:NewSpecialWarningStack(64771, nil, 2, nil, nil, 1, 6)
local specWarnFuseArmorOther		= mod:NewSpecialWarningTaunt(64771, nil, nil, nil, 1, 2)

local timerDeepBreathCooldown		= mod:NewCDTimer(21, 64021, nil, nil, nil, 5) -- 21s on AC, permanent ground phase only
local timerDeepBreathCast			= mod:NewCastTimer(2.5, 64021)
-- Grounded window, measured from the commander's yell. Her self-stun (62794) and the harpoon hits
-- (62505) both carry DO_NOT_LOG, so touchdown is invisible to the combat log and the yell is the only
-- start we get. Server: yell -> she flies to the landing spot and descends (~3s the first time from the
-- near hover point, ~5s later from the far one) -> 30s stunned -> Flame Breath -> Wing Buffet 2s later
-- -> airborne 4s after that. Wing Buffet does log and is exactly 4s from takeoff, so it snaps the
-- bar to its exact tail. Flame Breath is not usable for that: her AI skips events while casting, so
-- the buffet slips from 2s to however long the breath cast actually runs.
local timerGrounded					= mod:NewTimer("v39-42", "timerGrounded", nil, nil, nil, 6)
local timerFuseArmorCD				= mod:NewCDTimer(12, 64771, nil, "Tank", nil, 5, nil, DBM_COMMON_L.TANK_ICON)

mod:GroupSpells(63236, 64733) -- Devouring Flame (cast and damage)

function mod:FlameTarget(targetname)
	if not targetname then return end
	if targetname == UnitName("player") then
		specWarnDevouringFlameYou:Show()
		specWarnDevouringFlameYou:Play("targetyou")
		yellDevouringFlame:Yell()
	elseif self:CheckNearby(11, targetname) then
		specWarnDevouringFlameNear:Show(targetname)
		specWarnDevouringFlameNear:Play("runaway")
	else
		warnDevouringFlame:Show(targetname)
	end
end

function mod:OnCombatStart(delay)
	self:SetStage(1)
	enrageTimer:Start(-delay)
end

function mod:SPELL_CAST_START(args)
	if args:IsSpellID(63317, 64021) then	-- Flame Breath
		timerDeepBreathCast:Start()
		if self:GetStage() == 2 then
			timerDeepBreathCooldown:Start()	-- only the permanent ground phase repeats it
		end
	elseif args.spellId == 63236 then		-- Devouring Flame
		self:BossTargetScanner(args.sourceGUID, "FlameTarget", 0.1, 12)
	end
end

function mod:SPELL_CAST_SUCCESS(args)
	if args.spellId == 64771 then		-- Fuse Armor
		timerFuseArmorCD:Start()
	elseif args.spellId == 62666 and self:GetStage() ~= 2 then	-- Wing Buffet, she lifts off 4s later
		timerGrounded:Start(4)
	end
end

function mod:SPELL_AURA_APPLIED(args)
	if args.spellId == 64771 then		-- Fuse Armor
		local amount = args.amount or 1
		if amount >= 2 then
			if args:IsPlayer() then
				specWarnFuseArmor:Show(args.amount)
				specWarnFuseArmor:Play("stackhigh")
			else
				local _, _, _, _, _, _, expireTime = DBM:UnitDebuff("player", args.spellName)
				local remaining
				if expireTime then
					remaining = expireTime-GetTime()
				end
				if not UnitIsDeadOrGhost("player") and (not remaining or remaining and remaining < 12) then
					specWarnFuseArmorOther:Show(args.destName)
					specWarnFuseArmorOther:Play("tauntboss")
				else
					warnFuseArmor:Show(args.destName, amount)
				end
			end
		else
			warnFuseArmor:Show(args.destName, amount)
		end
	end
end
mod.SPELL_AURA_APPLIED_DOSE = mod.SPELL_AURA_APPLIED

function mod:SPELL_DAMAGE(_, _, _, destGUID, _, _, spellId)
	if (spellId == 64733 or spellId == 64704) and destGUID == UnitGUID("player") and self:AntiSpam() then
		specWarnDevouringFlame:Show()
		specWarnDevouringFlame:Play("runaway")
	end
end
mod.SPELL_MISSED = mod.SPELL_DAMAGE

function mod:CHAT_MSG_RAID_BOSS_EMOTE(emote)
	if emote == L.EmoteHarpoonReady or emote:find(L.EmoteHarpoonReady, nil, true) then
		-- Fired once per harpoon the engineers finish rebuilding
		warnTurretsReady:Show()
	elseif emote == L.EmotePhase2 or emote:find(L.EmotePhase2) then
		-- Phase 2: Razorscale grounded permanently.
		self:SetStage(2)
		timerGrounded:Stop()
		timerFuseArmorCD:Start(15)
		timerDeepBreathCooldown:Start()
	end
end

function mod:CHAT_MSG_MONSTER_YELL(msg)
	if msg == L.YellGround then
		timerGrounded:Start()
	end
end