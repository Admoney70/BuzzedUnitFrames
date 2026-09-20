-- ============================================================
-- BuzzardFrames: Core_AceConfigDialog.lua
-- Runtime operation of the AceConfigDialog options window:
--   • RecolorWidgetLabels (local) — walks widget tree and recolors
--     Slider/Dropdown labels from yellow to white.
--   • SyncOpenWorldSetupMode — keeps the active setup-mode tab in
--     sync with the Open World Solo/Raid dropdowns.
--   • GetActiveTab / GetTrueActiveTab — which options sub-tab
--     reflects the currently effective context.
--   • OpenOptions — opens the options window and attaches all the
--     post-open chrome (logo, lock button, tiny-handle checkbox,
--     X button, tree coloring, size/position persistence, and the
--     ACD.Open wrapper that re-runs this setup after NotifyChange).
-- Extracted from Core.lua in the Core split refactor.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- Recursively walk all AceGUI widget children and recolor their labels.
-- Sliders and DropDowns use .label; we set the color directly each time.
local function RecolorWidgetLabels(container)
    if not container.children then return end
    for _, widget in ipairs(container.children) do
        -- Slider and Dropdown: set label color to white now.
        -- IMPORTANT: we do NOT patch widget.SetDisabled here.  AceGUI recycles
        -- widget objects via an internal object pool, so any method monkey-patch
        -- applied here would persist on the widget after it is released back to
        -- the pool and later reused by a completely different addon, causing that
        -- addon's labels to also render as white.  Setting the color directly on
        -- each open is sufficient because RecolorWidgetLabels is called every time
        -- Buzzard's options panel is shown.
        if widget.label and (widget.type == "Slider" or widget.type == "Dropdown") then
            widget.label:SetTextColor(1, 1, 1)
        end
        -- Recurse into sub-containers (inline groups etc.)
        if widget.children then
            RecolorWidgetLabels(widget)
        end
    end
end

-- Schedule a deferred recolor of all widget labels in the options tree.
-- Called by _subcatTracker render callbacks (Options_Auras.lua, etc.)
-- when a subtab renders, ensuring freshly-pooled widgets get white labels.
-- Coalesces multiple calls within the same frame into a single pass.
function BF:ScheduleWidgetLabelRecolor()
    if self._recolorScheduled then return end
    self._recolorScheduled = true
    C_Timer.After(0, function()
        self._recolorScheduled = nil
        local tg = self._optionsTreeGroup
        if tg then RecolorWidgetLabels(tg) end
    end)
end

-- Returns the frames sub-tab key that reflects the currently active settings
-- Under the flat model there are no tier-specific test-mode flags to sync,
-- so SyncOpenWorldSetupMode has been removed. Open World dropdown changes
-- simply save to the flat profile and let the next live resolve pick them up.

function BF:GetActiveTab()
    -- Kept as a thin alias for GetTrueActiveTab. Setup mode no longer pins
    -- a tab; the options chrome drives editing via _modifyingFlat instead.
    return self:GetTrueActiveTab()
end

-- Returns the truly active tab based purely on game state, ignoring setup/test mode.
function BF:GetTrueActiveTab()
    local p = self.db.profile
    local _, instanceType = GetInstanceInfo()
    local inOpenWorld = instanceType == "none"

    if inOpenWorld then
        if IsInRaid() then
            local setting = p.openWorldRaid or "auto"
            if setting ~= "auto" then return setting end
            local groupSize = GetNumGroupMembers()
            if groupSize <= 20 then
                return self:ResolveTier("raid20")
            elseif groupSize <= 30 then
                return self:ResolveTier("raid30")
            else
                return self:ResolveTier("raid40")
            end
        elseif IsInGroup() then
            -- In a party (not raid) in the open world: always party.
            -- Matches Grid2's GroupChanged() which returns "party" when
            -- GetNumGroupMembers() > 0 and not IsInRaid().
            return "party"
        else
            -- Actually solo in the open world: respect the solo dropdown.
            -- "party" maps to the Party tab; any raid key maps to that raid tab.
            -- "none" maps to "party" for setup mode purposes (no separate none tab).
            local soloVal = p.openWorldSolo or "party"
            if soloVal == "none" then return "party" end
            return soloVal
        end
    end

    -- Battlegrounds (pvp): use raid tier logic — they use raid frames.
    -- GetCapacityTier reads maxPlayers from GetInstanceInfo for pvp, so this
    -- returns the correct tier (e.g. raid40 for a 40-man BG).
    if instanceType == "pvp" then
        local tier = self:GetCapacityTier()
        return self:ResolveTier(tier)
    end

    -- Inside a dungeon, delve, Torghast, or arena: always party
    if instanceType == "party" or instanceType == "scenario"
            or instanceType == "arena" then
        return "party"
    end

    -- Inside a raid instance: use tier logic
    local tier = self:GetCapacityTier()
    return self:ResolveTier(tier)
end

