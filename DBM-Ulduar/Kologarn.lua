local mod	= DBM:NewMod("Kologarn", "DBM-Ulduar")
local L		= mod:GetLocalizedStrings()

mod:SetRevision("20260507220131")
mod:SetCreatureID(32930)
mod:SetEncounterID(749)
mod:SetUsedIcons(5, 6, 7, 8)

mod:RegisterCombat("combat")

mod:RegisterEventsInCombat(
	"SPELL_CAST_SUCCESS 63573 64006 62166 63981",
	"SPELL_AURA_APPLIED 64290 64292 64002 63355",
	"SPELL_AURA_APPLIED_DOSE 64002 63355",
	"SPELL_AURA_REMOVED 64290 64292",
	"SPELL_DAMAGE 63356 64003 63783 63982 63346 63976",
	"SPELL_MISSED 63356 64003 63783 63982 63346 63976",
	"CHAT_MSG_RAID_BOSS_EMOTE",
	"CHAT_MSG_RAID_BOSS_WHISPER",
	"UNIT_DIED",
	"UNIT_SPELLCAST_SUCCEEDED"
)

mod:SetBossHealthInfo(
	32930, L.Health_Body,
	32934, L.Health_Right_Arm,
	32933, L.Health_Left_Arm
)

-- General
local enrageTimer				= mod:NewBerserkTimer(600, nil, nil, nil, false) -- berserk default OFF
local timerTimeForDisarmed		= mod:NewTimer(10, "achievementDisarmed")	-- 10 HC / 12 nonHC

--NOTE: Two crunch armors are setup to appear in gui twice on purpose, because they are very different mechanically. One is meant to be ignored and one is meant to be tank swap
-- Kologarn
mod:AddTimerLine(L.name)
local warnFocusedEyebeam		= mod:NewTargetNoFilterAnnounce(63346, 4)
local warnCrunchArmor			= mod:NewStackAnnounce(64002, 2, nil, "Tank|Healer")

local specWarnCrunchArmor2		= mod:NewSpecialWarningStack(64002, nil, 2, nil, 2, 1, 6)
local specWarnEyebeam			= mod:NewSpecialWarningRun(63346, nil, nil, nil, 4, 2)
local specWarnEyebeamNear		= mod:NewSpecialWarningClose(63346, nil, nil, nil, 1, 2)
local yellBeam					= mod:NewYell(63346)

local timerCrunch10				= mod:NewTargetTimer(6, 63355)
local timerNextSmash			= mod:NewCDTimer(14, 64003, DBM:GetSpellInfo(64003), "Tank", nil, 5, nil, DBM_COMMON_L.TANK_ICON) -- on the server's schedule, so no "CD" in the label
local timerNextEyebeam			= mod:NewCDTimer(20, 63346, DBM:GetSpellInfo(63346), nil, nil, 3, nil, DBM_COMMON_L.IMPORTANT_ICON, true) -- same

mod:AddSetIconOption("SetIconOnEyebeamTarget", 63346, true, false, {8})

-- Right Arm
mod:AddTimerLine(L.Health_Right_Arm)
local warnGrip					= mod:NewTargetNoFilterAnnounce(64292, 2)

local timerNextGrip				= mod:NewNextTimer(25, 62166, nil, nil, nil, 3)
local timerRespawnRightArm		= mod:NewTimer(50, "timerRightArm", nil, nil, nil, 1) --50s on AC

mod:AddSetIconOption("SetIconOnGripTarget", 64292, true, false, {7, 6, 5})

-- Left Arm
mod:AddTimerLine(L.Health_Left_Arm)
local timerNextShockwave		= mod:NewNextTimer(17, 63982, nil, nil, nil, 2)
local timerRespawnLeftArm		= mod:NewTimer(50, "timerLeftArm", nil, nil, nil, 1) --50s on AC

