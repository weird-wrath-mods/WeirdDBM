local mod	= DBM:NewMod("Gothik", "DBM-Naxx", 4)
local L		= mod:GetLocalizedStrings()

mod:SetRevision("20260408175536")
mod:SetCreatureID(16060)
mod:SetEncounterID(1109)
mod:RegisterCombat("yell", L.yell)

mod:RegisterEventsInCombat(
	"CHAT_MSG_MONSTER_YELL",
	"CHAT_MSG_RAID_BOSS_EMOTE",
	"UNIT_SPELLCAST_SUCCEEDED",
	"UNIT_HEALTH"
)

local warnGateOpen		= mod:NewSpellAnnounce(3366, 2)
local warnPhase2		= mod:NewPhaseAnnounce(2, 3)

local timerPhase2		= mod:NewTimer(274.33, "TimerPhase2", 27082, nil, nil, 6)
local timerGate			= mod:NewTimer(120, "Gate Opens", 9484)
local timerTeleport		= mod:NewCDTimer(20, 46573, "TimerTeleport", nil, nil, 3)
local specWarnLowHP		= mod:NewSpecialWarning("SpecWarnGothLow")


mod.vb.lowHealthWarned = false

local function StartPhase2(self)
	self:SetStage(2)
	warnPhase2:Show()
	timerTeleport:Start(20)
end

function mod:OnCombatStart()
	self:SetStage(1)
	self.vb.lowHealthWarned = false
	timerGate:Start()
	timerPhase2:Start()
end

function mod:CHAT_MSG_MONSTER_YELL(msg)
	if msg == L.GothikPhase2Yell or msg:find(L.GothikPhase2Yell) then
		StartPhase2(self)
	end
end

function mod:CHAT_MSG_RAID_BOSS_EMOTE(msg)
	if msg == L.GothikDoorEmote or msg:find(L.GothikDoorEmote) then
		DBM:AddSpecialEventToTranscriptorLog("Gothik Door Opened")
		warnGateOpen:Show()
	end
end

function mod:UNIT_SPELLCAST_SUCCEEDED(unit, spellName)
    if spellName == GetSpellInfo(28025) or spellName == GetSpellInfo(28026) then
        timerTeleport:Start(20)
    end
end

function mod:UNIT_HEALTH(uId)
    local cid = self:GetUnitCreatureId(uId)
    if cid == 16060 and not self.vb.lowHealthWarned and UnitHealth(uId) / UnitHealthMax(uId) < 0.3 then
        self.vb.lowHealthWarned = true
        specWarnLowHP:Show()
        timerTeleport:Stop()
    end
end