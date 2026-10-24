local mod	= DBM:NewMod("GeneralVezax", "DBM-Ulduar")
local L		= mod:GetLocalizedStrings()

mod:SetRevision("20260507220131")
mod:SetCreatureID(33271)
mod:SetEncounterID(755)
mod:SetUsedIcons(7, 8)

mod:RegisterCombat("combat")

mod:RegisterEventsInCombat(
	"SPELL_CAST_START 62661 62662",
	"SPELL_CAST_SUCCESS 62660 63276 63364",
	"SPELL_AURA_APPLIED 62662",
	"SPELL_AURA_REMOVED 62662",
	"SPELL_INTERRUPT 62661",
	"UNIT_DIED",
	"CHAT_MSG_RAID_BOSS_EMOTE"
--	"UNIT_SPELLCAST_START boss1",
--	"UNIT_SPELLCAST_SUCCEEDED boss1"
)

local warnShadowCrash				= mod:NewTargetAnnounce(62660, 4)
local warnLeechLife					= mod:NewTargetNoFilterAnnounce(63276, 3)
local warnSaroniteVapor				= mod:NewCountAnnounce(63322, 2)

local specWarnShadowCrash			= mod:NewSpecialWarningDodge(62660, nil, nil, nil, 1, 2)
local specWarnShadowCrashNear		= mod:NewSpecialWarningClose(62660, nil, nil, nil, 1, 2)
local yellShadowCrash				= mod:NewYell(62660)
local specWarnSurgeDarkness			= mod:NewSpecialWarningDefensive(62662, nil, nil, 2, 1, 2)
local specWarnMarkoftheFacelessYou	= mod:NewSpecialWarningMoveAway(63276, nil, nil, nil, 3, 2)
local yellMarkoftheFaceless			= mod:NewYell(63276)
local specWarnMarkoftheFacelessNear	= mod:NewSpecialWarningClose(63276, nil, nil, 2, 1, 2)
local specWarnSearingFlames			= mod:NewSpecialWarningInterruptCount(62661, "HasInterrupt", nil, nil, 1, 2)

local timerEnrage					= mod:NewBerserkTimer(600, nil, nil, nil, false) -- berserk default OFF
local timerSearingFlamesCast		= mod:NewCastTimer(2, 62661, nil, nil, nil, 5, nil, DBM_COMMON_L.INTERRUPT_ICON)
local timerSurgeofDarkness			= mod:NewBuffActiveTimer(10, 62662, nil, false, nil, 5, nil, DBM_COMMON_L.TANK_ICON)
local timerNextSurgeofDarkness		= mod:NewCDTimer(63, 62662, nil, false, nil, 5, nil, DBM_COMMON_L.TANK_ICON) -- 63s on AC
local timerShadowCrashCD			= mod:NewCDTimer(10, 62660, nil, "Ranged", nil, 3) -- 13s on AC
local timerMarkoftheFaceless		= mod:NewTargetTimer(10, 63276, nil, false, 2, 3, nil, DBM_COMMON_L.IMPORTANT_ICON)
local timerMarkoftheFacelessCD		= mod:NewCDTimer(40, 63276, nil, nil, nil, 3, nil, DBM_COMMON_L.IMPORTANT_ICON) -- 40s on AC

mod:AddSetIconOption("SetIconOnShadowCrash", 62660, true, false, {8})
mod:AddSetIconOption("SetIconOnLifeLeach", 63276, true, false, {7})
mod:AddArrowOption("CrashArrow", 62660, true)

-- Hard Mode
mod:AddTimerLine(DBM_COMMON_L.HEROIC_ICON..DBM_CORE_L.HARD_MODE)
local specWarnAnimus			= mod:NewSpecialWarningSwitch(63145, nil, nil, nil, 1, 2)

local timerHardmode				= mod:NewTimer(188, "hardmodeSpawn", nil, nil, nil, 1)
mod:AddBoolOption("VaporKilledSign", true)
local vaporIcon = select(3, GetSpellInfo(63322))