-- 5/23 00:33:48.648  SPELL_AURA_APPLIED,0x0000000000000000,nil,0x80000000,0x0480000001860FAC,"Hâzzad",0x4000512,63355,"Crunch Armor",0x1,DEBUFF
-- 6/3 21:41:56.140 UNIT_DIED,0x0000000000000000,nil,0x80000000,0xF1500080A60274A0,"Rechter Arm",0xa48

mod:GroupSpells(64292, 62166) -- Stone Grip aura and cast

mod.vb.disarmActive = false
local gripTargets = {}

local function armReset(self)
	self.vb.disarmActive = false
end

local function GripAnnounce(self)
	warnGrip:Show(table.concat(gripTargets, "<, >"))
	table.wipe(gripTargets)
end

-- AC (boss_kologarn.cpp): every ability is instant and runs on its own event: Smash 8s then 14s, Sweep
-- (Shockwave) 17s then 17s, Stone Grip 15s then 25s, Focused Eyebeam 10s then 20s. Smash and Sweep each
-- push every other pending event back 1s, and they still do with the arm they need dead (no cast, no
-- log). So the mod runs the same schedule itself, and what the log shows only corrects it. Overhead Smash
-- is an on-next-swing spell: it lands on his next swing after its event, mostly at once (logs: 40% under
-- 0.25s, most within 1s, at most 2.8s), so its bar ends at the event and a Smash hit never retimes it.
local FIRST = {smash = 8, sweep = 17, grip = 15, eye = 10}
local EVERY = {smash = 14, sweep = 17, grip = 25, eye = 20}
local PUSHES = {smash = true, sweep = true}
local SEEN_WINDOW = 3 -- one ability's hits within this are the same cast
local ARM_BACK = 50
local SHOCKWAVE_TRAVEL = 0.2 -- first Shockwave hit lands this long after the Sweep
local due, firedAt, seenAt, shownEnd = {}, {}, {}, {}
local leftArm, rightArm = true, true
local tick

-- A bar restarts only when its own ability starts a new cycle (restart = that key); a push or a correction
-- only moves its end, so the bar keeps its length and how far it has run.
local function redraw(restart)
	local now = GetTime()
	local function show(timer, k, can)
		if not can then
			timer:Stop()
			shownEnd[k] = nil
		elseif k == restart or not shownEnd[k] or timer:GetTime() == 0 then
			timer:Start(due[k] - now)
			shownEnd[k] = due[k]
		elseif due[k] > shownEnd[k] + 0.01 then
			timer:AddTime(due[k] - shownEnd[k])
			shownEnd[k] = due[k]
		elseif due[k] < shownEnd[k] - 0.01 then
			timer:RemoveTime(shownEnd[k] - due[k])
			shownEnd[k] = due[k]
		end
	end
	show(timerNextSmash, "smash", leftArm or rightArm)
	show(timerNextShockwave, "sweep", leftArm)
	show(timerNextGrip, "grip", rightArm)
	show(timerNextEyebeam, "eye", true)
end

local function nextDue()
	local k
	for key, t in pairs(due) do
		if not k or t < due[k] then k = key end
	end
	return k
end

-- the server runs event k at t, seen or not
local function fire(self, k, t)
	if PUSHES[k] then
		for other in pairs(due) do
			if other ~= k then due[other] = due[other] + 1 end
		end
	end
	due[k], firedAt[k] = t + EVERY[k], t
	redraw(k)
	self:Unschedule(tick)
	self:Schedule(math.max(0, due[nextDue()] - GetTime()), tick, self)
end

tick = function(self)
	fire(self, nextDue(), GetTime())
end

-- the log showed ability k at t
local function seen(self, k, t)
	if seenAt[k] and t - seenAt[k] < SEEN_WINDOW then return end
	seenAt[k] = t
	if k == "smash" and firedAt[k] and t - firedAt[k] < SEEN_WINDOW then return end -- the swing after its event
	if firedAt[k] and t - firedAt[k] < SEEN_WINDOW then -- already run a moment early: just retime it
		due[k], firedAt[k] = t + EVERY[k], t
		redraw()
		self:Unschedule(tick)
		self:Schedule(math.max(0, due[nextDue()] - GetTime()), tick, self)
	else
		fire(self, k, t)
	end
