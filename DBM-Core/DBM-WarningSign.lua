---------------
--  Globals  --
---------------
-- A big spell icon above the special warning text, after BigWigs' WarningSign: one at a time, gone after its duration.
DBM.WarningSign = {}

--------------
--  Locals  --
--------------
local sign = DBM.WarningSign
local L = DBM_CORE_L
local frame, texture, sweep, text, shown, endTime, moving

--------------------
--  Create Frame  --
--------------------
frame = CreateFrame("Frame", "DBMWarningSign", UIParent)
frame:SetSize(100, 100)
frame:SetFrameStrata("HIGH")
frame:SetAlpha(0.8)
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:RegisterForDrag("LeftButton")
frame:Hide()
texture = frame:CreateTexture(nil, "ARTWORK")
texture:SetAllPoints(frame)
texture:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- crop the icon border
sweep = CreateFrame("Cooldown", nil, frame) -- the action-button clock sweep, counting down the duration
sweep:SetAllPoints(frame)
-- the sweep draws over its parent, so the text sits on a frame above it
local textFrame = CreateFrame("Frame", nil, frame)
textFrame:SetAllPoints(frame)
textFrame:SetFrameLevel(sweep:GetFrameLevel() + 1)
text = textFrame:CreateFontString(nil, "OVERLAY", "ZoneTextFont")
text:SetPoint("CENTER", frame, "CENTER", 0, 0)

-- options load after this file, so the position is read when the sign shows
function sign:UpdatePosition()
	local o = DBM.Options
	frame:ClearAllPoints()
	frame:SetPoint(o.WarningSignPoint, UIParent, o.WarningSignPoint, o.WarningSignX, o.WarningSignY)
	frame:SetScale(o.WarningSignScale)
end

frame:SetScript("OnUpdate", function(self)
	if GetTime() >= endTime then
		shown = nil
		moving = nil
		self:EnableMouse(false)
		self:Hide()
	end
end)

frame:SetScript("OnDragStart", function(self)
	self:StartMoving()
end)
frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, _, x, y = self:GetPoint(1)
	DBM.Options.WarningSignPoint, DBM.Options.WarningSignX, DBM.Options.WarningSignY = point, x, y
end)

-- sound (optional): a sound file path, played through DBM:PlaySoundFile when the sign shows
function sign:Show(icon, duration, label, sound)
	if moving then return end
	shown = icon
	duration = duration or 1
	endTime = GetTime() + duration
	self:UpdatePosition()
	texture:SetTexture(icon)
	text:SetText(label or "")
	frame:Show()
	sweep:SetCooldown(GetTime(), duration)
	if sound then
		DBM:PlaySoundFile(sound)
	end
end

-- only hides the sign it was asked about, so a newer one stays up
function sign:Hide(icon)
	if moving then return end
	if not icon or icon == shown then
		shown = nil
		frame:Hide()
	end
end

-- a draggable test sign for 15s, like the special warning's Move me; a second call ends it
function sign:Move()
	if moving then
		endTime = 0
		DBT:CancelBar(L.MOVE_WARNING_SIGN_BAR)
		return
	end
	self:Show("Interface\\Icons\\Spell_Nature_WispSplode", 15, L.MOVE_WARNING_SIGN_TEXT)
	moving = true
	frame:EnableMouse(true)
	DBT:CreateBar(15, L.MOVE_WARNING_SIGN_BAR, "Interface\\Icons\\Spell_Holy_BorrowedTime")
end
