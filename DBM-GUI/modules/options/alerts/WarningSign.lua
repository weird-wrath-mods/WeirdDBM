local L = DBM_GUI_L

local signPanel = DBM_GUI.Cat_Alerts:CreateNewPanel(L.Panel_WarningSign, "option")

local signArea = signPanel:CreateArea(L.Area_WarningSign)

local movemebutton = signArea:CreateButton(L.MoveMe, 120, 16)
movemebutton:SetPoint("TOPRIGHT", signArea.frame, "TOPRIGHT", -2, -4)
movemebutton:SetNormalFontObject(GameFontNormalSmall)
movemebutton:SetHighlightFontObject(GameFontNormalSmall)
movemebutton:SetScript("OnClick", function()
	DBM.WarningSign:Move()
end)

local scaleSlider = signArea:CreateSlider(L.WarningSignScale, 0.5, 2, 0.05, 200)
scaleSlider:SetPoint("TOPLEFT", signArea.frame, "TOPLEFT", 20, -35)
scaleSlider:SetScript("OnShow", function(self) self:SetValue(DBM.Options.WarningSignScale) end)
scaleSlider:HookScript("OnValueChanged", function(self)
	DBM.Options.WarningSignScale = self:GetValue()
	DBM.WarningSign:UpdatePosition()
end)

local resetbutton = signArea:CreateButton(L.Reset, 120, 16)
resetbutton:SetPoint("BOTTOMRIGHT", signArea.frame, "BOTTOMRIGHT", -2, 4)
resetbutton:SetNormalFontObject(GameFontNormalSmall)
resetbutton:SetHighlightFontObject(GameFontNormalSmall)
resetbutton:SetScript("OnClick", function()
	for _, k in ipairs({"WarningSignPoint", "WarningSignX", "WarningSignY", "WarningSignScale"}) do
		DBM.Options[k] = DBM.DefaultOptions[k]
	end
	scaleSlider:SetValue(DBM.Options.WarningSignScale)
	DBM.WarningSign:UpdatePosition()
end)
