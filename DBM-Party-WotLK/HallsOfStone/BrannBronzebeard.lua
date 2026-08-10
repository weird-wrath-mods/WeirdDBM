local mod	= DBM:NewMod("BrannBronzebeard", "DBM-Party-WotLK", 7)
local L		= mod:GetLocalizedStrings()

mod:SetRevision("20251124220131")
mod:SetCreatureID(28070)
mod:SetEncounterID(567)
mod:SetMinSyncRevision(20251123220131)

mod:RegisterCombat("yell", L.Pull)
mod:RegisterKill("yell", L.Kill)
mod:SetMinCombatTime(300)
mod:SetWipeTime(20)

mod:RegisterEventsInCombat(
	"CHAT_MSG_MONSTER_YELL"
)

local warningPhase	= mod:NewAnnounce("WarningPhase", 2, "Interface\\Icons\\Spell_Nature_WispSplode")
local timerEvent	= mod:NewTimer(302, "timerEvent", "Interface\\Icons\\Spell_Holy_BorrowedTime", nil, nil, 6)
local timerWave		= mod:NewTimer(52, "TimerWave", 694, nil, nil, 1)

local function NextWave(self)
	local cd = self:IsHeroic() and 23.5 or 32.5
	if timerEvent:GetRemaining() < cd + 1 then return end
	timerWave:Start(cd)
	self:Schedule(cd, NextWave, self)
end

function mod:WatchdogWipe()
	DBM:EndCombat(self, true)
end

function mod:OnCombatStart(delay)
	timerEvent:Start(-delay)
	timerWave:Start(-delay)
	self:Schedule(timerWave.timer - delay, NextWave, self)
	self:Schedule(35, self.WatchdogWipe, self, "BrannWatchdog")
end

function mod:OnCombatEnd()
	self:Unschedule(NextWave)
	timerWave:Stop()
end

function mod:CHAT_MSG_MONSTER_YELL(msg)
	if msg:find(L.Phase1, 1, true) then
		warningPhase:Show(1)
		self:Unschedule(self.WatchdogWipe, self, "BrannWatchdog")
		self:Schedule(90, self.WatchdogWipe, self, "BrannWatchdog")

	elseif msg:find(L.Phase2, 1, true) then
		warningPhase:Show(2)
		self:Unschedule(self.WatchdogWipe, self, "BrannWatchdog")
		self:Schedule(115, self.WatchdogWipe, self, "BrannWatchdog")

	elseif msg:find(L.Phase3, 1, true) then
		warningPhase:Show(3)
		self:Unschedule(self.WatchdogWipe, self, "BrannWatchdog")
		self:Schedule(115, self.WatchdogWipe, self, "BrannWatchdog")
	end
end