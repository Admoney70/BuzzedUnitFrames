--[[
BuzzardFrames: Indicators/BuffOverlay.lua
Buff overlay — a colored solid or gradient overlaying the health bar
when tracked buffs are active. Style and fade direction come from the
per-spell Overlay Style / Gradient Direction options.

v67: this indicator now only OWNS the widget — it creates and lays out
`frame.buffOverlay`, and never renders into it itself. The live renderer
is BF:ShowSingleSpellPreview (AuraCustomizations/AuraCustomizations.lua),
which stamps color / style / gradient direction / fillOnly onto this
texture for the Aura Customizations single-spell preview.

Do NOT delete this file on the grounds that it has no :Update body — the
texture it creates is read by AuraCustomizations.lua, Auras/DummyAuras.lua,
Preview/Options_Preview.lua and Indicators/Container.lua.

v67 also removed the durationMap StatusBar path (BF.EnsureBuffOverlayBar
and everything that drove `frame.buffOverlayBar`). Its only caller was
BuffHighlight:Update, which was deleted with Indicators/BuffHighlight.lua
because the BuffMatch getters it read no longer exist. Nothing creates a
buffOverlayBar any more, so the surviving nil-guarded references to it
elsewhere are inert.
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- v67: local C_DurationUtil removed — its only reader was the durationMap
-- StatusBar's CreateDuration call in the deleted BF.EnsureBuffOverlayBar.

local BuffOverlay = BF.indicatorPrototype:new("buffOverlay")

-- v59: the fill file is chosen per Overlay Style / Gradient Direction by
-- BF.FxFillTexture (Indicators/BuffsAndContainers.lua) — the flat white
-- fill for Solid, or one of four alpha-ramp assets baked at the right
-- orientation for Gradient. This is just the neutral starting texture;
-- the update path swaps it. The _heightmap asset is no longer read.
local OVERLAY_FILL = "Interface\\Buttons\\WHITE8x8"

function BuffOverlay:Create(parent)
	if parent.buffOverlay then
		parent[self.name] = parent.buffOverlay
		return
	end

	local hBar = parent.healthBar
	if not hBar then return end

	local tex = BF.Texture(hBar, nil, "OVERLAY", nil, 1)
	tex:SetPoint("BOTTOMLEFT",  hBar, "BOTTOMLEFT",  0, 0)
	tex:SetPoint("BOTTOMRIGHT", hBar, "BOTTOMRIGHT", 0, 0)
	tex:SetHeight(hBar:GetHeight() * 0.5)
	tex:SetTexture(OVERLAY_FILL)
	tex:Hide()
	-- Rounded border style: clip to the frame's rounded shape (attach-once;
	-- inert while the mask is hidden).
	BF:AttachFrameRoundMask(parent, tex)

	parent[self.name] = tex
	parent.buffOverlay = tex
end

function BuffOverlay:Layout(parent)
	local tex = parent[self.name]
	if not tex then return end
	local hBar = parent.healthBar
	if not hBar then return end

	tex:ClearAllPoints()
	tex:SetPoint("BOTTOMLEFT",  hBar, "BOTTOMLEFT",  0, 0)
	tex:SetPoint("BOTTOMRIGHT", hBar, "BOTTOMRIGHT", 0, 0)
	tex:SetHeight(hBar:GetHeight() * 0.5)
	-- v67: the buffOverlayBar re-anchor was removed with the durationMap
	-- StatusBar path — nothing creates that widget any more.
end

-- v67: BuffOverlay:Update removed. It was an empty stub whose only comment
-- pointed at the deleted BuffHighlight:Update; indicatorPrototype:Update
-- (BFIndicator.lua:56-57) is already a no-op, so the framework dispatch
-- still resolves. Rendering into frame.buffOverlay is owned by
-- BF:ShowSingleSpellPreview.

function BuffOverlay:GetFrame(parent)
	return parent[self.name]
end

-- ============================================================
-- Hide helpers
-- ============================================================
-- v67: BF.EnsureBuffOverlayBar removed along with the durationMap
-- StatusBar path. Its only caller was BuffHighlight:Update.

-- Hide the overlay texture. NOTE: currently unreferenced — its only callers
-- were in the deleted BuffHighlight:Update. Kept as the natural public
-- counterpart to BF.HideBuffColorOverlay below, which the preview cleanup
-- paths in AuraCustomizations / DummyAuras / Options_Preview open-code.
function BF.HideBuffOverlay(parent)
	if parent.buffOverlay then parent.buffOverlay:Hide() end
end

-- BF.EnsureBuffColorOverlayBar was removed in v59 along with the health
-- color tint's "Map Height to Remaining Duration" option — the tint now
-- always covers the whole health fill, stamped with the bar's own texture,
-- so there is no height to drain and no StatusBar to drive.
-- v67: the buffColorOverlayBar clear was dropped too — nothing has created
-- that widget since v59, so the branch was permanently nil.
-- NOTE: currently unreferenced (its callers were in the deleted
-- BuffHighlight:Update); frame.buffColorOverlay itself is still live,
-- created and hidden directly by BF:ShowSingleSpellPreview.
function BF.HideBuffColorOverlay(parent)
	if parent.buffColorOverlay then parent.buffColorOverlay:Hide() end
end

BF:RegisterIndicator(BuffOverlay)