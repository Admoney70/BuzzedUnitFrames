--[[
BuzzardFrames: Indicators/NameText.lua
Name text indicator — mirrors Grid2's IndicatorText.lua pattern.

Creates a FontString on each frame, positions it per profile settings,
and updates it from UnitName.

Each call to Update unconditionally overwrites stale state (Grid2 pattern).
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitClass           = UnitClass
local UnitIsAFK           = UnitIsAFK
local issecretvalue       = issecretvalue or function() return false end
local canaccessvalue      = canaccessvalue or function() return true end

-- Grid2 pattern (GridUtils.lua strcututf8): UTF-8 safe string truncation.
-- Counts characters (not bytes) so multi-byte characters are never split.
local strbyte = string.byte
local function strcututf8(s, c)
    if issecretvalue(s) then return s end
    local l, i = #s, 1
    while c > 0 and i <= l do
        local b = strbyte(s, i)
        if     b < 192 then i = i + 1
        elseif b < 224 then i = i + 2
        elseif b < 240 then i = i + 3
        else                i = i + 4
        end
        c = c - 1
    end
    return s:sub(1, i - 1)
end

-- Grid2 pattern: count UTF-8 characters (not bytes).
local function strlenutf8(s)
    if issecretvalue(s) then return 0 end
    local l, i, count = #s, 1, 0
    while i <= l do
        local b = strbyte(s, i)
        if     b < 192 then i = i + 1
        elseif b < 224 then i = i + 2
        elseif b < 240 then i = i + 3
        else                i = i + 4
        end
        count = count + 1
    end
    return count
end

local NameText = BF.indicatorPrototype:new("nameText")

-- ============================================================
-- Create
-- ============================================================
function NameText:Create(parent)
	-- Skip if already created by legacy InitFrame
	if parent.nameText then
		parent[self.name] = parent.nameText
		return
	end

	-- Parent to a clip frame anchored to the health bar so long names
	-- don't overflow the frame edges.
	local textFrame = parent.textFrame
	if not textFrame then
		textFrame = CreateFrame("Frame", nil, parent)
		textFrame:SetAllPoints(parent)
		textFrame:SetFrameLevel(parent:GetFrameLevel() + 216)
		textFrame:EnableMouse(false)
		parent.textFrame = textFrame
	end

	local hBar = parent.healthBar
	local clipParent = textFrame
	if hBar then
		local nameClip = parent.nameClip
		if not nameClip then
			nameClip = CreateFrame("Frame", nil, textFrame)
			nameClip:SetAllPoints(parent.container or hBar)
			nameClip:SetFrameLevel(parent:GetFrameLevel() + 217)
			nameClip:EnableMouse(false)
			nameClip:SetClipsChildren(true)
			parent.nameClip = nameClip
		end
		clipParent = nameClip
	end

	local fs = clipParent:CreateFontString(nil, "OVERLAY")
	fs:SetFontObject(GameFontNormalSmall)
	local defaultFont, defaultSize, defaultFlags = fs:GetFont()
	defaultFont = defaultFont or BF.font or "Fonts\\FRIZQT__.TTF"
	defaultSize = defaultSize or 10
	defaultFlags = defaultFlags or ""
	fs:SetShadowOffset(1, -1)
	fs:SetShadowColor(0, 0, 0, 1)
	fs.SF_defaultFont  = defaultFont
	fs.SF_defaultSize  = defaultSize
	fs.SF_defaultFlags = defaultFlags
	fs:SetJustifyH("CENTER")
	fs:SetWordWrap(false)

	if hBar then
		local anchor = parent.container or hBar
		fs:SetPoint("CENTER", anchor, "CENTER", 0, 0)
	else
		fs:SetPoint("CENTER", parent, "CENTER", 0, 0)
	end

	parent[self.name] = fs
	parent.nameText = fs  -- backward compat alias
end

-- ============================================================
-- Layout
-- ============================================================
function NameText:Layout(parent)
	local fs = parent[self.name]
	if not fs then return end

	-- Route by frame: preview frames resolve to their own flat (set via
	-- parent._flatID) so the options preview reflects per-layout edits;
	-- live frames resolve via active game context, matching NameText:Update.
	-- See BF:GetSectionProfileForFrame for the full breakdown.
	local tp = BF:GetSectionProfileForFrame("text", parent)
	local ip = BF:GetSectionProfileForFrame("icons", parent)
	local bp = BF:GetSectionProfileForFrame("borders", parent)
	if not tp then return end
	if not tp.namePosition then return end

	local hBar = parent.healthBar
	local np = tp.namePosition

	-- Re-assert the clip frame's anchoring on EVERY Layout. nameClip was
	-- previously anchored exactly once, at Create — against a container
	-- texture that had no anchors yet (Container:Layout runs later), under
	-- a hidden, unpositioned header at login. With SetClipsChildren(true), a
	-- clip rect resolved in that window can clip a perfectly painted name to
	-- nothing, and NO code path ever re-anchored it on a live frame — which
	-- is why every FontString-side fix failed for the affected user while
	-- merely MOVING the frames (a pure engine re-anchor of the ancestry)
	-- healed it. ClearAllPoints+SetAllPoints forces the engine to rebuild
	-- the clip rect from current geometry each time Layout runs (build,
	-- OnUnitChanged, LoadLayout deferred tail, resize).
	local nameClip = parent.nameClip
	if nameClip then
		nameClip:ClearAllPoints()
		nameClip:SetAllPoints(parent.container or hBar or parent)
	end

	-- Font. Configured font is cached on the FontString itself (Grid2
	-- pattern: layout state lives on the indicator's own widgets, e.g.
	-- IndicatorText caches textlength on self). The old parent._nameFont*
	-- snapshots — replayed by Update on every paint — are GONE: that replay
	-- was the stale-state bug class this refactor exists to eliminate
	-- (plan D1). Update never touches font except the Cyrillic fallback,
	-- which reads these fs-scoped values.
	local origFont  = fs.SF_defaultFont  or "Fonts\\FRIZQT__.TTF"
	local origSize  = fs.SF_defaultSize  or 10
	local origFlags = fs.SF_defaultFlags or ""
	local cfgFont, cfgSize, cfgFlags
	if tp.adjustNameFont then
		cfgFont  = BF:ResolveFontPath(tp.nameFont)
		cfgSize  = tp.nameFontSize
		cfgFlags = tp.nameFontBorder or ""
	else
		cfgFont, cfgSize, cfgFlags = origFont, origSize, origFlags
	end
	fs:SetFont(cfgFont, cfgSize, cfgFlags)
	fs._cfgFontPath  = cfgFont
	fs._cfgFontSize  = cfgSize
	fs._cfgFontFlags = cfgFlags

	-- Anchor
	local anchorPoint = np.point or "CENTER"
	if not tp.linkNameAndRole then
		fs:ClearAllPoints()
		local nameX = np.x or 0
		local nameY = np.y or 0
		local rp = (ip and ip.roleIconPosition) or { point = "TOPLEFT", x = 2, y = -2 }
		-- Default to icon-visible offset if the global toggle is on.
		-- RoleIcon:Update will correct with AdjustNameForHiddenRole
		-- for units where the icon ends up hidden (per-role filter, NONE role, etc.).
		if ip and ip.showRoleIcons then
			if np.point == rp.point then
				local rpX = rp.x or 0
				if np.point:find("LEFT") then nameX = nameX + (ip.roleIconSize or 12) + 1 + rpX
				elseif np.point:find("RIGHT") then nameX = nameX - (ip.roleIconSize or 12) - 1 + rpX end
			end
		else
			-- Role icons globally off: apply small inset so name isn't flush with frame edge
			if np.point == rp.point then
				if np.point:find("LEFT") then nameX = nameX + 3
				elseif np.point:find("RIGHT") then nameX = nameX - 3 end
			end
		end
		local vAnchor
		if anchorPoint:find("TOP") then vAnchor = "TOP"
		elseif anchorPoint:find("BOTTOM") then vAnchor = "BOTTOM"
		else vAnchor = "" end
		local pinPoint = vAnchor ~= "" and (vAnchor .. "LEFT") or "LEFT"
		local anchor = parent.container or hBar or parent
		fs:SetPoint(pinPoint, anchor, pinPoint, nameX, nameY)
		-- This unit's role icon is currently hidden (per-role filter,
		-- NONE role, pet frame): the icon-offset anchor above is wrong
		-- for it. Re-apply the hidden-role position now — RoleIcon only
		-- corrects on role/roster events, which don't follow a plain
		-- LayoutFrame sweep (e.g. border-color setters).
		if parent._roleIconNameAdjusted and BF.ReapplyHiddenRoleNameAdjust then
			BF:ReapplyHiddenRoleNameAdjust(parent)
		end
	end

	-- Width. Set ONLY here — Update never writes width (Grid2:
	-- IndicatorText.lua:130 sets width in layout, Text_SetText never
	-- does). Width persists on the FontString; SetText does not reset it.
	-- No parent._nameWidth snapshot: a build-time width pinned there and
	-- replayed per paint was the first-login invisible-name mechanism.
	-- Staleness is healed by re-running Layout on resize/profile changes
	-- (plan Phase 4), not by replaying a possibly-bad value forever.
	local header = parent:GetParent()
	local w = header and header.frameWidth or parent:GetWidth()
	-- EffectiveBorderPixels: rounded border styles use fixed 2/3px art
	-- thickness (must agree with Container:Layout's content inset).
	local borderN = BF:EffectiveBorderPixels(bp)
	local borderUI = BF:PixelsToUI(borderN)
	local barW = w - borderUI * 2
	if barW > 0 then
		fs:SetWidth(barW)
	end
	fs:SetMaxLines(1)

	-- Justify
	if anchorPoint:find("TOP") then fs:SetJustifyV("TOP")
	elseif anchorPoint:find("BOTTOM") then fs:SetJustifyV("BOTTOM")
	else fs:SetJustifyV("MIDDLE") end

	-- CRITICAL WoW QUIRK: SetFont resets JustifyH to its default (LEFT).
	-- SetJustifyH must therefore come AFTER the final SetFont call.
	-- Additionally, WoW will silently no-op a SetFont call if the font
	-- path/size/flags haven't changed from the current values — meaning
	-- the JustifyH reset never fires, and the subsequent SetJustifyH call
	-- also fails to "stick" because WoW thinks nothing changed.
	-- The fix (same pattern used in refreshNameFont in Options_Text.lua):
	-- briefly switch to a DIFFERENT font first, then set the real font.
	-- This forces WoW to flush the render state and pick up the new
	-- JustifyH reliably. DO NOT remove this two-step SetFont pattern
	-- or JustifyH changes will silently stop working on preview frames
	-- (and potentially real frames too if the font hasn't changed).
	local fp = fs._cfgFontPath
	local fz = fs._cfgFontSize
	local ff = fs._cfgFontFlags or ""
	if fp and fz then
		local altFont = (fp == (fs.SF_defaultFont or "")) and "Fonts\\FRIZQT__.TTF" or (fs.SF_defaultFont or "Fonts\\FRIZQT__.TTF")
		fs:SetFont(altFont, fz, ff)
		fs:SetFont(fp, fz, ff)
	end

	local justH
	if anchorPoint:find("LEFT") then justH = "LEFT"
	elseif anchorPoint:find("RIGHT") then justH = "RIGHT"
	else justH = "CENTER" end
	fs:SetJustifyH(justH)
end

-- ============================================================
-- Update — Grid2 shape (IndicatorText.lua Text_OnUpdate/Text_SetText).
--
-- STATELESS: no snapshot replays, no per-paint option branching, no
-- geometry writes. Text options come from the composed entry memoized
-- per section-table (BFStatus.lua Name:GetComposed — Grid2's UpdateDB
-- closure swap adapted for BF's per-flat/CFG profile model). Geometry
-- and font live exclusively in Layout; a bad early paint is healed by
-- the next repaint instead of replaying captured state forever.
--
-- Deliberate BF features preserved on top of the Grid2 shape (each
-- config-gated, off by default unless noted):
--   * per-frame pet-name semantics (pet header shows pet name; the same
--     pet token on a main header — vehicle swap — shows the owner)
--   * append-status-to-name handoff (StatusText_Overlay composes)
--   * reduced-max-health "(NN%)" append
--   * Cyrillic fallback font when transliteration is off
--   * showName visibility (owned HERE now; StatusText_Overlay no longer
--     hides the name — plan Phase 3)
-- ============================================================
-- Per-frame pet-header resolution, cached once per frame: a frame never
-- migrates between headers, so parent's header.isPetFrame is static.
-- Replaces the per-paint frames_of_unit scan (plan D5, review M11).
local function IsPetHeaderFrame(parent)
	local isPet = parent._bf_isPetHeader
	if isPet == nil then
		local header = parent:GetParent()
		isPet = (header and header.isPetFrame) and true or false
		parent._bf_isPetHeader = isPet
	end
	return isPet
end

-- Status-state resolution (BF append/color features). Offline and dead
-- are read from their status objects (cache reads, never the unit APIs);
-- the AFK read is secret-guarded and a secret state counts as "not AFK".
-- Shared by Update and UpdateColor.
local function ComputeStatusState(unit, entry)
	local offlineStatus = BF.statuses and BF.statuses.offline
	local deathStatus   = BF.statuses and BF.statuses.death
	local isOffline = offlineStatus and offlineStatus:IsActive(unit)
	local isDead    = deathStatus and deathStatus:IsActive(unit) or false
	local isAFK = false
	if entry.showAFK and UnitIsAFK then
		local afkVal = UnitIsAFK(unit)
		isAFK = canaccessvalue(afkVal) and afkVal == true
	end
	return isOffline or isDead or isAFK
end

-- ============================================================
-- Color companion — the SINGLE writer for nameText color/alpha
-- (Grid2 TextColor sidekick role, IndicatorText.lua:320-329).
--
-- Consolidates the three previous writers (plan 2.3/3.4, review M3):
--   * NameText's own base color (class/custom/white)
--   * LayoutFrame ApplyStatusColorToName (offline color + offline fade
--     alpha) — now a thin wrapper delegating here
--   * RangeAlpha's OOR text adjustments for the NAME (gray-blended
--     offline/dead colors, OOR alpha) — RangeAlpha keeps its
--     statusText-only writes and delegates the name here
--
-- Resolution order (deterministic; replaces the old trigger-order fights):
--   1. base: defer when a status state is active and
--      applyStatusColorsToNames is on (StatusText_Overlay paints the
--      status color); else class/custom/white, alpha 1
--   2. offline override: offline color (class variant), gray-blended
--      when out of range; alpha = offline fade
--   3. dead override: dead color only in append mode (as RangeAlpha
--      did), blended when OOR; alpha = deadColorOORFactor when OOR
--      (non-player), else 1
--   4. Swiftmend latch: suppresses ALL color writes (alpha still applies)
--   5. reduced-max append color override (Update path only)
--
-- OOR state reads the raw rangeCache exactly as RangeAlpha did: a secret
-- value counts as in-range (adjustments skipped), never branched on.
-- ============================================================
local function ApplyNameColor(parent, unit, fs, entry, inStatusState, nameStatus, reducedOverride)
	local hp = BF:GetCachedSection("healthPower", parent)

	-- OOR from the raw rangeCache. A SECRET value resolves to in-range: the
	-- plain (non-blended) outcomes are applied rather than skipping writes
	-- entirely — deterministic, and only non-secret values are ever written.
	local raw = BF.rangeCache and BF.rangeCache[unit]
	local oor = raw ~= nil and not issecretvalue(raw) and raw == false

	local r, g, b   -- nil = leave color untouched
	local alpha     -- nil = leave alpha untouched

	-- 1. Base. Defer in append mode too (review B1): in append mode the
	-- overlay owns the composed text's color (AFK/offline/dead tints), and
	-- there is no AFK override below to restore it — writing class/white here
	-- clobbered the AFK color on every range tick. Overrides still layer.
	if not (inStatusState and (entry.applyStatusColors or entry.append)) then
		alpha = 1
		if entry.adjustColors then
			if entry.classColor then
				r, g, b = nameStatus:GetClassColor(unit)
			end
			if not r then
				local nc = entry.nameColor
				if nc then
					r, g, b = nc.r, nc.g, nc.b
					-- v65: Name Color alpha channel — rides the same
					-- alpha slot the fade states use; the status alphas
					-- below still take precedence.
					alpha = nc.a or 1
				else r, g, b = 1, 1, 1 end
			end
		else
			r, g, b = 1, 1, 1
		end
	end

	-- 2. Offline handling. Offline-first precedence (review M3): a unit that
	-- died and then disconnected is still dead in the death cache, and
	-- painting dead color over an offline name is wrong — offline owns the
	-- frame, so it is tested first and the dead branch is the else.
	--
	-- Alpha: fade whenever the fade option is on (old ApplyStatusColorToName).
	-- Color: ONLY under applyStatusColorsToNames (review M1 — strict parity:
	-- the two live legacy writers both gated color on it; old RangeAlpha's
	-- ungated offline color write was unreachable dead code, cut off by its
	-- own offline early-return). The OOR gray-blend applies to that gated
	-- color, matching the fade option's documented OOR color retention.
	local deathStatus = BF.statuses and BF.statuses.death
	if parent._offline then
		if entry.fadeOfflineName and not (hp and hp.fadeOfflineFrames) then
			alpha = (hp and hp.rangeFadeAlpha) or 0.4
		end
		if inStatusState and entry.applyStatusColors then
			local _, cn = UnitClass(unit)
			-- 12.1: a secret class name is truthy but cannot index a table.
			if not canaccessvalue(cn) then cn = nil end
			local classColor = entry.offlineUseClass and cn and BF.classColors and BF.classColors[cn]
			local c = classColor or entry.offlineColor or { r=0.5, g=0.5, b=0.5 }
			local cr, cg, cb = c.r, c.g, c.b
			if oor then
				local f2 = hp and hp.deadColorOORFactor
				if f2 == nil then f2 = 0.5 end
				local gray = (cr + cg + cb) / 3
				cr = cr * f2 + gray * (1 - f2)
				cg = cg * f2 + gray * (1 - f2)
				cb = cb * f2 + gray * (1 - f2)
			end
			r, g, b = cr, cg, cb
		end
	elseif deathStatus and deathStatus:IsActive(unit) then
		-- 3. Dead override (RangeAlpha:161-181/:198-213). Name color only in
		-- append mode, exactly as RangeAlpha wrote it; alpha regardless.
		if entry.append then
			local _, cn = UnitClass(unit)
			-- 12.1: a secret class name is truthy but cannot index a table.
			if not canaccessvalue(cn) then cn = nil end
			local classColor = entry.deadUseClass and cn and BF.classColors and BF.classColors[cn]
			local c = classColor or entry.deadColor or { r=0.8, g=0.1, b=0.1 }
			local cr, cg, cb = c.r, c.g, c.b
			if oor then
				local f2 = hp and hp.deadColorOORFactor
				if f2 == nil then f2 = 0.5 end
				local gray = (cr + cg + cb) / 3
				cr = cr * f2 + gray * (1 - f2)
				cg = cg * f2 + gray * (1 - f2)
				cb = cb * f2 + gray * (1 - f2)
			end
			r, g, b = cr, cg, cb
		end
		if oor and unit ~= "player" then
			local f2 = hp and hp.deadColorOORFactor
			if f2 == nil then f2 = 0.5 end
			alpha = f2
		else
			alpha = 1
		end
	end

	-- 4. Swiftmend latch REMOVED: _bf_swiftmendNameActive was set only by
	-- BF:UpdateSwiftmendable, the pre-12.1 Lua recolor path. On 12.1 the name
	-- recolor is an engine-driven MIRROR FontString on the fxSM slot
	-- (BuffsAndContainers.lua, "nm" fx kind) laid OVER this one, so nothing
	-- here needs to yield the color any more.

	-- 5. Reduced-max append color (Update path only)
	if reducedOverride then
		r, g, b = reducedOverride.r, reducedOverride.g, reducedOverride.b
	end

	if r then fs:SetTextColor(r, g, b) end
	if alpha then fs:SetAlpha(alpha) end
end

function NameText:Update(parent, unit)
	local fs = parent[self.name]
	if not fs then return end

	-- Memoized section lookup (never caches nil, so this cannot latch —
	-- a nil tp here is re-resolved on the very next repaint).
	local tp = BF:GetCachedSection("text", parent)
	if not tp then return end

	local nameStatus = BF.statuses and BF.statuses.name
	if not unit or not nameStatus then return end

	local entry = nameStatus:GetComposed(tp)

	-- showName: visibility is owned here now (was StatusText_Overlay's
	-- nameText:Hide()). Default true; hidden frames are re-Shown by the
	-- next Update after the option is re-enabled (RefreshAllNames).
	if not entry.showName then
		fs:Hide()
		return
	end

	local inStatusState = ComputeStatusState(unit, entry)

	if inStatusState and entry.append then
		-- Append mode: StatusText_Overlay composes and owns "Name (Dead)"
		-- text + color. Non-blanking defer — the composed string stays.
		fs:Show()
		return
	end

	-- Resolve name unit: BF per-frame pet semantics (see header comment).
	local nameUnit = unit
	local owners = BF.owner_of_unit
	local owner = owners and owners[unit]
	if owner and not IsPetHeaderFrame(parent) then
		nameUnit = owner
	end

	local name = entry.getText(nameUnit)

	-- Secret name: pass straight through — every string op below is
	-- forbidden on secrets. getText composition is internally guarded.
	if issecretvalue(name) then
		fs:SetText(name)
		ApplyNameColor(parent, unit, fs, entry, inStatusState, nameStatus, nil)
		fs:Show()
		return
	end

	-- Cyrillic fallback font (BF feature): when transliteration is OFF
	-- and the name contains Cyrillic, swap to the fallback font; restore
	-- the configured font otherwise. Uses Layout's fs-scoped config cache
	-- — no parent snapshots.
	if name and BF.HasCyrillic and BF:HasCyrillic(name) then
		if not entry.translit then
			local fallback = BF.cyrillicFont or BF.font
			fs:SetFont(fallback, fs._cfgFontSize or 10, fs._cfgFontFlags or "")
		end
	elseif fs._cfgFontPath then
		fs:SetFont(fs._cfgFontPath, fs._cfgFontSize or 10, fs._cfgFontFlags or "")
	end

	-- Reduced-max-health append (BF feature; status bound conditionally
	-- in RebindAbsorbStatuses so _reducedMaxPct changes repaint us).
	local reducedOverride
	local ab = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.absorbs
	local rPct = parent._reducedMaxPct
	if ab and ab.showReducedMaxHealthText and ab.appendReducedMaxText
	   and ab.appendReducedMaxTarget == "name"
	   and rPct and not issecretvalue(rPct) and rPct > 0
	   and name then
		local remainPct = math.floor((1 - rPct) * 100 + 0.5)
		local label = string.format("%d%%", remainPct)
		if entry.append and BF.AppendStatus then
			name = BF.AppendStatus(name, label, parent)
		else
			name = name .. " (" .. label .. ")"
		end
		-- (parent._reducedMaxNameColor is no longer written: the override is
		-- passed directly to ApplyNameColor and the field has zero readers.)
		reducedOverride = ab.reducedMaxHealthTextColor
	end

	-- Truncate (Grid2 strcututf8 shape, gated on abbreviateNames — B3).
	if name and entry.maxChars and strlenutf8(name) > entry.maxChars then
		name = strcututf8(name, entry.maxChars)
	end

	-- Grid2 Text_SetText: unconditional write, empty string for nil.
	fs:SetText(name or "")

	ApplyNameColor(parent, unit, fs, entry, inStatusState, nameStatus, reducedOverride)
	fs:Show()
end

-- ============================================================
-- Public color-only entry point — the companion's external trigger.
-- Called by RangeAlpha on range flips and by BF:ApplyStatusColorToName
-- (thin wrapper) from the RefreshAll funnels. Recomputes and applies
-- color+alpha without touching text/visibility.
-- ============================================================
function NameText:UpdateColor(parent, unit)
	local fs = parent[self.name]
	if not fs then return end
	local tp = BF:GetCachedSection("text", parent)
	if not tp then return end
	local nameStatus = BF.statuses and BF.statuses.name
	if not unit or not nameStatus then return end
	local entry = nameStatus:GetComposed(tp)
	if not entry.showName then return end
	local inStatusState = ComputeStatusState(unit, entry)
	-- No append-mode early return here, deliberately: in append mode the
	-- overlay owns text + base color, but the offline/dead OOR overrides
	-- were always layered ON TOP by RangeAlpha (its dead name-color write
	-- was explicitly append-gated). ApplyNameColor reproduces that layering:
	-- base defers via applyStatusColors, overrides still apply.
	ApplyNameColor(parent, unit, fs, entry, inStatusState, nameStatus, nil)
end

BF:RegisterIndicator(NameText)
