local mod	= DBM:NewMod("Razuvious", "DBM-Naxx", 4)
local L		= mod:GetLocalizedStrings()

mod:SetRevision("20260907000000")
mod:SetCreatureID(16061)
mod:SetEncounterID(1113)
mod:RegisterCombat("combat_yell", L.Yell1, L.Yell2, L.Yell3, L.Yell4)

mod:RegisterEventsInCombat(
	"SPELL_CAST_SUCCESS 29060 29061 55470",
	"SPELL_AURA_APPLIED 605",
	"UNIT_DIED"
)

local warnShieldWall	= mod:NewAnnounce("WarningShieldWallSoon", 3, 29061, nil, nil, nil, 29061)

local timerStrikeCD		= mod:NewNextTimer(20, 55470, nil, nil, nil, 5, nil, DBM_COMMON_L.TANK_ICON)
local timerTaunt		= mod:NewCDTimer(20, 29060, nil, nil, nil, 5, nil, DBM_COMMON_L.TANK_ICON)
local timerShieldWall	= mod:NewCDTimer(20, 29061, nil, nil, nil, 5, nil, DBM_COMMON_L.TANK_ICON)
local timerMindControl	= mod:NewBuffActiveTimer(60, 605, nil, nil, nil, 6)

function mod:OnCombatStart(delay)
	timerStrikeCD:Start(20 - delay)
end

function mod:SPELL_CAST_SUCCESS(args)
	local spellId = args.spellId
	if spellId == 55470 then -- Unbalancing Strike
		timerStrikeCD:Start()
	elseif spellId == 29060 then -- Taunt
		timerTaunt:Start(20, args.sourceGUID)
	elseif spellId == 29061 then -- ShieldWall
		timerShieldWall:Start(20, args.sourceGUID)
		warnShieldWall:Schedule(15)
	end
end

function mod:SPELL_AURA_APPLIED(args)
	if args.spellId == 605 and args:IsSrcTypePlayer() then -- Mind Control
		timerMindControl:Start(nil, args.sourceName)
	end
end

function mod:UNIT_DIED(args)
	local guid = args.destGUID
	local cid = self:GetCIDFromGUID(guid)
	if cid == 16803 then--Deathknight Understudy
		timerTaunt:Stop(args.destGUID)
		timerShieldWall:Stop(args.destGUID)
	end
end
