local mod	= DBM:NewMod("Sartharion", "DBM-ChamberOfAspects", 1)
local L		= mod:GetLocalizedStrings()

-- Self role from the raid's /maintank /mainassist assignments. MAINTANK = Sartharion ground
-- tank (frontal Flame Breath), MAINASSIST = drake tank (Shadow Breath, portals, whelps).
-- GetPartyAssignment works in normal raids (only UnitGroupRolesAssigned is LFG-gated).
-- Unassigned players, and the RoleFilterByAssignment option being off, fall through to "ALL"
-- so nobody silently loses warnings.
local function myAssignment()
	if not mod.Options.RoleFilterByAssignment then return "ALL" end
	if GetPartyAssignment("MAINTANK", "player", 1) then return "MT" end
	if GetPartyAssignment("MAINASSIST", "player", 1) then return "DT" end
	return "ALL"
end
local function seesSarth()	-- Sartharion ground-tank content (Flame Breath)
	local r = myAssignment()
	return r == "ALL" or r == "MT"
end
local function seesDrake()	-- drake-tank content (Shadow Breath, portals, whelps, fissures)
	local r = myAssignment()
	return r == "ALL" or r == "DT"
end

mod.statTypes = "normal,normal25"

mod:SetRevision("20260629000000")
mod:SetCreatureID(28860)
mod:SetEncounterID(742)

mod:RegisterCombat("yell", L.YellSarthPull)

mod:RegisterEventsInCombat(
	"SPELL_CAST_START 56908 58956",
	"SPELL_CAST_SUCCESS 57579 59127 57570 59126",
	"SPELL_AURA_APPLIED 57491",
	"SPELL_DAMAGE 59128",
	"CHAT_MSG_RAID_BOSS_EMOTE",
	"CHAT_MSG_MONSTER_YELL",
	"CHAT_MSG_MONSTER_EMOTE",
	"UNIT_DIED"
)

local warnShadowFissure			= mod:NewSpellAnnounce(59127, 4, nil, nil, nil, nil, nil, 2)
local warnBreathSoon			= mod:NewSoonAnnounce(58956, 2, nil, false)
local warnTenebron				= mod:NewAnnounce("WarningTenebron", 2, 61248)
local warnShadron				= mod:NewAnnounce("WarningShadron", 2, 58105)
local warnVesperon				= mod:NewAnnounce("WarningVesperon", 2, 61251)
local warnTenebronWhelpsSoon	= mod:NewAnnounce("WarningWhelpsSoon", 1, 1022, false)
local warnShadronPortalSoon		= mod:NewAnnounce("WarningPortalSoon", 1, 11420, false)
local warnVesperonPortalSoon	= mod:NewAnnounce("WarningReflectSoon", 1, 57988, false)

local specWarnFireWall			= mod:NewSpecialWarning("WarningFireWall", nil, nil, nil, 2, 2)
local specWarnVesperonPortal	= mod:NewSpecialWarning("WarningVesperonPortal", false, nil, nil, 1, 7)
local specWarnTenebronPortal	= mod:NewSpecialWarning("WarningTenebronPortal", false, nil, nil, 1, 7)
local specWarnShadronPortal		= mod:NewSpecialWarning("WarningShadronPortal", false, nil, nil, 1, 7)
local specWarnFissureYou    = mod:NewSpecialWarningYou(59127, nil, nil, nil, 3, 2)
local specWarnFissureClose  = mod:NewSpecialWarningClose(59127, nil, nil, nil, 2, 8)

-- Fissure bar defaults off (the announce + personal "you" warnings carry the mechanic);
-- the constant 5s bar during portal phases is clutter most raids don't want.
local timerShadowFissure		= mod:NewCastTimer(5, 59128, nil, false, nil, 3, nil, DBM_COMMON_L.DEADLY_ICON)
local timerBreath 				= mod:NewVarTimer(10, 58956, nil, "Tank|Healer", nil, 5)
local timerDrakeBreath			= mod:NewVarSourceTimer(17.5, 57570, nil, true, nil, 5)
-- Each drake's "Power of ..." buff icon, reused on its Shadow Breath bar
local drakeBreathIcon = {
	[L.NameTenebron]	= 61248,	-- Power of Tenebron
	[L.NameShadron]		= 58105,	-- Power of Shadron
	[L.NameVesperon]	= 61251,	-- Power of Vesperon
}

