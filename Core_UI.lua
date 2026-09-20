-- ============================================================
-- BuzzardFrames: Core_UI.lua
-- Game UI integration points:
--   • Shared StaticPopupDialog registrations
--   • Blizzard Settings panel (ESC > Options > AddOns)
--   • Addon Compartment dropdown (|)
--   • Minimap button (via LibDBIcon)
-- Extracted from Core.lua in the Core split refactor.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- ============================================================
-- STATIC POPUP DIALOGS
-- Shared confirmation dialogs used across the addon.
-- ============================================================
StaticPopupDialogs["BUZZARDFRAMES_RELOAD"] = {
    text      = "BuzzardFrames: Reload UI to apply this change.",
    button1   = "Reload",
    button2   = "Later",
    OnAccept  = function() ReloadUI() end,
    timeout   = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["BUZZARDFRAMES_LAYOUT_IN_USE"] = {
    text      = "%s",
    button1   = "OK",
    timeout   = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- v61: confirmation for the corner X on a Single Buff group (Raid/Party
-- Frames -> Buffs -> Single Buffs). That X is a raw decoration button on a
-- custom AceGUI widget, so it is NOT covered by AceConfig's `confirm` member --
-- hence a popup here. `data.fn` carries the removal closure.
StaticPopupDialogs["BUZZARDFRAMES_REMOVE_SINGLE_BUFF"] = {
    text      = "Remove the single buff \"%s\"?",
    button1   = "Remove",
    button2   = "Cancel",
    OnAccept  = function(self)
        local fn = self and self.data and self.data.fn
        if fn then fn() end
    end,
    timeout   = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- ============================================================
-- SETTINGS PANEL (ESC > Options > AddOns)
-- Registers a BuzzardFrames entry in the WoW Settings panel.
-- Shows a description and an "Open BuzzardFrames Options" button.
-- ============================================================
do
    -- Only register if the modern Settings API is available (WoW 10.x+)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local panel = CreateFrame("Frame")
        panel.name = "BuzzardFrames"

        -- Built now rather than in OnShow. An unparented frame is already
        -- shown, so OnShow never fires on the first visit to the category --
        -- the page came up blank until the reader left it and came back.
        local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        desc:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
        desc:SetText("Buzzard Frames")

        local subDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        subDesc:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -8)
        subDesc:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
        subDesc:SetJustifyH("LEFT")
        subDesc:SetText("Use /bf or the below button to open the options panel.")

        local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        btn:SetSize(220, 26)
        btn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -40)
        btn:SetText("Open Buzzard Frames Options")
        btn:SetScript("OnClick", function()
            local BF = _G["BuzzardFrames"]
            if BF and BF.OpenOptions then BF:OpenOptions() end
        end)

        local category = Settings.RegisterCanvasLayoutCategory(panel, "Buzzard Frames")
        Settings.RegisterAddOnCategory(category)
    end
end

-- ============================================================
-- ADDON COMPARTMENT (Game Menu > AddOns dropdown)
-- The three global functions are referenced by name in the .toc file.
-- ============================================================
function BuzzardFrames_AddonCompartmentFunc(addonName, menuButton)
    local BF = _G["BuzzardFrames"]
    if BF and BF.OpenOptions then BF:OpenOptions() end
end

function BuzzardFrames_AddonCompartmentFuncOnEnter(addonName, menuButton)
    GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cff11ace9Buzzard Frames|r", 1, 1, 1, true)
    GameTooltip:AddLine("Use /bf or the below button to open the options panel.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end

function BuzzardFrames_AddonCompartmentFuncOnLeave(addonName, menuButton)
    GameTooltip:Hide()
end

function BF:SetupMinimapButton()
    local LDB = LibStub("LibDataBroker-1.1", true)
    local LibDBIcon = LibStub("LibDBIcon-1.0", true)
    if not LDB or not LibDBIcon then return end

    local launcher = LDB:NewDataObject("BuzzardFrames", {
        type  = "launcher",
        label = "Buzzard Frames",
        icon  = "Interface\\AddOns\\BuzzardFrames\\Media\\buzzardRes",
        OnClick = function(_, button)
            if button == "LeftButton" then
			if BF:IsOptionsShown() then
				BF:CloseOptions()
			else
				BF:OpenOptions()
			end
			elseif button == "RightButton" then
				if InCombatLockdown() then
					print("|cffffd700BuzzardFrames:|r Cannot toggle Setup Mode in combat.")
					return
				end
				BF:ToggleSetupMode(not BF.db.global.setupModeActive)
			end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("|cff11ace9Buzzard Frames|r")
            tooltip:AddLine("Left click to open settings", 0.8, 0.8, 0.8)
            tooltip:AddLine("Right click to toggle Setup Mode", 0.8, 0.8, 0.8)
        end,
    })

    LibDBIcon:Register("BuzzardFrames", launcher, self.db.global.minimapIcon)
end

