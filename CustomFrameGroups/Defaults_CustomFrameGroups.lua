-- ============================================================
-- BuzzardFrames: Defaults_CustomFrameGroups.lua
-- Default values for the Custom Frame Groups module.
--
-- Grid2 pattern: RegisterNamespace creates a child database
-- stored in BuzzardFramesDB.namespaces.CustomFrameGroups.
-- Access via BF.cfgDB.profile.
--
-- Must be loaded before Core.lua (see .toc).
-- ============================================================
local BF = _G["BuzzardFrames"]

BF.customFrameGroupDefaults = {
    profile = {
        customFramesEnabled = true,
        -- customFrameGroups: array of group config tables, created dynamically.
        -- Each group has name, enabled, unit filter, layout settings, etc.
        customFrameGroups = {},
        -- customFrameGroupPositions: saved screen positions of detached CFG headers.
        -- Keyed by headerPosKey, value = { cfgLayoutAnchor, centerX, centerY }.
        customFrameGroupPositions = {},
    },
}