-- Start a drake's Shadow Breath bar with its own icon, forced onto the huge bar
-- regardless of the 17.5s length (which is past the default enlarge threshold).
local function showDrakeBreath(name, seedTime)
	if not seesDrake() then return end
	timerDrakeBreath:Start(seedTime, name)
	timerDrakeBreath:UpdateIcon(drakeBreathIcon[name], name)
	local bar = DBT:GetBar(timerDrakeBreath.id .. "\t" .. name)
	if bar then
		bar:ResetAnimations(true)
		DBT:UpdateBars()
	end
end
local timerWall					= mod:NewNextTimer(25, 43113, nil, nil, nil, 2)

local yellFissure           = mod:NewYellMe(59127)

--Drake and Portals timings
local timerTenebron       = mod:NewTimer(28, "TimerTenebron", 61248, nil, nil, 1)
local timerShadron        = mod:NewTimer (68, "TimerShadron", 58105, nil, nil, 1)
local timerVesperon       = mod:NewTimer(122, "TimerVesperon", 61251, nil, nil, 1)
local timerTenebronWhelps = mod:NewTimer(51, "TimerTenebronWhelps", 1022)
local timerShadronPortal  = mod:NewTimer(23, "TimerShadronPortal", 11420)
local timerVesperonPortal = mod:NewTimer(36, "TimerVesperonPortal", 57988)

mod:AddBoolOption("AnnounceFails", true, "announce")
mod:AddBoolOption("RoleFilterByAssignment", true)
mod:AddBoolOption("ShowAllDrakeTimers", false)

mod:GroupSpells(59127, 59128)--Shadow fissure with void blast

local lastvoids = {}
local lastfire = {}
local tsort, tinsert, twipe, tremove = table.sort, table.insert, table.wipe, table.remove

local function isunitdebuffed(spellName)
	for uId in DBM:GetGroupMembers() do
		local debuff = DBM:UnitDebuff(uId, spellName)
		if debuff then
			return true
		end
	end
	return false
end

-- Each drake's arrival schedule, in the order they fly down. "at" = seconds from pull until
-- it lands, "warnAt" = when the incoming announce fires (a few seconds before). The drakes
-- present on this attempt are detected via Sartharion's "Power of ..." buff at pull.
local drakeArrival = {
    [L.NameTenebron] = { buff = 61248, timer = timerTenebron, warn = warnTenebron, at = 28,  warnAt = 25,  hpId = 30452 },
    [L.NameShadron]  = { buff = 58105, timer = timerShadron,  warn = warnShadron,  at = 68,  warnAt = 62,  hpId = 30451 },
    [L.NameVesperon] = { buff = 61251, timer = timerVesperon, warn = warnVesperon, at = 122, warnAt = 115, hpId = 30449 },
}
local drakeArrivalOrder = { L.NameTenebron, L.NameShadron, L.NameVesperon }
local pendingDrakes = {}

-- First (or all, in show-all mode) drake shown at pull: same schedule as before, started
-- "delay" seconds ago to account for the post-pull detection window.
local function revealDrakeArrival(name, delay)
    local d = drakeArrival[name]
    d.timer:Start(-delay)
    d.warn:Schedule(d.warnAt - delay)
end

-- A later drake revealed only once its predecessor lands (show-next mode): its bar shows the
-- gap between the two arrivals, since drakes fly down on a fixed schedule from pull.
local function revealDrakeNext(name, prevName)
    local d, p = drakeArrival[name], drakeArrival[prevName]
    local delta = d.at - p.at
    d.timer:Start(delta)
    local warnIn = delta - (d.at - d.warnAt)
    if warnIn > 0 then d.warn:Schedule(warnIn) else d.warn:Show() end
end

