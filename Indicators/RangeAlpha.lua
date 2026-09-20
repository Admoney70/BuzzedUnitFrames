-- BuzzardFrames: Indicators/RangeAlpha.lua
-- Grid2 IndicatorAlpha.lua pattern: uses EvaluateColorValueFromBoolean
-- to resolve secret booleans into alpha values without branching.

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitClass       = UnitClass
local EvaluateColorValueFromBoolean = C_CurveUtil.EvaluateColorValueFromBoolean
-- 12.1: a secret class name is truthy but cannot index a table — guard
-- before every BF.classColors[cn] lookup below.
local canaccessvalue  = canaccessvalue or function() return true end
local issecretvalue   = issecretvalue  or function() return false end

local RangeAlpha = BF.indicatorPrototype:new("rangeAlpha")

-- ============================================================
-- Dark overlay for out-of-range darkening.
-- ============================================================
local function EnsureDarkenOverlay(parent)
	local df = parent._oorDarkenFrame
	if df then return df end
	df = CreateFrame("Frame", nil, parent)
	-- Frames are SHOWN by default. Hide FIRST and register on the parent
	-- BEFORE anything fallible: the old order painted the frame fully
	-- black while still shown and only assigned parent._oorDarkenFrame as
	-- the very last step, so any error in between stranded a permanently
	-- visible opaque overlay that HideDarkenOverlay could never reach (it
	-- looks up the parent field, which was never set).
	df:Hide()
	parent._oorDarkenFrame = df
	df:SetAllPoints(parent)
	df:SetFrameLevel(parent:GetFrameLevel() + 250)
	df:EnableMouse(false)
	local tex = BF.Texture(df, nil, "OVERLAY", nil, 7)
	tex:SetAllPoints(df)
	tex:SetColorTexture(0, 0, 0, 1)
	df._tex = tex  -- exposed for the rounded-mask walk (EachMaskableRegion)
	-- Rounded border style: clip the darken fill to the frame's rounded
	-- shape (attach-once; inert while the mask is hidden).
	BF:AttachFrameRoundMask(parent, tex)
	return df
end

local function HideDarkenOverlay(parent)
	if parent._oorDarkenFrame then
		parent._oorDarkenFrame:Hide()
	end
end

-- ============================================================
-- ApplyRangeEffects — THE single writer for both range effects.
--
-- Frame alpha (range fade) and the OOR darken overlay are two sinks
-- driven by ONE (state, invert) pair: both writes happen here, back to
-- back, so they cannot diverge. No other code may write range alpha or
-- touch the darken overlay — live paths and the options preview both
-- funnel through this function (preview via BF:ApplyRangeEffects).
--
-- Grid2 comparison: the alpha arm is Grid2's IndicatorAlpha
-- Alpha_UpdateStandard verbatim — EvaluateColorValueFromBoolean's
-- result passed straight to SetAlpha, never compared or branched on
-- (secret-safe). Grid2 has no OOR darken feature; the darken arm
-- applies the identical pattern to the overlay's FRAME alpha.
--
--   state=true (in range):  parent alpha 1,          darken alpha 0
--   state=false (OOR):      parent alpha fadeAlpha,  darken alpha darkenAmount
--   (invert=false flips the argument order, as in Grid2)
--
-- fadeAlpha=1, darkenAmount=0 is the reset:
--   ApplyRangeEffects(parent, true, true, 1, 0)
-- ============================================================
local function ApplyRangeEffects(parent, state, invert, fadeAlpha, darkenAmount)
	-- ── Alpha (Grid2 IndicatorAlpha verbatim) ──────────────────
	if invert then
		parent:SetAlpha(EvaluateColorValueFromBoolean(state, 1, fadeAlpha))
	else
		parent:SetAlpha(EvaluateColorValueFromBoolean(state, fadeAlpha, 1))
	end
	-- ── Darkening overlay (same pattern, same state) ───────────
	if darkenAmount > 0 then
		local df = EnsureDarkenOverlay(parent)
		if invert then
			df:SetAlpha(EvaluateColorValueFromBoolean(state, 0, darkenAmount))
		else
			df:SetAlpha(EvaluateColorValueFromBoolean(state, darkenAmount, 0))
		end
		df:Show()
	else
		HideDarkenOverlay(parent)
	end
end

-- Public entry for the options preview (Options_PreviewSystem /
-- Options_PreviewData). Preview passes plain booleans as state
-- (false = simulate OOR). This replaced BF:DarkenPreviewFrame, which
-- was a second, divergent darken implementation that wrote the
-- overlay TEXTURE's alpha while the live path writes the overlay
-- FRAME's alpha — same visual, two mechanisms.
function BF:ApplyRangeEffects(parent, state, invert, fadeAlpha, darkenAmount)
	ApplyRangeEffects(parent, state, invert, fadeAlpha, darkenAmount)