function BF:OpenOptions()
    local ACD = LibStub("AceConfigDialog-3.0")

    -- Modifying Layout reset rule: when the user opens the options panel
    -- while Setup Mode is NOT active, the panel was last closed without a
    -- setup-mode edit session carrying over, so _modifyingFlat should
    -- revert to the currently-active (live-rendering) flat. If Setup Mode
    -- IS active, the user has an edit session still running, so leave
    -- their selection alone. This is called before ACD:Open so the chrome
    -- Modifying Layout dropdown picks up the new value on its next build.
    if not (self.db and self.db.global and self.db.global.setupModeActive) then
        local fl = self.rpDB.profile.layouts.flatLayouts or {}
        local activeID = self:ResolveActiveFlat(self:GetActiveSlot())
        if activeID and activeID ~= "none" and fl[activeID] then
            self._modifyingFlat = activeID
        else
            self._modifyingFlat = fl.flat_party and "flat_party" or nil
        end
        self:InvalidateRaidProfileCache()
        -- Rebuild per-CFG aura caches immediately so that the preview
        -- renderer (which fires during this same AceConfig render pass)
        -- reads a fully-populated table via GetAuraCacheForFrame rather
        -- than the empty table left by InvalidateRaidProfileCache.
        if self.UpdateAuraSizeCache then self:UpdateAuraSizeCache() end
        if self._regeneratePreviewArgs then self._regeneratePreviewArgs() end
    end

    -- SetupOptionsPanel handles all post-open customisation: sizing, colours,
    -- the OnGroupSelected hook, and the initial SelectGroup call.
    -- It is called once on first open via C_Timer.After, and then re-attached
    -- after every NotifyChange-triggered rebuild by wrapping ACD.Open.
    local function SetupOptionsPanel()
        local aceFrame = ACD.OpenFrames and ACD.OpenFrames["BuzzardFrames"]
        if not aceFrame then return end



        -- Find the TreeGroup widget
        local treeGroup
        if aceFrame.children then
            for _, child in ipairs(aceFrame.children) do
                if child.SetTreeWidth then
                    treeGroup = child
                    break
                end
            end
        end
        if not treeGroup then return end

        -- Panel sizing: restore the user's last-used width (saved to db.global),
        -- falling back to the default 750. We also hook OnSizeChanged once to
        -- capture any manual resize the player makes during this session.
        local savedWidth = self.db and self.db.global and self.db.global.optionsPanelWidth
        local savedHeight = self.db and self.db.global and self.db.global.optionsPanelHeight
        aceFrame:SetWidth(savedWidth or 820)
        aceFrame:SetHeight(savedHeight or 760)
        if not self._optionsPanelResizeHooked and aceFrame.frame then
            self._optionsPanelResizeHooked = true
            local hookedFrame = aceFrame.frame
            aceFrame.frame:HookScript("OnSizeChanged", function(f, w, h)
                local bf = ACD.OpenFrames and ACD.OpenFrames["BuzzardFrames"]
                if bf and bf.frame and bf.frame == hookedFrame
                   and hookedFrame:IsShown()
                   and self.db and self.db.global then
                    self.db.global.optionsPanelWidth = w
                    self.db.global.optionsPanelHeight = h
                end
            end)
        end
        treeGroup:SetTreeWidth(170)
        if treeGroup.treeframe then
            treeGroup.treeframe:SetBackdropColor(0.1, 0.1, 0.1, 0.92)
        end
        if treeGroup.border then
            treeGroup.border:SetBackdropColor(0.1, 0.1, 0.1, 0.92)
        end

        -- Reserve vertical space at the top of the panel for the chrome Modify
        -- Layout dropdown.  Copied directly from ElvUI's approach in
        -- Config_ContentPlacement: re-anchor the AceGUI Frame widget's `content`
        -- frame (not the TreeGroup's internal treeframe, which would have no
        -- effect since TreeGroup.frame fills content anyway).  The content
        -- frame is the container that holds the TreeGroup; pushing its TOPLEFT
        -- down leaves an empty strip above the tree and content panes.
        -- Default AceGUI Frame layout anchors content to the frame with
        -- TOPLEFT +17,-27 and BOTTOMRIGHT -17,+40 (see AceGUIContainer-Frame.lua).
        if aceFrame.content then
            aceFrame.content:ClearAllPoints()
            aceFrame.content:SetPoint("TOPLEFT",     aceFrame.frame, "TOPLEFT",      17, -52) -- was -27
            aceFrame.content:SetPoint("BOTTOMRIGHT", aceFrame.frame, "BOTTOMRIGHT", -17,  40)
        end

        -- Recolor option name labels from yellow to white.
        -- Run once immediately (catches already-populated widgets) and
        -- once deferred (catches widgets built by GroupSelected which
        -- may fire after SetupOptionsPanel returns).
        -- Store the treeGroup so deferred recolor requests (e.g. from
        -- subtab _subcatTracker render callbacks) can find it.
        BF._optionsTreeGroup = treeGroup
        RecolorWidgetLabels(treeGroup)
        C_Timer.After(0, function() RecolorWidgetLabels(treeGroup) end)

        -- Hook tree node clicks to trigger NotifyChange so top-level hidden
        -- functions (Layout/Group Type dropdowns) re-evaluate.
        -- Guard with a flag on the treeGroup object so we install the callback
        -- exactly once per treeGroup instance.  Without this guard, every
        -- NotifyChange rebuild calls SetupOptionsPanel again, and each call
        -- would snapshot the previous BF callback as "existingCB" and wrap it
        -- in a new closure — stacking up O(N) callback layers after N rebuilds.
        -- Install / reinstall the OnGroupSelected hook on every SetupOptionsPanel
        -- run.  AceConfigDialog's Open() releases the TreeGroup back to the
        -- AceGUI widget pool and creates a new tree whose OnGroupSelected is
        -- set to AceConfigDialog's internal GroupSelected function — so any
        -- hook we installed on a previous tree instance is gone.  We must
        -- capture the CURRENT callback and wrap it so our logic runs alongside
        -- AceConfig's navigation.  The `_BF_BaseCallback` flag tracks whether
        -- we've already wrapped THIS specific widget's current callback, so
        -- re-running SetupOptionsPanel on the same tree instance (e.g. from
        -- NotifyChange without a full release) doesn't keep stacking wrappers.
        local currentCB = treeGroup.events and treeGroup.events["OnGroupSelected"]
        if currentCB ~= treeGroup._BF_WrappedCallback then
            local baseCB = currentCB
            local function wrappedCB(widget, event, value)
                if baseCB then baseCB(widget, event, value) end
                -- Refresh chrome dropdown visibility immediately on nav click,
                -- before NotifyChange round-trip, so it hides/shows without a
                -- noticeable frame delay when switching between raid/party
                -- sub-tabs and other sections.
                local bfFrame = aceFrame and aceFrame.frame
                if bfFrame and bfFrame._BF_RefreshLayoutDDVisibility then
                    bfFrame._BF_RefreshLayoutDDVisibility()
                end
                -- Save panel position before NotifyChange triggers a rebuild
                local f = aceFrame.frame
                if f then
                    local x, y = f:GetCenter()
                    local ux, uy = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2
                    self._optionsPanelSavedX = x - ux
                    self._optionsPanelSavedY = y - uy
                end
                C_Timer.After(0, function()
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                end)
            end
            treeGroup:SetCallback("OnGroupSelected", wrappedCB)
            treeGroup._BF_WrappedCallback = wrappedCB
        end

        local frame = aceFrame.frame
        if not frame then return end

        -- Restore position if we saved one before a NotifyChange rebuild
        if self._optionsPanelSavedX and self._optionsPanelSavedY then
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "CENTER", self._optionsPanelSavedX, self._optionsPanelSavedY)
            self._optionsPanelSavedX = nil
            self._optionsPanelSavedY = nil
        end

        -- One-time UI chrome: X button and status bar resize
        if not frame._BF_XButtonSetup then
            frame._BF_XButtonSetup = true

            -- Find and store the native AceConfigDialog Close button so we can
            -- hide it while Buzzard's panel is open and restore it when another
            -- addon's panel opens on the same shared frame.
            local nativeCloseBtn
            for i = 1, select("#", frame:GetChildren()) do
                local child = select(i, frame:GetChildren())
                if child and child.GetObjectType and child:GetObjectType() == "Button" then
                    local text = child.GetText and child:GetText()
                    if text == CLOSE or text == "Close" then
                        nativeCloseBtn = child
                        child:Hide()  -- hide now since Buzzard's panel is currently open
                        break
                    end
                end
            end
            frame._BF_NativeCloseBtn = nativeCloseBtn

            -- Lock/Unlock button anchored to the bottom-left of the status bar area.
            local lockBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
            lockBtn:SetSize(110, 22)
            lockBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 15, 15)
            lockBtn:SetScript("OnClick", function()
                if InCombatLockdown() then return end
                local p = BF.db.profile
                p.locked = not p.locked
                BF:SetLocked(p.locked)
                lockBtn:SetText(p.locked and "|cff11ace9Unlock Frames|r" or "|cff11ace9Lock Frames|r")
                print("BuzzardFrames: Frames " .. (p.locked and "locked" or "unlocked"))
            end)
            frame._BF_LockBtn = lockBtn

            -- Setup Mode button anchored to the bottom-right of the status bar area.
            -- Mirrored from the old globalTestMode execute widget: enters/exits Setup
            -- Mode for the currently-modified group type and updates its label.
            local setupBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
            setupBtn:SetSize(170, 22)
            setupBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 15, -29)
            local function refreshSetupBtnLabel()
                setupBtn:SetText(BF.db.global.setupModeActive and "|cff11ace9Exit Setup Mode|r" or "|cff11ace9Setup Mode|r")
            end
            setupBtn:SetScript("OnClick", function()
                if InCombatLockdown() then return end
                BF:ToggleSetupMode(not BF.db.global.setupModeActive)
                refreshSetupBtnLabel()
                LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
            end)
            frame._BF_SetupBtn = setupBtn
            frame._BF_RefreshSetupBtnLabel = refreshSetupBtnLabel

            -- ────────────────────────────────────────────────────────────────
            -- Aura Customizations spec button
            -- Floating navigation shortcut anchored BOTTOMLEFT to the panel's
            -- TOPLEFT with +10px Y offset -- sits just above the panel's top-left
            -- corner (matching the logo's floating pattern). Visible whenever the
            -- panel is open AND the player's current spec is in HEALER_SPECS
            -- (includes Augmentation Evoker). Clicking navigates to
            -- tabHealerBuffs -> tabSpec_<playerSpecID>.
            --
            -- No per-frame work: the button state is only refreshed on panel
            -- open and on BF:OnPlayerSpecChanged (which calls
            -- BF:RefreshAuraCustomizationsSpecButton). No combat-path cost.
            --
            -- Pattern mirrors the logo / setup / X button chrome: created once in
            -- this _BF_XButtonSetup block, show/hide driven by the OnShow /
            -- OnHide / every-open visibility hooks below.
            -- ────────────────────────────────────────────────────────────────
            local specBtn = CreateFrame("Button", nil, UIParent, "UIPanelButtonTemplate")
            specBtn:SetHeight(22)
            specBtn:SetFrameStrata("DIALOG")
            -- Same frame level as the options panel so the button renders in
            -- the same layer as the panel chrome rather than floating above it.
            specBtn:SetFrameLevel(frame:GetFrameLevel())
            specBtn:ClearAllPoints()
            specBtn:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 10, -3)
            specBtn:Hide()
            specBtn:SetScript("OnClick", function(self)
                local specId = self._specId
                if not specId then return end
                local ACD2 = LibStub("AceConfigDialog-3.0")
                if ACD2 then
                    ACD2:SelectGroup("BuzzardFrames", "customAuras", "tabHealerBuffs", "tabSpec_" .. specId)
                end
            end)
            frame._BF_SpecBtn = specBtn

            -- Refresh function: re-evaluates the player spec and updates the
            -- button's label + visibility. Safe to call repeatedly; early-exits
            -- if BF.HEALER_SPEC_ORDER isn't populated yet (loads with
            -- Options_AuraCustomizations.lua).
            local function refreshSpecBtn()
                local btn = frame._BF_SpecBtn
                if not btn then return end
                -- Inline panel-shown check (instead of calling
                -- isBuzzardPanelShown, which is declared as a local
                -- further down in this block and therefore not visible
                -- to this earlier closure -- Lua forward-reference
                -- issue that was causing a nil-call at refresh time).
                local bf = ACD.OpenFrames and ACD.OpenFrames["BuzzardFrames"]
                local panelShown = bf and bf.frame and bf.frame == frame and frame:IsShown()
                if not panelShown then
                    btn:Hide()
                    return
                end
                local specId = BF.playerSpecID
                local specs  = BF.HEALER_SPEC_ORDER
                local match
                if specId and specs then
                    for _, s in ipairs(specs) do
                        if s.id == specId then match = s; break end
                    end
                end
                if not match then
                    btn._specId = nil
                    btn:Hide()
                    return
                end
                btn._specId = specId
                local data = BF.specByID and BF.specByID[specId]
                local iconPath = data and data.icon
                if iconPath then iconPath = iconPath:gsub("\\", "/") end
                local iconStr = iconPath and ("|T" .. iconPath .. ":14:14:0:0|t ") or ""
                -- Use tabName (matches the Aura Customizations spec tab headings;
                -- differs from name for Resto Druid / Resto Shaman). Color only
                -- the spec name with the spec's classColor; leave " Aura
                -- Customizations" in default white so the action label reads
                -- consistently across specs.
                local color = match.classColor or "ffffff"
                local label = iconStr .. "|cff" .. color .. match.tabName .. "|r |cff11ace9Aura Customizations|r"
                btn:SetText(label)
                -- Size to fit text content with comfortable padding.
                -- UIPanelButtonTemplate exposes its label FontString as
                -- .Text, not via :GetFontString() (which this template does
                -- not implement and throws a nil-value error on).
                local fs = btn.Text
                if fs then
                    local tw = fs:GetStringWidth() or 160
                    btn:SetWidth(tw + 30)
                end
                btn:Show()
            end
            frame._BF_RefreshSpecBtn = refreshSpecBtn

            -- Also expose on BF so OnPlayerSpecChanged can call it without
            -- reaching into the chrome frame directly.
            function BF:RefreshAuraCustomizationsSpecButton()
                if frame._BF_RefreshSpecBtn then frame._BF_RefreshSpecBtn() end
            end

            -- Modify Layout dropdown — uses AceGUI's own Dropdown widget so it
            -- behaves identically to the dropdowns inside the panel (click
            -- anywhere to open, proper focus handling, matching visual style).
            -- The widget is created standalone (not inside an AceGUI container)
            -- and its .frame is anchored manually to the panel chrome.
            -- Visible only when a Raid/Party Frames sub-tab is selected.
            local gui = LibStub("AceGUI-3.0")
            local layoutDD = gui:Create("Dropdown")
            layoutDD:SetLabel("Modifying Layout")
            layoutDD:SetWidth(200)
            layoutDD.frame:SetParent(frame)
            layoutDD.frame:ClearAllPoints()
            layoutDD.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", 185, -11)
            layoutDD.frame:SetFrameStrata(frame:GetFrameStrata())
            layoutDD.frame:SetFrameLevel(frame:GetFrameLevel() + 10)
            layoutDD.frame:Show()

            local function buildLayoutDDList()
                local lpp = BF.rpDB.profile.layouts
                local fl = lpp.flatLayouts or {}
                local list, order = {}, {}
                local activeID = BF:ResolveActiveFlat(BF:GetActiveSlot())
                -- Ordered: all party flats alphabetically, then all raid flats alphabetically.
                local partyIDs, raidIDs = {}, {}
                for id, flat in pairs(fl) do
                    if type(flat) == "table" then
                        if flat.type == "party" then
                            partyIDs[#partyIDs + 1] = id
                        else
                            raidIDs[#raidIDs + 1] = id
                        end
                    end
                end
                local function byName(a, b)
                    local na = fl[a].name or a
                    local nb = fl[b].name or b
                    return na:lower() < nb:lower()
                end
                table.sort(partyIDs, byName)
                table.sort(raidIDs, byName)
                for _, id in ipairs(partyIDs) do
                    local name = fl[id].name or id
                    list[id] = (id == activeID) and ("|cff76CC4B" .. name .. "|r") or name
                    order[#order + 1] = id
                end
                for _, id in ipairs(raidIDs) do
                    local name = fl[id].name or id
                    list[id] = (id == activeID) and ("|cff76CC4B" .. name .. "|r") or name
                    order[#order + 1] = id
                end
                layoutDD:SetList(list, order)
                -- Restore selection
                local fl2 = BF.rpDB.profile.layouts.flatLayouts or {}
                local cur = BF._modifyingFlat
                if not (cur and fl2[cur]) then
                    cur = fl2.flat_party and "flat_party" or order[1]
                end
                if cur then layoutDD:SetValue(cur) end
            end

            layoutDD:SetCallback("OnValueChanged", function(_, _, value)
                BF._modifyingFlat = value
                BF:InvalidateRaidProfileCache()
                if BF.UpdateAuraSizeCache then BF:UpdateAuraSizeCache() end
                -- Swap the setup mode test header to match the newly selected
                -- flat. UpdateSetupFrames dispatches to the correct party or
                -- raid test header based on flat.type and re-reads size/spacing
                -- from the new modifying profile, so setup mode stays live.
                if BF.UpdateSetupFrames then BF:UpdateSetupFrames() end
                -- Also re-position the test anchor to the new modifying flat's
                -- saved anchor. Without this, swapping from a raid flat to a
                -- party flat (or any cross-flat swap) leaves testAnchorFrame at
                -- the old flat's saved position, so the freshly-built party
                -- test header renders at the raid's anchor instead of its own.
                -- The slot-assignment dropdown in Options_Layouts.lua already
                -- runs both calls for the same reason; this dropdown was
                -- missing the second call.
                if BF.UpdateAnchorPosition then BF:UpdateAnchorPosition() end
                -- The editing flat is part of the preview set; refresh.
                if BF._regeneratePreviewArgs then BF._regeneratePreviewArgs() end
                if BF.RefreshPreviewFrames      then BF:RefreshPreviewFrames()      end
                LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
            end)

            buildLayoutDDList()

            frame._BF_LayoutDD = layoutDD
            frame._BF_RefreshLayoutDDText = buildLayoutDDList

            -- "Tiny Handle" checkbox — sits just left of the status bar.
            local tinyChk = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
            tinyChk:SetSize(24, 24)
            tinyChk:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 130, 13)
            tinyChk.text:SetText("|cff11ace9Tiny Handle|r")
            tinyChk.text:SetFontObject("GameFontNormalSmall")
            tinyChk:SetScript("OnClick", function()
                if InCombatLockdown() then tinyChk:SetChecked(BF.db.global.tinyHandle); return end
                BF.db.global.tinyHandle = tinyChk:GetChecked()
                BF:ApplyTinyHandle()
            end)
            frame._BF_TinyHandleChk = tinyChk

            -- Status bar repositioning is now handled in the every-open block below
            -- so it is correctly applied on every open, not just the first.

            local xBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
            xBtn:SetSize(26, 26)
            xBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
            xBtn:SetScript("OnClick", function()
                PlaySound(799)
                aceFrame:Hide()
            end)
            frame._BF_XBtn = xBtn  -- store so OnShow/OnHide can hide it with the rest of Buzzard's chrome

            -- Floating buzzard logo anchored above the top-center of the options panel.
            -- Dragging the logo drags the whole panel with it.
            local logoSize = 64
            local logoFrame = CreateFrame("Frame", nil, UIParent)
            frame._BF_LogoFrame = logoFrame  -- store so every-open code can show/hide it
            logoFrame:SetSize(logoSize, logoSize)
            logoFrame:SetFrameStrata("DIALOG")
            logoFrame:SetFrameLevel(frame:GetFrameLevel() + 5)
            logoFrame:SetMovable(true)
            logoFrame:EnableMouse(true)
            -- Bottom-center of logo sits flush on top-center of the panel
            logoFrame:SetPoint("BOTTOM", frame, "TOP", 0, 6)

            local logoTex = logoFrame:CreateTexture(nil, "ARTWORK")
            logoTex:SetAllPoints(logoFrame)
            logoTex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\buzzardlogo")



            -- On drag start: detach both frames from their anchors and begin
            -- moving the logo. The panel is re-anchored to follow the logo.
            logoFrame:SetScript("OnMouseDown", function(self, button)
                if button ~= "LeftButton" then return end
                -- Break both frames free from their current anchors
                local fx, fy = frame:GetCenter()
                local lx, ly = logoFrame:GetCenter()
                local ux, uy = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2

                frame:ClearAllPoints()
                frame:SetPoint("CENTER", UIParent, "CENTER", fx - ux, fy - uy)

                logoFrame:ClearAllPoints()
                logoFrame:SetPoint("CENTER", UIParent, "CENTER", lx - ux, ly - uy)

                -- Re-attach panel to logo so it follows during the drag
                frame:ClearAllPoints()
                frame:SetPoint("TOP", logoFrame, "BOTTOM", 0, -6)

                logoFrame:StartMoving()
            end)

            logoFrame:SetScript("OnMouseUp", function(self, button)
                logoFrame:StopMovingOrSizing()
                -- After drag, re-anchor both frames independently so the panel
                -- is not left pinned below the logo (which would create empty
                -- space at the top of the options window).
                local lx, ly = logoFrame:GetCenter()
                local ux, uy = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2
                -- Place logo at its current absolute position
                logoFrame:ClearAllPoints()
                logoFrame:SetPoint("CENTER", UIParent, "CENTER", lx - ux, ly - uy)
                -- Re-anchor panel below logo (breaks the TOP→logo anchor from OnMouseDown)
                frame:ClearAllPoints()
                frame:SetPoint("TOP", logoFrame, "BOTTOM", 0, -6)
                -- Then immediately switch panel back to a CENTER anchor so
                -- resizing / rebuilds don't drag it around with the logo.
                local fx, fy = frame:GetCenter()
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", UIParent, "CENTER", fx - ux, fy - uy)
                -- Keep logo sitting above panel's final position
                logoFrame:ClearAllPoints()
                logoFrame:SetPoint("BOTTOM", frame, "TOP", 0, 6)
            end)

            -- Mirror the panel's visibility, but ONLY show Buzzard's chrome when
            -- the Buzzard options panel is specifically the one being displayed.
            -- AceConfigDialog-3.0 is a shared library: the same underlying frame
            -- object can be reused by any other addon that also uses Ace3.  Without
            -- this guard the OnShow hook fires whenever *any* addon opens their
            -- AceConfig panel, causing the Buzzard logo and lock button to appear
            -- on top of an unrelated addon's options window.
            local function isBuzzardPanelShown()
                local bf = ACD.OpenFrames and ACD.OpenFrames["BuzzardFrames"]
                return bf and bf.frame and bf.frame == frame and frame:IsShown()
            end

            -- Is a Raid/Party Frames sub-tab currently selected?  Used as a
            -- pre-check before consulting per-section toggles.
            local function isRaidPartySubTab()
                local st = ACD:GetStatusTable("BuzzardFrames")
                if not st or not st.groups then return false end
                local selected = st.groups.selected or ""
                -- Must start with raidPartyFrames\001 (i.e. be a child of raidPartyFrames,
                -- not the parent node itself).
                return selected:sub(1, #"raidPartyFrames\001") == "raidPartyFrames\001"
            end
            frame._BF_IsRaidPartySubTab = isRaidPartySubTab
            -- Returns the currently-selected sub-tab's args key (e.g. "frames",
            -- "framesSorting", "auras") or nil if the selection is not a
            -- Raid/Party Frames child node.
            local function getCurrentSubTab()
                local st = ACD:GetStatusTable("BuzzardFrames")
                if not st or not st.groups then return nil end
                local selected = st.groups.selected or ""
                local prefix   = "raidPartyFrames\001"
                if selected:sub(1, #prefix) ~= prefix then return nil end
                local rest = selected:sub(#prefix + 1)
                -- Take the first segment before any further \001 so nested
                -- child-group selections (if any) still map to their parent
                -- sub-tab key.
                return rest:match("^([^\001]+)") or rest
            end
            -- The "Modifying Layout" dropdown is only meaningful when the
            -- settings on the current sub-tab actually differ per-flat. That
            -- is true for:
            --   * "frames" - always per-flat by design (frame dimensions,
            --     showGroup, etc. live on the flat itself)
            --   * any section whose "Separate configuration per Layout"
            --     toggle is currently ON (BF._perLayoutSectionByTab maps the
            --     sub-tab key -> storage section key; BF:IsPerLayoutSection
            --     reads the flag).
            -- On all other sub-tabs the section is global, so picking a flat
            -- would have no effect -- hide the dropdown there.
            local function shouldShowLayoutDD()
                if not isBuzzardPanelShown() then return false end
                local st = ACD:GetStatusTable("BuzzardFrames")
                local selected = st and st.groups and st.groups.selected or ""
                -- Hide on Unit Frames, Custom Frame Groups, and Incoming Casts
                -- (including any of their sub-tabs).
                if selected == "unitFrames" or selected:sub(1, #("unitFrames\001")) == "unitFrames\001"
                or selected == "customFrames" or selected:sub(1, #("customFrames\001")) == "customFrames\001"
                or selected == "incomingCasts" or selected:sub(1, #("incomingCasts\001")) == "incomingCasts\001" then
                    return false
                end
                return true
            end
            local function refreshLayoutDDVisibility()
                if not frame._BF_LayoutDD then return end
                if shouldShowLayoutDD() then
                    frame._BF_LayoutDD.frame:Show()
                    if frame._BF_RefreshLayoutDDText then frame._BF_RefreshLayoutDDText() end
                else
                    frame._BF_LayoutDD.frame:Hide()
                end
            end
            frame._BF_RefreshLayoutDDVisibility = refreshLayoutDDVisibility

            frame:HookScript("OnShow", function()
                if isBuzzardPanelShown() then
                    -- Buzzard's panel is opening: show Buzzard chrome, hide native close button
                    logoFrame:Show()
                    if frame._BF_XBtn then frame._BF_XBtn:Show() end
                    if frame._BF_LockBtn then frame._BF_LockBtn:Show() end
                    if frame._BF_TinyHandleChk then frame._BF_TinyHandleChk:Show() end
                    if frame._BF_SetupBtn then frame._BF_SetupBtn:Show() end
                    if frame._BF_NativeCloseBtn then frame._BF_NativeCloseBtn:Hide() end
                    if frame._BF_RefreshSpecBtn then frame._BF_RefreshSpecBtn() end
                    refreshLayoutDDVisibility()
                    -- Restore status bar to Buzzard's inset position
                    local sb = aceFrame.statustext and aceFrame.statustext:GetParent()
                    if sb then
                        sb:ClearAllPoints()
                        sb:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  220, 15)
                        sb:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -15, 15)
                    end
                else
                    -- Another addon's panel is opening: hide Buzzard chrome, restore native close
                    logoFrame:Hide()
                    if frame._BF_XBtn then frame._BF_XBtn:Hide() end
                    if frame._BF_LockBtn then frame._BF_LockBtn:Hide() end
                    if frame._BF_TinyHandleChk then frame._BF_TinyHandleChk:Hide() end
                    if frame._BF_SetupBtn then frame._BF_SetupBtn:Hide() end
                    if frame._BF_LayoutDD then frame._BF_LayoutDD.frame:Hide() end
                    if frame._BF_SpecBtn then frame._BF_SpecBtn:Hide() end
                    if frame._BF_NativeCloseBtn then frame._BF_NativeCloseBtn:Show() end
                    -- Restore status bar to its original full-width position
                    local sb = aceFrame.statustext and aceFrame.statustext:GetParent()
                    if sb then
                        sb:ClearAllPoints()
                        sb:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  15, 15)
                        sb:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -15, 15)
                    end
                end
            end)
            frame:HookScript("OnHide", function()
                -- Always clean up Buzzard chrome when the frame hides
                logoFrame:Hide()
                if frame._BF_XBtn then frame._BF_XBtn:Hide() end
                if frame._BF_LockBtn then frame._BF_LockBtn:Hide() end
                if frame._BF_TinyHandleChk then frame._BF_TinyHandleChk:Hide() end
                if frame._BF_SetupBtn then frame._BF_SetupBtn:Hide() end
                if frame._BF_LayoutDD then frame._BF_LayoutDD.frame:Hide() end
                if frame._BF_SpecBtn then frame._BF_SpecBtn:Hide() end
                -- Restore native close button so the next opener (Buzzard or other) starts clean
                if frame._BF_NativeCloseBtn then frame._BF_NativeCloseBtn:Show() end
                -- Restore status bar to full width
                local sb = aceFrame.statustext and aceFrame.statustext:GetParent()
                if sb then
                    sb:ClearAllPoints()
                    sb:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  15, 15)
                    sb:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -15, 15)
                end
                -- Hide preview frames
                if self.HidePreviewFrames then self:HidePreviewFrames() end
            end)
            -- SetupOptionsPanel is only called when Buzzard's own panel is opening,
            -- so chrome will be made visible by the every-open code below this block.
        end

        -- Every time Buzzard's panel opens: show chrome, hide native close button,
        -- and reposition status bar.  These must run every open because OnHide
        -- restores the native close button and status bar to their defaults.
        if frame._BF_LogoFrame then frame._BF_LogoFrame:Show() end
        if frame._BF_XBtn then frame._BF_XBtn:Show() end
        if frame._BF_NativeCloseBtn then frame._BF_NativeCloseBtn:Hide() end
        if frame._BF_SetupBtn then
            frame._BF_SetupBtn:Show()
            if frame._BF_RefreshSetupBtnLabel then frame._BF_RefreshSetupBtnLabel() end
        end
        if frame._BF_RefreshSpecBtn then frame._BF_RefreshSpecBtn() end
        if frame._BF_RefreshLayoutDDVisibility then
            frame._BF_RefreshLayoutDDVisibility()
        end
        local sb = aceFrame.statustext and aceFrame.statustext:GetParent()
        if sb then
            sb:ClearAllPoints()
            sb:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  220, 15)
            sb:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -15, 15)
        end

        -- Refresh preview frames on every panel rebuild so they stay visible
        -- and correctly positioned regardless of which tab is selected.
        if self.RefreshPreviewFrames then self:RefreshPreviewFrames() end

        -- Update lock button label every time the panel rebuilds (lock state may have changed).
        -- Also re-show the button here since it may have been hidden when the frame was
        -- previously used by another addon (our OnHide hook hides it defensively).
        if frame._BF_LockBtn then
            local locked = self.db and self.db.profile and self.db.profile.locked
            if locked == nil then locked = true end
            frame._BF_LockBtn:SetText(locked and "|cff11ace9Unlock Frames|r" or "|cff11ace9Lock Frames|r")
            frame._BF_LockBtn:Show()
        end
        if frame._BF_TinyHandleChk then
            frame._BF_TinyHandleChk:SetChecked(self.db and self.db.profile and self.db.global.tinyHandle or false)
            frame._BF_TinyHandleChk:Show()
        end

        if not frame._BF_CloseHooked then
            frame._BF_CloseHooked = true
            -- Guard: only perform cleanup when Buzzard's own panel is hiding,
            -- not when the shared AceConfigDialog frame is reused by another addon.
            frame:HookScript("OnHide", function()
                local bf = ACD.OpenFrames and ACD.OpenFrames["BuzzardFrames"]
                if bf and bf.frame and bf.frame == frame then
                    self._layoutManualOverride = false
                    self:InvalidateRaidProfileCache()
                    self:ApplyRoleSpecLayout()
                    self:RefreshAll()
                end
            end)
        end
    end

    -- Wrap ACD.Open so SetupOptionsPanel re-runs after every rebuild
    -- triggered by NotifyChange (which calls Open internally on next frame).
    if not ACD._BF_OpenHooked then
        ACD._BF_OpenHooked = true
        local origOpen = ACD.Open
        ACD.Open = function(acd, appName, ...)
            -- Before origOpen runs, sync status.top/left to the frame's actual
            -- current position.  origOpen calls f:SetStatusTable(status) which
            -- triggers ApplyStatus() and repositions the frame to status.top/left.
            -- If the user is mid-drag when they click a widget, status.top/left
            -- still holds the position from the last MouseUp (not the current
            -- drag position), causing the snap.  Updating here prevents that.
            if appName == "BuzzardFrames" then
                local existingFrame = acd.OpenFrames and acd.OpenFrames[appName]
                if existingFrame and existingFrame.frame and existingFrame.frame:IsShown() then
                    local f = existingFrame.frame
                    local top  = f:GetTop()
                    local left = f:GetLeft()
                    if top and left then
                        local status = acd:GetStatusTable(appName)
                        status.top  = top
                        status.left = left
                    end
                end
            end
            origOpen(acd, appName, ...)
            if appName == "BuzzardFrames" then
                SetupOptionsPanel()
            end
        end
    end

    self._currentSection = "roleSpecLayouts"
    local ACD_st = ACD:GetStatusTable("BuzzardFrames")
    -- Restore saved panel size from profile so ACD:Open uses it.
    if self.db.global._optionsPanelW then ACD_st.width  = self.db.global._optionsPanelW end
    if self.db.global._optionsPanelH then ACD_st.height = self.db.global._optionsPanelH end
    -- Strip any \001 sub-path from persisted selection so Ace restores to the
    -- correct top-level node cleanly (sub-tabs within sections are remembered
    -- separately by Ace's own child status tables).
    if ACD_st.groups and ACD_st.groups.selected then
        ACD_st.groups.selected = ACD_st.groups.selected:match("^([^\001]+)") or ACD_st.groups.selected
    end
    ACD:Open("BuzzardFrames")
    SetupOptionsPanel()

    -- Hook all resize sizers to save panel size to profile when the user drags.
    -- AceGUI Frame has sizer_se (corner), sizer_s (bottom), sizer_e (right).
    local aceFrame = ACD.OpenFrames and ACD.OpenFrames["BuzzardFrames"]
    if aceFrame and aceFrame.frame and not aceFrame._bfSizerHooked then
        local function savePanelSize()
            local fr = aceFrame.frame
            if not fr then return end
            local w, h = fr:GetWidth(), fr:GetHeight()
            if w and w > 0 then BF.db.global._optionsPanelW = w end
            if h and h > 0 then BF.db.global._optionsPanelH = h end
        end
        if aceFrame.sizer_se then aceFrame.sizer_se:HookScript("OnMouseUp", savePanelSize) end
        if aceFrame.sizer_s  then aceFrame.sizer_s:HookScript("OnMouseUp", savePanelSize) end
        if aceFrame.sizer_e  then aceFrame.sizer_e:HookScript("OnMouseUp", savePanelSize) end
        aceFrame._bfSizerHooked = true
    end
end