-- On a drake landing, drop it from the queue and, in show-next mode, surface the next one.
local function advanceDrakes(self, landedName)
    local idx
    for i, n in ipairs(pendingDrakes) do
        if n == landedName then idx = i break end
    end
    if not idx then return end
    tremove(pendingDrakes, idx)
    if self.Options.ShowAllDrakeTimers then return end  -- all timers already up
    local nxt = pendingDrakes[1]
    if nxt then revealDrakeNext(nxt, landedName) end
end

local function CheckDrakes(self, delay)
    if self.Options.HealthFrame then
        DBM.BossHealth:Show(L.name)
        DBM.BossHealth:AddBoss(28860, "Sartharion")
    end
    twipe(pendingDrakes)
    for _, name in ipairs(drakeArrivalOrder) do
        local d = drakeArrival[name]
        if isunitdebuffed(DBM:GetSpellInfo(d.buff)) then
            tinsert(pendingDrakes, name)
            if self.Options.HealthFrame then
                DBM.BossHealth:AddBoss(d.hpId, name)
            end
        end
    end
    if self.Options.ShowAllDrakeTimers then
        for _, name in ipairs(pendingDrakes) do
            revealDrakeArrival(name, delay)
        end
    elseif pendingDrakes[1] then
        revealDrakeArrival(pendingDrakes[1], delay)
    end
end

local sortedFails = {}
local function sortFails1(e1, e2)
	return (lastvoids[e1] or 0) > (lastvoids[e2] or 0)
end
local function sortFails2(e1, e2)
	return (lastfire[e1] or 0) > (lastfire[e2] or 0)
end

function mod:OnCombatStart(delay)
	--Cache spellnames so a solo player check doesn't fail in CheckDrakes in 8.0+
	self:Schedule(5, CheckDrakes, self, delay)
	timerWall:Start(20-delay)
	if seesSarth() then
		warnBreathSoon:Schedule(5-delay)
		timerBreath:Start(8-delay)
	end

	twipe(lastvoids)
	twipe(lastfire)
end

function mod:OnCombatEnd()
	if not self.Options.AnnounceFails then return end
	if DBM:GetRaidRank() < 1 or not self.Options.Announce then return end

	local voids = ""
	for k, _ in pairs(lastvoids) do
		tinsert(sortedFails, k)
	end
	tsort(sortedFails, sortFails1)
	for _, v in ipairs(sortedFails) do
		voids = voids.." "..v.."("..(lastvoids[v] or "")..")"
	end
	SendChatMessage(L.VoidZones:format(voids), "RAID")
	twipe(sortedFails)
	local fire = ""
	for k, _ in pairs(lastfire) do
		tinsert(sortedFails, k)
	end
	tsort(sortedFails, sortFails2)
	for _, v in ipairs(sortedFails) do
		fire = fire.." "..v.."("..(lastfire[v] or "")..")"
	end
	SendChatMessage(L.FireWalls:format(fire), "RAID")
	twipe(sortedFails)
end

-- Fires at the moment the breath lands (cast start + ~2s cast); restarts the 10s "next breath" bar so its zero is the hit.
local function startBreathTimer()
	if not seesSarth() then return end
	timerBreath:Start()
	warnBreathSoon:Schedule(7)
end

function mod:SPELL_CAST_START(args)
	if args:IsSpellID(56908, 58956) then -- Flame Breath; it lands ~2s after the cast starts
		self:Unschedule(startBreathTimer)
		self:Schedule(2, startBreathTimer)
	end
end

function mod:SPELL_CAST_SUCCESS(args)
    if args:IsSpellID(57579, 59127) then
        if args:IsPlayer() then
            specWarnFissureYou:Show()
            specWarnFissureYou:Play("watchfeet")
            yellFissure:Yell()
        elseif self:CheckNearby(8, args.destName) then
            specWarnFissureClose:Show(args.destName)
            specWarnFissureClose:Play("watchfeet")
        end
        warnShadowFissure:Show()
        warnShadowFissure:Play("watchstep")
        timerShadowFissure:Start()
    elseif args:IsSpellID(57570, 59126) then -- Shadow Breath (Tenebron/Shadron/Vesperon)
        showDrakeBreath(args.sourceName)
    end
end