end

function RangeAlpha:Create(parent)
	parent[self.name] = parent
end

function RangeAlpha:Layout(parent)
end

-- ============================================================
-- Update: Grid2 IndicatorAlpha pattern.
--
-- Grid2's IndicatorAlpha:
--   1. Gets (state, invert) from each bound status
--   2. Calls EvaluateColorValueFromBoolean to compute alpha
--   3. Calls SetAlpha with the result
--   4. NEVER compares or branches on the result
--
-- The darkening overlay follows the same pattern: compute alpha
-- via EvaluateColorValueFromBoolean, pass directly to SetAlpha.
-- ============================================================
function RangeAlpha:Update(parent, unit)
	if not parent or not unit then return end

	local hp = BF:GetSectionProfileForFrame("healthPower", parent)
	local tp = BF:GetSectionProfileForFrame("text", parent)
	if not hp then return end

	-- Both features off: reset everything.
	if not hp.enableRangeFade and not hp.enableRangeDesaturate then
		ApplyRangeEffects(parent, true, true, 1, 0)
		return
	end

	-- Player is always in range.
	if unit == "player" then
		ApplyRangeEffects(parent, true, true, 1, 0)
		return
	end

	-- Offline units. "Offline" is the offline STATUS (its cache), the same
	-- source the overlay and the name text use, so frame alpha can never
	-- disagree with them. fadeOfflineFrames ("Apply range fading to offline
	-- unit frames") lives in healthPower (its widget is on the Health &
	-- Power tab, so it obeys the healthPower per-layout toggle).
	--   ON  = offline frames are ALWAYS faded, regardless of range.
	--   OFF = offline frames are EXCLUDED from range fading: full alpha, no
	--         darken. The game gives nothing to measure here — verified in
	--         game, UnitInRange reports a disconnected member whose character
	--         has left the world as CHECKED and out of range, exactly like a
	--         living player 50 yards away, so "actually out of range" cannot
	--         be told apart from "gone". Falling through would fade every
	--         offline frame (that is what the range status records), which
	--         is the ON behavior; OFF therefore declines to fade rather than
	--         guessing.
	-- fadeAlpha is ALSO consumed by the statusText adjustments below,
	-- where it applies even with enableRangeFade off (old behavior) —
	-- so the enableRangeFade gate is folded into the ARGUMENT (1 = no
	-- fade), not into this variable. Resolved here, above the offline
	-- branch, so the offline ON case and the out-of-range case are fed
	-- the SAME arguments.
	local fadeAlpha = hp.rangeFadeAlpha or 0.4
	local darkenAmount = hp.enableRangeDesaturate and (hp.rangeDesaturation or 0.5) or 0

	local offlineStatus = BF.statuses and BF.statuses.offline
	if offlineStatus and offlineStatus:IsActive(unit) then
		if hp.fadeOfflineFrames then
			-- state=false with exactly the out-of-range arguments: same fade
			-- alpha, same darken overlay, same enable toggles. An offline
			-- frame must be indistinguishable from an out-of-range one.
			ApplyRangeEffects(parent, false, true,
				hp.enableRangeFade and fadeAlpha or 1, darkenAmount)
		else
			ApplyRangeEffects(parent, true, true, 1, 0)
		end
		return
	end

	-- Grid2 pattern: get state from the range status.
	-- Range:IsActive returns (cache[unit], true) — true means inverted.
	local rangeStatus = BF.statuses and BF.statuses.range
	if not rangeStatus then
		ApplyRangeEffects(parent, true, true, 1, 0)
		return
	end

	local state, invert = rangeStatus:IsActive(unit)

	-- Both effects, one writer, one state — they cannot diverge.
	-- state may be secret; ApplyRangeEffects never compares it.
	ApplyRangeEffects(parent, state, invert,
		hp.enableRangeFade and fadeAlpha or 1, darkenAmount)

	-- ── OOR text color adjustments ─────────────────────────────
	-- REFACTOR (plan 2.3/3.4): this indicator no longer writes to
	-- nameText. All name color/alpha — including the OOR gray-blend and
	-- fade logic that used to live here — is owned by NameText's color
	-- companion; we delegate so range flips still trigger it. Only the
	-- statusText adjustments (which NameText does not own) remain below.
	do
		local nameInd = BF.GetIndicatorByName and BF:GetIndicatorByName("nameText")
		if nameInd and nameInd.UpdateColor then
			nameInd:UpdateColor(parent, unit)
		end
	end

	-- statusText adjustments require knowing OOR as a non-secret boolean.
	-- If the raw rangeCache value is secret we skip them (the alpha fade
	-- handles visibility). NameText's companion does its own secret-safe
	-- read, so the delegation above is NOT gated on this.
	local rawInRange = BF.rangeCache and BF.rangeCache[unit]
	if issecretvalue(rawInRange) then
		return
	end

	local oor = (rawInRange == false)
	local deathStatus = BF.statuses and BF.statuses.death

	if oor then
		if parent._offline and tp and tp.fadeOfflineNameText and not (hp and hp.fadeOfflineFrames) then
			local _, cn = UnitClass(unit)
			if not canaccessvalue(cn) then cn = nil end
			local classColor = tp.offlineColorUseClassColor and cn and BF.classColors and BF.classColors[cn]
			local offlineTextColor = classColor or tp.offlineColor or { r=0.5, g=0.5, b=0.5 }
			local f2 = hp and hp.deadColorOORFactor
			if f2 == nil then f2 = 0.5 end
			local gray = (offlineTextColor.r + offlineTextColor.g + offlineTextColor.b) / 3
			local r = offlineTextColor.r * f2 + gray * (1 - f2)
			local g = offlineTextColor.g * f2 + gray * (1 - f2)
			local b = offlineTextColor.b * f2 + gray * (1 - f2)
			if parent.statusText and parent.statusText:IsShown() then
				parent.statusText:SetTextColor(r, g, b)
				parent.statusText:SetAlpha(fadeAlpha)
			end
		end
		if deathStatus and deathStatus:IsActive(unit) then
			local _, cn = UnitClass(unit)
			if not canaccessvalue(cn) then cn = nil end
			local classColor = tp and tp.deadColorUseClassColor and cn and BF.classColors and BF.classColors[cn]
			local deadTextColor = classColor or (tp and tp.deadColor) or { r=0.8, g=0.1, b=0.1 }
			local f2 = hp and hp.deadColorOORFactor
			if f2 == nil then f2 = 0.5 end
			local gray = (deadTextColor.r + deadTextColor.g + deadTextColor.b) / 3
			local r = deadTextColor.r * f2 + gray * (1 - f2)
			local g = deadTextColor.g * f2 + gray * (1 - f2)
			local b = deadTextColor.b * f2 + gray * (1 - f2)
			if parent.statusText then
				local st = parent.statusText
				st:SetTextColor(r, g, b)
				-- Out of range: outline off. Path and size come from the
				-- StatusOverlay:Layout cache, never from GetFont() -- a
				-- GetFont -> SetFont round trip on every range tick shrank the
				-- height over time (see StatusOverlay:Layout).
				if st._cfgFontPath then
					st:SetFont(st._cfgFontPath, st._cfgFontSize, "")
				end
			end
		end
	else
		if parent._offline and tp and tp.fadeOfflineNameText and not (hp and hp.fadeOfflineFrames) then
			local _, cn = UnitClass(unit)
			if not canaccessvalue(cn) then cn = nil end
			local classColor = tp.offlineColorUseClassColor and cn and BF.classColors and BF.classColors[cn]
			local offlineTextColor = classColor or tp.offlineColor or { r=0.5, g=0.5, b=0.5 }
			local offlineFadeAlpha = (tp.fadeOfflineNameText and not (hp and hp.fadeOfflineFrames)) and (fadeAlpha or 0.4) or 1
			if parent.statusText and parent.statusText:IsShown() then
				parent.statusText:SetTextColor(offlineTextColor.r, offlineTextColor.g, offlineTextColor.b)
				parent.statusText:SetAlpha(offlineFadeAlpha)
			end
		end
		if deathStatus and deathStatus:IsActive(unit) then
			local _, cn = UnitClass(unit)
			if not canaccessvalue(cn) then cn = nil end
			local classColor = tp and tp.deadColorUseClassColor and cn and BF.classColors and BF.classColors[cn]
			local deadTextColor = classColor or (tp and tp.deadColor) or { r=0.8, g=0.1, b=0.1 }
			if parent.statusText then
				local st = parent.statusText
				st:SetTextColor(deadTextColor.r, deadTextColor.g, deadTextColor.b)
				-- Back in range: restore the configured outline, from the
				-- Layout cache (same rule as the out-of-range branch above).
				if st._cfgFontPath then
					st:SetFont(st._cfgFontPath, st._cfgFontSize, st._cfgFontFlags or "")
				end
			end
		end
	end
end

function RangeAlpha:GetFrame(parent)
	return parent[self.name]
end

BF:RegisterIndicator(RangeAlpha)