mod.vb.interruptCount = 0
mod.vb.hardmodeLost = false

-- AC: a vapor every 30s from engage; after the 6th a 6s swirl and 2s more to the Animus. No event runs
-- while Vezax casts, so a vapor due during a Searing Flames (2s) or Surge of Darkness (3s) cast spawns
-- when the cast ends (or is interrupted), and the next is 30s after that. The mod follows the same
-- schedule from his casts; the vapor emote, when anyone gets it, pins it to the real spawn.
local VAPOR_EVERY, ANIMUS_AFTER_6TH = 30, 8
local CAST_TIME = {[62661] = 2, [62662] = 3}
local pullTime, castEnd, shownAnimus = 0, 0, nil

-- one bar for the whole wait: a later vapor or a cast delay moves its end, it doesn't restart it
local function animusBar(self)
	if self.vb.hardmodeLost then return end
	local at = self.vb.nextVapor + (5 - self.vb.vapors) * VAPOR_EVERY + ANIMUS_AFTER_6TH
	if not shownAnimus or timerHardmode:GetTime() == 0 then
		timerHardmode:Start(at - GetTime())
	elseif at > shownAnimus + 0.01 then
		timerHardmode:AddTime(at - shownAnimus)
	elseif at < shownAnimus - 0.01 then
		timerHardmode:RemoveTime(shownAnimus - at)
	end
	shownAnimus = at
end

local vaporDue
vaporDue = function(self)
	local now = GetTime()
	if castEnd > now then -- waits out the cast
		self.vb.nextVapor = castEnd
		self:Schedule(castEnd - now, vaporDue, self)
		animusBar(self)
		return
	end
	self.vb.vapors = self.vb.vapors + 1
	self.vb.nextVapor = now + VAPOR_EVERY
	if self.vb.vapors < 6 then self:Schedule(VAPOR_EVERY, vaporDue, self) end
	animusBar(self)
end

--[[function mod:ShadowCrashTarget(targetname, uId)
	if not targetname then return end
	if self.Options.SetIconOnShadowCrash then
		self:SetIcon(targetname, 8, 5)
	end
	if targetname == UnitName("player") then
		specWarnShadowCrash:Show()
		specWarnShadowCrash:Play("runaway")
		yellShadowCrash:Yell()
	elseif self:CheckNearby(11, targetname) then
		specWarnShadowCrashNear:Show(targetname)
		specWarnShadowCrashNear:Play("runaway")
	else
		warnShadowCrash:Show(targetname)
	end
	if uId and self.Options.CrashArrow then
		local x, y = GetPlayerMapPosition(uId)
		if x == 0 and y == 0 then
			SetMapToCurrentZone()
			x, y = GetPlayerMapPosition(uId)
		end
		DBM.Arrow:ShowRunAway(x, y, 13, 5) -- 15yd was too conservative. Try 13yd instead (from personal testing, the hitbox was around ~12.5yd)
	end
end]]

function mod:OnCombatStart(delay)
	self.vb.interruptCount = 0
	self.vb.hardmodeLost = false
	pullTime, castEnd, shownAnimus = GetTime() - delay, 0, nil
	self.vb.vapors, self.vb.nextVapor = 0, pullTime + VAPOR_EVERY
	self:Schedule(VAPOR_EVERY - delay, vaporDue, self)
	timerShadowCrashCD:Start(13-delay) --13s on AC
	timerMarkoftheFacelessCD:Start(20-delay) -- 20s on AC
	timerEnrage:Start(-delay)
	animusBar(self)
	timerNextSurgeofDarkness:Start(-delay) -- REVIEW! 10s variance [50-60]? (25 man NM log 2022/07/10 || S3 HM log 2022/07/21) - 60.0 || 60.0
end

