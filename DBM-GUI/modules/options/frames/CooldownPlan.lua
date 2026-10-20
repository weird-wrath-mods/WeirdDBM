local L = DBM_GUI_L

local panel = DBM_GUI.Cat_Frames:CreateNewPanel(L.Panel_CooldownPlan, "option")
local general = panel:CreateArea(L.Area_General)
general:CreateCheckButton(L.CooldownPlanEnabled, true, nil, "CooldownPlanEnabled")