function mod:UNIT_DIED(args)
    local cid = DBM:GetCIDFromGUID(args.destGUID)
    if cid == 30452 or cid == 30451 or cid == 30449 then -- a drake died, clear its breath bar
        timerDrakeBreath:Stop(args.destName)
    end
end

function mod:SPELL_AURA_APPLIED(args)
	if self.Options.AnnounceFails and self.Options.Announce and args.spellId == 57491 and DBM:GetRaidRank() >= 1 and DBM:GetRaidUnitId(args.destName) ~= "none" and args.destName then
		lastfire[args.destName] = (lastfire[args.destName] or 0) + 1
		SendChatMessage(L.FireWallOn:format(args.destName), "RAID")
	end
end

function mod:SPELL_DAMAGE(_, _, _, _, destName, _, spellId)
	if self.Options.AnnounceFails and self.Options.Announce and spellId == 59128 and DBM:GetRaidRank() >= 1 and DBM:GetRaidUnitId(destName) ~= "none" and destName then
		lastvoids[destName] = (lastvoids[destName] or 0) + 1
		SendChatMessage(L.VoidZoneOn:format(destName), "RAID")
	end
end

function mod:CHAT_MSG_MONSTER_YELL(msg, mob)
    -- A drake's aggro yell fires the moment it lands/engages; its first Shadow Breath is 10s later.
    if (mob == L.NameTenebron and L.YellTenebronAggro and msg:find(L.YellTenebronAggro, 1, true))
    or (mob == L.NameShadron and L.YellShadronAggro and msg:find(L.YellShadronAggro, 1, true))
    or (mob == L.NameVesperon and L.YellVesperonAggro and msg:find(L.YellVesperonAggro, 1, true)) then
        showDrakeBreath(mob, 10)
        advanceDrakes(self, mob)  -- arrival queue is shared, runs regardless of role
        return
    end
    if not seesDrake() then return end  -- whelps/portals are drake-tank concerns
    if mob == L.NameTenebron and L.YellTenebronLand and msg:find(L.YellTenebronLand, 1, true) then
        timerTenebronWhelps:Start(51)       -- 22s Portal + 2s Eggs + 25s Hatch
        warnTenebronWhelpsSoon:Schedule(46)
    elseif mob == L.NameShadron and L.YellShadronLand and msg:find(L.YellShadronLand, 1, true) then
        timerShadronPortal:Start(23)
        warnShadronPortalSoon:Schedule(19)
    elseif mob == L.NameVesperon and L.YellVesperonLand and msg:find(L.YellVesperonLand, 1, true) then
        timerVesperonPortal:Start(36)
        warnVesperonPortalSoon:Schedule(32)
    end
end

function mod:CHAT_MSG_RAID_BOSS_EMOTE(msg, mob)
    if msg == L.Wall or msg:find(L.Wall) then
        self:SendSync("FireWall")
    elseif msg == L.Portal or msg:find(L.Portal) then
        if mob == L.NameVesperon then
            self:SendSync("VesperonPortal")
        elseif mob == L.NameTenebron then
            self:SendSync("TenebronPortal")
        elseif mob == L.NameShadron then
            self:SendSync("ShadronPortal")
        end
    elseif L.TenebronHatch and msg:find(L.TenebronHatch, 1, true) then
        if not seesDrake() then return end  -- whelps are a drake-tank concern
        timerTenebronWhelps:Start(27)
        warnTenebronWhelpsSoon:Schedule(23)
    end
end

function mod:OnSync(event)
	if event == "FireWall" then
		timerWall:Start()
		specWarnFireWall:Show()
		specWarnFireWall:Play("watchwave")
	elseif not seesDrake() then  -- portals below are drake-tank concerns
		return
	elseif event == "VesperonPortal" then
		specWarnVesperonPortal:Show()
		specWarnVesperonPortal:Play("newportal")
	elseif event == "TenebronPortal" then
		specWarnTenebronPortal:Show()
		specWarnTenebronPortal:Play("newportal")
	elseif event == "ShadronPortal" then
		specWarnShadronPortal:Show()
		specWarnShadronPortal:Play("newportal")
	end
end