-- Confirmed as of 2022/07/25: CLEU SPELL_CAST_x is randomly failing on Warmane and not firing - https://www.warmane.com/bugtracker/report/112497. Resort to AURA/UNIT_SPELLCAST_x events for now.
-- EDIT 20/09/2022: after several log reviews and troubleshooting, https://www.warmane.com/bugtracker/report/112497 has been fixed serverside. Reinstating CLEU events.
function mod:SPELL_CAST_START(args)
	local spellId = args.spellId
	if CAST_TIME[spellId] then castEnd = GetTime() + CAST_TIME[spellId] end
	if spellId == 62661 then	-- Searing Flames
		-- 10-man has the interrupters for two kick groups, 25-man rotates three
		local groups = self:IsDifficulty("normal10") and 2 or 3
		self.vb.interruptCount = self.vb.interruptCount % groups + 1
		local kickCount = self.vb.interruptCount
		specWarnSearingFlames:Show(args.sourceName, kickCount)
		specWarnSearingFlames:Play("kick"..kickCount.."r")
		timerSearingFlamesCast:Start()
	elseif spellId == 62662 then
		if self:IsTanking("player", "boss1", nil, true) then--Player is current target
			specWarnSurgeDarkness:Show()
			specWarnSurgeDarkness:Play("defensive")
		end
		timerNextSurgeofDarkness:Start()
	end
end

function mod:SPELL_CAST_SUCCESS(args)
	local spellId = args.spellId
	if spellId == 62660 then		-- Shadow Crash
--		self:BossTargetScanner(33271, "ShadowCrashTarget", 0.05, 20) -- this method is not needed, since CLEU has destName
		timerShadowCrashCD:Start()
		if self.Options.SetIconOnShadowCrash then
			self:SetIcon(args.destName, 8, 5)
		end
		if args:IsPlayer() then
			specWarnShadowCrash:Show()
			specWarnShadowCrash:Play("runaway")
			yellShadowCrash:Yell()
		elseif self:CheckNearby(11, args.destName) then
			specWarnShadowCrashNear:Show(args.destName)
			specWarnShadowCrashNear:Play("runaway")
		else
			warnShadowCrash:Show(args.destName)
		end
		if self.Options.CrashArrow then
			local uId = DBM:GetRaidUnitId(args.destName)
			local x, y = GetPlayerMapPosition(uId)
			if x == 0 and y == 0 then
				SetMapToCurrentZone()
				x, y = GetPlayerMapPosition(uId)
			end
			DBM.Arrow:ShowRunAway(x, y, 13, 5) -- 15yd was too conservative. Try 13yd instead (from personal testing, the hitbox was around ~12.5yd)
		end
	elseif spellId == 63276 then	-- Mark of the Faceless
		if self.Options.SetIconOnLifeLeach then
			self:SetIcon(args.destName, 7, 10)
		end
		timerMarkoftheFaceless:Start(args.destName)
		timerMarkoftheFacelessCD:Start()
		if args:IsPlayer() then
			specWarnMarkoftheFacelessYou:Show()
			specWarnMarkoftheFacelessYou:Play("runout")
			yellMarkoftheFaceless:Yell()
		elseif self:CheckNearby(11, args.destName) then
			specWarnMarkoftheFacelessNear:Show(args.destName)
			specWarnMarkoftheFacelessNear:Play("runaway")
		else
			warnLeechLife:Show(args.destName)
		end
	elseif spellId == 63364 then
		specWarnAnimus:Show()
		specWarnAnimus:Play("bigmob")
	end
end

function mod:SPELL_AURA_APPLIED(args)
	local spellId = args.spellId
	if spellId == 62662 then	-- Surge of Darkness
		timerSurgeofDarkness:Start()
