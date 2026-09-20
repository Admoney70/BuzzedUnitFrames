-- oUF_BuzzardExport.lua
-- Shim: export oUF from the addon's private namespace into a global
-- that BuzzardFrames can read, since oUF deliberately refuses to set
-- _G["oUF"] when embedded inside another addon.
local _, ns = ...
_G["BuzzardFrames_oUF"] = ns.oUF
