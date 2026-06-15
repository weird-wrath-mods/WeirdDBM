local mod	= DBM:NewMod("Loatheb", "DBM-Naxx", 3)
local L		= mod:GetLocalizedStrings()

mod:SetRevision("20251209220131")
mod:SetCreatureID(16011)
mod:SetEncounterID(1115)

mod:RegisterCombat("combat")--Maybe change to a yell later so pull detection works if you chain pull him from tash gauntlet

mod:RegisterEventsInCombat(
	"SPELL_CAST_SUCCESS 29234 26662",
	"SPELL_DAMAGE",
	"SWING_DAMAGE",
	"UNIT_DIED",
	"SPELL_SUMMON 29234"
)

local warnSporeNow	= mod:NewCountAnnounce(29234, 2)
local warnSporeSoon	= mod:NewSoonAnnounce(29234, 1)
local warnBerserk	= mod:NewSpellAnnounce(26662, 4)

local timerSpore	= mod:NewNextTimer(35, 29234, nil, nil, nil, 5, 42524, DBM_COMMON_L.DAMAGE_ICON)
local timerBerserk	= mod:NewBerserkTimer(720, nil, nil, nil, false) -- berserk default OFF

mod:AddBoolOption("SporeDamageAlert", false)

mod.vb.sporeCounter = 0

function mod:OnCombatStart(delay)
	self.vb.sporeCounter = 0
	timerSpore:Start(15 - delay, 1)
	warnSporeSoon:Schedule(10 - delay)
	timerBerserk:Start(-delay)
end

function mod:SPELL_SUMMON(args)
local spellId = args.spellId
	if spellId == 29234 then  -- Summon Spore
		self.vb.sporeCounter = self.vb.sporeCounter + 1
		timerSpore:Start(35, self.vb.sporeCounter + 1)
		warnSporeNow:Show(self.vb.sporeCounter)
		warnSporeSoon:Schedule(30)
	end
end

function mod:SPELL_CAST_SUCCESS(args)
	local spellId = args.spellId
	if spellId == 26662 then  -- Berserk
		warnBerserk:Show()
	end
end

--Spore loser function. Credits to Forte guild and their old discontinued dbm plugins. Sad to see that guild disband, best of luck to them!
function mod:SPELL_DAMAGE(_, sourceName, _, _, destName, _, spellId, _, _, amount)
	if self.Options.SporeDamageAlert and destName == "Spore" and spellId ~= 62124 and self:IsInCombat() then
		SendChatMessage(sourceName..", You are damaging a Spore!!! ("..amount.." damage)", "RAID_WARNING")
		SendChatMessage(sourceName..", You are damaging a Spore!!! ("..amount.." damage)", "WHISPER", nil, sourceName)
	end
end

function mod:SWING_DAMAGE(_, sourceName, _, _, destName, _, _, _, _, amount)
	if self.Options.SporeDamageAlert and destName == "Spore" and self:IsInCombat() then
		SendChatMessage(sourceName..", You are damaging a Spore!!! ("..amount.." damage)", "RAID_WARNING")
		SendChatMessage(sourceName..", You are damaging a Spore!!! ("..amount.." damage)", "WHISPER", nil, sourceName)
	end
end

--because in all likelyhood, pull detection failed (cause 90s like to charge in there trash and all and pull it
--We unschedule the pre warnings on death as a failsafe
function mod:UNIT_DIED(args)
	local cid = self:GetCIDFromGUID(args.destGUID)
	if cid == 16011 then  -- Loatheb died
		warnSporeSoon:Cancel()
	end
end