--[[elseif spellId == 63276 then	-- Mark of the Faceless
		if self.Options.SetIconOnLifeLeach then
			self:SetIcon(args.destName, 7, 10)
		end
		timerMarkoftheFaceless:Start(args.destName)
		timerMarkoftheFacelessCD:Start()
		if args:IsPlayer() then
			specWarnMarkoftheFacelessYou:Show()
			specWarnMarkoftheFacelessYou:Play("runout")
			yellMarkoftheFaceless:Yell()
		elseif self:CheckNearby(11, args.destName) then
			specWarnMarkoftheFacelessNear:Show(args.destName)
			specWarnMarkoftheFacelessNear:Play("runaway")
		else
			warnLeechLife:Show(args.destName)
		end]]
	end
end

function mod:SPELL_AURA_REMOVED(args)
	if args.spellId == 62662 then
		timerSurgeofDarkness:Stop()
	end
end

function mod:SPELL_INTERRUPT(args)
	if args.spellId == 62661 then
		timerSearingFlamesCast:Stop()
		local waiting = castEnd > GetTime() and self.vb.nextVapor == castEnd
		castEnd = GetTime()
		if waiting then -- the vapor it was holding spawns now
			self:Unschedule(vaporDue)
			vaporDue(self)
		end
	end
end

function mod:UNIT_DIED(args)
	local cid = self:GetCIDFromGUID(args.destGUID)
	if cid == 33488 then--Saronite Vapor: a dead one ends hard mode (AC DoAction 1)
		if not self.vb.hardmodeLost and self.Options.VaporKilledSign then
			DBM.WarningSign:Show(vaporIcon, 5, L.HardModeLost, nil, true)
		end
		self.vb.hardmodeLost = true
		timerHardmode:Stop()
	end
end

-- Range restricted (players near Vezax get it), so it is synced raid-wide
function mod:CHAT_MSG_RAID_BOSS_EMOTE(emote)
	if emote == L.EmoteSaroniteVapors or emote:find(L.EmoteSaroniteVapors) then
		self:SendSync("SaroniteVaporsSpawned")
	end
end

--[[function mod:UNIT_SPELLCAST_START(_, spellName)
	if spellName == GetSpellInfo(62661) then	-- Searing Flames
		self.vb.interruptCount = self.vb.interruptCount + 1
		if self.vb.interruptCount == 4 then
			self.vb.interruptCount = 1
		end
		local kickCount = self.vb.interruptCount
		specWarnSearingFlames:Show(L.name, kickCount)
		specWarnSearingFlames:Play("kick"..kickCount.."r")
		timerSearingFlamesCast:Start()
	elseif spellName == GetSpellInfo(62662) then
		if self:IsTanking("player", "boss1", nil, true) then--Player is current target
			specWarnSurgeDarkness:Show()
			specWarnSurgeDarkness:Play("defensive")
		end
		timerNextSurgeofDarkness:Start()
	end
end

function mod:UNIT_SPELLCAST_SUCCEEDED(_, spellName)
	if spellName == GetSpellInfo(62660) then		-- Shadow Crash
		self:BossTargetScanner(33271, "ShadowCrashTarget", 0.05, 20)
		timerShadowCrashCD:Start()
	elseif spellName == GetSpellInfo(63364) then
		self:Unschedule(saroniteVaporsSpawned)
		timerSaroniteVapors:Stop()
		specWarnAnimus:Show()
		specWarnAnimus:Play("bigmob")
	end
end]]

function mod:OnSync(msg)
	if msg == "SaroniteVaporsSpawned" and self:AntiSpam(3, 1) then
		-- which vapor from the time since engage, so a missed emote can't throw the count off
		local n = math.floor((GetTime() - pullTime) / VAPOR_EVERY + 0.5)
		warnSaroniteVapor:Show(n)
		if n >= 1 and n <= 6 then
			self:Unschedule(vaporDue)
			self.vb.vapors, self.vb.nextVapor = n, GetTime() + VAPOR_EVERY
			if n < 6 then self:Schedule(VAPOR_EVERY, vaporDue, self) end
			animusBar(self)
		end
	end
end