end

local function armBack(self, left)
	if left then leftArm = true else rightArm = true end
	redraw()
end

function mod:OnCombatStart(delay)
	enrageTimer:Start(-delay)
	local engage = GetTime() - delay
	table.wipe(firedAt)
	table.wipe(seenAt)
	table.wipe(shownEnd)
	for k, t in pairs(FIRST) do due[k] = engage + t end
	leftArm, rightArm = true, true
	redraw()
	self:Schedule(math.max(0, due[nextDue()] - GetTime()), tick, self)
end

function mod:SPELL_CAST_SUCCESS(args)
	if args:IsSpellID(63573, 64006) then -- One-Armed Overhead Smash
		seen(self, "smash", GetTime())
	elseif args:IsSpellID(62166, 63981) then -- Stone Grip
		seen(self, "grip", GetTime())
	end
end

function mod:SPELL_AURA_APPLIED(args)
	if args:IsSpellID(64290, 64292) then
		if self.Options.SetIconOnGripTarget then
			self:SetIcon(args.destName, 8 - #gripTargets, 10)
		end
		table.insert(gripTargets, args.destName)
		self:Unschedule(GripAnnounce)
		if #gripTargets >= 3 then
			GripAnnounce(self)
		else
			self:Schedule(0.3, GripAnnounce, self)
		end
	elseif args:IsSpellID(64002, 63355) then	-- Crunch Armor
		local amount = args.amount or 1
		if amount >= 2 then
			if args:IsPlayer() then
				specWarnCrunchArmor2:Show(amount)
				specWarnCrunchArmor2:Play("stackhigh")
			else
				warnCrunchArmor:Show(args.destName, amount)
			end
		else
			warnCrunchArmor:Show(args.destName, amount)
		end
		if self:IsDifficulty("normal10") then
			timerCrunch10:Start(args.destName)  -- We track duration timer only in 10-man since it's only 6sec and tanks don't switch.
		end
	end
end
mod.SPELL_AURA_APPLIED_DOSE = mod.SPELL_AURA_APPLIED

function mod:SPELL_AURA_REMOVED(args)
	if args:IsSpellID(64290, 64292) then
		self:SetIcon(args.destName, 0)
	end
end

function mod:UNIT_DIED(args)
	if self:GetCIDFromGUID(args.destGUID) == 32934 then		-- right arm
		timerRespawnRightArm:Start()
		rightArm = false
		self:Schedule(ARM_BACK, armBack, self, false)
		redraw()
		if not self.vb.disarmActive then
			self.vb.disarmActive = true
			if self:IsDifficulty("normal10") then
				timerTimeForDisarmed:Start(12)
				self:Schedule(12, armReset, self)
			else
				timerTimeForDisarmed:Start()
				self:Schedule(10, armReset, self)
			end
		end
	elseif self:GetCIDFromGUID(args.destGUID) == 32933 then		-- left arm
		timerRespawnLeftArm:Start()
		leftArm = false
		self:Schedule(ARM_BACK, armBack, self, true)
		redraw()
		if not self.vb.disarmActive then
			self.vb.disarmActive = true
			if self:IsDifficulty("normal10") then
				timerTimeForDisarmed:Start(12)
				self:Schedule(12, armReset, self)
			else
				timerTimeForDisarmed:Start()
				self:Schedule(10, armReset, self)
			end
		end
	end
end

function mod:SPELL_DAMAGE(_, _, _, destGUID, destName, _, spellId)
	if spellId == 63356 or spellId == 64003 then -- two-armed Overhead Smash: logs no cast success, only its hit
		seen(self, "smash", GetTime())
	elseif spellId == 63783 or spellId == 63982 then -- Shockwave
		seen(self, "sweep", GetTime() - SHOCKWAVE_TRAVEL)
	elseif (spellId == 63346 or spellId == 63976) and self:AntiSpam(2, 2) then
		if destGUID == UnitGUID("player") then
			specWarnEyebeam:Show()
		else
			local uId = self:GetUnitIdFromGUID(destGUID)
			if uId then
				local inRange = CheckInteractDistance(uId, 5)
				if inRange then
					specWarnEyebeamNear:Show(destName)
				end
			end
		end

	end
end
mod.SPELL_MISSED = mod.SPELL_DAMAGE

-- TEMPORARY server workaround: AzerothCore sends Kologarn EMOTE_EYES as creature_text type 41 (raid-wide
-- RAID_BOSS_EMOTE) instead of type 42 (RAID_BOSS_WHISPER to the target only), so every client prints
-- "focuses his eyes on you!". Both eye NPCs also Talk it on summon, so the target gets it twice.
-- This block hides other players' copies and the duplicate. Delete it once AzerothCore makes the row type 42;
-- the CHAT_MSG_RAID_BOSS_WHISPER handler below already covers the fixed server.
local function isEyebeamEmote(event, msg)
	return event == "CHAT_MSG_RAID_BOSS_EMOTE" and msg and msg:find(L.FocusedEyebeam, 1, true)
end

local lastEyebeamEmote = 0
local emoteOnEvent = RaidBossEmoteFrame:GetScript("OnEvent")
RaidBossEmoteFrame:SetScript("OnEvent", function(self, event, msg, sender, arg3, arg4, target, ...)
	if isEyebeamEmote(event, msg) then
		if target ~= UnitName("player") or GetTime() - lastEyebeamEmote < 5 then return end
		lastEyebeamEmote = GetTime()
	end
	return emoteOnEvent(self, event, msg, sender, arg3, arg4, target, ...)
end)

ChatFrame_AddMessageEventFilter("CHAT_MSG_RAID_BOSS_EMOTE", function(_, event, msg, _, _, _, target)
	return isEyebeamEmote(event, msg) and target ~= UnitName("player")
end)
-- end TEMPORARY server workaround

function mod:CHAT_MSG_RAID_BOSS_EMOTE(msg, _, _, _, target)
	if msg:find(L.FocusedEyebeam, 1, true) then
		self:SendSync("EyeBeamOn", target)
	end
end

function mod:CHAT_MSG_RAID_BOSS_WHISPER(msg)
	if msg:find(L.FocusedEyebeam, 1, true) then
		self:SendSync("EyeBeamOn", UnitName("player"))
	end
end

function mod:OnSync(msg, target)
	if msg == "EyeBeamOn" and self:AntiSpam(2, 1) then
		seen(self, "eye", GetTime()) -- the eyes emote as they are summoned
		warnFocusedEyebeam:Show(target)
		if target == UnitName("player") then
			specWarnEyebeam:Show()
			specWarnEyebeam:Play("justrun")
			specWarnEyebeam:ScheduleVoice(1, "keepmove")
			yellBeam:Yell()
		end
		if self.Options.SetIconOnEyebeamTarget then
			self:SetIcon(target, 8, 8)
		end
	end
end

function mod:UNIT_SPELLCAST_SUCCEEDED(_, spellName)
	if spellName == GetSpellInfo(63983) then--Arm Sweep
		seen(self, "sweep", GetTime())
	elseif spellName == GetSpellInfo(63342) then --Focused Eyebeam Summon Trigger
		seen(self, "eye", GetTime())
	elseif spellName == GetSpellInfo(63573) then  -- One-Armed Overhead Smash
		seen(self, "smash", GetTime())
	elseif spellName == GetSpellInfo(63726) then -- Pacify Self (End Combat, since there isn't a UNIT_DIED for OnMobKill to run)
		DBM:EndCombat(self)
	end
end
